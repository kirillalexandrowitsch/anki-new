import CardsCore
import Foundation
import GRDB

struct SQLiteStudyPreferences: StudyPreferencesRepository {
    let writer: CollectionWriter
    static let key = "study.preferences.v1"
    private struct Stored: Codable { let schemaVersion: Int; let snapshot: StudyPreferencesSnapshot }
    static func fetch(_ db: Database) throws -> StudyPreferencesSnapshot {
        guard let json = try String.fetchOne(db, sql: "SELECT valueJSON FROM collection_settings WHERE key=?", arguments: [key]) else {
            return StudyPreferencesSnapshot()
        }
        let stored = try JSONDecoder().decode(Stored.self, from: Data(json.utf8))
        guard stored.schemaVersion == 1 else { throw CollectionRepositoryError.unsupportedCommandResult }
        return stored.snapshot
    }
    func load() async throws -> StudyPreferencesSnapshot { try await writer.read { try Self.fetch($0) } }
    func save(_ command: SaveStudyPreferences) async throws -> StudyPreferencesSnapshot {
        try await writer.execute(commandID: command.commandID, kind: "study.preferences.save.v1", request: command) { db in
            let current = try Self.fetch(db)
            guard current.revision == command.expectedRevision else {
                throw CollectionRepositoryError.revisionConflict(entity: .collection(try CollectionMetadata.fetch(db).id),
                    expected: command.expectedRevision, actual: current.revision)
            }
            let result = try StudyPreferencesSnapshot(value: command.value, revision: current.revision.advanced())
            try db.execute(sql: "INSERT INTO collection_settings(key,valueJSON) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET valueJSON=excluded.valueJSON",
                arguments: [Self.key, BasicNoteDefaults.json(Stored(schemaVersion: 1, snapshot: result))])
            return result
        }
    }
}
