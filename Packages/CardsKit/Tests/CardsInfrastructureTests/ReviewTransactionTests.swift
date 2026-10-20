import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct ReviewFixture {
    let directory: TestDirectory
    let clock = TestClock(date: Date(timeIntervalSince1970: 1_792_368_000.123456))
    let database: CollectionDatabase
    let writer: CollectionWriter
    let generation = UUID()
    init() throws {
        directory = try TestDirectory()
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("reviews.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
    func card() async throws -> Card {
        let deck = try await SQLiteDeckRepository(writer: writer).save(SaveDeckCommand(commandID: CommandID(),
            deckID: DeckID(), expectedRevision: nil, name: EntityName(UUID().uuidString)))
        return try await SQLiteNoteRepository(writer: writer, clock: clock).save(SaveNoteCommand(commandID: CommandID(),
            noteID: NoteID(), expectedRevision: nil, initialDeckID: deck.id,
            content: BasicNoteContent(front: "Synthetic question", back: "Synthetic answer"))).card
    }
    func session(limit: Int = 20) async throws -> SQLiteStudySession {
        try await SQLiteStudySession.open(writer: writer,
            configuration: StudyQueueConfiguration(generation: generation, calendar: StudyDayCalculator(timeZoneID: "UTC"),
                dailyLimits: StudyQueueLimits(new: limit, review: limit)), clock: clock)
    }
    func command(_ session: SQLiteStudySession, grade: Grade = .good, id: CommandID = CommandID()) async throws -> RateCardCommand {
        guard case .question(let p) = try await session.next(skipping: [], preferred: nil) else {
            throw CollectionRepositoryError.reviewUnavailable
        }
        return RateCardCommand(sessionID: session.sessionID, rating: StudyRatingCommand(id: id, cardID: p.cardID,
            expectedRevision: p.revision, grade: grade, occurredAt: clock.now(), scheduleEpoch: p.scheduleEpoch,
            durationMs: 1234, seed: 900))
    }
    func state() async throws -> [String] {
        try await database.pool.read { db in
            try ["card_schedules", "review_logs", "domain_events", "processed_commands", "study_sessions", "session_items"].map { table in
                try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { row in
                    row.columnNames.map { "\($0)=\(row[$0] as DatabaseValue)" }.joined(separator: "|")
                }.joined(separator: "\n")
            }
        }
    }
}

@Test func reviewConcurrentDoubleSubmissionReplaysOneDurableReceipt() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    _ = try await f.card()
    let s = try await f.session(), c = try await f.command(s)
    let receipts = try await withThrowingTaskGroup(of: ReviewReceipt.self) { group in
        for _ in 0..<16 { group.addTask { try await s.reviews.rateCard(c) } }
        var results = [ReviewReceipt]()
        for try await result in group { results.append(result) }
        return results
    }
    let receipt = try #require(receipts.first)
    #expect(receipts.count == 16 && receipts.allSatisfy { $0 == receipt })
    #expect(receipt.scheduling.after.revision == (try Revision(1)))
    #expect(receipt.scheduling.metadata.seed == 900 && receipt.scheduling.metadata.grade == .good)
    #expect(try await s.reviews.effectiveStatistics() == EffectiveReviewStatistics(ratings: 1, uniqueCards: 1, durationMs: 1234))
    let stable = try await f.state()
    let different = RateCardCommand(sessionID: s.sessionID, rating: StudyRatingCommand(id: c.rating.id,
        cardID: c.rating.cardID, expectedRevision: .initial, grade: .easy, occurredAt: c.rating.occurredAt))
    await #expect(throws: CollectionRepositoryError.commandIDReused) { try await s.reviews.rateCard(different) }
    #expect(try await f.state() == stable)
    try await f.database.checkIntegrity()
}

@Test func reviewFailureBeforeCommitRollsBackEveryTableAndRetrySucceeds() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    _ = try await f.card()
    let s = try await f.session(), c = try await f.command(s)
    let before = try await f.state()
    var broken = s.reviews
    broken.fault = { if $0 == .beforeCommit { throw InjectedFault.triggered } }
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await broken.rateCard(c) }
    #expect(try await f.state() == before)
    // Fail the final command journal insert as well: even all earlier writes must roll back.
    try await f.database.pool.write { try $0.execute(sql: """
        CREATE TRIGGER fail_review_journal BEFORE INSERT ON processed_commands
        BEGIN SELECT RAISE(ABORT,'synthetic fault'); END;
        """) }
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await s.reviews.rateCard(c) }
    #expect(try await f.state() == before)
    try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_review_journal") }
    _ = try await s.reviews.rateCard(c)
    #expect(try await s.reviews.effectiveStatistics().ratings == 1)
}

