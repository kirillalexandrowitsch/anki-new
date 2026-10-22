import CardsCore
import Foundation
import GRDB

private struct CardDeletionBatch: Codable, Sendable {
    let schemaVersion: Int
    let target: CardDeletionTarget
    let deletedRevision: Revision
    let bootID: String
    let startedSeconds: Double
    let deadlineSeconds: Double

    func remaining(at time: DeletionInstant) -> Double {
        guard schemaVersion == 1, time.bootID == bootID, time.seconds >= startedSeconds else { return 0 }
        return max(0, min(5, deadlineSeconds - time.seconds))
    }
}

struct SQLiteCardDeletion: CardDeletionService {
    let writer: CollectionWriter
    let clock: any CardsCore.Clock
    var time: any DeletionTime = SystemDeletionTime()

    func target(cardID: CardID) async throws -> CardDeletionTarget {
        try await writer.read { try Self.fetchTarget($0, id: cardID) }
    }

    private static func fetchTarget(_ db: Database, id: CardID) throws -> CardDeletionTarget {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT c.noteID, c.revision, c.variantKey, n.revision AS noteRevision, n.fieldsJSON,
                (SELECT count(*) FROM cards s WHERE s.noteID=c.noteID AND s.id!=c.id
                    AND s.deletedAt IS NULL AND s.generationState='active') AS others
            FROM cards c JOIN notes n ON n.id=c.noteID
            WHERE c.id=? AND c.deletedAt IS NULL AND c.generationState='active' AND n.deletedAt IS NULL
            """, arguments: [ReviewSQL.key(id)]) else { throw CollectionRepositoryError.notFound(.card(id)) }
        struct Fields: Decodable { let front: String }
        let fields = try ReviewSQL.decode(Fields.self, row["fieldsJSON"])
        return try CardDeletionTarget(id: id, noteID: NoteID(uuidString: row["noteID"]),
            cardRevision: Revision(row["revision"]), noteRevision: Revision(row["noteRevision"]),
            front: fields.front, variantKey: row["variantKey"], otherCardCount: row["others"])
    }

    func delete(_ command: DeleteCardCommand) async throws -> CardDeletionReceipt {
        try await writer.execute(commandID: command.id, kind: "card.delete.v1", request: command) { db in
            let target = try Self.fetchTarget(db, id: command.target.id)
            guard target.cardRevision == command.target.cardRevision else {
                throw CollectionRepositoryError.revisionConflict(entity: .card(target.id),
                    expected: command.target.cardRevision, actual: target.cardRevision)
            }
            guard target == command.target else { throw CollectionRepositoryError.undoConflict }
            let instant = try time.now()
            let now = try EpochMilliseconds(date: clock.now()).rawValue
            let revision = try target.cardRevision.advanced()
            let batch = CardDeletionBatch(schemaVersion: 1, target: target, deletedRevision: revision,
                bootID: instant.bootID, startedSeconds: instant.seconds, deadlineSeconds: instant.seconds + 5)
            let receipt = CardDeletionReceipt(batchID: command.id.rawValue, cardID: target.id)
            try db.execute(sql: """
                UPDATE cards SET deletedAt=?, generationState='suppressed', revision=? WHERE id=?;
                """, arguments: [now, revision.rawValue, ReviewSQL.key(target.id)])
            // Keep the unique variant row, schedule, Note, attachments and history. No media GC here.
            try db.execute(sql: """
                INSERT INTO deletion_batches(id,kind,affectedIDsJSON,deletedAt,undoUntil,purgeAfter,state)
                VALUES (?,'card.v1',?,?,?,?, 'pending')
                """, arguments: [receipt.batchID.uuidString.lowercased(), ReviewSQL.json(batch), now, now + 5_000, now + 604_800_000])
            try ReviewSQL.event(db, command: command.id, type: "card.deleted", object: ReviewSQL.key(target.id),
                at: clock.now(), payload: receipt)
            return receipt
        }
    }

    func pendingUndo() async throws -> [CardDeletionUndo] {
        try await writer.read { db in
            let instant = try time.now()
            return try Row.fetchAll(db, sql: """
                SELECT id, affectedIDsJSON FROM deletion_batches WHERE kind='card.v1' AND state='pending'
                    AND json_extract(affectedIDsJSON,'$.bootID')=?
                    AND json_extract(affectedIDsJSON,'$.deadlineSeconds')>?
                ORDER BY rowid DESC
                """, arguments: [instant.bootID, instant.seconds])
                .compactMap { row in
                    let batch = try ReviewSQL.decode(CardDeletionBatch.self, row["affectedIDsJSON"])
                    let remaining = batch.remaining(at: instant)
                    guard remaining > 0 else { return nil }
                    guard let id = UUID(uuidString: row["id"]) else { throw CollectionRepositoryError.integrityFailure }
                    return CardDeletionUndo(receipt: CardDeletionReceipt(batchID: id,
                        cardID: batch.target.id), front: batch.target.front, remainingSeconds: remaining)
                }
        }
    }

    func undo(_ command: UndoCardDeletionCommand) async throws -> CardDeletionReceipt {
        try await writer.execute(commandID: command.id, kind: "card.delete.undo.v1", request: command) { db in
            let batchKey = command.batchID.uuidString.lowercased()
            guard let row = try Row.fetchOne(db, sql: "SELECT affectedIDsJSON FROM deletion_batches WHERE id=? AND kind='card.v1' AND state='pending'",
                arguments: [batchKey]) else { throw CollectionRepositoryError.undoConflict }
            let batch = try ReviewSQL.decode(CardDeletionBatch.self, row["affectedIDsJSON"])
            guard batch.remaining(at: try time.now()) > 0 else { throw CollectionRepositoryError.undoConflict }
            let id = batch.target.id
            let revision = try batch.deletedRevision.advanced()
            try db.execute(sql: """
                UPDATE cards SET deletedAt=NULL, generationState='active', revision=?
                WHERE id=? AND revision=? AND deletedAt IS NOT NULL AND generationState='suppressed'
                    AND EXISTS(SELECT 1 FROM notes WHERE id=cards.noteID AND deletedAt IS NULL)
                    AND EXISTS(SELECT 1 FROM decks WHERE id=cards.deckID AND deletedAt IS NULL)
                """, arguments: [revision.rawValue, ReviewSQL.key(id), batch.deletedRevision.rawValue])
            guard db.changesCount == 1 else { throw CollectionRepositoryError.undoConflict }
            try db.execute(sql: "UPDATE deletion_batches SET state='restored' WHERE id=?", arguments: [batchKey])
            let receipt = CardDeletionReceipt(batchID: command.batchID, cardID: id)
            try ReviewSQL.event(db, command: command.id, type: "card.deletionUndone", object: ReviewSQL.key(id),
                at: clock.now(), payload: receipt)
            return receipt
        }
    }
}
