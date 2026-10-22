import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private final class FakeDeletionTime: DeletionTime {
    private let lock = NSLock()
    private nonisolated(unsafe) var seconds: Double = 100
    private nonisolated(unsafe) var boot = "synthetic-boot"
    func now() -> DeletionInstant { lock.withLock { DeletionInstant(bootID: boot, seconds: seconds) } }
    func advance(_ value: Double) { lock.withLock { seconds += value } }
    func reboot() { lock.withLock { boot = "another-boot"; seconds = 1 } }
}

private struct DeletionFixture {
    let directory: TestDirectory
    let clock = TestClock()
    let time = FakeDeletionTime()
    let database: CollectionDatabase
    let writer: CollectionWriter
    let generation = UUID()
    var service: SQLiteCardDeletion { SQLiteCardDeletion(writer: writer, clock: clock, time: time) }
    var notes: SQLiteNoteRepository { SQLiteNoteRepository(writer: writer, clock: clock) }
    var queries: SQLiteCollectionQueries { SQLiteCollectionQueries(writer: writer, generation: generation) }
    init() throws {
        directory = try TestDirectory()
        for name in ["Staging", "Media", "Trash"] {
            try FileManager.default.createDirectory(at: directory.url.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("deletion.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic deletion"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
    func note(media: [NoteMediaReference] = []) async throws -> SavedBasicNote {
        let deck = try await SQLiteDeckRepository(writer: writer).save(SaveDeckCommand(commandID: CommandID(),
            deckID: DeckID(), expectedRevision: nil, name: EntityName(UUID().uuidString)))
        return try await notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(), expectedRevision: nil,
            initialDeckID: deck.id, content: BasicNoteContent(front: "Synthetic deletion", back: "Answer", media: media), tags: ["Shared tag"]))
    }
    func rows(_ tables: [String]) async throws -> [String] {
        try await database.pool.read { db in
            try tables.map { table in
                try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map { row in
                    row.columnNames.map { "\($0)=\(row[$0] as DatabaseValue)" }.joined(separator: "|")
                }.joined(separator: "\n")
            }
        }
    }
    func session() async throws -> SQLiteStudySession {
        try await SQLiteStudySession.open(writer: writer,
            configuration: StudyQueueConfiguration(generation: generation, calendar: StudyDayCalculator(timeZoneID: "UTC")), clock: clock)
    }
}

@Test @MainActor func deletionCancelIsReadOnlyAndUndoRestoresFullProgressAfterLateNoteSave() async throws {
    let f = try DeletionFixture()
    defer { try? f.database.close() }
    let note = try await f.note()
    let session = try await f.session()
    guard case .question(let question) = try await session.next(skipping: [], preferred: nil) else { Issue.record("Missing question"); return }
    try await session.rate(StudyRatingCommand(cardID: question.cardID, expectedRevision: question.revision,
        grade: .good, occurredAt: f.clock.now(), scheduleEpoch: question.scheduleEpoch, durationMs: 1234))
    let scheduleAndHistory = try await f.rows(["card_schedules", "review_logs", "study_sessions", "session_items"])
    let allTables = ["cards", "notes", "card_schedules", "review_logs", "deletion_batches", "domain_events", "processed_commands", "note_media", "note_tags"]
    let beforeCancel = try await f.rows(allTables)
    let model = CardDeletionModel(service: f.service)
    await model.prepare(cardID: note.card.id)
    #expect(model.target?.noteID == note.note.id && model.target?.otherCardCount == 0)
    model.cancel()
    #expect(!model.isPresented && model.target == nil)
    #expect(try await f.rows(allTables) == beforeCancel)
    await model.prepare(cardID: note.card.id); await model.confirm()
    #expect(!model.isPresented && model.pending.count == 1)
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 0)
    #expect(try await f.rows(["card_schedules", "review_logs", "study_sessions", "session_items"]) == scheduleAndHistory)
    let edited = try await f.notes.save(SaveNoteCommand(commandID: CommandID(), noteID: note.note.id,
        expectedRevision: note.note.revision, initialDeckID: note.card.deckID,
        content: BasicNoteContent(front: "Late draft saved", back: "New answer")))
    #expect(edited.card.id == note.card.id && edited.card.generationState == .suppressed && edited.card.deletedAt != nil)
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 0)
    f.clock.advance(by: 30 * 86_400) // wall time cannot consume or extend the monotonic window
    f.time.advance(4.999)
    await model.undo(batchID: try #require(model.pending.first).id)
    #expect(model.pending.isEmpty && model.undoError == nil)
    let restored = try #require(await f.notes.note(id: note.note.id))
    #expect(restored.card.id == note.card.id && restored.card.generationState == .active && restored.card.deletedAt == nil)
    #expect(restored.card.revision == (try Revision(2)))
    #expect(restored.content.front == "Late draft saved")
    #expect(try await f.rows(["card_schedules", "review_logs", "study_sessions", "session_items"]) == scheduleAndHistory)
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 1)
    #expect(try await session.progress().ratings == 1)
    try await f.database.checkIntegrity()
}

