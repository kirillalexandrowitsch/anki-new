import CardsCore
@testable import CardsInfrastructure
import CryptoKit
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers

private struct MediaFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    func remove() { try? FileManager.default.removeItem(at: root) }
    func directory(_ context: CollectionContext) -> URL {
        root.appendingPathComponent("Collections/\(context.id.rawValue.uuidString.lowercased())")
    }
    func image(width: Int = 80, height: Int = 40) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = root.appendingPathComponent("\(UUID().uuidString).misleading-mp3")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
    func query<T>(_ context: CollectionContext, _ body: (Database) throws -> T) throws -> T {
        let queue = try CollectionMigrations.readOnlyQueue(directory(context).appendingPathComponent("collection.sqlite"))
        defer { try? queue.close() }
        return try queue.read(body)
    }
    func mutate(_ context: CollectionContext, _ sql: String) throws {
        let queue = try DatabaseQueue(path: directory(context).appendingPathComponent("collection.sqlite").path)
        defer { try? queue.close() }
        try queue.write { try $0.execute(sql: sql) }
    }
    func count(_ context: CollectionContext) throws -> Int {
        try query(context) { try Int.fetchOne($0, sql: "SELECT count(*) FROM media_assets")! }
    }
}

private enum MediaCrash: Error { case injected }

@Test func mediaDeduplicatesActualContentAcrossNamesConcurrentImportsAndReopen() async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let original = try Data(contentsOf: source)
    let store = CollectionStore(root: fixture.root)
    let context = try await store.open()
    let media = try await store.media(generation: context.generation)
    let copy = fixture.root.appendingPathComponent("другое имя.jpg")
    try original.write(to: copy)
    let assets = try await withThrowingTaskGroup(of: MediaAsset.self) { group in
        for index in 0..<12 { group.addTask { try await media.importFile(index % 2 == 0 ? source : copy) } }
        var results: [MediaAsset] = []
        for try await result in group { results.append(result) }
        return results
    }
    let first = try #require(assets.first)
    #expect(assets.count == 12 && assets.allSatisfy { $0 == first })
    #expect(first.uti == UTType.png.identifier)
    #expect(first.sha256 == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
    #expect(first.relativePath == "Media/\(first.sha256).png")
    #expect(first.byteCount == original.count)
    #expect(try fixture.count(context) == 1)
    let directory = fixture.directory(context)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Media").path).count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Staging").path).isEmpty)
    #expect(try Data(contentsOf: await media.fileURL(id: first.id)) == original)
    let preview = try await media.thumbnail(id: first.id, maxPixelSize: 24)
    let image = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
    #expect(decoded.width == 24 && decoded.height == 12)
    #expect(try Data(contentsOf: directory.appendingPathComponent(first.relativePath)) == original)
    try await store.close(generation: context.generation)
    await #expect(throws: MediaStorageError.staleContext) { try await media.importFile(source) }
    await #expect(throws: MediaStorageError.staleContext) { try await media.fileURL(id: first.id) }
    let next = try await store.open()
    let reopened = try await store.media(generation: next.generation)
    #expect(try await reopened.importFile(copy) == first)
    #expect(try await reopened.asset(id: first.id) == first)
    await #expect(throws: MediaStorageError.staleContext) { try await store.media(generation: context.generation) }
    try await store.close(generation: next.generation)
}

@Test(arguments: MediaCheckpoint.allCases)
func mediaCrashRecoveryNeverCommitsAnUnpublishedReference(checkpoint: MediaCheckpoint) async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let store = CollectionStore(root: fixture.root, mediaFault: { point in
        #expect(!Thread.isMainThread)
        if point == checkpoint { throw MediaCrash.injected }
    })
    let context = try await store.open()
    let media = try await store.media(generation: context.generation)
    if checkpoint == .removedStaging {
        _ = try await media.importFile(source) // cleanup failure must preserve committed outcome
    } else {
        await #expect(throws: MediaCrash.injected) { try await media.importFile(source) }
    }
    let committed = checkpoint == .commit || checkpoint == .removedStaging
    #expect(try fixture.count(context) == (committed ? 1 : 0))
    let mediaDirectory = fixture.directory(context).appendingPathComponent("Media")
    #expect(try FileManager.default.contentsOfDirectory(atPath: mediaDirectory.path).count == (checkpoint == .prepare ? 0 : 1))
    // An active operation from another kind and unknown staging must not be collected.
    let unknown = fixture.directory(context).appendingPathComponent("Staging/another-active-operation")
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
    try Data("synthetic active payload".utf8).write(to: unknown.appendingPathComponent("keep"))
    try fixture.mutate(context, "INSERT INTO operation_journal(id,kind,phase,stagingRelativePath,manifestJSON,startedAt) VALUES ('other','import','prepare','Staging/another-active-operation','{\"schemaVersion\":1}',0)")
    let orphan = mediaDirectory.appendingPathComponent("unclaimed-orphan.bin")
    try Data("orphan retained for future GC".utf8).write(to: orphan)
    try await store.close(generation: context.generation)
    let recovered = CollectionStore(root: fixture.root)
    let next = try await recovered.open()
    #expect(try fixture.count(next) == (committed ? 1 : 0))
    #expect(FileManager.default.fileExists(atPath: unknown.appendingPathComponent("keep").path))
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    #expect(try fixture.query(next) { try String.fetchOne($0, sql: "SELECT phase FROM operation_journal WHERE id='other' AND completedAt IS NULL") } == "prepare")
    #expect(try fixture.query(next) { try Int.fetchOne($0, sql: "SELECT count(*) FROM operation_journal WHERE kind='media.v1' AND phase='cleanup' AND completedAt IS NOT NULL") } == 1)
    let fresh = try await recovered.media(generation: next.generation)
    let asset = try await fresh.importFile(source)
    #expect(try fixture.count(next) == 1)
    #expect(try Data(contentsOf: await fresh.fileURL(id: asset.id)) == Data(contentsOf: source))
    try await recovered.close(generation: next.generation)
}

