import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private func hierarchyDeck(_ repository: any DeckRepository, _ name: String, parent: DeckID? = nil) async throws -> Deck {
    try await CreateDeck(repository: repository).execute(DeckInput(name: name), id: DeckID(),
                                                       commandID: CommandID(), parentID: parent)
}

@Test func deckMoveRejectsCyclesDuplicatesAndStaleUndoAndReplaysAfterReopen() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let store = CollectionStore(root: directory.url)
    let context = try await store.open()
    let w = try await store.deckWorkspace(generation: context.generation)
    let root = try await hierarchyDeck(w.repository, "Root")
    let child = try await hierarchyDeck(w.repository, "Child", parent: root.id)
    let leaf = try await hierarchyDeck(w.repository, "Leaf", parent: child.id)
    let other = try await hierarchyDeck(w.repository, "Other")
    let duplicate = try await hierarchyDeck(w.repository, "Child", parent: other.id)
    let move = MoveDeck(repository: w.repository)
    for destination in [root.id, child.id, leaf.id] {
        await #expect(throws: CollectionRepositoryError.invalidHierarchy) {
            try await move.execute(root, to: destination, commandID: CommandID())
        }
    }
    await #expect(throws: CollectionRepositoryError.validation(.duplicateName(normalized: "child"))) {
        try await move.execute(child, to: other.id, commandID: CommandID())
    }
    let absent = DeckID()
    await #expect(throws: CollectionRepositoryError.notFound(.deck(absent))) {
        try await move.execute(child, to: absent, commandID: CommandID())
    }
    #expect(try await w.repository.deck(id: child.id) == child)
    #expect(try await w.repository.deck(id: duplicate.id) == duplicate)
    let commandID = CommandID()
    let moved = try await move.execute(child, to: nil, commandID: commandID)
    #expect(moved.parentID == nil)
    #expect(moved.revision == (try child.revision.advanced()))
    #expect(try await w.repository.deck(id: leaf.id) == leaf)
    let favorite = try await SetDeckFavorite(repository: w.repository).execute(moved, favorite: true, commandID: CommandID())
    await #expect(throws: CollectionRepositoryError.revisionConflict(entity: .deck(child.id),
        expected: moved.revision, actual: favorite.revision)) {
        try await move.execute(moved, to: root.id, commandID: CommandID())
    }
    let undone = try await move.execute(favorite, to: root.id, commandID: CommandID())
    #expect(undone.parentID == root.id && undone.isFavorite)
    let edited = try await UpdateDeck(repository: w.repository).execute(DeckInput(name: "Edited"), original: undone,
                                                                       commandID: CommandID())
    #expect(edited.isFavorite)
    #expect(try await move.execute(child, to: nil, commandID: commandID) == moved)
    await #expect(throws: CollectionRepositoryError.commandIDReused) {
        try await move.execute(child, to: leaf.id, commandID: commandID)
    }
    try await store.close(generation: context.generation)
    let reopened = try await store.open()
    let next = try await store.deckWorkspace(generation: reopened.generation)
    #expect(try await next.repository.deck(id: child.id) == edited)
    #expect(try await next.repository.deck(id: leaf.id) == leaf)
    #expect(try await MoveDeck(repository: next.repository).execute(child, to: nil, commandID: commandID) == moved)
    try await store.close(generation: reopened.generation)
}

@Test func deckHierarchySnapshotIsCompleteBeyondOneHundredAndExcludesDeletedAncestry() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let database = try CollectionDatabase(url: directory.url.appendingPathComponent("tree.sqlite"),
        newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
    let writer = CollectionWriter(database: database, clock: TestClock())
    let repo = SQLiteDeckRepository(writer: writer)
    let root = try await hierarchyDeck(repo, "Z root")
    let child = try await hierarchyDeck(repo, "A child", parent: root.id)
    let leaf = try await hierarchyDeck(repo, "A leaf", parent: child.id)
    let hiddenRoot = try await hierarchyDeck(repo, "Deleted root")
    _ = try await hierarchyDeck(repo, "Hidden child", parent: hiddenRoot.id)
    for index in 0..<101 { _ = try await hierarchyDeck(repo, "Deck \(index)") }
    try await database.pool.write { db in
        try db.execute(sql: "UPDATE decks SET deletedAt=1 WHERE id=?", arguments: [QuerySQL.key(hiddenRoot.id)])
    }
    let queries = SQLiteCollectionQueries(writer: writer, generation: UUID())
    let page = try await queries.decks(.all, asOf: EpochMilliseconds(0))
    #expect(page.rows.count == 100)
    let forest = try await queries.decks(DeckQuery(hierarchy: true), asOf: EpochMilliseconds(0))
    #expect(forest.rows.count == 104 && forest.deckCount == 104)
    let hierarchy = DeckHierarchy(rows: forest.rows)
    #expect(hierarchy.ancestors(of: leaf.id).map(\.id) == [root.id, child.id])
    #expect(hierarchy.path(leaf.id) == "Z root / A child / A leaf")
    #expect(!hierarchy.visible(expanded: []).contains { $0.id == child.id })
    let visible = hierarchy.visible(expanded: [root.id, child.id])
    let index = try #require(visible.firstIndex { $0.id == root.id })
    #expect(visible[index...index+2].map(\.id) == [root.id, child.id, leaf.id])
    #expect(!hierarchy.canMove(root.id, to: leaf.id))
    try await writer.close()
}