@Test func deletionSuppressesOnlySelectedVariantAndRejectsStaleQueueRating() async throws {
    let f = try DeletionFixture()
    defer { try? f.database.close() }
    let note = try await f.note(), sibling = CardID()
    try await f.database.pool.write { db in
        try db.execute(sql: "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES (?,?,?,'synthetic.reverse','synthetic.reverse',0)",
            arguments: [ReviewSQL.key(sibling), ReviewSQL.key(note.note.id), ReviewSQL.key(note.card.deckID)])
        try db.execute(sql: "INSERT INTO card_schedules(cardID,algorithmID,algorithmVersion,parameterSetID,phase) SELECT ?,algorithmID,algorithmVersion,parameterSetID,phase FROM card_schedules WHERE cardID=?",
            arguments: [ReviewSQL.key(sibling), ReviewSQL.key(note.card.id)])
    }
    let session = try await f.session()
    guard case .question(let p) = try await session.next(skipping: [], preferred: nil) else { Issue.record("Missing question"); return }
    let siblingBefore = try await f.database.pool.read { try String.fetchOne($0, sql: "SELECT json_object('revision',revision,'deletedAt',deletedAt,'state',generationState) FROM cards WHERE id=?", arguments: [ReviewSQL.key(sibling)]) }
    let target = try await f.service.target(cardID: note.card.id)
    #expect(target.otherCardCount == 1)
    let receipt = try await f.service.delete(DeleteCardCommand(target: target))
    let rows = try await f.queries.library(LibraryQuery())
    #expect(rows.cardCount == 1 && rows.noteCount == 1 && rows.rows.first?.id == sibling)
    #expect(try await f.queries.studyToday(asOf: f.clock.now(), calendar: StudyDayCalculator(timeZoneID: "UTC")).counts.total == 0)
    #expect(try await session.next(skipping: [], preferred: p.cardID) == .completed(.noCards))
    await #expect(throws: CollectionRepositoryError.reviewUnavailable) {
        try await session.rate(StudyRatingCommand(cardID: p.cardID, expectedRevision: p.revision,
            grade: .easy, occurredAt: f.clock.now(), scheduleEpoch: p.scheduleEpoch))
    }
    _ = try await f.service.undo(UndoCardDeletionCommand(batchID: receipt.batchID))
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 2)
    let siblingAfter = try await f.database.pool.read { try String.fetchOne($0, sql: "SELECT json_object('revision',revision,'deletedAt',deletedAt,'state',generationState) FROM cards WHERE id=?", arguments: [ReviewSQL.key(sibling)]) }
    #expect(siblingAfter == siblingBefore)
    guard case .question(let restored) = try await session.next(skipping: [], preferred: p.cardID) else { Issue.record("Missing restored question"); return }
    #expect(restored.cardID == p.cardID && restored.revision == p.revision)
}

