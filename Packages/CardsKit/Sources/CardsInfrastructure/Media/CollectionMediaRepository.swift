import CardsCore
import Foundation

actor CollectionMediaRepository: MediaRepository {
    private let root: URL
    private let writer: CollectionWriter
    private let fault: MediaFault?
    private var accepting = true

    init(root: URL, writer: CollectionWriter, fault: MediaFault? = nil) {
        self.root = root
        self.writer = writer
        self.fault = fault
    }

    func close() { accepting = false }

    private func requireActive() throws {
        guard accepting else { throw MediaStorageError.staleContext }
    }

    func importFile(_ source: URL) async throws -> MediaAsset {
        try requireActive()
        guard !Task.isCancelled else { throw MediaStorageError.cancelled }
        let files = FileManager.default
        try MediaFiles.directory(root.appendingPathComponent("Staging"))
        let id = UUID()
        let staging = root.appendingPathComponent("Staging/\(id.uuidString.lowercased())")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        let manifest: MediaManifest
        do {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let target = staging.appendingPathComponent("asset")
            let (hash, count) = try MediaFiles.copy(source, to: target)
            let uti = try MediaFiles.contentType(target, size: count)
            guard let ext = MediaFiles.formats[uti] else { throw MediaStorageError.unsupportedFormat }
            manifest = MediaManifest(schemaVersion: 1, asset: MediaAsset(id: MediaID(), sha256: hash,
                relativePath: "Media/\(hash).\(ext)", uti: uti, byteCount: count))
            try MediaFiles.synchronizeDirectory(staging)
            try MediaFiles.synchronizeDirectory(root.appendingPathComponent("Staging"))
            guard !Task.isCancelled else { throw MediaStorageError.cancelled }
        } catch {
            try? files.removeItem(at: staging) // not journaled, private preparation only
            throw error
        }
        // Once queued, close waits behind this synchronous final phase on the shared writer.
        do {
            return try await writer.mediaAccess { pool in
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: staging) // still private, before journal prepare
                    throw MediaStorageError.cancelled
                }
                return try MediaJournal.apply(pool: pool, root: self.root, id: id, manifest: manifest, fault: self.fault)
            }
        } catch CollectionRepositoryError.staleContext {
            throw MediaStorageError.staleContext
        }
    }

    func asset(id: MediaID) async throws -> MediaAsset? {
        try requireActive()
        let asset = try await writer.read { try MediaJournal.fetch($0, id: id) }
        try requireActive()
        return asset
    }

    func fileURL(id: MediaID) async throws -> URL {
        guard let asset = try await asset(id: id) else { throw MediaStorageError.notFound }
        try requireActive()
        try MediaFiles.verify(asset, root: root)
        return root.appendingPathComponent(asset.relativePath)
    }

    func thumbnail(id: MediaID, maxPixelSize: Int) async throws -> Data {
        let url = try await fileURL(id: id)
        try requireActive()
        return try MediaFiles.thumbnail(url, maxPixelSize: maxPixelSize)
    }
}
