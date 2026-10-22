import CardsCore
import CryptoKit
import Foundation
import GRDB
import ZIPFoundation

public enum CollectionExportError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedContent, invalidDestination, invalidArchive, limitExceeded
    public var errorDescription: String? {
        switch self {
        case .unsupportedContent: "CSV поддерживает только Basic v1. Выберите cardsdeck или резервную копию."
        case .invalidDestination: "Выберите новое имя вне папки коллекции. Существующие файлы не заменяются."
        case .invalidArchive: "Не удалось проверить экспорт. Выберите другую папку и повторите."
        case .limitExceeded: "Превышен безопасный размер экспорта. Используйте резервную копию."
        }
    }
}

/// Called only with an immutable, verified T011 snapshot. No live database or media
/// can change between serializing content, hashing attachments and publishing.
enum CollectionExporter {
    static let columns = ["note_id", "front", "back", "pronunciation", "examples_json", "tags_json", "deck_path", "type", "variant"]

    static func create(snapshot: URL, destination: URL, format: CollectionExportFormat, safe: Bool) throws {
        let reader = try CollectionMigrations.readOnlyQueue(snapshot.appendingPathComponent("collection.sqlite"))
        defer { try? reader.close() }
        if format == .csv || format == .tsv {
            try reader.read { db in try csv(db, destination: destination, tab: format == .tsv, safe: safe) }
        } else {
            try reader.read { db in try deck(db, snapshot: snapshot, destination: destination) }
        }
    }

