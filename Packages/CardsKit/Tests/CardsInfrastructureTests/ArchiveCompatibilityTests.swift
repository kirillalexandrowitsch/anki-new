import Foundation
import Testing
import ZIPFoundation

@Test func zipRoundTripPreservesUnicodeBinaryEmptyAndChecksums() async throws {
    // ZIPFoundation's Archive is mutable/non-Sendable. Confine the whole operation
    // to one background task; only Sendable values may cross the task boundary.
    try await Task.detached {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try manager.createDirectory(at: source.appendingPathComponent("Медиа"), withIntermediateDirectories: true)
        let files = [
            "Медиа/слово.txt": Data("Привет, мир!\nline two\n".utf8),
            "bytes.bin": Data((0...255).map(UInt8.init)),
            "empty.txt": Data(),
        ]
        for (path, data) in files { try data.write(to: source.appendingPathComponent(path)) }
        let zip = root.appendingPathComponent("probe.zip")
        try manager.zipItem(at: source, to: zip, shouldKeepParent: false, compressionMethod: .deflate)
        let archive = try Archive(url: zip, accessMode: .read)
        #expect(archive.filter { $0.type == .file }.count == files.count)
        for (path, expected) in files {
            let entry = try #require(archive[path])
            var extracted = Data()
            let checksum = try archive.extract(entry, consumer: { extracted.append($0) })
            #expect(checksum == entry.checksum)
            #expect(extracted == expected)
        }
        let destination = root.appendingPathComponent("restored")
        try manager.unzipItem(at: zip, to: destination)
        for (path, expected) in files {
            #expect(try Data(contentsOf: destination.appendingPathComponent(path)) == expected)
        }
    }.value
}
