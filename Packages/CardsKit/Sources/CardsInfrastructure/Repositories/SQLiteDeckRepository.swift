import CardsCore
import Foundation
import GRDB

struct SQLiteDeckRepository: DeckRepository {
    let writer: CollectionWriter

    func deck(id: DeckID) async throws -> Deck? {
        try await writer.read { try Self.fetch($0, id: id) }
    }

    func save(_ command: SaveDeckCommand) async throws -> Deck {
        try await writer.execute(commandID: command.commandID, kind: "deck.save.v1", request: command) { db in
            let key = command.deckID.rawValue.uuidString.lowercased()
            let current = try Self.fetch(db, id: command.deckID)
            let revision: Revision
            if let expected = command.expectedRevision {
                guard let current else { throw CollectionRepositoryError.notFound(.deck(command.deckID)) }
                guard current.revision == expected else {
                    throw CollectionRepositoryError.revisionConflict(entity: .deck(command.deckID),
                        expected: expected, actual: current.revision)
                }
                revision = try expected.advanced()
            } else {
                guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
                                         arguments: [key])! else {
                    throw CollectionRepositoryError.alreadyExists(.deck(command.deckID))
                }
                revision = .initial
            }
            let parentKey = command.parentID?.rawValue.uuidString.lowercased()
            if let parentID = command.parentID {
                guard parentID != command.deckID else { throw CollectionRepositoryError.invalidHierarchy }
                guard try Self.fetch(db, id: parentID) != nil else {
                    throw CollectionRepositoryError.notFound(.deck(parentID))
                }
                let cycle = try Bool.fetchOne(db, sql: """
                    WITH RECURSIVE ancestors(id) AS (
                        SELECT ? UNION SELECT decks.parentID FROM decks JOIN ancestors ON decks.id = ancestors.id
                        WHERE decks.parentID IS NOT NULL
                    ) SELECT EXISTS(SELECT 1 FROM ancestors WHERE id = ?)
                    """, arguments: [parentKey, key])!
                guard !cycle else { throw CollectionRepositoryError.invalidHierarchy }
            }
            let duplicate = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM decks
                WHERE parentID IS ? AND normalizedName = ? AND id != ? AND deletedAt IS NULL)
                """, arguments: [parentKey, command.name.normalizedValue, key])!
            guard !duplicate else {
                throw CollectionRepositoryError.validation(.duplicateName(normalized: command.name.normalizedValue))
            }
            if command.expectedRevision == nil {
                try db.execute(sql: """
                    INSERT INTO decks(id, parentID, name, normalizedName, description, iconKey, colorKey, revision)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [key, parentKey, command.name.displayValue, command.name.normalizedValue,
                                      command.description, command.iconKey, command.colorKey, revision.rawValue])
            } else {
                try db.execute(sql: """
                    UPDATE decks SET parentID = ?, name = ?, normalizedName = ?, description = ?, iconKey = ?, colorKey = ?, revision = ?
                    WHERE id = ? AND revision = ? AND deletedAt IS NULL
                    """, arguments: [parentKey, command.name.displayValue, command.name.normalizedValue,
                                      command.description, command.iconKey, command.colorKey, revision.rawValue, key, command.expectedRevision!.rawValue])
                guard db.changesCount == 1 else { throw CollectionRepositoryError.integrityFailure }
            }
            return Deck(id: command.deckID, parentID: command.parentID, name: command.name,
                        description: command.description, iconKey: command.iconKey, colorKey: command.colorKey, revision: revision)
        }
    }

    private static func fetch(_ db: Database, id: DeckID) throws -> Deck? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM decks WHERE id = ? AND deletedAt IS NULL",
                                         arguments: [id.rawValue.uuidString.lowercased()]) else { return nil }
        let parent: String? = row["parentID"]
        return try Deck(id: id, parentID: parent.map { try DeckID(uuidString: $0) },
                        name: EntityName(row["name"]), description: row["description"], iconKey: row["iconKey"], colorKey: row["colorKey"],
                        revision: Revision(row["revision"]))
    }
}
