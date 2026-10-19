import CardsCore
import Foundation
import GRDB

/// Startup uses this only while holding the collection lease, before exposing any repository.
enum MediaJournal {
    static let kind = "media.v1"

    static func fetch(_ db: Database, id: MediaID) throws -> MediaAsset? {
        try Row.fetchOne(db, sql: "SELECT * FROM media_assets WHERE id = ?",
                        arguments: [id.rawValue.uuidString.lowercased()]).map(asset)
    }

    static func asset(_ row: Row) throws -> MediaAsset {
        let value = try MediaAsset(id: MediaID(uuidString: row["id"]), sha256: row["sha256"],
            relativePath: row["relativePath"], uti: row["uti"], byteCount: row["byteCount"])
        try MediaManifest(schemaVersion: 1, asset: value).validate()
        guard (row["lifecycleState"] as String) != "trashed" else { throw MediaStorageError.notFound }
        return value
    }

    static func finish(_ pool: DatabasePool, id: String, staging: URL, root: URL) throws {
        try MediaFiles.directory(root.appendingPathComponent("Staging"))
        if FileManager.default.fileExists(atPath: staging.path) {
            try MediaFiles.directory(staging)
            try FileManager.default.removeItem(at: staging)
            try MediaFiles.synchronizeDirectory(root.appendingPathComponent("Staging"))
        }
        try pool.write { db in
            try db.execute(sql: "UPDATE operation_journal SET phase = 'cleanup', completedAt = ? WHERE id = ?",
                arguments: [try EpochMilliseconds(date: Date()).rawValue, id])
        }
    }

    static func apply(pool: DatabasePool, root: URL, id: UUID, manifest: MediaManifest,
                      fault: MediaFault?) throws -> MediaAsset {
        try manifest.validate()
        let operationID = id.uuidString.lowercased()
        let relative = "Staging/\(operationID)"
        let staging = root.appendingPathComponent(relative)
        let json = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO operation_journal(id,kind,phase,stagingRelativePath,manifestJSON,startedAt)
                VALUES (?,?,'prepare',?,?,?)
                """, arguments: [operationID, kind, relative, json, try EpochMilliseconds(date: Date()).rawValue])
        }
        try fault?(.prepare)
        try MediaFiles.publish(manifest.asset, staging: staging.appendingPathComponent("asset"), root: root)
        try fault?(.publishedFile)
        try pool.write { db in
            try db.execute(sql: "UPDATE operation_journal SET phase = 'publish' WHERE id = ?", arguments: [operationID])
        }
        try fault?(.publish)
        let result = try pool.write { db in
            let result: MediaAsset
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM media_assets WHERE sha256 = ?",
                                         arguments: [manifest.asset.sha256]) {
                result = try asset(row)
                guard result.relativePath == manifest.asset.relativePath, result.uti == manifest.asset.uti,
                      result.byteCount == manifest.asset.byteCount else { throw MediaStorageError.integrityFailure }
            } else {
                result = manifest.asset
                try db.execute(sql: """
                    INSERT INTO media_assets(id,sha256,relativePath,uti,byteCount,createdAt,lifecycleState)
                    VALUES (?,?,?,?,?,?,'published')
                    """, arguments: [result.id.rawValue.uuidString.lowercased(), result.sha256, result.relativePath,
                        result.uti, result.byteCount, try EpochMilliseconds(date: Date()).rawValue])
            }
            try db.execute(sql: "UPDATE operation_journal SET phase = 'commit' WHERE id = ?", arguments: [operationID])
            return result
        }
        try fault?(.commit)
        // A committed asset is a successful outcome even if housekeeping must wait until startup.
        do {
            try MediaFiles.directory(staging)
            try FileManager.default.removeItem(at: staging)
            try MediaFiles.synchronizeDirectory(root.appendingPathComponent("Staging"))
            try fault?(.removedStaging)
            try finish(pool, id: operationID, staging: staging, root: root)
        } catch { /* committed journal is the durable retry record */ }
        return result
    }

    static func recover(pool: DatabasePool, root: URL) throws {
        let rows = try pool.read { try Row.fetchAll($0, sql: "SELECT * FROM operation_journal WHERE kind = ? AND completedAt IS NULL",
                                                  arguments: [kind]) }
        for row in rows {
            let id: String = row["id"]
            guard let uuid = UUID(uuidString: id), id == uuid.uuidString.lowercased(),
                  (row["stagingRelativePath"] as String) == "Staging/\(id)" else {
                throw MediaStorageError.integrityFailure
            }
            let manifest = try JSONDecoder().decode(MediaManifest.self, from: Data((row["manifestJSON"] as String).utf8))
            try manifest.validate()
            let phase: String = row["phase"]
            guard ["prepare", "publish", "commit"].contains(phase) else { throw MediaStorageError.integrityFailure }
            let existing = try pool.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM media_assets WHERE sha256 = ?",
                                 arguments: [manifest.asset.sha256]).map(asset)
            }
            if let existing {
                guard existing.sha256 == manifest.asset.sha256, existing.relativePath == manifest.asset.relativePath,
                      existing.uti == manifest.asset.uti, existing.byteCount == manifest.asset.byteCount else {
                    throw MediaStorageError.integrityFailure
                }
                try MediaFiles.verify(existing, root: root)
            } else if phase == "commit" {
                throw MediaStorageError.integrityFailure
            }
            // Published orphans remain immutable; never delete Media without full GC/undo knowledge.
            try finish(pool, id: id, staging: root.appendingPathComponent("Staging/\(id)"), root: root)
        }
    }
}
