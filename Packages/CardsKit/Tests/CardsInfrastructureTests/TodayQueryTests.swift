import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct TodayFixture {
    let directory: TestDirectory
    let clock = TestClock(date: Date(timeIntervalSince1970: 1_792_368_000))
    let database: CollectionDatabase
    let writer: CollectionWriter
    let generation = UUID()
    let calendar = try! StudyDayCalculator(timeZoneID: "UTC")
    var queries: SQLiteCollectionQueries { SQLiteCollectionQueries(writer: writer, generation: generation) }
    init() throws {
        directory = try TestDirectory()
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("today.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic Today"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
    func deck(_ name: String = UUID().uuidString, parent: DeckID? = nil) async throws -> Deck {
        try await SQLiteDeckRepository(writer: writer).save(SaveDeckCommand(commandID: CommandID(),
            deckID: DeckID(), expectedRevision: nil, parentID: parent, name: EntityName(name)))
    }
    func card(_ deck: Deck) async throws -> Card {
        try await SQLiteNoteRepository(writer: writer, clock: clock).save(SaveNoteCommand(commandID: CommandID(),
            noteID: NoteID(), expectedRevision: nil, initialDeckID: deck.id,
            content: BasicNoteContent(front: "Synthetic question", back: "Synthetic answer"))).card
    }
    func today() async throws -> TodayStudySnapshot { try await queries.studyToday(asOf: clock.now(), calendar: calendar) }
    func session(_ configuration: StudyQueueConfiguration? = nil) async throws -> SQLiteStudySession {
        try await SQLiteStudySession.open(writer: writer,
            configuration: configuration ?? StudyQueueConfiguration(generation: generation, calendar: calendar), clock: clock)
    }
}

private enum TodayTestError: Error { case timeout, ended }
private func todayNext(_ source: QueryObservation<TodayStudySnapshot>) async throws -> TodayStudySnapshot {
    try await withThrowingTaskGroup(of: TodayStudySnapshot.self) { group in
        group.addTask {
            var iterator = source.makeAsyncIterator()
            guard let value = try await iterator.next() else { throw TodayTestError.ended }
            return value
        }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw TodayTestError.timeout }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Test func todayEmptyAndMoreThanOnePageOfDecksNeverCreateASession() async throws {
    let f = try TodayFixture()
    defer { try? f.database.close() }
    let empty = try await f.today()
    #expect(empty.decks.isEmpty && empty.counts.total == 0 && empty.resumableSessionID == nil)
    for index in 0..<102 { _ = try await f.deck("Synthetic \(index)") }
    let decks = try await f.today()
    #expect(decks.decks.count == 102 && decks.counts.total == 0)
    #expect(decks.emptyReasons.contains(.noCardsInScope))
    #expect(try await f.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM study_sessions") } == 0)
}

@Test func todayCountsMatchQueueLimitsAvailabilityAndPersistedScope() async throws {
    let f = try TodayFixture()
    defer { try? f.database.close() }
    let root = try await f.deck("Root"), child = try await f.deck("Child", parent: root.id), other = try await f.deck("Other")
    var cards: [Card] = []
    for _ in 0..<25 { cards.append(try await f.card(child)) }
    _ = try await f.card(other)
    let suspended = cards[0].id, buried = cards[1].id, review = cards[2].id, learning = cards[3].id
    let now = try EpochMilliseconds(date: f.clock.now()).rawValue
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE cards SET suspended=1 WHERE id=?", arguments: [ReviewSQL.key(suspended)])
        try db.execute(sql: "UPDATE cards SET buriedUntil=? WHERE id=?", arguments: [now + 60_000, ReviewSQL.key(buried)])
        try db.execute(sql: "UPDATE card_schedules SET phase='review', dueAt=? WHERE cardID=?", arguments: [now, ReviewSQL.key(review)])
        try db.execute(sql: "UPDATE card_schedules SET phase='learning', dueAt=? WHERE cardID=?", arguments: [now, ReviewSQL.key(learning)])
    }
    let initial = try await f.today()
    #expect(initial.counts == TodayQueueCounts(new: 20, due: 2))
    #expect(initial.decks.reduce(0) { $0 + $1.counts.total } == initial.counts.total)
    let config = try StudyQueueConfiguration(generation: f.generation, scope: .decks([root.id]), calendar: f.calendar,
        dailyLimits: StudyQueueLimits(new: 2, review: 0), deckLimits: [root.id: StudyQueueLimits(new: 1, review: 0)])
    let session = try await f.session(config)
    let current = try await f.today()
    let source = try await f.writer.read { try ReviewSQL.snapshot($0, generation: f.generation, sessionID: session.sessionID) }
    let queue = try QueueBuilder().build(source, configuration: config, now: f.clock.now())
    #expect(current.counts.new == queue.ready.filter { $0.schedule?.phase == .new }.count)
    #expect(current.counts == TodayQueueCounts(new: 1, due: 1)) // learning bypasses review quota
    #expect(current.decks.first { $0.id == other.id }?.counts.total == 0)
    #expect(current.resumableSessionID == session.sessionID)
    guard case .question(let question) = try await session.next(skipping: [], preferred: nil) else {
        Issue.record("Expected queue question"); return
    }
    #expect(question.cardID == queue.ready.first?.card.id)
    let skipped = Set(source.cards.map { $0.card.id })
    try await session.checkpoint(StudyCheckpoint(cardID: nil, phase: .summary, skipped: skipped))
    #expect(try await f.today().emptyReasons.contains(.skipped))
}

@Test func todayRatingUndoFutureDueRolloverAndReopenUseEffectiveHistory() async throws {
    let f = try TodayFixture()
    let deck = try await f.deck(), card = try await f.card(deck), session = try await f.session()
    guard case .question(let p) = try await session.next(skipping: [], preferred: nil) else { Issue.record("Missing question"); return }
    let command = StudyRatingCommand(cardID: p.cardID, expectedRevision: p.revision, grade: .again,
        occurredAt: f.clock.now(), scheduleEpoch: p.scheduleEpoch, durationMs: 2345)
    try await session.rate(command)
    let rated = try await f.today()
    #expect(rated.counts.total == 0 && rated.futureIsLearning && rated.nextAvailableAt! > f.clock.now())
    #expect(rated.ratings == 1 && rated.uniqueCards == 1 && rated.responseDurationMs == 2345)
    _ = try await session.undoRating(UndoRatingCommand(ratingID: command.id, sessionID: session.sessionID, occurredAt: f.clock.now()))
    let undone = try await f.today()
    #expect(undone.ratings == 0 && undone.uniqueCards == 0 && undone.responseDurationMs == 0 && undone.counts.new == 1)
    guard case .question(let fresh) = try await session.next(skipping: [], preferred: card.id) else { Issue.record("Missing question"); return }
    try await session.rate(StudyRatingCommand(cardID: fresh.cardID, expectedRevision: fresh.revision, grade: .again,
        occurredAt: f.clock.now(), scheduleEpoch: fresh.scheduleEpoch, durationMs: 1234))
    try await session.checkpoint(StudyCheckpoint(cardID: nil, phase: .summary))
    try await f.writer.close()
    let reopened = try CollectionDatabase(url: f.directory.url.appendingPathComponent("today.sqlite"))
    let writer = CollectionWriter(database: reopened, clock: f.clock), generation = UUID()
    let queries = SQLiteCollectionQueries(writer: writer, generation: generation)
    // A different current timezone must not replace the saved policy while resuming.
    let restored = try await queries.studyToday(asOf: f.clock.now(), calendar: StudyDayCalculator(timeZoneID: "Asia/Tokyo"))
    #expect(restored.generation == generation && restored.resumableSessionID == session.sessionID)
    #expect(restored.day.timeZoneID == "UTC" && restored.ratings == 1 && restored.counts.total == 0)
    let resumed = try await SQLiteStudySession.open(writer: writer,
        configuration: StudyQueueConfiguration(generation: generation, calendar: f.calendar), clock: f.clock)
    #expect(resumed.sessionID == session.sessionID)
    f.clock.advance(by: 61)
    let due = try await queries.studyToday(asOf: f.clock.now(), calendar: f.calendar)
    #expect(due.counts == TodayQueueCounts(new: 0, due: 1))
    guard case .question(let next) = try await resumed.next(skipping: [], preferred: nil) else { Issue.record("Missing due question"); return }
    #expect(next.cardID == card.id)
    try await resumed.finish(early: false)
    #expect(try await queries.studyToday(asOf: f.clock.now(), calendar: f.calendar).resumableSessionID == nil)
    let replacement = try await SQLiteStudySession.open(writer: writer,
        configuration: StudyQueueConfiguration(generation: generation, calendar: f.calendar), clock: f.clock)
    #expect(replacement.sessionID != session.sessionID)
    f.clock.advance(by: 86_400)
    #expect(try await queries.studyToday(asOf: f.clock.now(), calendar: f.calendar).ratings == 0)
    try await writer.close()
}

@Test func todayObservationUpdatesLibraryEditsRatingsVoidsAndSessionClosure() async throws {
    let f = try TodayFixture()
    defer { try? f.database.close() }
    let deck = try await f.deck(), card = try await f.card(deck)
    let source = try await f.queries.observeStudyToday(asOf: f.clock.now(), calendar: f.calendar)
    defer { source.cancel() }
    #expect(try await todayNext(source).counts.new == 1)
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE cards SET suspended=1 WHERE id=?", arguments: [ReviewSQL.key(card.id)])
    }
    #expect(try await todayNext(source).counts.total == 0)
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE cards SET suspended=0 WHERE id=?", arguments: [ReviewSQL.key(card.id)])
    }
    #expect(try await todayNext(source).counts.new == 1)
    _ = try await f.card(deck) // Library SaveNote uses the same committed observation.
    #expect(try await todayNext(source).counts.new == 2)
    let session = try await f.session()
    #expect(try await todayNext(source).resumableSessionID == session.sessionID)
    guard case .question(let p) = try await session.next(skipping: [], preferred: nil) else { Issue.record("Missing question"); return }
    let command = StudyRatingCommand(cardID: p.cardID, expectedRevision: p.revision, grade: .easy,
        occurredAt: f.clock.now(), scheduleEpoch: p.scheduleEpoch, durationMs: 321)
    try await session.rate(command)
    #expect(try await todayNext(source).ratings == 1)
    _ = try await session.undoRating(UndoRatingCommand(ratingID: command.id, sessionID: session.sessionID, occurredAt: f.clock.now()))
    let undone = try await todayNext(source)
    #expect(undone.ratings == 0 && undone.counts.new == 2)
    try await session.finish(early: true)
    #expect(try await todayNext(source).resumableSessionID == nil)
    // Log-only mutation must invalidate metrics even with no schedule change.
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE review_logs SET voidedBy=NULL WHERE commandID=?", arguments: [ReviewSQL.key(command.id)])
    }
    #expect(try await todayNext(source).ratings == 1)
    try await f.writer.close()
    await #expect(throws: CollectionRepositoryError.staleContext) { try await todayNext(source) }
}

