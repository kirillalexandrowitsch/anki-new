import CardsCore
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct DatabaseFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("collection.sqlite") }
    let metadata = NewCollectionMetadata(id: CollectionID(), name: try! EntityName("Тестовая коллекция"),
                                         createdAt: EpochMilliseconds(1_700_000_000_123))

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func create() throws -> CollectionDatabase { try CollectionDatabase(url: url, newCollection: metadata) }
}

private let expectedTables: Set<String> = [
    "collection_meta", "decks", "note_types", "notes", "cards", "card_schedules",
    "scheduler_parameters", "deck_presets", "tags", "note_tags", "media_assets", "note_media",
    "study_sessions", "session_items", "review_logs", "domain_events", "processed_commands",
    "collection_settings", "local_notifications", "operation_journal", "deletion_batches", "grdb_migrations",
]

@Test func collectionSchemaCreatesReopensAndKeepsIdentity() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    #expect(CollectionDatabase.schemaVersion == CollectionMigrations.initial.count)
    for attempt in 0..<3 {
        let store = try CollectionDatabase(url: fixture.url, newCollection: attempt == 0 ? fixture.metadata : nil)
        let metadata = try await store.metadata()
        #expect(metadata.id == fixture.metadata.id)
        #expect(metadata.name == fixture.metadata.name)
        #expect(metadata.createdAt == fixture.metadata.createdAt)
        #expect(metadata.schemaVersion == 1 && metadata.containerVersion == 1)
        #expect(metadata.settingsRevision == .initial)
        #expect(store.migrationBackupURL == nil)
        try await store.checkIntegrity()
        try await store.pool.read { db throws -> Void in
            let tables = try String.fetchSet(db, sql: "SELECT name FROM sqlite_schema WHERE type='table'")
            #expect(tables == expectedTables)
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") == ["v1"])
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            let strictTables = try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_table_list WHERE strict=1")
            #expect(strictTables == expectedTables.count - 1)
        }
        try store.close()
    }
    #expect(throws: CollectionDatabaseError.collectionIdentityMismatch) {
        try CollectionDatabase(url: fixture.url, newCollection: NewCollectionMetadata(
            id: CollectionID(), name: fixture.metadata.name, createdAt: fixture.metadata.createdAt))
    }
}

/// IDs below are synthetic stable fixture keys. Product boundaries use Core UUID wrappers.
private func seedGraph(_ db: Database) throws {
    try db.execute(sql: """
        INSERT INTO scheduler_parameters VALUES ('params', '6', '{"schemaVersion":1,"weights":[]}', 0.9,
            36500, '{"schemaVersion":1}', 1700000000000);
        INSERT INTO deck_presets VALUES ('default', 'По умолчанию', 20, 200, 'params', '{"schemaVersion":1}', 0);
        INSERT INTO decks(id, name, normalizedName, presetID) VALUES ('deck', 'English', 'english', 'default');
        INSERT INTO note_types VALUES ('basic', 'builtin.basic', 'Basic', 1,
            '{"schemaVersion":1,"fields":["front","back"]}', '{"schemaVersion":1}', 0, NULL);
        INSERT INTO notes VALUES ('note', 'basic', '{"schemaVersion":1,"front":"Hello"}', 1,
            'hello', 1700000000123, 1700000000123, 0, NULL);
        INSERT INTO cards(id, noteID, deckID, variantKey, templateID, createdAt)
            VALUES ('card', 'note', 'deck', 'basic.forward', 'forward', 1700000000123);
        INSERT INTO card_schedules(cardID, algorithmID, algorithmVersion, parameterSetID, phase)
            VALUES ('card', 'fsrs', '6', 'params', 'new');
        INSERT INTO tags(id, name, normalizedName) VALUES ('tag', 'Language', 'language');
        INSERT INTO note_tags VALUES ('note', 'tag');
        INSERT INTO media_assets VALUES ('media',
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'Media/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png',
            'public.png', 128, 1700000000000, 'published');
        INSERT INTO note_media VALUES ('note', 'media', 'front', 'image', 0);
        INSERT INTO study_sessions VALUES ('session', 'scheduled', '{"schemaVersion":1}',
            1700000000000, 1700000000123, NULL, 'active', 123, '{"schemaVersion":1}', 0);
        INSERT INTO session_items VALUES ('item', 'session', 'card', 0, 'answer', NULL, 1700000000000, 'draft', 0);
        INSERT INTO review_logs VALUES ('review', 'rate-command', 'card', 'card', 'session',
            1700000000123, '2023-11-14', 'Europe/Moscow', 'deck', 3, 'new', 123,
            '{"schemaVersion":1}', '{"schemaVersion":1}', 'params', 0, NULL);
        INSERT INTO domain_events VALUES ('event', 'rate-command', 'rate', 'card', 1700000000123,
            1, '{"schemaVersion":1}');
        INSERT INTO processed_commands VALUES ('rate-command', 1, '{"schemaVersion":1}', 1700000000123);
        INSERT INTO collection_settings VALUES ('timezone', '{"schemaVersion":1,"value":"Europe/Moscow"}', 0);
        INSERT INTO local_notifications VALUES ('notification', 'info', 1700000000123, '{"schemaVersion":1}', NULL);
        INSERT INTO operation_journal VALUES ('operation', 'media', 'completed', 'Staging/operation',
            '{"schemaVersion":1}', 1700000000000, 1700000000123);
        INSERT INTO deletion_batches VALUES ('batch', 'card', '{"schemaVersion":1,"ids":[]}',
            1700000000000, NULL, 1700604800000, 'pending');
        """)
}

