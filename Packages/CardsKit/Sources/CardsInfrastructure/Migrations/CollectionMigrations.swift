import Foundation
import GRDB

struct CollectionMigration: Sendable {
    let identifier: String
    let apply: @Sendable (Database) throws -> Void
}

enum CollectionMigrations {
    static let initial = [CollectionMigration(identifier: "v1", apply: InitialSchema.create)]
    static let current = initial + [CollectionMigration(identifier: "v2-search", apply: SearchSchema.create)]

    static func readOnlyQueue(_ url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    /// SQLite OPEN_READONLY happens before DatabasePool can enable WAL or migrate.
    static func preflight(url: URL, migrations: [CollectionMigration]) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let reader = try readOnlyQueue(url)
        defer { try? reader.close() }
        return try reader.read { try validate($0, migrations: migrations) }
    }

    static func validate(_ db: Database, migrations: [CollectionMigration]) throws -> Int {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version")!
        guard version <= migrations.count else { throw CollectionDatabaseError.unsupportedSchema }
        var migrator = DatabaseMigrator()
        for migration in migrations { migrator.registerMigration(migration.identifier) { _ in } }
        let applied = try migrator.appliedIdentifiers(db)
        guard applied.isSubset(of: Set(migrations.map(\.identifier))) else {
            throw CollectionDatabaseError.unsupportedSchema
        }
        guard version >= 0, applied == Set(migrations.prefix(version).map(\.identifier)) else {
            throw CollectionDatabaseError.inconsistentSchema
        }
        if version == 0 {
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_schema WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                """)
            guard tables.isEmpty else { throw CollectionDatabaseError.inconsistentSchema }
        } else {
            let metadata = try CollectionMetadata.fetch(db)
            guard metadata.schemaVersion <= migrations.count else {
                throw CollectionDatabaseError.unsupportedSchema
            }
            guard metadata.schemaVersion == version, metadata.containerVersion == 1 else {
                throw CollectionDatabaseError.inconsistentSchema
            }
        }
        return version
    }

    /// Snapshot via SQLite Backup API includes committed WAL data. Verification/close must
    /// succeed before schema writes start. Failure (including disk full) aborts the upgrade.
    static func backup(url: URL, version: Int, directory: URL) throws -> URL {
        let target = directory.appendingPathComponent(
            "\(url.lastPathComponent).pre-migration-v\(version)-\(UUID().uuidString).sqlite")
        let source = try readOnlyQueue(url)
        defer { try? source.close() }
        let metadata = try source.read { try CollectionMetadata.fetch($0) }
        do {
            let destination = try DatabaseQueue(path: target.path)
            do {
                try source.backup(to: destination)
                try destination.read { db in
                    try CollectionDatabase.checkIntegrity(db)
                    guard try CollectionMetadata.fetch(db) == metadata, metadata.schemaVersion == version else {
                        throw CollectionDatabaseError.inconsistentSchema
                    }
                }
                try destination.close()
            } catch {
                try? destination.close()
                throw error
            }
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
}
