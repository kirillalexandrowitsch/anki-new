import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct StatsFixture {
    let directory: TestDirectory
    let clock = TestClock(date: Date(timeIntervalSince1970: 1_792_368_000))
    let database: CollectionDatabase
    let writer: CollectionWriter
    let generation = UUID()
    let calendar = try! StudyDayCalculator(timeZoneID: "UTC")
    var queries: SQLiteCollectionQueries { SQLiteCollectionQueries(writer: writer, generation: generation) }
    init() throws {
        directory = try TestDirectory()
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("stats.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic Statistics"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
    func card() async throws -> Card {
        let deck = try await SQLiteDeckRepository(writer: writer).save(SaveDeckCommand(commandID: CommandID(),
            deckID: DeckID(), expectedRevision: nil, name: EntityName(UUID().uuidString)))
        return try await SQLiteNoteRepository(writer: writer, clock: clock).save(SaveNoteCommand(commandID: CommandID(),
            noteID: NoteID(), expectedRevision: nil, initialDeckID: deck.id,
            content: BasicNoteContent(front: "Synthetic question", back: "Synthetic answer"))).card
    }
    func session(calendar: StudyDayCalculator? = nil) async throws -> SQLiteStudySession {
        try await SQLiteStudySession.open(writer: writer,
            configuration: StudyQueueConfiguration(generation: generation, calendar: calendar ?? self.calendar), clock: clock)
    }
    func query(_ period: StatsPeriod = .week, asOf: Date? = nil, calendar: StudyDayCalculator? = nil) -> StatsQuery {
        StatsQuery(asOf: asOf ?? clock.now(), period: period, calendar: calendar ?? self.calendar)
    }
    func rate(_ session: SQLiteStudySession, card: Card, grade: Grade, duration: Int64) async throws -> StudyRatingCommand {
        guard case .question(let p) = try await session.next(skipping: [], preferred: card.id) else {
            throw CollectionRepositoryError.reviewUnavailable
        }
        #expect(p.cardID == card.id)
        let c = StudyRatingCommand(cardID: p.cardID, expectedRevision: p.revision, grade: grade,
            occurredAt: clock.now(), scheduleEpoch: p.scheduleEpoch, durationMs: duration)
        try await session.rate(c)
        return c
    }
}

@Test func statsManualLogMatchesEveryMetricAndUndoAcrossScreens() async throws {
    let f = try StatsFixture()
    defer { try? f.database.close() }
    let a = try await f.card(), b = try await f.card(), session = try await f.session()
    _ = try await f.rate(session, card: a, grade: .again, duration: 1000)
    _ = try await f.rate(session, card: b, grade: .hard, duration: 2000)
    f.clock.advance(by: 61)
    _ = try await f.rate(session, card: a, grade: .good, duration: 3000)
    f.clock.advance(by: 86_400)
    let last = try await f.rate(session, card: b, grade: .easy, duration: 4000)
    try await session.checkpoint(StudyCheckpoint(cardID: nil, phase: .summary, activeDurationMs: 12345))
    let snapshot = try await f.queries.statistics(f.query())
    #expect(snapshot.totals == StatsTotals(ratings: 4, uniqueCards: 2, grades: [1,1,1,1], responseDurationMs: 10_000))
    #expect(snapshot.totals.successRate == 0.75)
    #expect(snapshot.startedSessionActiveDurationMs == 12345)
    #expect(snapshot.days.count == 7 && snapshot.days.map(\.totals.ratings) == [0,0,0,0,0,3,1])
    #expect(snapshot.days.suffix(2).map(\.totals.uniqueCards) == [2,1]) // not additive across days
    #expect(snapshot.days.reduce(0) { $0 + $1.totals.responseDurationMs } == 10_000)
    #expect(try await session.progress().grades == snapshot.totals.grades)
    let today = try await f.queries.studyToday(asOf: f.clock.now(), calendar: f.calendar)
    #expect(today.ratings == 1 && today.uniqueCards == 1 && today.responseDurationMs == 4000)
    _ = try await session.undoRating(UndoRatingCommand(ratingID: last.id, sessionID: session.sessionID, occurredAt: f.clock.now()))
    let undone = try await f.queries.statistics(f.query())
    #expect(undone.totals == StatsTotals(ratings: 3, uniqueCards: 2, grades: [1,1,1,0], responseDurationMs: 6000))
    #expect(undone.totals.successRate == 2.0 / 3)
    #expect(undone.days.last?.totals.ratings == 0 && undone.days.last?.totals.successRate == nil)
    #expect(undone.startedSessionActiveDurationMs == 12345)
    #expect(try await session.progress().ratings == 3)
    #expect(try await f.queries.studyToday(asOf: f.clock.now(), calendar: f.calendar).ratings == 0)
    // Live state changes must not rewrite historical identities or remove history.
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE cards SET deckID=?, suspended=1 WHERE id=?", arguments: [ReviewSQL.key(b.deckID), ReviewSQL.key(a.id)])
        try db.execute(sql: "UPDATE decks SET deletedAt=1 WHERE id=?", arguments: [ReviewSQL.key(a.deckID)])
        try db.execute(sql: "UPDATE cards SET deletedAt=1 WHERE id=?", arguments: [ReviewSQL.key(a.id)])
    }
    #expect(try await f.queries.statistics(f.query()) == undone)
    // A session started before the period is deliberately excluded, even if rated inside it.
    f.clock.advance(by: 7 * 86_400)
    let later = try await f.queries.statistics(f.query())
    #expect(later.totals.ratings == 0 && later.startedSessionActiveDurationMs == 0)
}

@Test func statsEmptyVoidedOnlyAndReadOnlyPeriodsHaveNoInventedPercentages() async throws {
    let f = try StatsFixture()
    defer { try? f.database.close() }
    for period in StatsPeriod.allCases {
        let empty = try await f.queries.statistics(f.query(period))
        #expect(empty.days.count == period.rawValue)
        #expect(empty.totals.ratings == 0 && empty.totals.uniqueCards == 0 && empty.totals.successRate == nil)
        #expect(empty.totals.grades == [0,0,0,0] && empty.totals.responseDurationMs == 0 && empty.startedSessionActiveDurationMs == 0)
        #expect(empty.days.allSatisfy { $0.totals.successRate == nil })
    }
    #expect(try await f.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM study_sessions") } == 0)
    let card = try await f.card(), session = try await f.session()
    let c = try await f.rate(session, card: card, grade: .again, duration: 1500)
    #expect(try await f.queries.statistics(f.query()).totals.successRate == 0)
    _ = try await session.undoRating(UndoRatingCommand(ratingID: c.id, sessionID: session.sessionID, occurredAt: f.clock.now()))
    let empty = try await f.queries.statistics(f.query())
    #expect(empty.totals.ratings == 0 && empty.totals.successRate == nil && empty.days.allSatisfy { $0.totals.ratings == 0 })
}

@Test func statsSavedCalendarDSTHalfOpenBoundariesAndTimezones() async throws {
    let f = try StatsFixture()
    defer { try? f.database.close() }
    let iso = ISO8601DateFormatter()
    let instant = iso.date(from: "2026-03-08T12:00:00Z")!
    f.clock.advance(by: instant.timeIntervalSince(f.clock.now()))
    let calendar = try StudyDayCalculator(timeZoneID: "America/New_York")
    let card = try await f.card(), session = try await f.session(calendar: calendar)
    _ = try await f.rate(session, card: card, grade: .easy, duration: 1000)
    let initial = try await f.queries.statistics(f.query(calendar: f.calendar))
    #expect(initial.days.last?.day.timeZoneID == "America/New_York")
    #expect(initial.days[5].day.end.timeIntervalSince(initial.days[5].day.start) == 23 * 3600)
    #expect(initial.totals.ratings == 1 && initial.totals.successRate == 1)
    let first = initial.days[0].day
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE review_logs SET studyDayKey=?, ratedAt=?", arguments: [first.key.rawValue, ReviewSQL.ms(first.start)])
    }
    #expect(try await f.queries.statistics(f.query()).days.first?.totals.ratings == 1)
    let before = try calendar.studyDay(containing: first.start.addingTimeInterval(-0.001))
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE review_logs SET studyDayKey=?, ratedAt=?", arguments: [before.key.rawValue, ReviewSQL.ms(first.start.addingTimeInterval(-0.001))])
    }
    #expect(try await f.queries.statistics(f.query()).totals.ratings == 0)
    let end = initial.days.last!.day.end
    let after = try calendar.studyDay(containing: end)
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE review_logs SET studyDayKey=?, ratedAt=?", arguments: [after.key.rawValue, ReviewSQL.ms(end)])
    }
    #expect(try await f.queries.statistics(f.query()).totals.ratings == 0)
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE review_logs SET studyDayKey=?, timezoneID='Asia/Tokyo'", arguments: [first.key.rawValue])
    }
    #expect(try await f.queries.statistics(f.query()).totals.ratings == 0)
}

