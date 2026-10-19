import AudioToolbox
import CardsCore
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MediaManifest: Codable, Sendable {
    let schemaVersion: Int
    let asset: MediaAsset

    func validate() throws {
        let hash = asset.sha256
        guard schemaVersion == 1, hash.count == 64,
              hash.allSatisfy({ "0123456789abcdef".contains($0) }),
              let ext = MediaFiles.formats[asset.uti],
              asset.relativePath == "Media/\(hash).\(ext)",
              asset.byteCount > 0, asset.byteCount <= (asset.uti == "public.mp3" || asset.uti == "com.apple.m4a-audio" ||
                  asset.uti == "com.microsoft.waveform-audio" ? MediaFiles.audioLimit : MediaFiles.imageLimit) else {
            throw MediaStorageError.integrityFailure
        }
    }
}

enum MediaCheckpoint: CaseIterable, Sendable {
    case prepare, publishedFile, publish, commit, removedStaging
}
typealias MediaFault = @Sendable (MediaCheckpoint) throws -> Void

/// Synchronous helpers run only on collection/media/writer actors, never MainActor.
enum MediaFiles {
    static let imageLimit: Int64 = 20 * 1024 * 1024
    static let audioLimit: Int64 = 100 * 1024 * 1024
    static let formats = ["public.png": "png", "public.jpeg": "jpg", "com.compuserve.gif": "gif",
                          "public.tiff": "tiff", "public.heic": "heic", "org.webmproject.webp": "webp",
                          "public.mp3": "mp3", "com.apple.m4a-audio": "m4a", "com.microsoft.waveform-audio": "wav"]

    static func directory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MediaStorageError.integrityFailure
        }
    }

    static func regular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MediaStorageError.invalidSource
        }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw MediaStorageError.fileSystem(Int(errno)) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw MediaStorageError.fileSystem(Int(errno)) }
    }

    static func copy(_ source: URL, to target: URL) throws -> (String, Int64) {
        guard source.isFileURL else { throw MediaStorageError.invalidSource }
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw MediaStorageError.invalidSource }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw MediaStorageError.invalidSource
        }
        guard info.st_size <= audioLimit else { throw MediaStorageError.sizeLimitExceeded }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw MediaStorageError.invalidSource
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard !Task.isCancelled else { throw MediaStorageError.cancelled }
            count += Int64(chunk.count)
            guard count <= audioLimit else { throw MediaStorageError.sizeLimitExceeded }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        guard count > 0 else { throw MediaStorageError.invalidContent }
        guard fchmod(output.fileDescriptor, S_IRUSR | S_IRGRP | S_IROTH) == 0 else {
            throw MediaStorageError.fileSystem(Int(errno))
        }
        try output.synchronize()
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    static func hash(_ url: URL) throws -> (String, Int64) {
        try regular(url)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            count += Int64(chunk.count)
            guard count <= audioLimit else { throw MediaStorageError.sizeLimitExceeded }
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    static func verify(_ asset: MediaAsset, root: URL) throws {
        do {
            try MediaManifest(schemaVersion: 1, asset: asset).validate()
            try directory(root.appendingPathComponent("Media"))
            let (hash, size) = try hash(root.appendingPathComponent(asset.relativePath))
            guard hash == asset.sha256, size == asset.byteCount else { throw MediaStorageError.integrityFailure }
        } catch { throw MediaStorageError.integrityFailure }
    }

    static func contentType(_ url: URL, size: Int64) throws -> String {
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let type = CGImageSourceGetType(source) as String?, UTType(type)?.conforms(to: .image) == true {
            guard formats[type] != nil else { throw MediaStorageError.unsupportedFormat }
            guard size <= imageLimit else { throw MediaStorageError.sizeLimitExceeded }
            _ = try thumbnail(url, maxPixelSize: 32) // validates pixels and an actual bounded decode
            return type
        }
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else {
            throw MediaStorageError.invalidContent
        }
        defer { AudioFileClose(file) }
        var kind: AudioFileTypeID = 0
        var length = UInt32(MemoryLayout.size(ofValue: kind))
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &length, &kind) == noErr else {
            throw MediaStorageError.invalidContent
        }
        var bytes: UInt64 = 0
        length = UInt32(MemoryLayout.size(ofValue: bytes))
        guard AudioFileGetProperty(file, kAudioFilePropertyAudioDataByteCount, &length, &bytes) == noErr,
              bytes > 0, bytes <= size else { throw MediaStorageError.invalidContent }
        switch kind {
        case kAudioFileMP3Type: return "public.mp3"
        case kAudioFileM4AType: return "com.apple.m4a-audio"
        case kAudioFileWAVEType: return "com.microsoft.waveform-audio"
        default: throw MediaStorageError.unsupportedFormat
        }
    }

    static func thumbnail(_ url: URL, maxPixelSize: Int) throws -> Data {
        guard (1...512).contains(maxPixelSize) else { throw MediaStorageError.pixelLimitExceeded }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetStatus(source) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw MediaStorageError.invalidContent
        }
        guard width <= 16384, height <= 16384, Int64(width) * Int64(height) <= 40_000_000 else {
            throw MediaStorageError.pixelLimitExceeded
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw MediaStorageError.invalidContent
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaStorageError.invalidContent
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaStorageError.invalidContent }
        return data as Data
    }

    static func publish(_ asset: MediaAsset, staging: URL, root: URL) throws {
        let destination = root.appendingPathComponent(asset.relativePath)
        try directory(root.appendingPathComponent("Media"))
        // link is atomic and never replaces an existing hash file, even when another import deduplicates.
        if Darwin.link(staging.path, destination.path) != 0 {
            guard errno == EEXIST else { throw MediaStorageError.fileSystem(Int(errno)) }
        }
        try verify(asset, root: root)
        // Durably order the published directory entry before the database reference.
        try synchronizeDirectory(root.appendingPathComponent("Media"))
    }
}
