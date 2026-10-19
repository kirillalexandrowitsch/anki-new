import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private enum LibraryTestError: Error { case timeout }
@MainActor private func waitForLibrary(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LibraryTestError.timeout
}

@Test @MainActor func libraryObservesCreateOtherWindowEditSelectionSearchInspectorAndReopen() async throws {
    let directory = try TestDirectory()
    let clock = TestClock()
    let store = CollectionStore(root: directory.url, clock: clock)
    let context = try await store.open()
    let decks = try await store.decks(generation: context.generation)
    let deck = try await CreateDeck(repository: decks).execute(DeckInput(name: "Synthetic library"), id: DeckID(), commandID: CommandID())
    let workspace = try await store.editorWorkspace(generation: context.generation)
    let model = LibraryModel(workspace: workspace, clock: clock)
    var task = Task { await model.observe() }
    defer { task.cancel(); model.stop() }
    try await waitForLibrary { !model.isLoading }
    #expect(model.rows.isEmpty && model.cardCount == 0 && model.noteCount == 0)
    await model.launcher.open()
    let create = try #require(model.launcher.editor)
    create.draft.front = "Synthetic café"; create.draft.back = "First answer"
    create.draft.pronunciation = "/test/"
    create.draft.examples = [NoteExample(en: "Resilient example", ru: "Пример")]
    let original = try #require(await create.save())
    model.launcher.editor = nil
    // No reload on sheet dismissal: the DB observation must deliver the write.
    try await waitForLibrary { model.cardCount == 1 }
    #expect(model.noteCount == 1 && model.selection == original.card.id)
    #expect(model.selectedRow?.directionTitle == "Лицевая → оборотная")
    await model.inspect()
    #expect(model.inspectedNote?.content == original.content)
    let second = EditorModel(repository: workspace.notes, decks: [deck])
    second.draft.front = "Another row"; second.draft.back = "Another answer"
    _ = try #require(await second.save())
    try await waitForLibrary { model.cardCount == 2 }
    #expect(model.selection == original.card.id)
    let otherWindow = EditorModel(repository: workspace.notes, decks: [deck], original: original)
    otherWindow.draft.back = "Updated answer"
    let saved = try #require(await otherWindow.save())
    try await waitForLibrary { model.selectedRow?.back == "Updated answer" }
    #expect(model.selection == original.card.id)
    await model.inspect()
    #expect(model.inspectedNote == saved)
    await model.launcher.open(noteID: original.note.id)
    #expect(model.launcher.editor?.draft.back == "Updated answer")
    model.launcher.editor?.requestClose(); model.launcher.editor = nil
    task.cancel(); await task.value
    model.search = "resilient"
    task = Task { await model.observe() }
    try await waitForLibrary { !model.isLoading }
    #expect(model.cardCount == 1 && model.rows.first?.id == original.card.id)
    task.cancel(); await task.value
    model.search = "absent"
    task = Task { await model.observe() }
    try await waitForLibrary { !model.isLoading }
    #expect(model.rows.isEmpty && model.selection == nil && model.cardCount == 0)
    task.cancel(); await task.value
    model.search = String(repeating: "x", count: 513)
    await model.observe()
    #expect(model.errorMessage?.contains("512") == true && !model.isLoading)
    model.stop()
    try await store.close(generation: context.generation)
    let reopened = try await store.open()
    let reopenedWorkspace = try await store.editorWorkspace(generation: reopened.generation)
    let reopenedModel = LibraryModel(workspace: reopenedWorkspace, clock: clock)
    let reopenedTask = Task { await reopenedModel.observe() }
    try await waitForLibrary { !reopenedModel.isLoading }
    #expect(reopenedModel.cardCount == 2 && reopenedModel.noteCount == 2)
    #expect(reopenedModel.rows.first { $0.id == original.card.id }?.back == "Updated answer")
    reopenedModel.stop(); reopenedTask.cancel(); await reopenedTask.value
    try await store.close(generation: reopened.generation)
}

