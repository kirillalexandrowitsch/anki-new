import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct DiscoveryFixture {
    let directory: TestDirectory
    let database: CollectionDatabase
    let clock = TestClock()
    let writer: CollectionWriter
    let generation = UUID()
    var queries: SQLiteCollectionQueries { .init(writer: writer, generation: generation) }
    init() throws {
        directory = try TestDirectory()
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("discovery.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
    func deck(_ name: String) async throws -> Deck {
        try await CreateDeck(repository: SQLiteDeckRepository(writer: writer)).execute(DeckInput(name: name), id: DeckID(), commandID: CommandID())
    }
    func note(_ deck: Deck, front: String = "Resilient") async throws -> SavedBasicNote {
        try await SQLiteNoteRepository(writer: writer, clock: clock).save(SaveNoteCommand(commandID: CommandID(),
            noteID: NoteID(), expectedRevision: nil, initialDeckID: deck.id,
            content: BasicNoteContent(front: front, back: "Ответ", pronunciation: "/test/", examples: [.init(en: "Example", ru: "Пример")])) )
    }
    func word(_ day: Int, excluding: NoteID? = nil) async throws -> DailyWord? {
        try await writer.read { try DiscoverySQL.word($0, day: day, excluding: excluding, generation: generation) }
    }
}
private enum DiscoveryTestError: Error { case timeout }
@MainActor private func discoveryWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
        if predicate() { return }; try await Task.sleep(for: .milliseconds(10))
    }
    throw DiscoveryTestError.timeout
}

@Test func discoveryDailyEmptySingleUniqueNotesDeterministicDayAndExclusion() async throws {
    let f = try DiscoveryFixture(); defer { try? f.database.close() }
    #expect(try await f.word(10) == nil)
    let deck = try await f.deck("Local")
    let first = try await f.note(deck)
    let one = try #require(await f.word(10))
    #expect(one.noteID == first.note.id && one.content == first.content && !one.hasAlternative)
    #expect(try await f.word(11)?.noteID == first.note.id)
    #expect(try await f.word(10, excluding: first.note.id) == nil)
    let second = try await f.note(deck, front: "Worthwhile")
    let noteID = first.note.id, deckID = deck.id
    try await f.database.pool.write { db in
        try db.execute(sql: "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES (?,?,?,'reverse','reverse',0)",
            arguments: [QuerySQL.key(CardID()), QuerySQL.key(noteID), QuerySQL.key(deckID)])
    }
    let today = try #require(await f.word(10)), tomorrow = try #require(await f.word(11))
    #expect(today.hasAlternative && today.noteID != tomorrow.noteID)
    #expect(try await f.word(10) == today)
    #expect(try await f.word(10, excluding: today.noteID)?.noteID == tomorrow.noteID)
    let removed = second.card.id
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE cards SET deletedAt=1 WHERE id=?", arguments: [QuerySQL.key(removed)])
    }
    #expect(try await f.word(10)?.hasAlternative == false)
    #expect(try await f.word(10)?.noteID == first.note.id)
    let zone = try #require(TimeZone(identifier: "Europe/Moscow"))
    let before = try #require(ISO8601DateFormatter().date(from: "2026-10-24T20:59:59Z"))
    #expect(DailyWordDay.number(at: before.addingTimeInterval(1), timeZone: zone) == DailyWordDay.number(at: before, timeZone: zone) + 1)
    try await f.writer.close()
    let reopened = try CollectionDatabase(url: f.directory.url.appendingPathComponent("discovery.sqlite"))
    defer { try? reopened.close() }
    #expect(try await reopened.pool.read { try DiscoverySQL.word($0, day: 10, excluding: nil, generation: UUID()) }?.noteID == first.note.id)
}