@Test func reviewLostAcknowledgementReopenReturnsSavedResultWithoutAdvancingAgain() async throws {
    let f = try ReviewFixture()
    _ = try await f.card()
    let s = try await f.session(), c = try await f.command(s)
    var lost = s.reviews
    lost.fault = { if $0 == .afterCommit { throw InjectedFault.triggered } }
    await #expect(throws: InjectedFault.triggered) { try await lost.rateCard(c) }
    let committed = try await f.state()
    try await f.writer.close()
    let reopened = try CollectionDatabase(url: f.directory.url.appendingPathComponent("reviews.sqlite"))
    let writer = CollectionWriter(database: reopened, clock: f.clock)
    let resumed = try await SQLiteStudySession.open(writer: writer,
        configuration: s.reviews.configuration, clock: f.clock)
    #expect(resumed.sessionID == s.sessionID)
    let receipt = try await resumed.reviews.rateCard(c)
    #expect(receipt.command == c && receipt.scheduling.after.repetitions == 1)
    #expect(try await resumed.reviews.effectiveStatistics().ratings == 1)
    let actual = try await reopened.pool.read { db in try ReviewSQL.schedule(db, cardID: c.rating.cardID) }
    #expect(actual == receipt.scheduling.after)
    #expect(committed[3].contains(ReviewSQL.key(c.rating.id)))
    try await writer.close()
}

@Test func reviewDistinctCommandsRaceAndStaleRevisionCannotWrite() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    _ = try await f.card()
    let s = try await f.session(), c = try await f.command(s)
    let wins = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<12 {
            group.addTask {
                let command = RateCardCommand(sessionID: s.sessionID, rating: StudyRatingCommand(cardID: c.rating.cardID,
                    expectedRevision: .initial, grade: .easy, occurredAt: c.rating.occurredAt))
                do { _ = try await s.reviews.rateCard(command); return true } catch { return false }
            }
        }
        var count = 0
        for await win in group { if win { count += 1 } }
        return count
    }
    #expect(wins == 1)
    #expect(try await s.reviews.effectiveStatistics().ratings == 1)
    let stable = try await f.state()
    await #expect(throws: CollectionRepositoryError.self) { try await s.reviews.rateCard(c) }
    #expect(try await f.state() == stable)
}

@Test func reviewUndoRestoresScheduleWithFreshRevisionVoidsHistoryAndReleasesQuota() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    let first = try await f.card(), second = try await f.card()
    let s = try await f.session(limit: 1), c = try await f.command(s, grade: .easy)
    let receipt = try await s.reviews.rateCard(c)
    guard case .completed = try await s.next(skipping: [], preferred: nil) else { Issue.record("Quota must be exhausted"); return }
    let undo = UndoRatingCommand(ratingID: c.rating.id, sessionID: s.sessionID, occurredAt: f.clock.now())
    let restored = try await s.undoRating(undo)
    #expect(restored.restored.phase == .new && restored.restored.stability == nil && restored.restored.repetitions == 0)
    #expect(restored.restored.revision == (try Revision(2)))
    #expect(restored.presentation.cardID == c.rating.cardID && restored.presentation.revision == restored.restored.revision)
    #expect(try await s.reviews.effectiveStatistics() == EffectiveReviewStatistics(ratings: 0, uniqueCards: 0, durationMs: 0))
    let stable = try await f.state()
    #expect(try await s.undoRating(undo) == restored)
    #expect(try await s.reviews.rateCard(c) == receipt) // historical replay never reapplies a voided rating
    #expect(try await f.state() == stable)
    let other = c.rating.cardID == first.id ? second.id : first.id
    guard case .question(let next) = try await s.next(skipping: [c.rating.cardID], preferred: other) else {
        Issue.record("Undo must release the daily unique quota"); return
    }
    #expect(next.cardID == other)
    #expect(try await f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM review_logs WHERE voidedBy IS NOT NULL") } == 1)
    #expect(try await f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM domain_events WHERE type='review.undone'") } == 1)
    try await f.database.checkIntegrity()
}

@Test func reviewUndoRejectsLaterScheduleMutationAndLaterRating() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    _ = try await f.card(); _ = try await f.card()
    let s = try await f.session(), c = try await f.command(s, grade: .easy)
    _ = try await s.reviews.rateCard(c)
    let undo = UndoRatingCommand(ratingID: c.rating.id, sessionID: s.sessionID, occurredAt: f.clock.now())
    let other = try await f.command(s, grade: .easy)
    _ = try await s.reviews.rateCard(other)
    let stable = try await f.state()
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await s.undoRating(undo) }
    #expect(try await f.state() == stable)
    let undoOther = UndoRatingCommand(ratingID: other.rating.id, sessionID: s.sessionID, occurredAt: f.clock.now())
    try await f.database.pool.write { try $0.execute(sql: "UPDATE card_schedules SET revision=revision+1, scheduleEpoch=scheduleEpoch+1 WHERE cardID=?",
        arguments: [ReviewSQL.key(other.rating.cardID)]) }
    let changed = try await f.state()
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await s.undoRating(undoOther) }
    #expect(try await f.state() == changed)
    #expect(try await s.reviews.effectiveStatistics().ratings == 2)
}

