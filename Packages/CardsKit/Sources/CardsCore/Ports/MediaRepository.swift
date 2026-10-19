import Foundation

public struct MediaAsset: Codable, Equatable, Sendable {
    public let id: MediaID
    public let sha256: String
    public let relativePath: String
    public let uti: String
    public let byteCount: Int64

    public init(id: MediaID, sha256: String, relativePath: String, uti: String, byteCount: Int64) {
        self.id = id
        self.sha256 = sha256
        self.relativePath = relativePath
        self.uti = uti
        self.byteCount = byteCount
    }
}

public enum MediaStorageError: Error, Equatable, Sendable {
    case unsupportedFormat
    case invalidContent
    case sizeLimitExceeded
    case pixelLimitExceeded
    case integrityFailure
    case invalidSource
    case notFound
    case staleContext
    case cancelled
    case fileSystem(Int)
}

/// Import creates a shared immutable asset; attaching it to a Note requires explicit Save.
public protocol MediaRepository: Sendable {
    func importFile(_ source: URL) async throws -> MediaAsset
    func asset(id: MediaID) async throws -> MediaAsset?
    func fileURL(id: MediaID) async throws -> URL
    func thumbnail(id: MediaID, maxPixelSize: Int) async throws -> Data
}