@Test func mediaSQLFailureLeavesPublishedOrphanAndRetryRecoversWithoutDuplicate() async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let store = CollectionStore(root: fixture.root)
    let context = try await store.open()
    try fixture.mutate(context, "CREATE TRIGGER fail_media BEFORE INSERT ON media_assets BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
    let media = try await store.media(generation: context.generation)
    await #expect(throws: (any Error).self) { try await media.importFile(source) }
    #expect(try fixture.count(context) == 0)
    #expect(try fixture.query(context) { try String.fetchOne($0, sql: "SELECT phase FROM operation_journal") } == "publish")
    try fixture.mutate(context, "DROP TRIGGER fail_media")
    let asset = try await media.importFile(source)
    #expect(try fixture.count(context) == 1)
    try await store.close(generation: context.generation)
    let next = try await store.open()
    #expect(try fixture.count(next) == 1)
    #expect(try await store.media(generation: next.generation).asset(id: asset.id) == asset)
    try await store.close(generation: next.generation)
}

@Test func mediaRejectsCorruptionOversizeSymlinksAndCancellationBeforeDatabaseWrites() async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let store = CollectionStore(root: fixture.root)
    let context = try await store.open()
    let media = try await store.media(generation: context.generation)
    let bad = fixture.root.appendingPathComponent("corrupt.png")
    try Data((try Data(contentsOf: source)).prefix(48)).write(to: bad)
    await #expect(throws: (any Error).self) { try await media.importFile(bad) }
    try Data("not an image or audio".utf8).write(to: bad)
    await #expect(throws: MediaStorageError.invalidContent) { try await media.importFile(bad) }
    let link = fixture.root.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    await #expect(throws: MediaStorageError.invalidSource) { try await media.importFile(link) }
    let huge = fixture.root.appendingPathComponent("huge.wav")
    #expect(FileManager.default.createFile(atPath: huge.path, contents: Data()))
    let handle = try FileHandle(forWritingTo: huge)
    try handle.truncate(atOffset: UInt64(MediaFiles.audioLimit + 1))
    try handle.close()
    await #expect(throws: MediaStorageError.sizeLimitExceeded) { try await media.importFile(huge) }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await media.importFile(source)
    }
    await #expect(throws: MediaStorageError.cancelled) { try await cancelled.value }
    #expect(try fixture.count(context) == 0)
    #expect(try fixture.query(context) { try Int.fetchOne($0, sql: "SELECT count(*) FROM operation_journal") } == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory(context).appendingPathComponent("Staging").path).isEmpty)
    try await store.close(generation: context.generation)
}

@Test func mediaNeverOverwritesExistingHashFileAndDetectsMissingCommittedContentOnRecovery() async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let store = CollectionStore(root: fixture.root, mediaFault: { if $0 == .commit { throw MediaCrash.injected } })
    let context = try await store.open()
    let media = try await store.media(generation: context.generation)
    await #expect(throws: MediaCrash.injected) { try await media.importFile(source) }
    let path = try #require(fixture.query(context) { try String.fetchOne($0, sql: "SELECT relativePath FROM media_assets") })
    let destination = fixture.directory(context).appendingPathComponent(path)
    let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o444)
    // Simulate external corruption explicitly, bypassing the immutable-file protection.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    try Data("synthetic corruption".utf8).write(to: destination)
    await #expect(throws: MediaStorageError.integrityFailure) { try await media.importFile(source) }
    #expect(try Data(contentsOf: destination) == Data("synthetic corruption".utf8))
    try await store.close(generation: context.generation)
    let fresh = CollectionStore(root: fixture.root)
    await #expect(throws: MediaStorageError.integrityFailure) { try await fresh.open() }
    try FileManager.default.removeItem(at: destination)
    await #expect(throws: MediaStorageError.integrityFailure) { try await fresh.open() }
    // Recovery failure releases pool/lease; externally restoring the original permits a clean retry.
    try Data(contentsOf: source).write(to: destination)
    let next = try await fresh.open()
    #expect(try fixture.count(next) == 1)
    try await fresh.close(generation: next.generation)
}

