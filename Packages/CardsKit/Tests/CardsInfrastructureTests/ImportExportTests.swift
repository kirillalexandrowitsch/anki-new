import CardsCore
import CardsTestSupport
@testable import CardsInfrastructure
import CryptoKit
import Foundation
import GRDB
import Testing
import ZIPFoundation

@Test func delimitedTextRoundTripsEveryByteBoundaryUnicodeMultilineAndBOM() throws {
    let rows = [["front", "back", "tags"], ["cafe\u{301},\"猫\"", "Перевод\r\nещё\nстрока\rконец", ""], ["", "\t", "последнее"]]
    for tab in [false, true] {
        for safe in [false, true] {
            let file = Data([0xef, 0xbb, 0xbf]) + rows.reduce(Data()) {
                $0 + DelimitedTextWriter.record($1, tabSeparated: tab, safeSpreadsheet: safe)
            }
            for chunkSize in 1...file.count {
                var parsed: [[String]] = []
                var parser = DelimitedTextParser(tabSeparated: tab)
                for offset in stride(from: 0, to: file.count, by: chunkSize) {
                    try parser.feed(file.subdata(in: offset..<min(offset + chunkSize, file.count))) { parsed.append($0) }
                }
                try parser.finish { parsed.append($0) }
                let expected = safe ? rows.map { $0.map { "'" + $0 } } : rows
                #expect(parsed == expected)
            }
        }
    }
    var short = DelimitedTextParser()
    var result: [[String]] = []
    try short.feed(Data("a,".utf8)) { result.append($0) }
    try short.finish { result.append($0) }
    #expect(result == [["a", ""]])
}

@Test func delimitedTextRejectsMalformedEncodingQuotingWidthAndOversizedFields() throws {
    let cases: [(Data, DelimitedTextDiagnostic.Reason, Int)] = [
        (Data([0x61, 0x2c, 0xff]), .invalidUTF8, 1),
        (Data("a,b\r\nx,\"y\nunfinished".utf8), .unclosedQuote, 3),
        (Data("a,b\nx,\"y\"z".utf8), .unexpectedQuote, 2),
        (Data("a,b\nx\"y,z".utf8), .unexpectedQuote, 2),
        (Data("a,b\nx,y,z".utf8), .columnCount, 2),
        (Data(repeating: 65, count: 1024 * 1024 + 1), .limitExceeded, 1)
    ]
    for (data, reason, line) in cases {
        var parser = DelimitedTextParser()
        do {
            try parser.feed(data) { _ in }
            try parser.finish { _ in }
            Issue.record("Malformed CSV accepted: \(reason)")
        } catch let error as DelimitedTextDiagnostic {
            #expect(error.reason == reason && error.line == line && error.column > 0)
        }
    }
    var parser = DelimitedTextParser()
    var rows: [[String]] = []
    try parser.feed(Data("a,b\r1,2\r\n3,4\n".utf8)) { rows.append($0) }
    try parser.finish { rows.append($0) }
    #expect(rows == [["a", "b"], ["1", "2"], ["3", "4"]])
}