private func expectConstraint(_ db: Database, _ sql: String,
                              arguments: StatementArguments = [], sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try db.execute(sql: sql, arguments: arguments)
        Issue.record("Expected SQLite constraint: \(sql)", sourceLocation: sourceLocation)
    } catch let error as DatabaseError {
        #expect(error.resultCode == .SQLITE_CONSTRAINT, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}

@Test func constraintsIndexesAndPartialUniqueness() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try fixture.create()
    defer { try? store.close() }
    try await store.pool.write { db throws -> Void in
        try seedGraph(db)
        expectConstraint(db, "INSERT INTO decks(id,name,normalizedName) VALUES ('duplicate','ENGLISH','english')")
        try db.execute(sql: "INSERT INTO decks(id,parentID,name,normalizedName) VALUES ('child','deck','English','english')")
        expectConstraint(db, "INSERT INTO decks(id,parentID,name,normalizedName) VALUES ('child-duplicate','deck','English','english')")
        try db.execute(sql: "INSERT INTO decks(id,name,normalizedName,deletedAt) VALUES ('old','English','english',1)")
        expectConstraint(db, "UPDATE decks SET deletedAt=NULL WHERE id='old'")
        expectConstraint(db, "UPDATE decks SET parentID='child' WHERE id='deck'")
        expectConstraint(db, "UPDATE decks SET parentID=id WHERE id='deck'")
        expectConstraint(db, "INSERT INTO decks(id,parentID,name,normalizedName) VALUES ('self','self','Self','self')")
        expectConstraint(db, "UPDATE decks SET parentID='missing' WHERE id='deck'")
        expectConstraint(db, "DELETE FROM decks WHERE id='deck'")
        expectConstraint(db, "INSERT INTO tags(id,name,normalizedName) VALUES ('tag2','LANGUAGE','language')")
        try db.execute(sql: "UPDATE tags SET deletedAt=1 WHERE id='tag'")
        try db.execute(sql: "INSERT INTO tags(id,name,normalizedName) VALUES ('tag2','Language','language')")
        expectConstraint(db, "UPDATE tags SET deletedAt=NULL WHERE id='tag'")
        expectConstraint(db, "INSERT INTO note_tags VALUES ('note','tag')")
        expectConstraint(db, "INSERT INTO note_media VALUES ('note','missing','back','audio',0)")
        expectConstraint(db, "DELETE FROM media_assets WHERE id='media'")
        expectConstraint(db, "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES ('duplicate','note','deck','basic.forward','forward',0)")
        try db.execute(sql: "UPDATE cards SET deletedAt=1, generationState='suppressed' WHERE id='card'")
        expectConstraint(db, "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES ('duplicate','note','deck','basic.forward','forward',0)")
        try db.execute(sql: "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES ('reverse','note','child','reverse.backward','backward',0)")
        expectConstraint(db, "INSERT INTO card_schedules(cardID,algorithmID,algorithmVersion,parameterSetID,phase) VALUES ('card','fsrs','6','params','new')")
        expectConstraint(db, "UPDATE card_schedules SET parameterSetID='missing'")
        expectConstraint(db, "UPDATE scheduler_parameters SET desiredRetention=0.8")
        expectConstraint(db, "INSERT OR REPLACE INTO scheduler_parameters SELECT * FROM scheduler_parameters")
        expectConstraint(db, "DELETE FROM scheduler_parameters WHERE id='params'")
        expectConstraint(db, "INSERT INTO processed_commands VALUES ('rate-command',1,'{}',0)")
        expectConstraint(db, "UPDATE review_logs SET grade=0")
        expectConstraint(db, "UPDATE cards SET generationState='invalid'")
        expectConstraint(db, "UPDATE card_schedules SET phase='suspended'")
        expectConstraint(db, "UPDATE card_schedules SET stability=?", arguments: [Double.infinity])
        expectConstraint(db, "UPDATE card_schedules SET difficulty=11")
        expectConstraint(db, "UPDATE notes SET fieldsJSON='broken json'")
        expectConstraint(db, "UPDATE notes SET fieldsJSON='{}'")
        expectConstraint(db, "UPDATE notes SET fieldsJSON='{\"schemaVersion\":0}'")
        expectConstraint(db, "UPDATE notes SET revision=-1")
        expectConstraint(db, "UPDATE notes SET createdAt=1.5")
        expectConstraint(db, "UPDATE study_sessions SET activeDurationMs=-1")
        expectConstraint(db, "UPDATE media_assets SET relativePath='Media/../secret'")
        expectConstraint(db, "UPDATE media_assets SET relativePath='/tmp/file'")
        expectConstraint(db, "UPDATE media_assets SET sha256='not-a-hash'")
        expectConstraint(db, "INSERT INTO media_assets SELECT 'other',sha256,'Media/other.png',uti,byteCount,createdAt,lifecycleState FROM media_assets")
        expectConstraint(db, "INSERT INTO study_sessions SELECT 'other',mode,scopeJSON,startedAt,lastActivityAt,endedAt,'paused',activeDurationMs,studyPolicyJSON,revision FROM study_sessions")
        expectConstraint(db, "INSERT INTO session_items SELECT 'other',sessionID,cardID,queueOrdinal,stage,eligibleAt,presentedAt,typedDraft,generation FROM session_items")
        expectConstraint(db, "INSERT INTO review_logs SELECT 'duplicate',commandID,cardID,cardIdentitySnapshot,sessionID,ratedAt,studyDayKey,timezoneID,deckIDSnapshot,grade,phaseBefore,durationMs,beforeJSON,afterJSON,parameterSetID,scheduleEpoch,voidedBy FROM review_logs")
        expectConstraint(db, "INSERT INTO collection_meta(id,name,containerVersion,schemaVersion,createdAt) VALUES ('other','Other',1,1,0)")
        expectConstraint(db, "INSERT OR REPLACE INTO collection_meta(id,name,containerVersion,schemaVersion,createdAt) VALUES ('other','Other',1,1,0)")
        expectConstraint(db, "DELETE FROM collection_meta")
        expectConstraint(db, "UPDATE collection_meta SET id='other'")
        let indexes = try String.fetchSet(db, sql: "SELECT name FROM sqlite_schema WHERE type='index'")
        #expect(indexes.isSuperset(of: ["cards_deck_availability", "card_schedules_due_phase",
                                       "review_logs_day_deck_effective", "session_items_queue",
                                       "decks_active_sibling_name", "tags_active_name"]))
    }
    try await store.checkIntegrity()
    try store.close()
    let reopened = try CollectionDatabase(url: fixture.url)
    defer { try? reopened.close() }
    try await reopened.pool.read { db throws -> Void in
        #expect(try Int64.fetchOne(db, sql: "SELECT createdAt FROM notes") == 1_700_000_000_123)
        #expect(try String.fetchOne(db, sql: "SELECT typedDraft FROM session_items") == "draft")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM review_logs") == 1)
    }
}