@Test func deletionReopenKeepsOnlyRemainingWindowAndRetainsSharedMediaAtTimeoutAndReboot() async throws {
    let f = try DeletionFixture()
    let media = CollectionMediaRepository(root: f.directory.url, writer: f.writer)
    let asset = try await media.importFile(SyntheticSeed.directory.appendingPathComponent("pixel.png"))
    let note = try await f.note(media: [NoteMediaReference(mediaID: asset.id, fieldID: "image", role: .image)])
    _ = try await f.note(media: [NoteMediaReference(mediaID: asset.id, fieldID: "image", role: .image)])
    let target = try await f.service.target(cardID: note.card.id)
    let command = DeleteCardCommand(target: target)
    let receipt = try await f.service.delete(command)
    f.time.advance(2)
    try await f.writer.close()
    let db = try CollectionDatabase(url: f.directory.url.appendingPathComponent("deletion.sqlite"))
    try MediaJournal.recover(pool: db.pool, root: f.directory.url)
    let writer = CollectionWriter(database: db, clock: f.clock)
    let service = SQLiteCardDeletion(writer: writer, clock: f.clock, time: f.time)
    let reopenedMedia = CollectionMediaRepository(root: f.directory.url, writer: writer)
    let pending = try #require(await service.pendingUndo().first)
    #expect(pending.id == receipt.batchID && pending.remainingSeconds == 3)
    #expect(try await service.delete(command) == receipt) // lost delete acknowledgement, no fresh deadline
    #expect(try await service.pendingUndo().first?.remainingSeconds == 3)
    #expect(try await reopenedMedia.fileURL(id: asset.id).lastPathComponent == URL(fileURLWithPath: asset.relativePath).lastPathComponent)
    let undo = UndoCardDeletionCommand(batchID: receipt.batchID)
    #expect(try await service.undo(undo) == receipt)
    f.time.advance(100)
    #expect(try await service.undo(undo) == receipt) // durable compensation replay after deadline
    let target2 = try await service.target(cardID: note.card.id)
    let receipt2 = try await service.delete(DeleteCardCommand(target: target2))
    f.clock.advance(by: -86_400 * 365)
    f.time.advance(5)
    #expect(try await service.pendingUndo().isEmpty)
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await service.undo(UndoCardDeletionCommand(batchID: receipt2.batchID)) }
    #expect(try await reopenedMedia.asset(id: asset.id) == asset)
    #expect(FileManager.default.fileExists(atPath: try await reopenedMedia.fileURL(id: asset.id).path))
    let refs = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note_media") }
    #expect(refs == 2)
    // A new boot cannot reuse persisted continuous-clock instants.
    let other = try #require(await SQLiteCollectionQueries(writer: writer, generation: UUID()).library(LibraryQuery()).rows.first)
    let otherReceipt = try await service.delete(DeleteCardCommand(target: service.target(cardID: other.id)))
    f.time.reboot()
    #expect(try await service.pendingUndo().isEmpty)
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await service.undo(UndoCardDeletionCommand(batchID: otherReceipt.batchID)) }
    try await writer.close()
    let final = try CollectionDatabase(url: f.directory.url.appendingPathComponent("deletion.sqlite"))
    let finalWriter = CollectionWriter(database: final, clock: f.clock)
    #expect(try await SQLiteCollectionQueries(writer: finalWriter, generation: UUID()).library(LibraryQuery()).cardCount == 0)
    try await final.checkIntegrity()
    try await finalWriter.close()
}

@Test func deletionConcurrentReplayStaleConfirmationAndTransactionFailureAreAtomic() async throws {
    let f = try DeletionFixture()
    defer { try? f.database.close() }
    let note = try await f.note()
    let target = try await f.service.target(cardID: note.card.id)
    _ = try await f.notes.save(SaveNoteCommand(commandID: CommandID(), noteID: note.note.id, expectedRevision: .initial,
        initialDeckID: note.card.deckID, content: BasicNoteContent(front: "Changed in another window", back: "Answer")))
    let tables = ["cards", "notes", "deletion_batches", "processed_commands", "domain_events", "card_schedules"]
    let staleBefore = try await f.rows(tables)
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await f.service.delete(DeleteCardCommand(target: target)) }
    #expect(try await f.rows(tables) == staleBefore)
    let command = try await DeleteCardCommand(target: f.service.target(cardID: note.card.id))
    try await f.database.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_card_deletion BEFORE INSERT ON domain_events WHEN NEW.type='card.deleted' BEGIN SELECT RAISE(ABORT,'synthetic deletion fault'); END") }
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await f.service.delete(command) }
    #expect(try await f.rows(tables) == staleBefore)
    try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_card_deletion") }
    let results = try await withThrowingTaskGroup(of: CardDeletionReceipt.self) { group in
        for _ in 0..<12 { group.addTask { try await f.service.delete(command) } }
        var results: [CardDeletionReceipt] = []
        for try await result in group { results.append(result) }
        return results
    }
    #expect(results.count == 12 && Set(results.map(\.batchID)).count == 1)
    #expect(try await f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM deletion_batches") } == 1)
    let undo = UndoCardDeletionCommand(batchID: try #require(results.first).batchID)
    let beforeUndo = try await f.rows(tables)
    try await f.database.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_card_undo BEFORE INSERT ON domain_events WHEN NEW.type='card.deletionUndone' BEGIN SELECT RAISE(ABORT,'synthetic undo fault'); END") }
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await f.service.undo(undo) }
    #expect(try await f.rows(tables) == beforeUndo)
    try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_card_undo") }
    _ = try await f.service.undo(undo)
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 1)
    try await f.database.checkIntegrity()
}