@Test func mediaRecoveryRejectsUnsafeManifestWithoutDeletingAnything() async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let store = CollectionStore(root: fixture.root, mediaFault: { if $0 == .prepare { throw MediaCrash.injected } })
    let context = try await store.open()
    await #expect(throws: MediaCrash.injected) { try await store.media(generation: context.generation).importFile(source) }
    try fixture.mutate(context, "UPDATE operation_journal SET stagingRelativePath='Staging/../Media'")
    try await store.close(generation: context.generation)
    let fresh = CollectionStore(root: fixture.root)
    await #expect(throws: MediaStorageError.integrityFailure) { try await fresh.open() }
    #expect(try fixture.count(context) == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory(context).appendingPathComponent("Staging").path).count == 1)
}

@Test func mediaRecognizesSyntheticWAVByContentAndRejectsAudioAsThumbnail() async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    var wav = Data()
    func ascii(_ value: String) { wav.append(contentsOf: value.utf8) }
    func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) } }
    ascii("RIFF"); u32(36 + 1600); ascii("WAVEfmt "); u32(16)
    u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
    ascii("data"); u32(1600); wav.append(Data(repeating: 0, count: 1600))
    let source = fixture.root.appendingPathComponent("synthetic.png")
    try wav.write(to: source)
    let store = CollectionStore(root: fixture.root)
    let context = try await store.open()
    let media = try await store.media(generation: context.generation)
    let asset = try await media.importFile(source)
    #expect(asset.uti == "com.microsoft.waveform-audio" && asset.relativePath.hasSuffix(".wav"))
    #expect(try await media.importFile(source) == asset)
    #expect(try Data(contentsOf: await media.fileURL(id: asset.id)) == wav)
    await #expect(throws: MediaStorageError.invalidContent) { try await media.thumbnail(id: asset.id, maxPixelSize: 32) }
    try await store.close(generation: context.generation)
}

@Test func mediaImageLimitsBoundBytesPixelsAndThumbnailDimensions() async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let wide = try fixture.image(width: 16385, height: 1)
    let store = CollectionStore(root: fixture.root)
    let context = try await store.open()
    let media = try await store.media(generation: context.generation)
    await #expect(throws: MediaStorageError.pixelLimitExceeded) { try await media.importFile(wide) }
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: UInt64(MediaFiles.imageLimit + 1))
    try handle.close()
    await #expect(throws: MediaStorageError.sizeLimitExceeded) { try await media.importFile(source) }
    #expect(try fixture.count(context) == 0)
    let valid = try fixture.image()
    let asset = try await media.importFile(valid)
    await #expect(throws: MediaStorageError.pixelLimitExceeded) { try await media.thumbnail(id: asset.id, maxPixelSize: 0) }
    await #expect(throws: MediaStorageError.pixelLimitExceeded) { try await media.thumbnail(id: asset.id, maxPixelSize: 513) }
    try await store.close(generation: context.generation)
}

@Test(arguments: ["schemaVersion", "phase"])
func mediaRecoveryRejectsUnknownProtocolVersions(field: String) async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let store = CollectionStore(root: fixture.root, mediaFault: { if $0 == .prepare { throw MediaCrash.injected } })
    let context = try await store.open()
    await #expect(throws: MediaCrash.injected) { try await store.media(generation: context.generation).importFile(source) }
    if field == "schemaVersion" {
        try fixture.mutate(context, "UPDATE operation_journal SET manifestJSON=json_set(manifestJSON,'$.schemaVersion',99)")
    } else {
        try fixture.mutate(context, "UPDATE operation_journal SET phase='unknown-future-phase'")
    }
    try await store.close(generation: context.generation)
    let fresh = CollectionStore(root: fixture.root)
    await #expect(throws: MediaStorageError.integrityFailure) { try await fresh.open() }
    #expect(try fixture.query(context) { try Int.fetchOne($0, sql: "SELECT count(*) FROM operation_journal WHERE completedAt IS NULL") } == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory(context).appendingPathComponent("Staging").path).count == 1)
}

@Test func mediaCancellationAfterPrepareReturnsCommittedOutcome() async throws {
    let fixture = MediaFixture()
    defer { fixture.remove() }
    let source = try fixture.image()
    let store = CollectionStore(root: fixture.root, mediaFault: { checkpoint in
        if checkpoint == .prepare { withUnsafeCurrentTask { $0?.cancel() } }
    })
    let context = try await store.open()
    let media = try await store.media(generation: context.generation)
    let operation = Task { try await media.importFile(source) }
    let asset = try await operation.value
    #expect(try fixture.count(context) == 1)
    #expect(try await media.asset(id: asset.id) == asset)
    #expect(try Data(contentsOf: await media.fileURL(id: asset.id)) == Data(contentsOf: source))
    try await store.close(generation: context.generation)
}