@Test func reviewUndoFailureIsAtomicAndLostAcknowledgementReplaysCompensation() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    _ = try await f.card()
    let s = try await f.session(), c = try await f.command(s)
    _ = try await s.reviews.rateCard(c)
    let undo = UndoRatingCommand(ratingID: c.rating.id, sessionID: s.sessionID, occurredAt: f.clock.now())
    let before = try await f.state()
    var broken = s.reviews
    broken.fault = { if $0 == .beforeCommit { throw InjectedFault.triggered } }
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await broken.undoRating(undo) }
    #expect(try await f.state() == before)
    broken.fault = { if $0 == .afterCommit { throw InjectedFault.triggered } }
    await #expect(throws: InjectedFault.triggered) { try await broken.undoRating(undo) }
    let committed = try await f.state()
    let result = try await s.undoRating(undo)
    #expect(result.restored.revision == (try Revision(2)))
    #expect(try await f.state() == committed)
    #expect(try await s.reviews.effectiveStatistics().ratings == 0)
}

@Test @MainActor func reviewRealServiceScreenUndoReturnsRevealedCardAndCanRateAgain() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    _ = try await f.card(); _ = try await f.card()
    let s = try await f.session()
    let model = StudySessionModel(service: s, clock: f.clock)
    await model.load(); model.reveal()
    let original = model.presentation
    await model.rate(.easy)
    #expect(model.phase == .question && model.confirmedRatings == 1 && model.canUndoRating)
    await model.undoRating()
    #expect(model.phase == .answer && model.presentation?.cardID == original?.cardID && model.canRate)
    #expect(model.confirmedRatings == 0 && model.reviewMessage != nil && !model.canUndoRating)
    await model.rate(.good)
    #expect(model.confirmedRatings == 1 && model.phase == .question)
    #expect(try await s.reviews.effectiveStatistics().ratings == 1)
}

// A real child exits without unwinding: SQLite must recover an open transaction/WAL itself.
import XCTest
import Darwin

final class ReviewCrashProcessTests: XCTestCase {
    func testWorker() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["REVIEW_CRASH_DIRECTORY"], let point = env["REVIEW_CRASH_POINT"] else { return }
        let root = URL(fileURLWithPath: path)
        let command = try JSONDecoder().decode(RateCardCommand.self, from: Data(contentsOf: root.appendingPathComponent("command.json")))
        let database = try CollectionDatabase(url: root.appendingPathComponent("reviews.sqlite"))
        let clock = TestClock(date: command.rating.occurredAt)
        let writer = CollectionWriter(database: database, clock: clock)
        let configuration = try StudyQueueConfiguration(generation: UUID(), calendar: StudyDayCalculator(timeZoneID: "UTC"))
        let session = try await SQLiteStudySession.open(writer: writer, configuration: configuration, clock: clock)
        var repository = session.reviews
        repository.fault = { checkpoint in
            if (point == "before" && checkpoint == .beforeCommit) || (point == "after" && checkpoint == .afterCommit) { _exit(86) }
        }
        _ = try await repository.rateCard(command)
        XCTFail("Crash checkpoint was not reached")
    }
}

