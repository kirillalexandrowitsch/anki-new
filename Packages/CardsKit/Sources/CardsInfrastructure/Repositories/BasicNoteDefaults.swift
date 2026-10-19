import CardsCore
import Foundation
import GRDB

/// Lazy, transactional installation: no rewrite of delivered migrations or existing profiles.
enum BasicNoteDefaults {
    static let parameterID = "00000000-0014-4000-8000-000000000002"
    static let fields = #"{"schemaVersion":1,"fields":[{"id":"front","kind":"text","required":true},{"id":"back","kind":"text","required":true},{"id":"pronunciation","kind":"text"},{"id":"examples","kind":"examplePairs"},{"id":"audio","kind":"audio"},{"id":"image","kind":"image"}]}"#
    static let templates = #"{"schemaVersion":1,"templates":[{"id":"basic.forward","variantKey":"basic.forward","questionFields":["front","pronunciation","audio","image"],"answerFields":["back","examples"]}]}"#

    static func installType(_ db: Database) throws {
        let key = BasicNoteType.id.rawValue.uuidString.lowercased()
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM note_types WHERE id = ? OR stableKey = ?",
                                     arguments: [key, BasicNoteType.stableKey]) {
            guard row["id"] as String == key, row["stableKey"] as String == BasicNoteType.stableKey,
                  row["version"] as Int == 1, row["deletedAt"] == nil,
                  row["fieldsSchemaJSON"] as String == fields, row["templatesJSON"] as String == templates else {
                throw CollectionRepositoryError.integrityFailure
            }
            return
        }
        try db.execute(sql: """
            INSERT INTO note_types(id, stableKey, name, version, fieldsSchemaJSON, templatesJSON)
            VALUES (?, ?, 'Basic', 1, ?, ?)
            """, arguments: [key, BasicNoteType.stableKey, fields, templates])
    }

    static func parameterSet(_ db: Database, deckID: DeckID, now: Int64) throws -> String {
        let key = deckID.rawValue.uuidString.lowercased()
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ? AND deletedAt IS NULL)",
                                arguments: [key]) == true else {
            throw CollectionRepositoryError.notFound(.deck(deckID))
        }
        if let inherited = try String.fetchOne(db, sql: """
            WITH RECURSIVE ancestors(id, parentID, presetID, depth) AS (
                SELECT id, parentID, presetID, 0 FROM decks WHERE id = ? AND deletedAt IS NULL
                UNION ALL SELECT d.id, d.parentID, d.presetID, a.depth + 1
                FROM decks d JOIN ancestors a ON d.id = a.parentID WHERE d.deletedAt IS NULL
            ) SELECT p.schedulerParameterSetID FROM ancestors a JOIN deck_presets p ON p.id = a.presetID
            ORDER BY a.depth LIMIT 1
            """, arguments: [key]) { return inherited }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM scheduler_parameters WHERE id = ?)",
                             arguments: [parameterID]) == true { return parameterID }
        let profile = FSRS6Configuration.makeScheduler().parameters
        struct Weights: Encodable { let schemaVersion = 1; let w: [Double] }
        struct Policy: Encodable {
            let schemaVersion = 1
            let enableFuzz: Bool
            let enableShortTerm: Bool
            let learningSteps: [String]
            let relearningSteps: [String]
        }
        try db.execute(sql: """
            INSERT INTO scheduler_parameters(id, algorithmVersion, weightsJSON, desiredRetention,
                maximumIntervalDays, learningPolicyJSON, createdAt) VALUES (?, '6', ?, ?, ?, ?, ?)
            """, arguments: [parameterID, json(Weights(w: profile.w)), profile.requestRetention,
                Int(profile.maximumInterval), json(Policy(enableFuzz: profile.enableFuzz,
                    enableShortTerm: profile.enableShortTerm, learningSteps: profile.learningSteps,
                    relearningSteps: profile.relearningSteps)), now])
        return parameterID
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
