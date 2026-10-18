import CardsCore
import GRDB

struct SQLiteCollectionInfoRepository: CollectionInfoRepository {
    let writer: CollectionWriter

    func info() async throws -> CollectionInfo {
        try await writer.read { try Self.fetch($0) }
    }

    func rename(_ command: RenameCollectionCommand) async throws -> CollectionInfo {
        try await writer.execute(commandID: command.commandID, kind: "collection.rename.v1", request: command) { db in
            let current = try Self.fetch(db)
            guard current.revision == command.expectedRevision else {
                throw CollectionRepositoryError.revisionConflict(entity: .collection(current.id),
                    expected: command.expectedRevision, actual: current.revision)
            }
            let revision = try current.revision.advanced()
            try db.execute(sql: """
                UPDATE collection_meta SET name = ?, settingsRevision = ? WHERE settingsRevision = ?
                """, arguments: [command.name.displayValue, revision.rawValue, command.expectedRevision.rawValue])
            guard db.changesCount == 1 else { throw CollectionRepositoryError.integrityFailure }
            return CollectionInfo(id: current.id, name: command.name, revision: revision)
        }
    }

    private static func fetch(_ db: Database) throws -> CollectionInfo {
        let metadata = try CollectionMetadata.fetch(db)
        return CollectionInfo(id: metadata.id, name: metadata.name, revision: metadata.settingsRevision)
    }
}