    private static func csv(_ db: Database, destination: URL, tab: Bool, safe: Bool) throws {
        let output = try output(destination)
        defer { try? output.close() }
        try output.write(contentsOf: DelimitedTextWriter.record(columns, tabSeparated: tab, safeSpreadsheet: safe))
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT n.id, n.fieldsJSON, n.contentVersion, t.stableKey, c.variantKey, c.deckID
            FROM cards c JOIN notes n ON n.id=c.noteID JOIN note_types t ON t.id=n.noteTypeID
            JOIN decks d ON d.id=c.deckID
            WHERE c.deletedAt IS NULL AND n.deletedAt IS NULL AND d.deletedAt IS NULL
            ORDER BY n.id, c.id
            """)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var count = 0
        var byteCount = 0
        while let row = try cursor.next() {
            try Task.checkCancellation()
            count += 1
            guard count <= 100_000 else { throw CollectionExportError.limitExceeded }
            guard row["stableKey"] as String == BasicNoteType.stableKey, row["contentVersion"] as Int == 1 else {
                throw CollectionExportError.unsupportedContent
            }
            let content = try JSONDecoder().decode(BasicNoteContent.self, from: Data((row["fieldsJSON"] as String).utf8))
            try content.validate()
            let tags = try String.fetchAll(db, sql: """
                SELECT t.name FROM tags t JOIN note_tags nt ON nt.tagID=t.id
                WHERE nt.noteID=? AND t.deletedAt IS NULL ORDER BY t.normalizedName, t.id
                """, arguments: [row["id"] as String])
            let path = try String.fetchAll(db, sql: """
                WITH RECURSIVE parents(id,parentID,name,depth) AS (
                    SELECT id,parentID,name,0 FROM decks WHERE id=? UNION ALL
                    SELECT d.id,d.parentID,d.name,p.depth+1 FROM decks d JOIN parents p ON d.id=p.parentID
                ) SELECT name FROM parents ORDER BY depth DESC
                """, arguments: [row["deckID"] as String]).joined(separator: "::")
            let fields = [row["id"] as String, content.front, content.back, content.pronunciation,
                String(decoding: try encoder.encode(content.examples), as: UTF8.self),
                String(decoding: try encoder.encode(tags), as: UTF8.self), path,
                row["stableKey"] as String, row["variantKey"] as String]
            // Every produced canonical field fits the reader's bounded-cell contract.
            guard fields.allSatisfy({ $0.utf8.count + (safe ? 1 : 0) <= 1024 * 1024 }) else {
                throw CollectionExportError.limitExceeded
            }
            let data = DelimitedTextWriter.record(fields, tabSeparated: tab, safeSpreadsheet: safe)
            byteCount += data.count
            guard byteCount <= 256 * 1024 * 1024 - 1024 else { throw CollectionExportError.limitExceeded }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    struct Manifest: Encodable {
        let format = "cardsdeck"
        let formatVersion = 1
        let contentVersion = 1
        let includesProgress = false
        let files: [BackupEntry]
    }

    private static func deck(_ db: Database, snapshot: URL, destination: URL) throws {
        let content = snapshot.appendingPathComponent("content.json")
        let output = try output(content)
        defer { try? output.close() }
        try output.write(contentsOf: Data("{\"schemaVersion\":1,\"tables\":{".utf8))
        let liveCards = "SELECT c.id FROM cards c JOIN notes n ON n.id=c.noteID JOIN decks d ON d.id=c.deckID WHERE c.deletedAt IS NULL AND n.deletedAt IS NULL AND d.deletedAt IS NULL"
        let liveNotes = "SELECT noteID FROM cards WHERE id IN (\(liveCards))"
        let queries: [(String, String)] = [
            ("decks", "SELECT * FROM decks WHERE deletedAt IS NULL ORDER BY id"),
            ("note_types", "SELECT * FROM note_types WHERE id IN (SELECT noteTypeID FROM notes WHERE id IN (\(liveNotes))) ORDER BY id"),
            ("notes", "SELECT * FROM notes WHERE id IN (\(liveNotes)) ORDER BY id"),
            ("cards", "SELECT * FROM cards WHERE id IN (\(liveCards)) ORDER BY id"),
            ("tags", "SELECT * FROM tags WHERE deletedAt IS NULL AND id IN (SELECT tagID FROM note_tags WHERE noteID IN (\(liveNotes))) ORDER BY id"),
            ("note_tags", "SELECT * FROM note_tags WHERE noteID IN (\(liveNotes)) AND tagID IN (SELECT id FROM tags WHERE deletedAt IS NULL) ORDER BY noteID,tagID"),
            ("note_media", "SELECT * FROM note_media WHERE noteID IN (\(liveNotes)) ORDER BY noteID,fieldID,role,orderIndex")
        ]
        for (index, item) in queries.enumerated() {
            try output.write(contentsOf: Data(((index == 0 ? "" : ",") + "\"\(item.0)\":[").utf8))
            let cursor = try Row.fetchCursor(db, sql: item.1)
            var count = 0
            while let row = try cursor.next() {
                try Task.checkCancellation()
                var object: [String: Any] = [:]
                for (name, value) in row {
                    if item.0 == "decks" && name == "presetID" { continue }
                    switch value.storage {
                    case .null: object[name] = NSNull()
                    case .int64(let number): object[name] = number
                    case .double(let number): object[name] = number
                    case .string(let string): object[name] = string
                    case .blob: throw CollectionExportError.unsupportedContent
                    }
                }
                if count > 0 { try output.write(contentsOf: Data(",".utf8)) }
                try output.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                count += 1
                guard count <= 250_000, try output.offset() <= UInt64(BackupFiles.totalLimit) else {
                    throw CollectionExportError.limitExceeded
                }
            }
            try output.write(contentsOf: Data("]".utf8))
        }
        try output.write(contentsOf: Data("}}".utf8)); try output.synchronize(); try output.close()
        let media = try String.fetchAll(db, sql: "SELECT relativePath FROM media_assets WHERE id IN (SELECT mediaID FROM note_media WHERE noteID IN (\(liveNotes))) ORDER BY relativePath")
        let paths = ["content.json"] + media
        var entries: [BackupEntry] = []
        for path in paths { entries.append(try BackupFiles.hash(snapshot.appendingPathComponent(path), path: path)) }
        guard entries.reduce(Int64(0), { $0 + $1.byteCount }) <= BackupFiles.totalLimit else { throw CollectionExportError.limitExceeded }
        let manifest = snapshot.appendingPathComponent("deck-manifest.json")
        try BackupFiles.write(Manifest(files: entries), to: manifest)
        let archive = try Archive(url: destination, accessMode: .create)
        try archive.addEntry(with: "manifest.json", fileURL: manifest, compressionMethod: .none)
        for path in paths { try archive.addEntry(with: path, relativeTo: snapshot, compressionMethod: .none) }
        // Verify all bytes from the completed ZIP, not only the input snapshot.
        let verify = try Archive(url: destination, accessMode: .read)
        for entry in entries {
            guard let zipped = verify[entry.path] else { throw CollectionExportError.invalidArchive }
            var hash = SHA256(); var count: Int64 = 0
            let crc = try verify.extract(zipped) { data in
                try Task.checkCancellation(); hash.update(data: data); count += Int64(data.count)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard crc == zipped.checksum, count == entry.byteCount, digest == entry.sha256 else {
                throw CollectionExportError.invalidArchive
            }
        }
    }

    private static func output(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CollectionExportError.invalidDestination }
        return try FileHandle(forWritingTo: url)
    }
}
