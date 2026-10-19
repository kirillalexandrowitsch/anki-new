import CardsCore
import CryptoKit
import Darwin
import Foundation

public enum CollectionBackupError: Error, Equatable, Sendable {
    case invalidArchive, unsupportedVersion, limitExceeded, invalidDestination, operationInProgress, staleContext
}

enum BackupCheckpoint: String, CaseIterable, Sendable {
    case journal, oldRenamed, newRenamed, registry, committed
}
typealias BackupFault = @Sendable (BackupCheckpoint) throws -> Void

struct BackupEntry: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

struct BackupManifest: Codable, Sendable {
    let formatVersion: Int
    let databaseVersion: Int
    let collectionID: CollectionID
    let createdAt: EpochMilliseconds
    let files: [BackupEntry]
}

enum BackupFiles {
    static let totalLimit: Int64 = 2 * 1024 * 1024 * 1024
    static let manifestLimit: Int64 = 32 * 1024 * 1024
    static let entryLimit = 100_003
    static var manager: FileManager { FileManager.default }

    static func allowed(_ path: String) -> Bool {
        if ["manifest.json", "collection.json", "collection.sqlite"].contains(path) { return true }
        guard path.hasPrefix("Media/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else { return false }
        let name = String(path.dropFirst(6))
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && hashString(String(parts[0])) && MediaFiles.formats.values.contains(String(parts[1]))
    }

    static func hashString(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func hash(_ url: URL, path: String) throws -> BackupEntry {
        try MediaFiles.regular(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(chunk.count)
            guard bytes <= totalLimit else { throw CollectionBackupError.limitExceeded }
            digest.update(data: chunk)
        }
        return BackupEntry(path: path, byteCount: bytes,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func syncFile(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try syncFile(url)
        try MediaFiles.synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func rename(_ source: URL, to target: URL) throws {
        try manager.moveItem(at: source, to: target)
        try MediaFiles.synchronizeDirectory(source.deletingLastPathComponent())
        try MediaFiles.synchronizeDirectory(target.deletingLastPathComponent())
    }

    static func outside(_ url: URL, root: URL) -> Bool {
        let value = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        return url.isFileURL && value != base && !value.hasPrefix(base + "/")
    }
}
