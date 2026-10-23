import CardsCore
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

@Test func deckUseCasesCommitAppearanceAndQueriesSurviveReopen() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let store = CollectionStore(root: directory.url)
    let context = try await store.open()
    let ports = try await store.deckWorkspace(generation: context.generation)
    let input = DeckInput(name: "  Английский  ", description: "Базовая лексика\nIPA /test/",
                          iconKey: "book.closed", colorKey: "purple")
    let id = DeckID()
    let created = try await CreateDeck(repository: ports.repository).execute(input, id: id, commandID: CommandID())
    #expect(created.name.displayValue == "Английский")
    let snapshot = try await ports.queries.decks(.all, asOf: EpochMilliseconds(0))
    #expect(snapshot.rows.map(\.deck) == [created])
    #expect(created.iconKey == "book.closed" && created.colorKey == "purple")
    let updated = try await UpdateDeck(repository: ports.repository).execute(
        DeckInput(name: "Изменённая", description: "Описание", iconKey: "airplane", colorKey: "teal"),
        original: created, commandID: CommandID())
    #expect(updated.revision == (try Revision(1)))
    try await store.close(generation: context.generation)
    let reopened = CollectionStore(root: directory.url)
    let next = try await reopened.open()
    let newPorts = try await reopened.deckWorkspace(generation: next.generation)
    #expect(try await newPorts.repository.deck(id: id) == updated)
    let persisted = try await newPorts.queries.decks(.all, asOf: EpochMilliseconds(0))
    #expect(persisted.rows.map(\.deck) == [updated])
    await #expect(throws: CollectionRepositoryError.staleContext) {
        try await UpdateDeck(repository: ports.repository).execute(input, original: updated, commandID: CommandID())
    }
    try await reopened.close(generation: next.generation)
}

@Test func deckUseCaseDuplicateAndRevisionConflictLeaveCommittedWinnerIntact() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let store = CollectionStore(root: directory.url)
    let context = try await store.open()
    let ports = try await store.deckWorkspace(generation: context.generation)
    let create = CreateDeck(repository: ports.repository)
    let base = try await create.execute(DeckInput(name: "Café"), id: DeckID(), commandID: CommandID())
    await #expect(throws: CollectionRepositoryError.validation(.duplicateName(normalized: "café"))) {
        try await create.execute(DeckInput(name: " CAFE\u{301} "), id: DeckID(), commandID: CommandID())
    }
    await #expect(throws: ValidationError.emptyName) {
        try await create.execute(DeckInput(name: " \n"), id: DeckID(), commandID: CommandID())
    }
    let update = UpdateDeck(repository: ports.repository)
    let winner = try await update.execute(DeckInput(name: "Победитель", description: "A",
        iconKey: "heart", colorKey: "pink"), original: base, commandID: CommandID())
    await #expect(throws: CollectionRepositoryError.revisionConflict(entity: .deck(base.id),
        expected: .initial, actual: try Revision(1))) {
        try await update.execute(DeckInput(name: "Устаревший", description: "B", iconKey: "star", colorKey: "orange"),
                                 original: base, commandID: CommandID())
    }
    #expect(try await ports.repository.deck(id: base.id) == winner)
    let other = try await create.execute(DeckInput(name: "Другая"), id: DeckID(), commandID: CommandID())
    await #expect(throws: CollectionRepositoryError.validation(.duplicateName(normalized: "другая"))) {
        try await update.execute(DeckInput(deck: other), original: winner, commandID: CommandID())
    }
    #expect(try await ports.repository.deck(id: base.id) == winner)
    try await store.close(generation: context.generation)
}

@Test func preT013CommandAndResultReplayWithDefaultAppearance() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let database = try CollectionDatabase(url: directory.url.appendingPathComponent("legacy.sqlite"),
        newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Fixture"),
                                            createdAt: EpochMilliseconds(0)))
    let writer = CollectionWriter(database: database, clock: TestClock(date: Date(timeIntervalSince1970: 0)))
    let repository = SQLiteDeckRepository(writer: writer)
    let command = try SaveDeckCommand(commandID: CommandID(), deckID: DeckID(), expectedRevision: nil,
                                       name: EntityName("Legacy"))
    let original = try await repository.save(command)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let request = String(decoding: try encoder.encode(command), as: UTF8.self)
    #expect(!request.contains("iconKey") && !request.contains("colorKey") && !request.contains("favorite"))
    // Reproduce the pre-T013 persisted result without either new DTO property.
    try await database.pool.write { db in
        let json = try String.fetchOne(db, sql: "SELECT resultJSON FROM processed_commands")!
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        var result = object["result"] as! [String: Any]
        result.removeValue(forKey: "iconKey"); result.removeValue(forKey: "colorKey"); result.removeValue(forKey: "isFavorite")
        object["result"] = result
        let legacy = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        try db.execute(sql: "UPDATE processed_commands SET resultJSON = ?", arguments: [String(decoding: legacy, as: UTF8.self)])
    }
    #expect(try await repository.save(command) == original)
    let decoded = try JSONDecoder().decode(SaveDeckCommand.self, from: Data(request.utf8))
    #expect(decoded == command)
    try await writer.close()
}