@Test @MainActor func todayModelDistinguishesEmptyReadySkippedAndErrorAndRefreshesTime() async throws {
    let f = try TodayFixture()
    let model = TodayModel(workspace: TodayWorkspace(generation: f.generation, queries: f.queries), clock: f.clock)
    let task = Task { await model.observe() }
    defer { task.cancel(); model.stop() }
    func waitFor(_ check: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TodayTestError.timeout
    }
    #expect(model.snapshot == nil && !model.canOpenStudy)
    try await waitFor { model.contentState == .noDecks }
    let deck = try await f.deck()
    try await waitFor { model.contentState == .noCards }
    let card = try await f.card(deck)
    try await waitFor { model.contentState == .ready }
    #expect(model.canOpenStudy && model.actionTitle == "Начать занятие")
    let session = try await f.session()
    try await session.checkpoint(StudyCheckpoint(cardID: nil, phase: .summary, skipped: [card.id]))
    try await waitFor { model.contentState == .skipped }
    #expect(model.canOpenStudy && model.actionTitle == "Продолжить занятие")
    try await session.finish(early: true)
    try await waitFor { model.actionTitle == "Начать занятие" }
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE card_schedules SET phase='learning', dueAt=? WHERE cardID=?",
            arguments: [try ReviewSQL.ms(f.clock.now().addingTimeInterval(60)), ReviewSQL.key(card.id)])
    }
    try await waitFor { model.contentState == .futureLearning }
    #expect(!model.canOpenStudy)
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE card_schedules SET phase='review' WHERE cardID=?", arguments: [ReviewSQL.key(card.id)])
    }
    try await waitFor { model.contentState == .allDone }
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE card_schedules SET phase='learning' WHERE cardID=?", arguments: [ReviewSQL.key(card.id)])
    }
    try await waitFor { model.contentState == .futureLearning }
    f.clock.advance(by: 61)
    model.reload()
    let refreshed = Task { await model.observe() }
    defer { refreshed.cancel() }
    try await waitFor { model.contentState == .ready }
    #expect(model.snapshot?.counts.due == 1)
    try await f.writer.close()
    try await waitFor { model.errorMessage != nil }
    #expect(model.snapshot == nil && !model.canOpenStudy && model.contentState == nil)
}