@Test func collectionExportCSVNativeAndBackupHaveDistinctVerifiedPayloadsAndFailureIsolation() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let root = directory.url.appendingPathComponent("collection")
    let store = CollectionStore(root: root)
    let context = try await store.open()
    let service = try await store.onboarding(generation: context.generation)
    let deck = DeckID()
    _ = try await service.complete(CompleteOnboardingCommand(commandID: CommandID(), deckID: deck,
        name: EntityName("Синтетика"), includeDemo: false))
    let notes = try await store.notes(generation: context.generation)
    let content = BasicNoteContent(front: "=\"cafe\u{301}\", 猫", back: "Перевод\r\nс \"кавычками\"",
        pronunciation: "/test/", examples: [NoteExample(en: "one\ntwo", ru: "один"), NoteExample(en: "three")])
    let id = NoteID()
    _ = try await notes.save(SaveNoteCommand(commandID: CommandID(), noteID: id, expectedRevision: nil,
        initialDeckID: deck, content: content, tags: ["Тег,\"один\"", "二"]))
    for format in [CollectionExportFormat.csv, .tsv] {
        let url = directory.url.appendingPathComponent("copy." + format.fileExtension)
        try await store.export(to: url, format: format, generation: context.generation)
        var rows: [[String]] = []
        try DelimitedTextParser.read(url, tabSeparated: format == .tsv) { rows.append($0) }
        #expect(rows.count == 2 && rows[0] == CollectionExporter.columns)
        #expect(rows[1][1] == content.front && rows[1][2] == content.back && rows[1][3] == content.pronunciation)
        #expect(try JSONDecoder().decode([NoteExample].self, from: Data(rows[1][4].utf8)) == content.examples)
        #expect(Set(try JSONDecoder().decode([String].self, from: Data(rows[1][5].utf8))) == Set(["Тег,\"один\"", "二"]))
        let before = try Data(contentsOf: url)
        await #expect(throws: CollectionExportError.invalidDestination) {
            try await store.export(to: url, format: format, generation: context.generation)
        }
        #expect(try Data(contentsOf: url) == before)
    }
    let safeURL = directory.url.appendingPathComponent("safe.csv")
    try await store.export(to: safeURL, format: .csv, safeSpreadsheet: true, generation: context.generation)
    var safeRows: [[String]] = []
    try DelimitedTextParser.read(safeURL) { safeRows.append($0.map { String($0.dropFirst()) }) }
    #expect(safeRows[0] == CollectionExporter.columns && safeRows[1][1] == content.front)
    let cancelledURL = directory.url.appendingPathComponent("cancelled.csv")
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await store.export(to: cancelledURL, format: .csv, generation: context.generation)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))
    let media = try await store.media(generation: context.generation)
    let image = try #require(Bundle.module.url(forResource: "pixel", withExtension: "png", subdirectory: "Fixtures/synthetic-v1"))
    let asset = try await media.importFile(image)
    let saved = try #require(await notes.note(id: id))
    let attached = BasicNoteContent(front: content.front, back: content.back, examples: content.examples,
        media: [NoteMediaReference(mediaID: asset.id, fieldID: "image", role: .image)])
    _ = try await notes.save(SaveNoteCommand(commandID: CommandID(), noteID: id, expectedRevision: saved.note.revision,
        initialDeckID: deck, content: attached, tags: ["Тег"]))
    let archiveURL = directory.url.appendingPathComponent("copy.cardsdeck")
    try await store.export(to: archiveURL, format: .cardsdeck, generation: context.generation)
    let zip = try Archive(url: archiveURL, accessMode: .read)
    func data(_ path: String) throws -> Data {
        let entry = try #require(zip[path])
        var result = Data()
        let crc = try zip.extract(entry) { result.append($0) }
        #expect(crc == entry.checksum)
        return result
    }
    let manifest = try #require(JSONSerialization.jsonObject(with: data("manifest.json")) as? [String: Any])
    #expect(manifest["format"] as? String == "cardsdeck" && manifest["formatVersion"] as? Int == 1)
    #expect(manifest["includesProgress"] as? Bool == false)
    let entries = try #require(manifest["files"] as? [[String: Any]])
    #expect(entries.count == 2)
    for entry in entries {
        let payload = try data(#require(entry["path"] as? String))
        #expect(payload.count == entry["byteCount"] as? Int)
        #expect(SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() == entry["sha256"] as? String)
    }
    #expect(try data(asset.relativePath) == Data(contentsOf: image))
    let payload = try #require(JSONSerialization.jsonObject(with: data("content.json")) as? [String: Any])
    let tables = try #require(payload["tables"] as? [String: [[String: Any]]])
    #expect(Set(tables.keys) == Set(["notes", "cards", "decks", "note_types", "tags", "note_tags", "note_media"]))
    let exported = try #require(tables["notes"]?.first?["fieldsJSON"] as? String)
    #expect(try JSONDecoder().decode(BasicNoteContent.self, from: Data(exported.utf8)) == attached)
    #expect(tables["decks"]?.first?["presetID"] == nil)
    let backup = directory.url.appendingPathComponent("exact.cardsbackup")
    try await store.export(to: backup, format: .cardsbackup, generation: context.generation)
    let restore = CollectionStore(root: directory.url.appendingPathComponent("restored"))
    let fresh = try await restore.open()
    let restored = try await restore.restoreBackup(from: backup, generation: fresh.generation)
    let restoredNotes = try await restore.notes(generation: restored.generation)
    let original = try await notes.note(id: id)
    #expect(try await restoredNotes.note(id: id) == original)
    try await restore.close(generation: restored.generation)
    // /System is read-only on macOS; failure must not alter the live Note or leave work dirs.
    do {
        try await store.export(to: URL(fileURLWithPath: "/System/anki-synthetic-\(UUID()).csv"), format: .csv, generation: context.generation)
        Issue.record("Read-only destination unexpectedly accepted")
    } catch {}
    await #expect(throws: CollectionExportError.invalidDestination) {
        try await store.export(to: root.appendingPathComponent("bad.csv"), format: .csv, generation: context.generation)
    }
    await #expect(throws: CollectionExportError.invalidDestination) {
        try await store.export(to: directory.url.appendingPathComponent("bad.apkg"), format: .cardsdeck, generation: context.generation)
    }
    #expect(try await notes.note(id: id)?.content == attached)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).allSatisfy { !$0.hasPrefix(".export-") })
    try await store.close(generation: context.generation)
    await #expect(throws: CollectionAccessError.staleContext) {
        try await store.export(to: directory.url.appendingPathComponent("stale.csv"), format: .csv, generation: context.generation)
    }
}