@Test @MainActor func deletionLibraryObservationAndStoppedGenerationRejectLateChanges() async throws {
    let f = try DeletionFixture()
    let note = try await f.note()
    let workspace = EditorWorkspace(generation: f.generation, notes: f.notes, queries: f.queries, deletions: f.service)
    let model = LibraryModel(workspace: workspace, clock: f.clock)
    let observer = Task { await model.observe() }
    defer { observer.cancel(); model.stop() }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CollectionRepositoryError.integrityFailure
    }
    try await wait { model.cardCount == 1 }
    let deletion = try #require(model.deletion)
    await deletion.prepare(cardID: note.card.id)
    await deletion.confirm()
    try await wait { model.cardCount == 0 && model.selection == nil }
    await deletion.undo(batchID: try #require(deletion.pending.first).id)
    try await wait { model.cardCount == 1 && model.selection == note.card.id }
    model.stop(); try await f.writer.close()
    await #expect(throws: CollectionRepositoryError.staleContext) { try await f.service.pendingUndo() }
    await deletion.prepare(cardID: note.card.id)
    #expect(!deletion.isPresented && model.rows.isEmpty)
}

@Test func deletionSystemClockIsComparableAndMonotonic() throws {
    let a = try SystemDeletionTime().now(), b = try SystemDeletionTime().now()
    #expect(UUID(uuidString: a.bootID) != nil && a.bootID == b.bootID && b.seconds >= a.seconds)
}

private actor DelayedDeletionService: CardDeletionService {
    let base: any CardDeletionService
    var wait: CheckedContinuation<Void, Never>?
    var delayTarget = false
    var delayDelete = false
    var loseDelete = false
    var loseUndo = false
    var deletes: [DeleteCardCommand] = []
    var undos: [UndoCardDeletionCommand] = []
    init(_ base: any CardDeletionService) { self.base = base }
    func configure(target: Bool = false, delete: Bool = false, lostDelete: Bool = false, lostUndo: Bool = false) {
        delayTarget = target; delayDelete = delete; loseDelete = lostDelete; loseUndo = lostUndo
    }
    func waiting() -> Bool { wait != nil }
    func release() { wait?.resume(); wait = nil }
    func submitted() -> ([DeleteCardCommand], [UndoCardDeletionCommand]) { (deletes, undos) }
    func target(cardID: CardID) async throws -> CardDeletionTarget {
        let value = try await base.target(cardID: cardID)
        if delayTarget { await withCheckedContinuation { wait = $0 } }
        return value
    }
    func delete(_ command: DeleteCardCommand) async throws -> CardDeletionReceipt {
        deletes.append(command)
        let value = try await base.delete(command)
        if delayDelete { await withCheckedContinuation { wait = $0 } }
        if loseDelete { loseDelete = false; throw InjectedFault.triggered }
        return value
    }
    func pendingUndo() async throws -> [CardDeletionUndo] { try await base.pendingUndo() }
    func undo(_ command: UndoCardDeletionCommand) async throws -> CardDeletionReceipt {
        undos.append(command)
        let value = try await base.undo(command)
        if loseUndo { loseUndo = false; throw InjectedFault.triggered }
        return value
    }
}

@Test @MainActor func deletionModelRetainsCommandOnLostAcknowledgementAndRejectsLateTargetAndCommit() async throws {
    let f = try DeletionFixture()
    defer { try? f.database.close() }
    let note = try await f.note()
    let delayed = DelayedDeletionService(f.service)
    let model = CardDeletionModel(service: delayed)
    await delayed.configure(target: true)
    let prepare = Task { await model.prepare(cardID: note.card.id) }
    while !(await delayed.waiting()) { await Task.yield() }
    model.cancel(); await delayed.release(); await prepare.value
    #expect(!model.isPresented && model.target == nil)
    await delayed.configure(lostDelete: true)
    await model.prepare(cardID: note.card.id); await model.confirm()
    #expect(model.isPresented && model.errorMessage != nil)
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 0)
    await model.confirm()
    #expect(!model.isPresented && model.pending.count == 1)
    let submitted = await delayed.submitted().0
    #expect(submitted.count == 2 && submitted[0] == submitted[1])
    await delayed.configure(lostUndo: true)
    await model.undo(batchID: try #require(model.pending.first).id)
    #expect(model.pending.isEmpty) // actual committed restore, even when acknowledgement was lost
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 1)
    await delayed.configure(delete: true)
    await model.prepare(cardID: note.card.id)
    let commit = Task { await model.confirm() }
    while !(await delayed.waiting()) { await Task.yield() }
    model.cancel(); #expect(model.isPresented && model.isCommitting)
    await model.confirm()
    #expect(await delayed.submitted().0.count == 3) // double confirm is inert
    model.stop(); await delayed.release(); await commit.value
    #expect(!model.isPresented && model.target == nil && model.pending.isEmpty)
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 0)
}