@Test func todayDailyQuotaResetsAtRolloverAndDeletedParentsHideDescendants() async throws {
    let f = try TodayFixture()
    defer { try? f.database.close() }
    let root = try await f.deck(), child = try await f.deck(parent: root.id)
    for _ in 0..<3 { _ = try await f.card(child) }
    let config = try StudyQueueConfiguration(generation: f.generation, calendar: f.calendar,
        dailyLimits: StudyQueueLimits(new: 1, review: 1))
    let session = try await f.session(config)
    guard case .question(let p) = try await session.next(skipping: [], preferred: nil) else { Issue.record("Missing question"); return }
    try await session.rate(StudyRatingCommand(cardID: p.cardID, expectedRevision: p.revision, grade: .easy,
        occurredAt: f.clock.now(), scheduleEpoch: p.scheduleEpoch))
    let exhausted = try await f.today()
    #expect(exhausted.counts.total == 0 && exhausted.emptyReasons.contains(.dailyLimit))
    f.clock.advance(by: 86_400)
    let nextDay = try await f.today()
    #expect(nextDay.counts.new == 1 && nextDay.ratings == 0)
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE decks SET deletedAt=1 WHERE id=?", arguments: [ReviewSQL.key(root.id)])
    }
    let hidden = try await f.today()
    #expect(hidden.decks.isEmpty && hidden.counts.total == 0)
}
