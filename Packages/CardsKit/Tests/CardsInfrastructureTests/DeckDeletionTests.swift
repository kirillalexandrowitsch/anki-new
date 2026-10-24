import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct DeckDeletionFixture {
    let directory: TestDirectory
    let database: CollectionDatabase
    let writer: CollectionWriter
    let clock = TestClock()
    let generation = UUID()
    var service: SQLiteDeckDeletion { .init(writer: writer, clock: clock) }
    var repository: SQLiteDeckRepository { .init(writer: writer) }
    var notes: SQLiteNoteRepository { .init(writer: writer, clock: clock) }
    var queries: SQLiteCollectionQueries { .init(writer: writer, generation: generation) }
    init() throws {
        directory = try TestDirectory()
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("deck-delete.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
    func deck(_ name: String, parent: DeckID? = nil) async throws -> Deck {
        try await CreateDeck(repository: repository).execute(DeckInput(name: name), id: DeckID(), commandID: CommandID(), parentID: parent)
    }
    func note(_ deck: Deck) async throws -> SavedBasicNote {
        try await notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(), expectedRevision: nil,
            initialDeckID: deck.id, content: BasicNoteContent(front: UUID().uuidString, back: "Synthetic answer"), tags: ["Shared"]))
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
    func session(scope: StudyQueueScope = .collection) async throws -> SQLiteStudySession {
        try await SQLiteStudySession.open(writer: writer, configuration: StudyQueueConfiguration(generation: generation,
            scope: scope, calendar: StudyDayCalculator(timeZoneID: "UTC")), clock: clock)
    }
}

@Test @MainActor func deckDeletionCancelNestedSharedNoteAndReopen() async throws {
    let f = try DeckDeletionFixture()
    let root = try await f.deck("Root"), child = try await f.deck("Child", parent: root.id)
    let leaf = try await f.deck("Leaf", parent: child.id), outside = try await f.deck("Outside")
    let shared = try await f.note(root), own = try await f.note(leaf), external = try await f.note(outside)
    let sibling = CardID()
    try await f.database.pool.write { db in
        try db.execute(sql: "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES (?,?,?,'synthetic.reverse','synthetic.reverse',0)",
            arguments: [ReviewSQL.key(sibling), ReviewSQL.key(shared.note.id), ReviewSQL.key(outside.id)])
        try db.execute(sql: "INSERT INTO card_schedules(cardID,algorithmID,algorithmVersion,parameterSetID,phase) SELECT ?,algorithmID,algorithmVersion,parameterSetID,phase FROM card_schedules WHERE cardID=?",
            arguments: [ReviewSQL.key(sibling), ReviewSQL.key(shared.card.id)])
    }
    let tables = ["decks", "cards", "notes", "card_schedules", "review_logs", "session_items", "deletion_batches", "domain_events", "processed_commands", "note_tags", "note_media"]
    let before = try await f.rows(tables)
    let externalBefore = try await f.queries.library(LibraryQuery()).rows.filter { $0.deckID == outside.id }
    let model = DeckDeletionModel(service: f.service)
    await model.prepare(deckID: root.id)
    let target = try #require(model.target)
    #expect(target.root == root && target.decks.count == 3 && target.cards.count == 2)
    #expect(target.notes.count == 2 && target.deletedNoteCount == 1 && target.sharedNoteCount == 1)
    model.cancel()
    #expect(try await f.rows(tables) == before)
    let preserved = try await f.rows(["card_schedules", "review_logs", "session_items", "note_tags", "note_media"])
    let command = DeleteDeckCommand(target: target)
    let receipt = try await f.service.delete(command)
    #expect(try await f.service.delete(command) == receipt)
    #expect(try await f.queries.decks(DeckQuery(hierarchy: true), asOf: EpochMilliseconds(0)).rows.map(\.id) == [outside.id])
    let library = try await f.queries.library(LibraryQuery())
    #expect(Set(library.rows.map(\.id)) == [sibling, external.card.id] && library.noteCount == 2)
    #expect(library.rows == externalBefore)
    #expect(try await f.repository.deck(id: outside.id) == outside)
    #expect(try await f.notes.note(id: shared.note.id)?.note == shared.note)
    #expect(try await f.notes.note(id: shared.note.id)?.content == shared.content)
    #expect(try await f.notes.note(id: own.note.id) == nil)
    #expect(try await f.rows(["card_schedules", "review_logs", "session_items", "note_tags", "note_media"]) == preserved)
    // A stale editor cannot revive an orphaned Note; a shared Note remains editable.
    await #expect(throws: CollectionRepositoryError.notFound(.note(own.note.id))) {
        try await f.notes.save(SaveNoteCommand(commandID: CommandID(), noteID: own.note.id, expectedRevision: own.note.revision,
            initialDeckID: leaf.id, content: own.content))
    }
    _ = try await f.notes.save(SaveNoteCommand(commandID: CommandID(), noteID: shared.note.id, expectedRevision: shared.note.revision,
        initialDeckID: root.id, content: BasicNoteContent(front: "Still shared", back: "Answer")))
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 2)
    try await f.database.checkIntegrity()
    try await f.writer.close()
    let reopened = try CollectionDatabase(url: f.directory.url.appendingPathComponent("deck-delete.sqlite"))
    let writer = CollectionWriter(database: reopened, clock: f.clock)
    #expect(try await SQLiteDeckDeletion(writer: writer, clock: f.clock).delete(command) == receipt)
    #expect(try await SQLiteCollectionQueries(writer: writer, generation: UUID()).library(LibraryQuery()).cardCount == 2)
    try await writer.close()
}