@Test(arguments: ["before", "after"])
func reviewProcessDeathRecoversAtomicCommitAndCommandReplay(point: String) async throws {
    let f = try ReviewFixture()
    _ = try await f.card()
    let session = try await f.session(), command = try await f.command(session)
    try JSONEncoder().encode(command).write(to: f.directory.url.appendingPathComponent("command.json"))
    try await f.writer.close()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["xctest", "-XCTest", "CardsInfrastructureTests.ReviewCrashProcessTests/testWorker",
        Bundle(for: ReviewCrashProcessTests.self).bundleURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["REVIEW_CRASH_DIRECTORY"] = f.directory.url.path
    environment["REVIEW_CRASH_POINT"] = point
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    if process.isRunning { process.terminate(); Issue.record("Crash worker timeout") }
    process.waitUntilExit()
    #expect(process.terminationStatus == 86)
    let reopened = try CollectionDatabase(url: f.directory.url.appendingPathComponent("reviews.sqlite"))
    let writer = CollectionWriter(database: reopened, clock: f.clock)
    let resumed = try await SQLiteStudySession.open(writer: writer, configuration: session.reviews.configuration, clock: f.clock)
    let prior = try await resumed.reviews.effectiveStatistics()
    #expect(prior.ratings == (point == "after" ? 1 : 0))
    let persisted = try await reopened.pool.read { db in
        let s = try ReviewSQL.schedule(db, cardID: command.rating.cardID)
        let journals = try Int.fetchOne(db, sql: "SELECT count(*) FROM processed_commands WHERE commandID=?",
            arguments: [ReviewSQL.key(command.rating.id)])!
        let stage = try String.fetchOne(db, sql: "SELECT stage FROM session_items WHERE sessionID=?",
            arguments: [ReviewSQL.key(command.sessionID)])!
        return (s.revision.rawValue, journals, stage)
    }
    #expect(persisted.0 == (point == "after" ? 1 : 0))
    #expect(persisted.1 == (point == "after" ? 1 : 0))
    #expect(persisted.2 == (point == "after" ? "rated" : "question"))
    _ = try await resumed.reviews.rateCard(command)
    #expect(try await resumed.reviews.effectiveStatistics().ratings == 1)
    try await reopened.checkIntegrity()
    try await writer.close()
}

@Test func reviewRevisionEpochAvailabilityAndDurationAreCheckedBeforeAnyWrite() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    _ = try await f.card()
    let s = try await f.session(), c = try await f.command(s)
    try await f.database.pool.write { try $0.execute(sql: "UPDATE card_schedules SET revision=1") }
    let changed = try await f.state()
    await #expect(throws: CollectionRepositoryError.revisionConflict(entity: .card(c.rating.cardID), expected: .initial, actual: try Revision(1))) {
        try await s.reviews.rateCard(c)
    }
    #expect(try await f.state() == changed)
    try await f.database.pool.write { try $0.execute(sql: "UPDATE card_schedules SET revision=0, scheduleEpoch=1") }
    let epochChanged = try await f.state()
    await #expect(throws: CollectionRepositoryError.reviewUnavailable) { try await s.reviews.rateCard(c) }
    #expect(try await f.state() == epochChanged)
    try await f.database.pool.write { try $0.execute(sql: "UPDATE card_schedules SET scheduleEpoch=0; UPDATE cards SET suspended=1") }
    let suspended = try await f.state()
    await #expect(throws: CollectionRepositoryError.reviewUnavailable) { try await s.reviews.rateCard(c) }
    #expect(try await f.state() == suspended)
    try await f.database.pool.write { try $0.execute(sql: "UPDATE cards SET suspended=0") }
    let badDuration = RateCardCommand(sessionID: s.sessionID, rating: StudyRatingCommand(cardID: c.rating.cardID,
        expectedRevision: .initial, grade: .good, occurredAt: f.clock.now(), durationMs: 60_001))
    await #expect(throws: CollectionRepositoryError.validation(.outOfRange(field: "durationMs"))) { try await s.reviews.rateCard(badDuration) }
    try await f.writer.close()
    await #expect(throws: CollectionRepositoryError.staleContext) { try await s.reviews.rateCard(c) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await s.next(skipping: [], preferred: nil) }
}

private actor LostUndoService: StudyReviewSessionService {
    nonisolated let sessionID: SessionID
    let wrapped: SQLiteStudySession
    var commands = [UndoRatingCommand]()
    init(_ session: SQLiteStudySession) { wrapped = session; sessionID = session.sessionID }
    func next(skipping: Set<CardID>, preferred: CardID?) async throws -> StudyNext { try await wrapped.next(skipping: skipping, preferred: preferred) }
    func rate(_ command: StudyRatingCommand) async throws { try await wrapped.rate(command) }
    func undoRating(_ command: UndoRatingCommand) async throws -> ReviewUndoResult {
        commands.append(command)
        let result = try await wrapped.undoRating(command)
        if commands.count == 1 { throw InjectedFault.triggered }
        return result
    }
    func submitted() -> [UndoRatingCommand] { commands }
}

@Test @MainActor func reviewScreenRetriesSameUndoIdentityAfterLostAcknowledgement() async throws {
    let f = try ReviewFixture()
    defer { try? f.database.close() }
    _ = try await f.card(); _ = try await f.card()
    let s = try await f.session(), lost = LostUndoService(s)
    let model = StudySessionModel(service: lost, clock: f.clock)
    await model.load(); model.reveal(); await model.rate(.easy)
    await model.undoRating()
    let pending = try #require(model.pendingUndo)
    #expect(model.errorMessage != nil && !model.canRate && model.canUndoRating && model.confirmedRatings == 1)
    await model.rate(.good); await model.skip()
    f.clock.advance(by: 2)
    await model.undoRating()
    #expect(await lost.submitted() == [pending, pending])
    #expect(model.phase == .answer && model.canRate && model.pendingUndo == nil && model.confirmedRatings == 0)
    #expect(try await s.reviews.effectiveStatistics().ratings == 0)
}
