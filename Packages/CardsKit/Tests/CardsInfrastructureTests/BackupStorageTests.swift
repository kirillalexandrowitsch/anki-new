import CardsCore
@testable import CardsInfrastructure
import Foundation
import Darwin
import GRDB
import Testing
import ZIPFoundation

private struct BackupFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var root: URL { base.appendingPathComponent("collection") }
    var archive: URL { base.appendingPathComponent("copy.cardsbackup") }
    func directory(_ context: CollectionContext, root: URL? = nil) -> URL {
        RestoreJournal.container(root ?? self.root, context.id)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func seed(_ context: CollectionContext) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: directory(context).appendingPathComponent("collection.sqlite").path)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO scheduler_parameters VALUES ('00000000-0000-4000-8000-000000000001','6','{"schemaVersion":1}',0.9,36500,'{"schemaVersion":1}',0);
                INSERT INTO deck_presets VALUES ('00000000-0000-4000-8000-000000000002','Обычный',20,200,'00000000-0000-4000-8000-000000000001','{"schemaVersion":1}',0);
                INSERT INTO decks(id,name,normalizedName,presetID) VALUES ('00000000-0000-4000-8000-000000000003','Колода','колода','00000000-0000-4000-8000-000000000002');
                INSERT INTO note_types VALUES ('00000000-0000-4000-8000-000000000004','test.basic','Basic',1,'{"schemaVersion":1}','{"schemaVersion":1}',0,NULL);
                INSERT INTO notes VALUES ('00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000004','{"schemaVersion":1,"front":"café","back":"Кофе"}',1,'cafe',0,1,0,NULL);
                INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES ('00000000-0000-4000-8000-000000000006','00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000003','forward','front',0);
                INSERT INTO card_schedules(cardID,algorithmID,algorithmVersion,parameterSetID,phase,dueAt) VALUES ('00000000-0000-4000-8000-000000000006','fsrs','6','00000000-0000-4000-8000-000000000001','review',1000);
                INSERT INTO review_logs VALUES ('00000000-0000-4000-8000-000000000007','00000000-0000-4000-8000-000000000008','00000000-0000-4000-8000-000000000006','00000000-0000-4000-8000-000000000006',NULL,1000,'2026-10-19','Europe/Moscow','00000000-0000-4000-8000-000000000003',3,'review',123,'{"schemaVersion":1}','{"schemaVersion":1}','00000000-0000-4000-8000-000000000001',0,NULL);
                INSERT INTO tags(id,name,normalizedName) VALUES ('00000000-0000-4000-8000-000000000009','Метка','метка');
                INSERT INTO note_tags VALUES ('00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000009');
                INSERT INTO collection_settings VALUES ('setting','{"schemaVersion":1,"value":42}',0);
                """)
        }
        // Remain open so the committed WAL must be included by SQLite Backup API.
        return queue
    }
    func dump(_ context: CollectionContext, root: URL? = nil) throws -> [String: [String]] {
        let reader = try CollectionMigrations.readOnlyQueue(directory(context, root: root).appendingPathComponent("collection.sqlite"))
        defer { try? reader.close() }
        return try reader.read { db in
            var result: [String: [String]] = [:]
            for name in try String.fetchAll(db, sql: "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'") {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(name)\")").map { row in
                    "quote(\"\(row["name"] as String)\")"
                }.joined(separator: " || '|' || ")
                result[name] = try String.fetchAll(db, sql: "SELECT \(columns) FROM \"\(name)\" ORDER BY 1")
            }
            return result
        }
    }
    func payloads() throws -> [String: Data] {
        let zip = try Archive(url: archive, accessMode: .read)
        var result: [String: Data] = [:]
        for entry in zip {
            var data = Data()
            _ = try zip.extract(entry) { data.append($0) }
            result[entry.path] = data
        }
        return result
    }
    func zip(_ payloads: [String: Data], name: String = UUID().uuidString) throws -> URL {
        let url = base.appendingPathComponent(name + ".cardsbackup")
        let zip = try Archive(url: url, accessMode: .create)
        for (path, data) in payloads {
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, size in
                data.subdata(in: Int(offset)..<min(data.count, Int(offset) + size))
            }
        }
        return url
    }
}

@Test func backupRoundTripIncludesWALAllSQLTablesAndImmutableMedia() async throws {
    let f = BackupFixture()
    defer { f.remove() }
    let store = CollectionStore(root: f.root)
    let original = try await store.open()
    let queue = try f.seed(original)
    defer { try? queue.close() }
    let png = f.base.appendingPathComponent("test.png")
    try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!.write(to: png)
    let media = try await store.media(generation: original.generation)
    let asset = try await media.importFile(png)
    try await queue.write { db in
        try db.execute(sql: "INSERT INTO note_media VALUES ('00000000-0000-4000-8000-000000000005',?,'front','image',0)",
                       arguments: [asset.id.rawValue.uuidString.lowercased()])
    }
    // Keep a private staging file and cache out of the archive.
    try Data("private draft".utf8).write(to: f.directory(original).appendingPathComponent("Staging/private"))
    try Data("cache".utf8).write(to: f.directory(original).appendingPathComponent("thumbnail-cache"))
    let expected = try f.dump(original)
    #expect(FileManager.default.fileExists(atPath: f.directory(original).appendingPathComponent("collection.sqlite-wal").path))
    try await store.createBackup(to: f.archive, generation: original.generation)
    #expect(try f.dump(original) == expected)
    let paths = try f.payloads().keys
    #expect(Set(paths) == Set(["manifest.json", "collection.json", "collection.sqlite", asset.relativePath]))
    let targetRoot = f.base.appendingPathComponent("other")
    let target = CollectionStore(root: targetRoot)
    let before = try await target.open()
    let oldRepository = try await target.decks(generation: before.generation)
    var damaged = try f.payloads()
    damaged[asset.relativePath] = Data("damaged media".utf8)
    let badMedia = try f.zip(damaged)
    await #expect(throws: (any Error).self) { try await target.restoreBackup(from: badMedia, generation: before.generation) }
    #expect(try await target.metadata(generation: before.generation).id == before.id)
    let restored = try await target.restoreBackup(from: f.archive, generation: before.generation)
    #expect(restored.id == original.id && restored.generation != before.generation)
    #expect(try f.dump(restored, root: targetRoot) == expected)
    let restoredMedia = try await target.media(generation: restored.generation)
    let restoredURL = try await restoredMedia.fileURL(id: asset.id)
    #expect(try Data(contentsOf: restoredURL) == Data(contentsOf: png))
    #expect((try FileManager.default.attributesOfItem(atPath: restoredURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o444)
    await #expect(throws: CollectionRepositoryError.staleContext) { _ = try await oldRepository.deck(id: DeckID()) }
    let queries = try await target.queries(generation: restored.generation)
    #expect(try await queries.library(LibraryQuery(filter: CardQueryFilter(search: "cafe"))).cardCount == 1)
    try await target.close(generation: restored.generation)
    let reopened = try await target.open()
    #expect(try f.dump(reopened, root: targetRoot) == expected)
    try await target.close(generation: reopened.generation)
    try queue.close()
    try await store.close(generation: original.generation)
}

@Test func backupCorruptArchivesNeverInvalidateOrReplaceLiveCollection() async throws {
    let f = BackupFixture()
    defer { f.remove() }
    let store = CollectionStore(root: f.root)
    let context = try await store.open()
    let queue = try f.seed(context)
    try queue.close()
    try await store.createBackup(to: f.archive, generation: context.generation)
    let original = try f.payloads()
    var variants: [[String: Data]] = []
    var badHash = original
    badHash["collection.sqlite"] = Data("not SQLite".utf8)
    variants.append(badHash)
    var missing = original
    missing.removeValue(forKey: "collection.sqlite")
    variants.append(missing)
    var extra = original
    extra["unlisted"] = Data()
    variants.append(extra)
    for path in ["../escape", "/absolute", "Media/../escape", "Media\\escape", "collection.sqlite-wal"] {
        var badPath = original
        badPath[path] = Data("escape".utf8)
        variants.append(badPath)
    }
    var version = original
    var manifest = try #require(JSONSerialization.jsonObject(with: original["manifest.json"]!) as? [String: Any])
    manifest["formatVersion"] = 999
    version["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest)
    variants.append(version)
    // Matching hashes still cannot authorize invalid SQL or inconsistent identities.
    for payload in ["collection.sqlite", "collection.json"] {
        var value = original
        value[payload] = Data("{}".utf8)
        let url = f.base.appendingPathComponent("hash-input")
        try value[payload]!.write(to: url)
        let hash = try BackupFiles.hash(url, path: payload)
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: original["manifest.json"]!)
        value["manifest.json"] = try JSONEncoder().encode(BackupManifest(formatVersion: 1,
            databaseVersion: decoded.databaseVersion, collectionID: decoded.collectionID,
            createdAt: decoded.createdAt, files: decoded.files.map { $0.path == payload ? hash : $0 }))
        variants.append(value)
    }
    for sql in ["DROP TABLE local_notifications", "DROP TRIGGER notes_search_update"] {
        var value = original
        let url = f.base.appendingPathComponent(UUID().uuidString + ".sqlite")
        try original["collection.sqlite"]!.write(to: url)
        let edited = try DatabaseQueue(path: url.path)
        try await edited.write { try $0.execute(sql: sql) }
        try edited.close()
        value["collection.sqlite"] = try Data(contentsOf: url)
        let entry = try BackupFiles.hash(url, path: "collection.sqlite")
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: original["manifest.json"]!)
        value["manifest.json"] = try JSONEncoder().encode(BackupManifest(formatVersion: 1,
            databaseVersion: decoded.databaseVersion, collectionID: decoded.collectionID,
            createdAt: decoded.createdAt, files: decoded.files.map { $0.path == entry.path ? entry : $0 }))
        variants.append(value)
    }
    let expected = try f.dump(context)
    for value in variants {
        let archive = try f.zip(value)
        await #expect(throws: (any Error).self) { try await store.restoreBackup(from: archive, generation: context.generation) }
        #expect(try await store.metadata(generation: context.generation).id == context.id)
        #expect(try f.dump(context) == expected)
        #expect(!FileManager.default.fileExists(atPath: RestoreJournal.url(f.root).path))
    }
    let truncated = f.base.appendingPathComponent("truncated.cardsbackup")
    try Data(contentsOf: f.archive).prefix(70).write(to: truncated)
    await #expect(throws: (any Error).self) { try await store.restoreBackup(from: truncated, generation: context.generation) }
    #expect(try f.dump(context) == expected)
    try await store.close(generation: context.generation)
}

private enum BackupCrash: Error { case injected }

@Test(arguments: BackupCheckpoint.allCases, [false, true])
func backupInterruptedSwapRecoversOldOrCommittedCollection(checkpoint: BackupCheckpoint, sameID: Bool) async throws {
    let f = BackupFixture()
    defer { f.remove() }
    let source = CollectionStore(root: f.root)
    let context = try await source.open()
    let queue = try f.seed(context)
    try queue.close()
    let expectedNew = try f.dump(context)
    try await source.createBackup(to: f.archive, generation: context.generation)
    try await source.close(generation: context.generation)
    let targetRoot = sameID ? f.root : f.base.appendingPathComponent("target")
    let target = CollectionStore(root: targetRoot, backupFault: { point in
        if point == checkpoint { throw BackupCrash.injected }
    })
    let before = try await target.open()
    let info = try await target.collectionInfo(generation: before.generation)
    _ = try await info.rename(RenameCollectionCommand(commandID: CommandID(), expectedRevision: Revision(0), name: EntityName("Before restore")))
    let expectedOld = try f.dump(before, root: targetRoot)
    let queries = try await target.queries(generation: before.generation)
    let observer = try await queries.observeLibrary(LibraryQuery())
    await #expect(throws: BackupCrash.injected) { try await target.restoreBackup(from: f.archive, generation: before.generation) }
    #expect(FileManager.default.fileExists(atPath: RestoreJournal.url(targetRoot).path))
    var iterator = observer.makeAsyncIterator()
    await #expect(throws: CollectionRepositoryError.staleContext) { _ = try await iterator.next() }
    if checkpoint == .oldRenamed {
        let lease = try CollectionLease(url: targetRoot.appendingPathComponent(".operations.lock"))
        defer { lease.release() }
        #expect(throws: BackupCrash.injected) {
            try RestoreJournal.recover(root: targetRoot, afterRollback: { throw BackupCrash.injected })
        }
        #expect(FileManager.default.fileExists(atPath: RestoreJournal.url(targetRoot).path))
    }
    // A fresh owner models startup, including a second crash during rollback recovery.
    let fresh = CollectionStore(root: targetRoot)
    let recovered = try await fresh.open()
    #expect(recovered.id == (checkpoint == .committed ? context.id : before.id))
    #expect(try f.dump(recovered, root: targetRoot) == (checkpoint == .committed ? expectedNew : expectedOld))
    #expect(!FileManager.default.fileExists(atPath: RestoreJournal.url(targetRoot).path))
    try await fresh.close(generation: recovered.generation)
    let again = try await fresh.open()
    #expect(try f.dump(again, root: targetRoot) == (checkpoint == .committed ? expectedNew : expectedOld))
    try await fresh.close(generation: again.generation)
}

@Test func backupRejectsSymlinksDuplicatesAndCompressionBombs() async throws {
    let f = BackupFixture()
    defer { f.remove() }
    let store = CollectionStore(root: f.root)
    let context = try await store.open()
    for kind in [0, 1, 2] {
        let url = f.base.appendingPathComponent("bad-\(kind).cardsbackup")
        do {
            let archive = try Archive(url: url, accessMode: .create)
            if kind == 0 {
                let data = Data("/tmp/escape".utf8)
                try archive.addEntry(with: "collection.sqlite", type: .symlink, uncompressedSize: Int64(data.count)) { _, _ in data }
            } else if kind == 1 {
                for _ in 0..<2 { try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(2)) { _, _ in Data("{}".utf8) } }
            } else {
                try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(2 * 1024 * 1024),
                                     compressionMethod: .deflate) { _, count in Data(repeating: 0, count: count) }
            }
        }
        await #expect(throws: (any Error).self) { try await store.restoreBackup(from: url, generation: context.generation) }
        #expect(try await store.metadata(generation: context.generation).id == context.id)
    }
    try await store.close(generation: context.generation)
}

@Test func backupDestinationCancellationAndOldGenerationAreSafe() async throws {
    let f = BackupFixture()
    defer { f.remove() }
    let store = CollectionStore(root: f.root)
    let context = try await store.open()
    await #expect(throws: CollectionBackupError.invalidDestination) {
        try await store.createBackup(to: f.root.appendingPathComponent("bad.cardsbackup"), generation: context.generation)
    }
    try await store.createBackup(to: f.archive, generation: context.generation)
    let bytes = try Data(contentsOf: f.archive)
    await #expect(throws: CollectionBackupError.invalidDestination) { try await store.createBackup(to: f.archive, generation: context.generation) }
    #expect(try Data(contentsOf: f.archive) == bytes)
    let cancel = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.restoreBackup(from: f.archive, generation: context.generation)
    }
    await #expect(throws: CancellationError.self) { try await cancel.value }
    #expect(try await store.metadata(generation: context.generation).id == context.id)
    let restored = try await store.restoreBackup(from: f.archive, generation: context.generation)
    await #expect(throws: CollectionBackupError.staleContext) { try await store.createBackup(to: f.base.appendingPathComponent("stale"), generation: context.generation) }
    try await store.close(generation: restored.generation)
}

@Test func backupProcessExitBetweenRenamesRecoversOriginalData() async throws {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["ANKI_BACKUP_TEST_ROOT"], let archive = environment["ANKI_BACKUP_TEST_ARCHIVE"] {
        let store = CollectionStore(root: URL(fileURLWithPath: path), backupFault: { checkpoint in
            if checkpoint == .oldRenamed { _exit(86) } // No ARC/defer/normal shutdown runs.
        })
        let context = try await store.open()
        _ = try await store.restoreBackup(from: URL(fileURLWithPath: archive), generation: context.generation)
        Issue.record("Crash checkpoint was not reached")
        return
    }
    let f = BackupFixture()
    defer { f.remove() }
    let store = CollectionStore(root: f.root)
    let context = try await store.open()
    let queue = try f.seed(context)
    try queue.close()
    try await store.createBackup(to: f.archive, generation: context.generation)
    let info = try await store.collectionInfo(generation: context.generation)
    _ = try await info.rename(RenameCollectionCommand(commandID: CommandID(), expectedRevision: Revision(0),
                                                      name: EntityName("Saved after backup")))
    let expected = try f.dump(context)
    try await store.close(generation: context.generation)
    // Reuse SwiftPM's actual runner: executable on older Xcode, bundle helper on newer Xcode.
    var arguments: [String] = []
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        if argument == "--filter" || argument == "--skip" { _ = iterator.next() }
        else { arguments.append(argument) }
    }
    arguments += ["--filter", "backupProcessExitBetweenRenamesRecoversOriginalData"]
    let executable = CommandLine.arguments[0]
    let childEnvironment = environment.merging(["ANKI_BACKUP_TEST_ROOT": f.root.path,
        "ANKI_BACKUP_TEST_ARCHIVE": f.archive.path]) { _, new in new }
    let status = try await Task.detached {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = childEnvironment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        return child.terminationStatus
    }.value
    #expect(status == 86)
    #expect(FileManager.default.fileExists(atPath: RestoreJournal.url(f.root).path))
    let recovered = try await store.open()
    #expect(try f.dump(recovered) == expected)
    try await store.close(generation: recovered.generation)
}