private enum StatsTestError: Error { case timeout, ended }
private func statsNext(_ source: QueryObservation<StatsSnapshot>) async throws -> StatsSnapshot {
    try await withThrowingTaskGroup(of: StatsSnapshot.self) { group in
        group.addTask {
            var iterator = source.makeAsyncIterator()
            guard let value = try await iterator.next() else { throw StatsTestError.ended }
            return value
        }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw StatsTestError.timeout }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Test func statsObservationRefreshesRatingUndoDurationAndRejectsClosedGeneration() async throws {
    let f = try StatsFixture()
    let card = try await f.card(), session = try await f.session()
    let source = try await f.queries.observeStatistics(f.query())
    defer { source.cancel() }
    #expect(try await statsNext(source).totals.ratings == 0)
    let c = try await f.rate(session, card: card, grade: .good, duration: 500)
    #expect(try await statsNext(source).totals.ratings == 1)
    try await session.checkpoint(StudyCheckpoint(cardID: nil, phase: .summary, activeDurationMs: 2400))
    #expect(try await statsNext(source).startedSessionActiveDurationMs == 2400)
    _ = try await session.undoRating(UndoRatingCommand(ratingID: c.id, sessionID: session.sessionID, occurredAt: f.clock.now()))
    let undone = try await statsNext(source)
    #expect(undone.totals.ratings == 0 && undone.totals.uniqueCards == 0 && undone.totals.successRate == nil)
    #expect(undone.totals.grades == [0,0,0,0] && undone.totals.responseDurationMs == 0 && undone.startedSessionActiveDurationMs == 2400)
    try await f.writer.close()
    await #expect(throws: CollectionRepositoryError.staleContext) { try await statsNext(source) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await f.queries.statistics(f.query()) }
    let reopened = try CollectionDatabase(url: f.directory.url.appendingPathComponent("stats.sqlite"))
    let writer = CollectionWriter(database: reopened, clock: f.clock)
    let generation = UUID()
    let restored = try await SQLiteCollectionQueries(writer: writer, generation: generation).statistics(f.query())
    #expect(restored.generation == generation && restored.totals == undone.totals && restored.startedSessionActiveDurationMs == 2400)
    try await writer.close()
}

@Test @MainActor func statsModelSeparatesLoadingEmptyErrorAndPeriodRefresh() async throws {
    let f = try StatsFixture()
    let model = StatisticsModel(workspace: StatsWorkspace(generation: f.generation, queries: f.queries), clock: f.clock)
    #expect(model.snapshot == nil && model.errorMessage == nil)
    func waitFor(_ check: @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if check() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw StatsTestError.timeout
    }
    let task = Task { await model.observe() }
    defer { task.cancel(); model.stop() }
    try await waitFor { model.snapshot?.days.count == 30 }
    #expect(model.snapshot?.totals.successRate == nil && model.errorMessage == nil)
    model.period = .week
    #expect(model.snapshot == nil)
    let refreshed = Task { await model.observe() }
    defer { refreshed.cancel() }
    try await waitFor { model.snapshot?.days.count == 7 }
    f.clock.advance(by: 86_400)
    let old = model.snapshot?.days.last?.day.key
    model.reload()
    let nextDay = Task { await model.observe() }
    defer { nextDay.cancel() }
    try await waitFor { model.snapshot?.days.last?.day.key != old }
    try await f.writer.close()
    try await waitFor { model.errorMessage != nil }
    #expect(model.snapshot == nil)
    model.stop()
    model.reload()
    await model.observe()
    #expect(model.snapshot == nil)
}