@Test func physicalPurgeKeepsReviewSnapshotsAndParameters() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try fixture.create()
    defer { try? store.close() }
    try await store.pool.write { db throws -> Void in
        try seedGraph(db)
        try db.execute(sql: "DELETE FROM cards; DELETE FROM study_sessions; DELETE FROM notes; DELETE FROM decks")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM review_logs") == 1)
        #expect(try String.fetchOne(db, sql: "SELECT cardID FROM review_logs") == nil)
        #expect(try String.fetchOne(db, sql: "SELECT sessionID FROM review_logs") == nil)
        #expect(try String.fetchOne(db, sql: "SELECT cardIdentitySnapshot FROM review_logs") == "card")
        #expect(try String.fetchOne(db, sql: "SELECT deckIDSnapshot FROM review_logs") == "deck")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM card_schedules") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM session_items") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM note_media") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM note_tags") == 0)
        expectConstraint(db, "DELETE FROM scheduler_parameters WHERE id='params'")
    }
    try await store.checkIntegrity()
}

@Test func poolEnforcesForeignKeysOnConcurrentReadersAndWriter() async throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try fixture.create()
    defer { try? store.close() }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
            group.addTask {
                try await store.pool.read { db throws -> Void in
                    #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1)
                }
            }
        }
        try await group.waitForAll()
    }
    try await store.pool.write { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1)
        expectConstraint(db, "INSERT INTO note_tags VALUES ('missing','missing')")
    }
}