@MainActor private func waitForDecks(_ model: DecksModel, _ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Deck observation timed out: \(model.errorMessage ?? "no error")")
    throw CollectionRepositoryError.integrityFailure
}

@Test @MainActor func deckBrowserSharesCountsFavoritesFiltersAndPersistentExpansionAcrossViewsAndReopen() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let suite = "anki.test.T031." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CollectionStore(root: directory.url)
    let context = try await store.open()
    let w = try await store.deckWorkspace(generation: context.generation)
    let root = try await hierarchyDeck(w.repository, "Root")
    let child = try await hierarchyDeck(w.repository, "Child", parent: root.id)
    let leaf = try await hierarchyDeck(w.repository, "Leaf", parent: child.id)
    let other = try await hierarchyDeck(w.repository, "Other")
    let editor = try await store.editorWorkspace(generation: context.generation)
    _ = try await editor.notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(), expectedRevision: nil,
        initialDeckID: leaf.id, content: BasicNoteContent(front: "Synthetic", back: "Test")))
    let preferences = UserDefaultsDeckBrowserPreferences(defaults: defaults, collectionID: context.id)
    let model = DecksModel(workspace: w, clock: TestClock(), preferences: preferences)
    let observation = Task { await model.observe() }
    defer { model.stop(); observation.cancel() }
    try await waitForDecks(model) { model.rows.count == 4 }
    #expect(model.visibleRows.map(\.id) == [other.id, root.id])
    model.toggleExpanded(root.id); model.toggleExpanded(child.id)
    #expect(model.visibleRows.map(\.id) == [other.id, root.id, child.id, leaf.id])
    let treeCounts = Dictionary(uniqueKeysWithValues: model.visibleRows.map { ($0.id, $0.counts) })
    #expect(treeCounts[leaf.id]?.cards == 1 && treeCounts[leaf.id]?.availableNew == 1)
    #expect(treeCounts[root.id]?.cards == 0)
    model.setLayout(.grid)
    #expect(Dictionary(uniqueKeysWithValues: model.visibleRows.map { ($0.id, $0.counts) }) == treeCounts)
    await model.toggleFavorite(leaf)
    try await waitForDecks(model) { model.rows.first { $0.id == leaf.id }?.deck.isFavorite == true }
    model.favoritesOnly = true
    #expect(model.visibleRows.map(\.id) == [leaf.id])
    let starred = try #require(model.rows.first { $0.id == leaf.id }?.deck)
    await model.toggleFavorite(starred)
    try await waitForDecks(model) { model.rows.first { $0.id == leaf.id }?.deck.isFavorite == false }
    #expect(model.visibleRows.isEmpty && model.hasFilter)
    let unstarred = try #require(model.rows.first { $0.id == leaf.id }?.deck)
    await model.toggleFavorite(unstarred)
    try await waitForDecks(model) { model.rows.first { $0.id == leaf.id }?.deck.isFavorite == true }
    model.setLayout(.tree)
    #expect(model.visibleRows.map(\.id) == [leaf.id])
    model.search = "missing"
    #expect(model.visibleRows.isEmpty && model.hasFilter)
    model.resetFilters(); model.search = "leaf"
    #expect(model.visibleRows.map(\.id) == [leaf.id])
    model.resetFilters()
    model.move(child)
    let dialog = try #require(model.moveEditor)
    #expect(!dialog.destinations.contains { $0.id == child.id || $0.id == leaf.id })
    dialog.parentID = other.id
    let moved = try #require(await dialog.save())
    model.completeMove(moved, from: child.parentID)
    try await waitForDecks(model) { model.rows.first { $0.id == child.id }?.deck.parentID == other.id }
    #expect(model.canUndoMove)
    await model.undoLastMove()
    try await waitForDecks(model) { model.rows.first { $0.id == child.id }?.deck.parentID == root.id }
    #expect(!model.canUndoMove)
    model.setLayout(.grid)
    model.stop(); observation.cancel(); await observation.value
    #expect(model.rows.isEmpty)
    try await store.close(generation: context.generation)
    let reopened = try await store.open()
    let reopenedPreferences = UserDefaultsDeckBrowserPreferences(defaults: defaults, collectionID: reopened.id)
    #expect(reopenedPreferences.loadDeckBrowser() == DeckBrowserPreferences(layout: .grid, expanded: [root.id, child.id]))
    let otherPreferences = UserDefaultsDeckBrowserPreferences(defaults: defaults, collectionID: CollectionID())
    #expect(otherPreferences.loadDeckBrowser() == .init())
    let next = try await store.deckWorkspace(generation: reopened.generation)
    let snapshot = try await next.queries.decks(DeckQuery(hierarchy: true), asOf: EpochMilliseconds(0))
    #expect(snapshot.rows.first { $0.id == leaf.id }?.deck.isFavorite == true)
    #expect(snapshot.rows.first { $0.id == leaf.id }?.counts.cards == 1)
    try await store.close(generation: reopened.generation)
}