@Test func deckDeletionStaleScopeAndTransactionFailureAreAtomic() async throws {
    let f = try DeckDeletionFixture(); defer { try? f.database.close() }
    let root = try await f.deck("Root"), child = try await f.deck("Child", parent: root.id)
    _ = try await f.note(child)
    let tables = ["decks", "cards", "notes", "card_schedules", "deletion_batches", "domain_events", "processed_commands"]
    let stale = try await f.service.target(deckID: root.id)
    _ = try await f.deck("New child", parent: root.id)
    let before = try await f.rows(tables)
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await f.service.delete(DeleteDeckCommand(target: stale)) }
    #expect(try await f.rows(tables) == before)
    let command = try await DeleteDeckCommand(target: f.service.target(deckID: root.id))
    // Failure after all tombstones and batch insertion must roll the entire mutation back.
    try await f.database.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_deck_delete BEFORE INSERT ON domain_events WHEN NEW.type='deck.deleted' BEGIN SELECT RAISE(ABORT,'synthetic deck fault'); END") }
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await f.service.delete(command) }
    #expect(try await f.rows(tables) == before)
    try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_deck_delete") }
    let receipts = try await withThrowingTaskGroup(of: DeckDeletionReceipt.self) { group in
        for _ in 0..<8 { group.addTask { try await f.service.delete(command) } }
        var values: [DeckDeletionReceipt] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(receipts.count == 8 && Set(receipts.map(\.batchID)).count == 1)
    #expect(try await f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM deletion_batches WHERE kind='deck.v1' AND undoUntil IS NULL") } == 1)
    try await f.database.checkIntegrity()
}

@Test func deckDeletionRejectsChangedCardNoteAndMovedChild() async throws {
    let f = try DeckDeletionFixture(); defer { try? f.database.close() }
    let root = try await f.deck("Root"), child = try await f.deck("Child", parent: root.id), outside = try await f.deck("Outside")
    let note = try await f.note(child)
    var target = try await f.service.target(deckID: root.id)
    _ = try await f.notes.save(SaveNoteCommand(commandID: CommandID(), noteID: note.note.id, expectedRevision: note.note.revision,
        initialDeckID: child.id, content: BasicNoteContent(front: "Changed", back: "Answer")))
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await f.service.delete(DeleteDeckCommand(target: target)) }
    target = try await f.service.target(deckID: root.id)
    _ = try await f.note(child)
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await f.service.delete(DeleteDeckCommand(target: target)) }
    target = try await f.service.target(deckID: root.id)
    _ = try await MoveDeck(repository: f.repository).execute(child, to: outside.id, commandID: CommandID())
    await #expect(throws: CollectionRepositoryError.undoConflict) { try await f.service.delete(DeleteDeckCommand(target: target)) }
    let empty = try await f.service.target(deckID: root.id)
    #expect(empty.cards.isEmpty && empty.decks.count == 1 && empty.notes.isEmpty)
    _ = try await f.service.delete(DeleteDeckCommand(target: empty))
    #expect(try await f.queries.library(LibraryQuery()).cardCount == 2)
}

@Test @MainActor func deckDeletionRefreshesObservedScreensAndOpenStudyWithoutRating() async throws {
    let f = try DeckDeletionFixture(); defer { try? f.database.close() }
    let root = try await f.deck("Root"), child = try await f.deck("Child", parent: root.id)
    let note = try await f.note(child)
    let decks = DecksModel(workspace: DeckWorkspace(generation: f.generation, repository: f.repository, queries: f.queries, deletions: f.service), clock: f.clock)
    let library = LibraryModel(workspace: EditorWorkspace(generation: f.generation, notes: f.notes, queries: f.queries), clock: f.clock)
    let deckWatch = Task { await decks.observe() }, libraryWatch = Task { await library.observe() }
    defer { deckWatch.cancel(); libraryWatch.cancel(); decks.stop(); library.stop() }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CollectionRepositoryError.integrityFailure
    }
    try await wait { decks.deckCount == 2 && library.cardCount == 1 }
    decks.inspectedID = child.id
    let session = try await f.session(scope: .decks([root.id]))
    let study = StudySessionModel(service: session, clock: f.clock)
    await study.load(); study.reveal()
    #expect(study.phase == .answer && study.presentation?.cardID == note.card.id)
    let presentation = try #require(study.presentation)
    await decks.deletion?.prepare(deckID: root.id); await decks.deletion?.confirm()
    try await wait { decks.deckCount == 0 && library.cardCount == 0 && library.selection == nil && decks.inspectedID == nil }
    await study.heartbeat(systemIdleSeconds: 0)
    #expect(study.phase == .completed && study.presentation == nil && study.confirmedRatings == 0)
    await #expect(throws: CollectionRepositoryError.reviewUnavailable) {
        try await session.rate(StudyRatingCommand(cardID: presentation.cardID, expectedRevision: presentation.revision,
            grade: .good, occurredAt: f.clock.now(), scheduleEpoch: presentation.scheduleEpoch))
    }
    #expect(try await session.next(skipping: [], preferred: note.card.id) == .completed(.noCards))
    #expect(await study.finishSession())
    study.stop()
}