@Test @MainActor func libraryPagesDistinctNoteCountsVariantDirectionsAndRemovedLastPage() async throws {
    let directory = try TestDirectory()
    let db = try CollectionDatabase(url: directory.url.appendingPathComponent("synthetic.sqlite"),
        newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
    let clock = TestClock()
    let writer = CollectionWriter(database: db, clock: clock)
    let deck = try await CreateDeck(repository: SQLiteDeckRepository(writer: writer)).execute(
        DeckInput(name: "Synthetic"), id: DeckID(), commandID: CommandID())
    let notes = SQLiteNoteRepository(writer: writer, clock: clock)
    let original = try await notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(), expectedRevision: nil,
        initialDeckID: deck.id, content: BasicNoteContent(front: "Shared", back: "Answer")))
    let noteID = original.note.id; let deckID = deck.id
    // Multiple Card variants of one Note verify that the UI never derives Note count from rows.
    try await db.pool.write { db in
        for index in 1...100 {
            try db.execute(sql: "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES (?,?,?,?,?,0)",
                arguments: [QuerySQL.key(CardID()), QuerySQL.key(noteID), QuerySQL.key(deckID), "reverse.\(index)", "reverse"])
        }
    }
    let generation = UUID()
    let library = LibraryModel(workspace: EditorWorkspace(generation: generation, notes: notes,
        queries: SQLiteCollectionQueries(writer: writer, generation: generation)), clock: clock)
    var task = Task { await library.observe() }
    defer { task.cancel(); library.stop() }
    try await waitForLibrary { !library.isLoading }
    #expect(library.rows.count == 100 && library.cardCount == 101 && library.noteCount == 1 && library.hasMore)
    #expect(library.rows.contains { $0.directionTitle.hasPrefix("reverse.") })
    task.cancel(); await task.value
    library.page(1)
    task = Task { await library.observe() }
    try await waitForLibrary { !library.isLoading }
    #expect(library.offset == 100 && library.rows.count == 1 && !library.hasMore)
    try await db.pool.write { db in
        try db.execute(sql: "UPDATE cards SET deletedAt=1 WHERE variantKey != ?", arguments: [BasicNoteType.variantKey])
    }
    try await waitForLibrary { library.offset == 0 }
    task.cancel(); await task.value
    task = Task { await library.observe() }
    try await waitForLibrary { !library.isLoading }
    #expect(library.cardCount == 1 && library.noteCount == 1 && library.selection == original.card.id)
    library.stop(); task.cancel(); await task.value
    try await writer.close()
}

private actor DelayedLibraryNotes: NoteRepository {
    let base: any NoteRepository
    var shouldDelay = true
    var pending: CheckedContinuation<Void, Never>?
    init(_ base: any NoteRepository) { self.base = base }
    func waiting() -> Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
    func note(id: NoteID) async throws -> SavedBasicNote? {
        let value = try await base.note(id: id)
        if shouldDelay {
            shouldDelay = false
            await withCheckedContinuation { pending = $0 }
        }
        return value
    }
    func save(_ command: SaveNoteCommand) async throws -> SavedBasicNote { try await base.save(command) }
}

@Test @MainActor func libraryInspectorRejectsLateReadOfPreviouslySelectedCard() async throws {
    let directory = try TestDirectory()
    let clock = TestClock()
    let store = CollectionStore(root: directory.url, clock: clock)
    let context = try await store.open()
    let decks = try await store.decks(generation: context.generation)
    let deck = try await CreateDeck(repository: decks).execute(DeckInput(name: "Synthetic"), id: DeckID(), commandID: CommandID())
    let workspace = try await store.editorWorkspace(generation: context.generation)
    var saved: [SavedBasicNote] = []
    for text in ["First", "Second"] {
        saved.append(try await workspace.notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(), expectedRevision: nil,
            initialDeckID: deck.id, content: BasicNoteContent(front: text, back: text))))
    }
    let delayed = DelayedLibraryNotes(workspace.notes)
    let model = LibraryModel(workspace: EditorWorkspace(generation: context.generation, notes: delayed, queries: workspace.queries), clock: clock)
    let observation = Task { await model.observe() }
    defer { model.stop(); observation.cancel() }
    try await waitForLibrary { !model.isLoading }
    model.selection = saved[0].card.id
    let firstRead = Task { await model.inspect() }
    for _ in 0..<500 {
        if await delayed.waiting() { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await delayed.waiting())
    model.selection = saved[1].card.id
    await model.inspect()
    #expect(model.inspectedNote == saved[1])
    await delayed.release()
    await firstRead.value
    #expect(model.inspectedNote == saved[1])
    model.stop(); observation.cancel(); await observation.value
    try await store.close(generation: context.generation)
    #expect(model.rows.isEmpty && model.inspectedNote == nil)
}