private enum InjectedFailure: Error { case interrupted }
private let secondMigration = CollectionMigration(identifier: "v2") { db throws -> Void in
    try db.execute(sql: "CREATE TABLE migration_probe(value TEXT NOT NULL) STRICT")
    try db.execute(sql: "INSERT INTO migration_probe VALUES ('upgraded')")
}

@Test func migrationIntegrityFailureDoesNotAdvanceVersion() throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try fixture.create()
    try store.close()
    let broken = CollectionMigration(identifier: "v2") { db in
        // GRDB defers FK checking for migrations. The post-migration integrity gate
        // must reject this before committing the migration and its version markers.
        try db.execute(sql: "INSERT INTO note_tags VALUES ('missing-note','missing-tag')")
    }
    #expect(throws: CollectionDatabaseError.integrityFailure) {
        try CollectionDatabase(url: fixture.url, migrations: CollectionMigrations.initial + [broken])
    }
    let reopened = try CollectionDatabase(url: fixture.url)
    defer { try? reopened.close() }
    try reopened.pool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT schemaVersion FROM collection_meta") == 1)
        #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") == ["v1"])
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM note_tags") == 0)
    }
}

@Test func interruptedMigrationRollsBackDDLDataAndAllVersionMarkers() throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try fixture.create()
    try store.pool.write { try seedGraph($0) }
    try store.close()
    let broken = CollectionMigration(identifier: "v2") { db throws -> Void in
        try secondMigration.apply(db)
        try db.execute(sql: "UPDATE notes SET normalizedFront='must rollback'")
        try db.execute(sql: "UPDATE collection_meta SET schemaVersion=2; PRAGMA user_version=2")
        throw InjectedFailure.interrupted
    }
    #expect(throws: InjectedFailure.interrupted) {
        try CollectionDatabase(url: fixture.url, migrations: CollectionMigrations.initial + [broken])
    }
    let reopened = try CollectionDatabase(url: fixture.url)
    defer { try? reopened.close() }
    try reopened.pool.read { db throws -> Void in
        #expect(try !db.tableExists("migration_probe"))
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT schemaVersion FROM collection_meta") == 1)
        #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") == ["v1"])
        #expect(try String.fetchOne(db, sql: "SELECT normalizedFront FROM notes") == "hello")
    }
    let backups = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.contains("pre-migration") && $0.pathExtension == "sqlite" }
    #expect(backups.count == 1)
    let backup = try CollectionDatabase(url: #require(backups.first))
    try backup.close()
}