private actor DelayedDeckDeletion: DeckDeletionService {
    let base: any DeckDeletionService
    var wait: CheckedContinuation<Void, Never>?
    var delayTarget = false
    var delayDelete = false
    var loseAcknowledgement = false
    var commands: [DeleteDeckCommand] = []
    init(_ base: any DeckDeletionService) { self.base = base }
    func configure(target: Bool = false, delete: Bool = false, lost: Bool = false) {
        delayTarget = target; delayDelete = delete; loseAcknowledgement = lost
    }
    func waiting() -> Bool { wait != nil }
    func release() { wait?.resume(); wait = nil }
    func submitted() -> [DeleteDeckCommand] { commands }
    func target(deckID: DeckID) async throws -> DeckDeletionTarget {
        let value = try await base.target(deckID: deckID)
        if delayTarget { await withCheckedContinuation { wait = $0 } }
        return value
    }
    func delete(_ command: DeleteDeckCommand) async throws -> DeckDeletionReceipt {
        commands.append(command)
        let value = try await base.delete(command)
        if delayDelete { await withCheckedContinuation { wait = $0 } }
        if loseAcknowledgement { loseAcknowledgement = false; throw CollectionRepositoryError.integrityFailure }
        return value
    }
}

@Test @MainActor func deckDeletionModelCancellationLostAcknowledgementAndStoppedGeneration() async throws {
    let f = try DeckDeletionFixture(); defer { try? f.database.close() }
    let root = try await f.deck("Root")
    let delayed = DelayedDeckDeletion(f.service), model = DeckDeletionModel(service: f.service)
    let slow = DeckDeletionModel(service: delayed)
    await delayed.configure(target: true)
    let prepare = Task { await slow.prepare(deckID: root.id) }
    while !(await delayed.waiting()) { await Task.yield() }
    slow.cancel(); await delayed.release(); await prepare.value
    #expect(!slow.isPresented && slow.target == nil)
    await delayed.configure(lost: true)
    await slow.prepare(deckID: root.id); await slow.confirm()
    #expect(slow.isPresented && slow.errorMessage != nil)
    await slow.confirm()
    #expect(!slow.isPresented)
    let submitted = await delayed.submitted()
    #expect(submitted.count == 2 && submitted[0] == submitted[1])
    let other = try await f.deck("Other")
    await delayed.configure(delete: true)
    await slow.prepare(deckID: other.id)
    let commit = Task { await slow.confirm() }
    while !(await delayed.waiting()) { await Task.yield() }
    slow.cancel(); #expect(slow.isPresented && slow.isCommitting)
    await slow.confirm()
    #expect(await delayed.submitted().count == 3)
    slow.stop(); await delayed.release(); await commit.value
    #expect(!slow.isPresented && slow.target == nil)
    try await f.writer.close()
    await model.prepare(deckID: root.id)
    #expect(model.target == nil && model.errorMessage != nil)
    model.stop()
}

@Test @MainActor func deckDeletionRatingRaceAndPausedStudyAdvanceToSurvivingCard() async throws {
    let f = try DeckDeletionFixture(); defer { try? f.database.close() }
    let first = try await f.deck("First"), second = try await f.deck("Second")
    _ = try await f.note(first); _ = try await f.note(second)
    let session = try await f.session()
    let study = StudySessionModel(service: session, clock: f.clock)
    await study.load(); study.reveal()
    let shown = try #require(study.presentation)
    let row = try #require(await f.queries.library(LibraryQuery()).rows.first { $0.id == shown.cardID })
    let deletedDeck = row.deckID
    _ = try await f.service.delete(DeleteDeckCommand(target: f.service.target(deckID: deletedDeck)))
    // Delete wins after reveal and before rating: no uncommitted pending command can trap the UI.
    await study.rate(.good)
    #expect(study.phase == .question && study.presentation?.cardID != shown.cardID && study.pendingCommand == nil)
    #expect(study.confirmedRatings == 0)
    study.pause()
    let remainingDeck = deletedDeck == first.id ? second.id : first.id
    _ = try await f.service.delete(DeleteDeckCommand(target: f.service.target(deckID: remainingDeck)))
    await study.heartbeat(systemIdleSeconds: 0)
    #expect(study.phase == .completed && study.presentation == nil)
    #expect(await study.finishSession())
    study.stop()
}