@Test @MainActor func discoverySearchKeyboardSafetyLiveUpdatesDeepLinkAndStop() async throws {
    let f = try DiscoveryFixture(); defer { try? f.database.close() }
    let deck = try await f.deck("Resilient %_ Deck")
    let first = try await f.note(deck)
    let model = DiscoveryModel(service: f.queries, generation: f.generation, clock: f.clock)
    defer { model.stop() }
    model.text = "Resil"
    var task = Task { await model.observeSearch() }
    try await discoveryWait { model.results != nil }
    #expect(model.results?.cards.rows.first?.id == first.card.id)
    #expect(model.destinations == [.card(first.card.id), .deck(deck.id)])
    model.move(1); #expect(model.selected == .deck(deck.id))
    model.move(1); #expect(model.selected == .card(first.card.id))
    model.move(-1); #expect(model.selected == .deck(deck.id))
    let second = try await f.note(deck, front: "Resilience")
    try await discoveryWait { model.results?.cards.cardCount == 2 }
    task.cancel(); await task.value
    for term in ["\"*:^(){}", "' OR 1=1 --", "front:absent OR resilient", "noresult", "%_"] {
        model.text = term; task = Task { await model.observeSearch() }
        try await discoveryWait { model.results != nil }
        #expect(model.results?.cards.cardCount == 0)
        if term == "%_" { #expect(model.results?.decks.rows.first?.id == deck.id) }
        else { #expect(model.destinations.isEmpty) }
        task.cancel(); await task.value
    }
    model.text = String(repeating: "x", count: 513); await model.observeSearch()
    #expect(model.searchError?.contains("512") == true)
    // Old debounce cannot replace the latest query.
    model.text = "Resil"; let old = Task { await model.observeSearch() }
    await Task.yield(); model.text = "absent"
    task = Task { await model.observeSearch() }
    try await discoveryWait { model.results != nil }
    #expect(model.destinations.isEmpty); old.cancel(); await old.value
    task.cancel(); await task.value
    let library = LibraryModel(workspace: .init(generation: f.generation,
        notes: SQLiteNoteRepository(writer: f.writer, clock: f.clock), queries: f.queries), clock: f.clock)
    library.showCard(second.card.id)
    let libraryTask = Task { await library.observe() }
    try await discoveryWait { !library.isLoading }
    #expect(library.selection == second.card.id && library.cardCount == 1)
    await library.inspect(); #expect(library.inspectedNote?.note.id == second.note.id)
    library.stop(); libraryTask.cancel(); await libraryTask.value
    let wordTask = Task { await model.observeWord() }
    try await discoveryWait { model.wordLoaded }
    #expect(model.word != nil)
    model.stop(); wordTask.cancel(); await wordTask.value
    #expect(model.results == nil && model.word == nil)
    try await f.writer.close()
    await #expect(throws: CollectionRepositoryError.staleContext) { _ = try await f.queries.observeDailyWord(day: 10, excluding: nil) }
}

@Test @MainActor func discoveryDayRefreshAlternativeAndSingleWordModel() async throws {
    let f = try DiscoveryFixture(); defer { try? f.database.close() }
    let deck = try await f.deck("Local")
    let model = DiscoveryModel(service: f.queries, generation: f.generation, clock: f.clock)
    var task = Task { await model.observeWord() }
    defer { task.cancel(); model.stop() }
    try await discoveryWait { model.wordLoaded }
    #expect(model.word == nil && model.wordError == nil)
    let first = try await f.note(deck)
    try await discoveryWait { model.word != nil }
    #expect(model.word?.noteID == first.note.id && model.word?.hasAlternative == false)
    let sameID = model.wordID; model.anotherWord(); #expect(model.wordID == sameID)
    _ = try await f.note(deck, front: "Different")
    try await discoveryWait { model.word?.hasAlternative == true }
    let initial = try #require(model.word)
    task.cancel(); await task.value
    model.anotherWord(); task = Task { await model.observeWord() }
    try await discoveryWait { model.wordLoaded }
    #expect(model.word?.noteID != initial.noteID)
    task.cancel(); await task.value
    f.clock.advance(by: 86_400); model.refreshDay()
    task = Task { await model.observeWord() }
    try await discoveryWait { model.wordLoaded }
    #expect(model.word?.noteID != initial.noteID)
    #expect(model.word?.noteID == (try await f.word(DailyWordDay.number(at: f.clock.now())))?.noteID)
    let unchanged = model.wordID; model.refreshDay(); #expect(model.wordID == unchanged)
    task.cancel(); await task.value
    model.anotherWord(); task = Task { await model.observeWord() }
    try await discoveryWait { model.wordLoaded }
    let deletedCard = try #require(model.word?.cardID)
    let beforeDeletion = model.wordID
    try await f.database.pool.write { db in
        try db.execute(sql: "UPDATE cards SET deletedAt=1 WHERE id=?", arguments: [QuerySQL.key(deletedCard)])
    }
    try await discoveryWait { model.wordID != beforeDeletion }
    task.cancel(); await task.value
    task = Task { await model.observeWord() }
    try await discoveryWait { model.wordLoaded }
    #expect(model.word != nil && model.word?.hasAlternative == false)
    task.cancel(); await task.value; model.stop()
    try await f.writer.close()
}

@Test @MainActor func discoveryBoundedGroupsAndCardBeyondFirstLibraryPage() async throws {
    let f = try DiscoveryFixture(); defer { try? f.database.close() }
    let deck = try await f.deck("Local 0")
    let oldest = try await f.note(deck, front: "Local oldest")
    for index in 1...106 {
        f.clock.advance(by: 1)
        _ = try await f.note(deck, front: "Local \(index)")
    }
    for index in 1...8 { _ = try await f.deck("Local \(index)") }
    let query = try await f.queries.library(.init())
    #expect(query.rows.count == 100 && !query.rows.contains { $0.id == oldest.card.id })
    let library = LibraryModel(workspace: .init(generation: f.generation,
        notes: SQLiteNoteRepository(writer: f.writer, clock: f.clock), queries: f.queries), clock: f.clock)
    let search = try #require(library.discovery)
    search.text = "Local"
    let searchTask = Task { await search.observeSearch() }
    try await discoveryWait { search.results != nil }
    #expect(search.results?.cards.rows.count == 6 && search.results?.cards.cardCount == 107)
    #expect(search.results?.decks.rows.count == 6 && search.results?.decks.deckCount == 9)
    library.showCard(oldest.card.id)
    let task = Task { await library.observe() }
    try await discoveryWait { !library.isLoading }
    #expect(library.selectedRow?.id == oldest.card.id && library.noteCount == 1 && library.isShowingCard)
    task.cancel(); await task.value
    library.showAll(search: "")
    let all = Task { await library.observe() }
    try await discoveryWait { !library.isLoading }
    #expect(library.cardCount == 107 && !library.isShowingCard)
    library.stop(); all.cancel(); await all.value; searchTask.cancel(); await searchTask.value
    try await f.writer.close()
}
