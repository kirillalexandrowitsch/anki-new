import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

@Test @MainActor func twoRealEditorDraftsConflictDisplayWinnerAndExplicitlySaveSeparateCopy() async throws {
    let directory = try TestDirectory()
    let store = CollectionStore(root: directory.url, clock: TestClock())
    let context = try await store.open()
    let deckRepository = try await store.decks(generation: context.generation)
    let deck = try await CreateDeck(repository: deckRepository).execute(DeckInput(name: "Synthetic"), id: DeckID(), commandID: CommandID())
    let workspace = try await store.editorWorkspace(generation: context.generation)
    let create = EditorModel(repository: workspace.notes, decks: [deck])
    create.draft.front = "Synthetic front"; create.draft.back = "Original"
    let saved = try #require(await create.save())
    let first = EditorModel(repository: workspace.notes, decks: [deck], original: saved)
    let second = EditorModel(repository: workspace.notes, decks: [deck], original: saved)
    first.draft.back = "Winner"
    second.draft.back = "My separate text"
    let winner = try #require(await first.save())
    #expect(await second.save() == nil && second.state == .conflict)
    #expect(second.latest == winner && second.draft.back == "My separate text")
    #expect(second.original == saved && !second.canSave && !second.isClosed)
    #expect(try await workspace.notes.note(id: saved.note.id) == winner)
    second.prepareSeparateCopy()
    #expect(second.canSave && second.draft.back == "My separate text")
    let copy = try #require(await second.save())
    #expect(copy.note.id != saved.note.id && copy.card.id != winner.card.id)
    let library = try await workspace.queries.library(LibraryQuery())
    #expect(library.cardCount == 2 && library.noteCount == 2)
    try await store.close(generation: context.generation)
    let reopened = try await store.open()
    let notes = try await store.notes(generation: reopened.generation)
    #expect(try await notes.note(id: winner.note.id) == winner)
    #expect(try await notes.note(id: copy.note.id) == copy)
    try await store.close(generation: reopened.generation)
}

@Test @MainActor func realSQLiteDiskFullKeepsEditorOpenAndAtomicThenSameDraftRetries() async throws {
    let directory = try TestDirectory()
    let clock = TestClock()
    let db = try CollectionDatabase(url: directory.url.appendingPathComponent("synthetic.sqlite"),
        newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
    let writer = CollectionWriter(database: db, clock: clock)
    let deck = try await CreateDeck(repository: SQLiteDeckRepository(writer: writer)).execute(
        DeckInput(name: "Synthetic"), id: DeckID(), commandID: CommandID())
    let notes = SQLiteNoteRepository(writer: writer, clock: clock)
    let editor = EditorModel(repository: notes, decks: [deck])
    editor.draft.front = "Synthetic disk test"
    editor.draft.back = String(repeating: "Synthetic long text ", count: 10000)
    // SQLite's actual SQLITE_FULL, isolated to this temporary connection/database.
    try await db.pool.writeWithoutTransaction { db in
        let count = try Int.fetchOne(db, sql: "PRAGMA page_count")!
        _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count = \(count)")
    }
    let draft = editor.draft
    editor.requestClose()
    await editor.resolveClose(.save)
    #expect(!editor.isClosed && editor.state == .failed && editor.draft == draft)
    #expect(editor.errorMessage?.contains("Недостаточно места") == true)
    #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM notes") } == 0)
    #expect(try await db.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM cards") } == 0)
    try await db.pool.writeWithoutTransaction { db in
        _ = try Int.fetchOne(db, sql: "PRAGMA max_page_count = 1073741823")
    }
    let saved = try #require(await editor.save())
    #expect(saved.content == draft.content && editor.isClosed)
    try await db.checkIntegrity()
    try await writer.close()
}
