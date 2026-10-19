import CardsCore
import Foundation
import GRDB
import ZIPFoundation

/// No Archive/Database objects escape the actor which calls these synchronous helpers.
enum BackupArchive {
    static func snapshot(pool: DatabasePool, source: URL, staging: URL, now: Date) throws {
        let files = FileManager.default
        try files.createDirectory(at: staging.appendingPathComponent("Media"), withIntermediateDirectories: true)
        let target = staging.appendingPathComponent("collection.sqlite")
        let queue = try DatabaseQueue(path: target.path)
        do {
            try pool.backup(to: queue)
            // Backup inherits WAL mode from page one; the archive must be a standalone file.
            try queue.writeWithoutTransaction { db in
                guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete" else {
                    throw CollectionBackupError.invalidArchive
                }
            }
            try queue.read { db in
                try CollectionDatabase.checkIntegrity(db)
                _ = try CollectionMigrations.validate(db, migrations: CollectionMigrations.current)
                for asset in try assets(db) {
                    try Task.checkCancellation()
                    try MediaFiles.verify(asset, root: source)
                    try files.copyItem(at: source.appendingPathComponent(asset.relativePath),
                                       to: staging.appendingPathComponent(asset.relativePath))
                }
            }
            try queue.close()
        } catch { try? queue.close(); throw error }
        try files.copyItem(at: source.appendingPathComponent("collection.json"),
                           to: staging.appendingPathComponent("collection.json"))
        let metadata = try validateDatabase(staging)
        let paths = ["collection.json", "collection.sqlite"] +
            (try files.contentsOfDirectory(atPath: staging.appendingPathComponent("Media").path)).map { "Media/" + $0 }
        var entries: [BackupEntry] = []
        var bytes: Int64 = 0
        for path in paths.sorted() {
            let entry = try BackupFiles.hash(staging.appendingPathComponent(path), path: path)
            entries.append(entry)
            bytes += entry.byteCount
            guard bytes <= BackupFiles.totalLimit, entries.count < BackupFiles.entryLimit else {
                throw CollectionBackupError.limitExceeded
            }
        }
        try BackupFiles.write(BackupManifest(formatVersion: 1, databaseVersion: metadata.schemaVersion,
            collectionID: metadata.id, createdAt: EpochMilliseconds(date: now), files: entries),
            to: staging.appendingPathComponent("manifest.json"))
    }

    static func create(staging: URL, archiveURL: URL) throws {
        let manifest = try JSONDecoder().decode(BackupManifest.self,
            from: Data(contentsOf: staging.appendingPathComponent("manifest.json")))
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for path in ["manifest.json"] + manifest.files.map(\.path) {
            try Task.checkCancellation()
            // Stored entries avoid pathological compression ratios in our own SQLite snapshots.
            try archive.addEntry(with: path, relativeTo: staging, compressionMethod: .none)
        }
    }

    static func extract(_ url: URL, to staging: URL) throws -> BackupManifest {
        try MediaFiles.regular(url)
        let archive = try Archive(url: url, accessMode: .read)
        var seen = Set<String>()
        var total: Int64 = 0
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("Media"), withIntermediateDirectories: true)
        for entry in archive {
            try Task.checkCancellation()
            guard entry.type == .file, BackupFiles.allowed(entry.path), seen.insert(entry.path).inserted else {
                throw CollectionBackupError.invalidArchive
            }
            guard seen.count <= BackupFiles.entryLimit,
                  entry.uncompressedSize <= UInt64(BackupFiles.totalLimit),
                  entry.uncompressedSize <= max(1, min(entry.compressedSize, UInt64(BackupFiles.totalLimit))) * 1000 else {
                throw CollectionBackupError.limitExceeded
            }
            let target = staging.appendingPathComponent(entry.path)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw CollectionBackupError.invalidArchive
            }
            let output = try FileHandle(forWritingTo: target)
            do {
                var count: Int64 = 0
                let crc = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    count += Int64(chunk.count)
                    total += Int64(chunk.count)
                    guard total <= BackupFiles.totalLimit,
                          count <= (entry.path == "manifest.json" ? BackupFiles.manifestLimit : BackupFiles.totalLimit) else {
                        throw CollectionBackupError.limitExceeded
                    }
                    try output.write(contentsOf: chunk)
                }
                guard crc == entry.checksum, count == entry.uncompressedSize else {
                    throw CollectionBackupError.invalidArchive
                }
                try output.synchronize()
                try output.close()
            } catch { try? output.close(); throw error }
        }
        guard seen.contains("manifest.json") else { throw CollectionBackupError.invalidArchive }
        let manifest = try JSONDecoder().decode(BackupManifest.self,
            from: Data(contentsOf: staging.appendingPathComponent("manifest.json")))
        guard manifest.formatVersion == 1, manifest.databaseVersion == CollectionDatabase.schemaVersion else {
            throw CollectionBackupError.unsupportedVersion
        }
        let paths = manifest.files.map(\.path)
        guard paths.count < BackupFiles.entryLimit, Set(paths).count == paths.count,
              !paths.contains("manifest.json"), Set(paths + ["manifest.json"]) == seen,
              seen.contains("collection.json"), seen.contains("collection.sqlite") else {
            throw CollectionBackupError.invalidArchive
        }
        for entry in manifest.files {
            guard entry.byteCount >= 0, BackupFiles.hashString(entry.sha256),
                  try BackupFiles.hash(staging.appendingPathComponent(entry.path), path: entry.path) == entry else {
                throw CollectionBackupError.invalidArchive
            }
        }
        let metadata = try validateDatabase(staging)
        guard metadata.id == manifest.collectionID, metadata.schemaVersion == manifest.databaseVersion else {
            throw CollectionBackupError.invalidArchive
        }
        return manifest
    }

    static func validateDatabase(_ directory: URL) throws -> CollectionMetadata {
        let manifest = try JSONDecoder().decode(CollectionManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("collection.json")))
        guard manifest.schemaVersion == 1, manifest.containerVersion == 1 else {
            throw CollectionBackupError.unsupportedVersion
        }
        let reader = try CollectionMigrations.readOnlyQueue(directory.appendingPathComponent("collection.sqlite"))
        defer { try? reader.close() }
        return try reader.read { db in
            guard try CollectionMigrations.validate(db, migrations: CollectionMigrations.current) == CollectionDatabase.schemaVersion else {
                throw CollectionBackupError.unsupportedVersion
            }
            try CollectionDatabase.checkIntegrity(db)
            let metadata = try CollectionMetadata.fetch(db)
            guard metadata.id == manifest.id else { throw CollectionBackupError.invalidArchive }
            let media = try assets(db)
            guard media.count <= 100_000 else { throw CollectionBackupError.limitExceeded }
            for asset in media { try MediaFiles.verify(asset, root: directory) }
            let actual = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Media").path)
            guard Set(actual.map { "Media/" + $0 }) == Set(media.map(\.relativePath)) else {
                throw CollectionBackupError.invalidArchive
            }
            return metadata
        }
    }

    private static func assets(_ db: Database) throws -> [MediaAsset] {
        try Row.fetchAll(db, sql: "SELECT * FROM media_assets LIMIT 100001").map { row in
            let asset = try MediaAsset(id: MediaID(uuidString: row["id"]), sha256: row["sha256"],
                relativePath: row["relativePath"], uti: row["uti"], byteCount: row["byteCount"])
            try MediaManifest(schemaVersion: 1, asset: asset).validate()
            return asset
        }
    }
}
