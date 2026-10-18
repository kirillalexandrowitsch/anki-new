import CardsCore
import Foundation
import GRDB

public enum CollectionDatabaseError: Error, Equatable, Sendable {
    case creationMetadataRequired
    case unsupportedSchema
    case inconsistentSchema
    case collectionIdentityMismatch
    case integrityFailure
}

public struct NewCollectionMetadata: Sendable {
    public let id: CollectionID
    public let name: EntityName
    public let createdAt: EpochMilliseconds

    public init(id: CollectionID, name: EntityName, createdAt: EpochMilliseconds) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public struct CollectionMetadata: Equatable, Sendable {
    public let id: CollectionID
    public let name: EntityName
    public let containerVersion: Int
    public let schemaVersion: Int
    public let createdAt: EpochMilliseconds
    public let settingsRevision: Revision

    static func fetch(_ db: Database) throws -> Self {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM collection_meta"),
              try Int.fetchOne(db, sql: "SELECT count(*) FROM collection_meta") == 1 else {
            throw CollectionDatabaseError.inconsistentSchema
        }
        return try Self(id: CollectionID(uuidString: row["id"]), name: EntityName(row["name"]),
                        containerVersion: row["containerVersion"], schemaVersion: row["schemaVersion"],
                        createdAt: EpochMilliseconds(row["createdAt"]),
                        settingsRevision: Revision(row["settingsRevision"]))
    }
}

/// Owns one file-backed WAL pool. Construct off the main actor, under the collection's
/// exclusive lifecycle lease (T007). SQL connections stay inside Infrastructure.
public final class CollectionDatabase: Sendable {
    public static let schemaVersion = 1
    let pool: DatabasePool
    public let migrationBackupURL: URL?

    public convenience init(url: URL, newCollection: NewCollectionMetadata? = nil) throws {
        try self.init(url: url, newCollection: newCollection, migrations: CollectionMigrations.initial)
    }

    // Migration injection is internal so tests exercise the same opening/backup/rollback path.
    init(url: URL, newCollection: NewCollectionMetadata? = nil,
         migrations: [CollectionMigration], backupDirectory: URL? = nil) throws {
        let version = try CollectionMigrations.preflight(url: url, migrations: migrations)
        if version == 0 && newCollection == nil {
            throw CollectionDatabaseError.creationMetadataRequired
        }
        // Check identity before any writable connection is opened.
        if version > 0, let newCollection {
            let reader = try CollectionMigrations.readOnlyQueue(url)
            defer { try? reader.close() }
            let metadata = try reader.read { try CollectionMetadata.fetch($0) }
            guard metadata.id == newCollection.id else {
                throw CollectionDatabaseError.collectionIdentityMismatch
            }
        }

        var backupURL: URL?
        if version > 0 && version < migrations.count {
            backupURL = try CollectionMigrations.backup(url: url, version: version,
                                                       directory: backupDirectory ?? url.deletingLastPathComponent())
        }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true // applied by GRDB on every writer/reader connection
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        do {
            // Recheck before running any migration; the lifecycle owner holds the lease.
            try pool.read { _ = try CollectionMigrations.validate($0, migrations: migrations) }
            var migrator = DatabaseMigrator()
            for (index, migration) in migrations.enumerated() {
                migrator.registerMigration(migration.identifier) { db in
                    try migration.apply(db)
                    if index == 0 {
                        guard let newCollection else { throw CollectionDatabaseError.creationMetadataRequired }
                        try db.execute(sql: """
                            INSERT INTO collection_meta(id, name, containerVersion, schemaVersion, createdAt)
                            VALUES (?, ?, 1, 1, ?)
                            """, arguments: [newCollection.id.rawValue.uuidString.lowercased(),
                                              newCollection.name.displayValue, newCollection.createdAt.rawValue])
                    }
                    try db.execute(sql: "UPDATE collection_meta SET schemaVersion = ?", arguments: [index + 1])
                    try db.execute(sql: "PRAGMA user_version = \(index + 1)")
                    try Self.checkIntegrity(db)
                }
            }
            try migrator.migrate(pool)
            try pool.read { db in
                _ = try CollectionMigrations.validate(db, migrations: migrations)
                try Self.checkIntegrity(db)
            }
        } catch {
            try? pool.close()
            throw error
        }
        self.pool = pool
        migrationBackupURL = backupURL
    }

    public func metadata() async throws -> CollectionMetadata {
        try await pool.read { try CollectionMetadata.fetch($0) }
    }

    public func checkIntegrity() async throws {
        try await pool.read { try Self.checkIntegrity($0) }
    }

    public func close() throws { try pool.close() }

    static func checkIntegrity(_ db: Database) throws {
        guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
              try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw CollectionDatabaseError.integrityFailure
        }
    }
}