@Test func failedInitialMigrationCanRetryWithoutFalseVersion() throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let broken = CollectionMigration(identifier: "v1") { db throws -> Void in
        try InitialSchema.create(db)
        throw InjectedFailure.interrupted
    }
    #expect(throws: InjectedFailure.interrupted) {
        try CollectionDatabase(url: fixture.url, newCollection: fixture.metadata, migrations: [broken])
    }
    let reader = try CollectionMigrations.readOnlyQueue(fixture.url)
    try reader.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations") == 0)
        #expect(try !db.tableExists("collection_meta"))
    }
    try reader.close()
    let retry = try fixture.create()
    try retry.close()
}

@Test func upgradeHasVerifiedSnapshotIncludingCommittedWALAndAbortsWithoutBackup() throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try fixture.create()
    // Keep the pool open to force the backup path to handle a live WAL snapshot.
    try store.pool.write { try seedGraph($0) }
    defer { try? store.close() }
    #expect(throws: (any Error).self) {
        try CollectionDatabase(url: fixture.url, migrations: CollectionMigrations.initial + [secondMigration],
                               backupDirectory: fixture.url) // file is not a destination directory
    }
    try store.pool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
        #expect(try !db.tableExists("migration_probe"))
    }
    let upgraded = try CollectionDatabase(url: fixture.url, migrations: CollectionMigrations.initial + [secondMigration])
    defer { try? upgraded.close() }
    let backupURL = try #require(upgraded.migrationBackupURL)
    let backup = try CollectionDatabase(url: backupURL)
    defer { try? backup.close() }
    try backup.pool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM review_logs") == 1)
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
        #expect(try !db.tableExists("migration_probe"))
    }
    try upgraded.pool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 2)
        #expect(try Int.fetchOne(db, sql: "SELECT schemaVersion FROM collection_meta") == 2)
        #expect(try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations") == ["v1", "v2"])
        #expect(try String.fetchOne(db, sql: "SELECT value FROM migration_probe") == "upgraded")
    }
}

@Test(arguments: ["userVersion", "metadataVersion", "unknownMigration", "missingMigration", "mismatchedVersion"])
func incompatibleSchemasAreRejectedWithoutChangingDatabaseContents(kind: String) throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    let store = try fixture.create()
    try store.pool.writeWithoutTransaction { db throws -> Void in
        switch kind {
        case "userVersion": try db.execute(sql: "PRAGMA user_version=99")
        case "metadataVersion": try db.execute(sql: "UPDATE collection_meta SET schemaVersion=99")
        case "unknownMigration": try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99')")
        case "missingMigration": try db.execute(sql: "DELETE FROM grdb_migrations")
        default: try db.execute(sql: "PRAGMA user_version=0")
        }
    }
    try store.close()
    let bytes = try Data(contentsOf: fixture.url)
    let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
    let walBefore = (try? Data(contentsOf: wal)) ?? Data()
    let expected: CollectionDatabaseError = ["missingMigration", "mismatchedVersion"].contains(kind)
        ? .inconsistentSchema : .unsupportedSchema
    #expect(throws: expected) { try CollectionDatabase(url: fixture.url) }
    #expect(try Data(contentsOf: fixture.url) == bytes)
    // WAL may contain committed frames after closing a pool. OPEN_READONLY must
    // preserve those bytes too; SHM contains SQLite coordination, not collection data.
    let walAfter = (try? Data(contentsOf: wal)) ?? Data()
    #expect(walAfter == walBefore)
}

@Test func unrecognizedDatabaseAndMissingMetadataAreNeverAdopted() throws {
    let fixture = try DatabaseFixture()
    defer { fixture.remove() }
    #expect(throws: CollectionDatabaseError.creationMetadataRequired) { try CollectionDatabase(url: fixture.url) }
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    let foreign = try DatabaseQueue(path: fixture.url.path)
    try foreign.write { try $0.execute(sql: "CREATE TABLE somebody_elses_data(value TEXT)") }
    try foreign.close()
    let bytes = try Data(contentsOf: fixture.url)
    #expect(throws: CollectionDatabaseError.inconsistentSchema) { try fixture.create() }
    #expect(try Data(contentsOf: fixture.url) == bytes)
}
