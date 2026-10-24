import CardsCore
import Foundation
import GRDB

struct SQLiteDeckDeletion: DeckDeletionService {
    let writer: CollectionWriter
    let clock: any CardsCore.Clock

    func target(deckID: DeckID) async throws -> DeckDeletionTarget {
        try await writer.read { try Self.fetchTarget($0, id: deckID) }
    }

    private static let subtree = """
        WITH RECURSIVE subtree(id) AS (
            SELECT id FROM decks WHERE id=? AND deletedAt IS NULL
            UNION SELECT d.id FROM decks d JOIN subtree s ON d.parentID=s.id WHERE d.deletedAt IS NULL
        )
        """

    private static func fetchTarget(_ db: Database, id: DeckID) throws -> DeckDeletionTarget {
        guard let root = try SQLiteDeckRepository.fetch(db, id: id) else {
            throw CollectionRepositoryError.notFound(.deck(id))
        }
        let key = ReviewSQL.key(id)
        // Hidden ancestry cannot be used as a deletion entry point.
        let hidden = try Bool.fetchOne(db, sql: """
            WITH RECURSIVE ancestors(id,parentID,deletedAt) AS (
                SELECT id,parentID,deletedAt FROM decks WHERE id=?
                UNION SELECT d.id,d.parentID,d.deletedAt FROM decks d JOIN ancestors a ON d.id=a.parentID
            ) SELECT EXISTS(SELECT 1 FROM ancestors WHERE deletedAt IS NOT NULL)
            """, arguments: [key])!
        guard !hidden else { throw CollectionRepositoryError.invalidHierarchy }
        let decks = try String.fetchAll(db, sql: subtree + " SELECT id FROM subtree ORDER BY id", arguments: [key])
            .map { try SQLiteDeckRepository.fetch(db, id: DeckID(uuidString: $0))! }
        let cards = try Row.fetchAll(db, sql: subtree + """
             SELECT c.id,c.revision FROM cards c JOIN subtree s ON c.deckID=s.id
             WHERE c.deletedAt IS NULL ORDER BY c.id
            """, arguments: [key]).map {
                try DeckDeletionTarget.Card(id: CardID(uuidString: $0["id"]), revision: Revision($0["revision"]))
            }
        let notes = try Row.fetchAll(db, sql: subtree + """
             SELECT DISTINCT n.id,n.revision FROM notes n JOIN cards c ON c.noteID=n.id JOIN subtree s ON c.deckID=s.id
             WHERE n.deletedAt IS NULL AND c.deletedAt IS NULL ORDER BY n.id
            """, arguments: [key]).map { row in
                let noteKey: String = row["id"]
                let external = try String.fetchAll(db, sql: subtree + """
                     SELECT c.id FROM cards c JOIN decks d ON d.id=c.deckID
                     WHERE c.noteID=? AND c.deletedAt IS NULL AND c.generationState='active'
                         AND d.deletedAt IS NULL AND c.deckID NOT IN (SELECT id FROM subtree) ORDER BY c.id
                    """, arguments: [key, noteKey]).map { try CardID(uuidString: $0) }
                return try DeckDeletionTarget.Note(id: NoteID(uuidString: noteKey), revision: Revision(row["revision"]), externalCards: external)
            }
        return DeckDeletionTarget(root: root, decks: decks, cards: cards, notes: notes)
    }

    func delete(_ command: DeleteDeckCommand) async throws -> DeckDeletionReceipt {
        try await writer.execute(commandID: command.id, kind: "deck.delete.v1", request: command) { db in
            let target = try Self.fetchTarget(db, id: command.target.root.id)
            guard target == command.target else { throw CollectionRepositoryError.undoConflict }
            let now = try EpochMilliseconds(date: clock.now()).rawValue
            for card in target.cards {
                try db.execute(sql: "UPDATE cards SET deletedAt=?,generationState='suppressed',revision=? WHERE id=?",
                    arguments: [now, card.revision.advanced().rawValue, ReviewSQL.key(card.id)])
            }
            for note in target.notes where note.externalCards.isEmpty {
                try db.execute(sql: "UPDATE notes SET deletedAt=?,updatedAt=?,revision=? WHERE id=?",
                    arguments: [now, now, note.revision.advanced().rawValue, ReviewSQL.key(note.id)])
            }
            for deck in target.decks {
                try db.execute(sql: "UPDATE decks SET deletedAt=?,revision=? WHERE id=?",
                    arguments: [now, deck.revision.advanced().rawValue, ReviewSQL.key(deck.id)])
            }
            let receipt = DeckDeletionReceipt(batchID: command.id.rawValue, rootID: target.root.id)
            try db.execute(sql: """
                INSERT INTO deletion_batches(id,kind,affectedIDsJSON,deletedAt,undoUntil,purgeAfter,state)
                VALUES (?,'deck.v1',?,?,NULL,?,'pending')
                """, arguments: [receipt.batchID.uuidString.lowercased(), ReviewSQL.json(target), now, now + 604_800_000])
            try ReviewSQL.event(db, command: command.id, type: "deck.deleted", object: ReviewSQL.key(target.root.id), at: clock.now(), payload: receipt)
            return receipt
        }
    }
}
