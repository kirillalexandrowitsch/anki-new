import CardsCore
@testable import CardsInfrastructure
import CardsTestSupport
import Foundation
import GRDB
import ImageIO
import AudioToolbox
import Testing

@Test func syntheticSeedIsDeterministicAcrossFreshFileDatabasesAndReopen() async throws {
    let first = try SyntheticFixture()
    let second = try SyntheticFixture()
    #expect(first.temporary.url != second.temporary.url)
    let expected = try first.fingerprint()
    #expect(try second.fingerprint() == expected)
    let fingerprint = try String(contentsOf: SyntheticSeed.directory.appendingPathComponent("fingerprint.sha256"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(expected == fingerprint)
    print("ANKI_FIXTURE_V1_SHA256=" + expected) // Fixed synthetic-only digest for check.py.
    try await first.database.checkIntegrity()
    #expect(try first.fingerprint() == expected) // Verification must not change content.
    // Check again after the first verification reader has observed another commit.
    try await first.database.pool.write { try $0.execute(sql: "UPDATE notes SET updatedAt=updatedAt+1") }
    try await first.database.checkIntegrity()
    try first.database.close()
    let reopened = try CollectionDatabase(url: first.databaseURL)
    defer { try? reopened.close() }
    #expect(try await reopened.metadata().createdAt.rawValue == first.seed.nowMilliseconds)
    #expect(try await reopened.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM cards") } == 5)
    #expect(try await reopened.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'кофе'") } == 1)
    // The same public verification still works before the FTS migration exists.
    let legacyDirectory = try TestDirectory()
    let legacy = try CollectionDatabase(url: legacyDirectory.url.appendingPathComponent("v1.sqlite"),
        newCollection: NewCollectionMetadata(id: CollectionID(uuidString: first.seed.key(1)),
            name: EntityName("Synthetic v1"), createdAt: EpochMilliseconds(0)), migrations: CollectionMigrations.initial)
    defer { try? legacy.close() }
    try await legacy.checkIntegrity()
    #expect(try await legacy.metadata().schemaVersion == 1)
}

@Test func syntheticCorruptFTSStillFailsFullIntegrityVerification() async throws {
    let f = try SyntheticFixture()
    try await f.database.checkIntegrity()
    // Deliberately corrupt a shadow content row without updating its token index.
    // GRDB's connection disallows shadow-table writes. Use the system SQLite CLI
    // as an external corruptor against this isolated synthetic file only.
    let corruptor = Process()
    corruptor.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    corruptor.arguments = [f.databaseURL.path,
        "UPDATE notes_fts_content SET c0='damaged synthetic index' WHERE id=1"]
    corruptor.standardOutput = FileHandle.nullDevice
    corruptor.standardError = FileHandle.nullDevice
    try corruptor.run()
    corruptor.waitUntilExit()
    #expect(corruptor.terminationStatus == 0)
    await #expect(throws: (any Error).self) { try await f.database.checkIntegrity() }
}

@Test func syntheticSeedQueriesUseClockBoundariesCyrillicAndIndependentDecks() async throws {
    let f = try SyntheticFixture()
    let writer = CollectionWriter(database: f.database, clock: f.clock)
    let queries = SQLiteCollectionQueries(writer: writer, generation: UUID())
    let now = EpochMilliseconds(f.seed.nowMilliseconds)
    let today = try await queries.today(.all, asOf: now)
    #expect(today.decks.deckCount == 3)
    #expect(today.counts.cards == 5 && today.counts.notes == 4)
    #expect(today.counts.availableNew == 1 && today.counts.due == 2 && today.counts.suspended == 1)
    let cyrillic = try await queries.library(LibraryQuery(filter: CardQueryFilter(search: "кофе")))
    #expect(cyrillic.cardCount == 2 && cyrillic.noteCount == 1)
    #expect(try await queries.library(LibraryQuery(filter: CardQueryFilter(
        deckID: DeckID(uuidString: f.seed.key(10)), includeDescendants: true))).cardCount == 3)
    f.clock.advance(by: 1)
    let later = EpochMilliseconds(Int64(f.clock.now().timeIntervalSince1970 * 1000))
    #expect(try await queries.today(.all, asOf: later).counts.due == 3)
    try await writer.close()
}

@Test func syntheticMediaDecodesAndMatchesPersistedHashes() throws {
    let f = try SyntheticFixture()
    let png = SyntheticSeed.directory.appendingPathComponent("pixel.png")
    let image = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
    #expect(CGImageSourceCreateImageAtIndex(image, 0, nil)?.width == 1)
    let wav = SyntheticSeed.directory.appendingPathComponent("tone.wav")
    var audio: AudioFileID?
    #expect(AudioFileOpenURL(wav as CFURL, .readPermission, 0, &audio) == noErr)
    if let audio { AudioFileClose(audio) }
    #expect(try f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note_media") } == 2)
    // The helper verified every byte against committed hashes before writing any SQL.
    #expect(try f.fingerprint().count == 64)
}

@Test func syntheticFixtureFaultRollsBackMutationAndCommandJournal() async throws {
    let f = try SyntheticFixture()
    let before = try f.fingerprint()
    let writer = CollectionWriter(database: f.database, clock: f.clock)
    let probe = FaultProbe(at: "beforeCommit")
    let commandID = CommandID()
    await #expect(throws: CollectionRepositoryError.integrityFailure) {
        _ = try await writer.execute(commandID: commandID, kind: "test.fixture", request: true) { db in
            try db.execute(sql: "UPDATE decks SET description='Synthetic mutation' WHERE id=?", arguments: [f.seed.key(10)])
            try probe.hit("beforeCommit")
            return true
        }
    }
    #expect(try f.fingerprint() == before)
    #expect(try await f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM processed_commands") } == 0)
    #expect(probe.checkpoints == ["beforeCommit"])
    // One-shot failure permits a real retry with the very same command.
    _ = try await writer.execute(commandID: commandID, kind: "test.fixture", request: true) { db in
        try db.execute(sql: "UPDATE decks SET description='Synthetic mutation' WHERE id=?", arguments: [f.seed.key(10)])
        try probe.hit("beforeCommit")
        return true
    }
    #expect(try f.fingerprint() != before)
    try await writer.close()
}

@Test func sharedFaultProbeWorksWithMediaRecoveryAndPrivateDirectoriesCleanUp() async throws {
    var removed: URL!
    do {
        let temp = try TestDirectory()
        removed = temp.url
        let probe = FaultProbe(at: MediaCheckpoint.publishedFile)
        let root = temp.url.appendingPathComponent("store")
        let store = CollectionStore(root: root, clock: TestClock(), mediaFault: { try probe.hit($0) })
        let context = try await store.open()
        let media = try await store.media(generation: context.generation)
        await #expect(throws: InjectedFault.triggered) {
            try await media.importFile(SyntheticSeed.directory.appendingPathComponent("pixel.png"))
        }
        #expect(probe.checkpoints == [.prepare, .publishedFile])
        try await store.close(generation: context.generation)
        let next = try await store.open() // Existing recovery handles the interrupted publish.
        let current = try await store.media(generation: next.generation)
        let asset = try await current.importFile(SyntheticSeed.directory.appendingPathComponent("pixel.png"))
        #expect(asset.sha256 == (try SyntheticSeed.load().media[0].sha256))
        try await store.close(generation: next.generation)
        withExtendedLifetime(temp) {}
    }
    #expect(!FileManager.default.fileExists(atPath: removed.path))
}
