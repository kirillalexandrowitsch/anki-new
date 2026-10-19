import CardsCore
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct NoteFixture {
    let directory: TestDirectory
    let clock = TestClock()
    let database: CollectionDatabase
    let writer: CollectionWriter
    var notes: SQLiteNoteRepository { SQLiteNoteRepository(writer: writer, clock: clock) }
    init() throws {
        directory = try TestDirectory()
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("notes.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
    func deck(parent: DeckID? = nil) async throws -> DeckID {
        let id = DeckID()
        _ = try await SQLiteDeckRepository(writer: writer).save(SaveDeckCommand(commandID: CommandID(), deckID: id,
            expectedRevision: nil, parentID: parent, name: EntityName(id.rawValue.uuidString)))
        return id
    }
    func schedule() async throws -> [String: DatabaseValue] {
        try await database.pool.read { try scheduleSnapshot($0) }
    }
    func counts() async throws -> [Int] {
        try await database.pool.read { db in
            try ["notes", "cards", "card_schedules", "tags", "note_tags", "note_media", "domain_events", "processed_commands", "notes_fts"]
                .map { try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")! }
        }
    }
}

private func scheduleSnapshot(_ db: Database) throws -> [String: DatabaseValue] {
    let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM card_schedules"))
    return Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as DatabaseValue) })
}

private func saveCommand(_ deck: DeckID, id: NoteID = NoteID(), revision: Revision? = nil,
                         commandID: CommandID = CommandID(), back: String = "Перевод", tags: [String] = [],
                         media: [NoteMediaReference] = []) -> SaveNoteCommand {
    SaveNoteCommand(commandID: commandID, noteID: id, expectedRevision: revision, initialDeckID: deck,
        content: BasicNoteContent(front: "  Café '); --\n", back: back, pronunciation: "/kæfeɪ/",
            examples: [NoteExample(en: "Synthetic example", ru: "Синтетический пример")], media: media), tags: tags)
}

@Test func basicNoteCreateEditReopenWithRealMediaTagsFTSAndCommandReplay() async throws {
    let directory = try TestDirectory()
    let clock = TestClock()
    let store = CollectionStore(root: directory.url, clock: clock)
    let context = try await store.open()
    let decks = try await store.decks(generation: context.generation)
    let deck = try await decks.save(SaveDeckCommand(commandID: CommandID(), deckID: DeckID(), expectedRevision: nil,
                                                   name: EntityName("Synthetic deck")))
    let media = try await store.media(generation: context.generation)
    let image = try await media.importFile(SyntheticSeed.directory.appendingPathComponent("pixel.png"))
    let audio = try await media.importFile(SyntheticSeed.directory.appendingPathComponent("tone.wav"))
    let refs = [NoteMediaReference(mediaID: image.id, fieldID: "image", role: .image),
                NoteMediaReference(mediaID: audio.id, fieldID: "audio", role: .audio)]
    let notes = try await store.notes(generation: context.generation)
    let useCase = SaveNote(repository: notes)
    let create = saveCommand(deck.id, tags: [" CAFÉ ", "cafe\u{301}", "Учебный"], media: refs)
    let saved = try await useCase.execute(create)
    #expect(saved.note.id == create.noteID && saved.note.noteTypeID == BasicNoteType.id)
    #expect(saved.content == create.content && saved.note.fields["front"] == create.content.front)
    #expect(saved.tags.map(\.normalizedValue) == ["café", "учебный"])
    #expect(saved.card.variantKey == "basic.forward" && saved.card.templateID == "basic.forward")
    #expect(saved.card.generationState == .active && saved.card.deckID == deck.id)
    #expect(saved.card.revision == .initial && saved.note.revision == .initial)
    clock.advance(by: 100)
    let edit = saveCommand(deck.id, id: saved.note.id, revision: saved.note.revision, back: "Новый перевод",
                           tags: ["Учебный"], media: [refs[0]])
    let edited = try await useCase.execute(edit)
    #expect(edited.card == saved.card)
    #expect(edited.note.revision == (try Revision(1)))
    #expect(edited.note.createdAt == saved.note.createdAt && edited.note.updatedAt > saved.note.updatedAt)
    #expect(try await notes.save(create) == saved)
    let queries = try await store.queries(generation: context.generation)
    let found = try await queries.library(LibraryQuery(filter: CardQueryFilter(search: "Новый")))
    #expect(found.cardCount == 1 && found.noteCount == 1 && found.rows.first?.id == saved.card.id)
    let examples = try await queries.library(LibraryQuery(filter: CardQueryFilter(search: "Синтетический")))
    #expect(examples.rows.first?.id == saved.card.id)
    try await store.close(generation: context.generation)
    let databaseURL = directory.url.appendingPathComponent("Collections/" + context.id.rawValue.uuidString.lowercased() + "/collection.sqlite")
    let reader = try CollectionMigrations.readOnlyQueue(databaseURL)
    try await reader.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM note_media")
        #expect(rows.count == 1)
        #expect(rows.first?["mediaID"] as String? == image.id.rawValue.uuidString.lowercased())
        #expect(rows.first?["fieldID"] as String? == "image")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM note_tags") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM cards") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM domain_events WHERE type = 'note.saved'") == 2)
    }
    try reader.close()
    let next = try await store.open()
    let reopened = try await store.notes(generation: next.generation)
    #expect(try await reopened.note(id: saved.note.id) == edited)
    #expect(try await reopened.save(create) == saved)
    #expect(try await reopened.save(edit) == edited)
    #expect(try await sharedMediaAssetStillExists(store, generation: next.generation, id: audio.id))
    await #expect(throws: CollectionRepositoryError.staleContext) { try await notes.note(id: saved.note.id) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await notes.save(edit) }
    try await store.close(generation: next.generation)
}

private func sharedMediaAssetStillExists(_ store: CollectionStore, generation: UUID, id: MediaID) async throws -> Bool {
    // Removing a Note ref must retain the shared asset for other Notes and future GC.
    let media = try await store.media(generation: generation)
    return try await media.asset(id: id) != nil
}

@Test func basicFreshScheduleAndEditingPreserveEveryScheduleColumn() async throws {
    let f = try NoteFixture()
    defer { try? f.database.close() }
    let deck = try await f.deck()
    let created = try await f.notes.save(saveCommand(deck))
    let fresh = try await f.schedule()
    #expect(fresh["phase"] == "new".databaseValue && fresh["algorithmID"] == "fsrs".databaseValue)
    #expect(fresh["algorithmVersion"] == "6".databaseValue && fresh["revision"] == 0.databaseValue)
    for field in ["stability", "difficulty", "dueAt", "lastReviewAt", "learningStep"] { #expect(fresh[field] == .null) }
    for field in ["repetitions", "lapses", "scheduleEpoch"] { #expect(fresh[field] == 0.databaseValue) }
    let parameters = try await f.database.pool.read { try #require(try String.fetchOne($0, sql: "SELECT weightsJSON FROM scheduler_parameters")) }
    let weights = try JSONSerialization.jsonObject(with: Data(parameters.utf8)) as! [String: Any]
    #expect(weights["w"] as? [Double] == FSRS6Configuration.makeScheduler().parameters.w)
    try await f.database.pool.write { db in
        try db.execute(sql: """
            UPDATE card_schedules SET phase='review', stability=12.5, difficulty=6.7, dueAt=2000000,
                lastReviewAt=1000000, repetitions=9, lapses=2, learningStep=1, scheduleEpoch=3, revision=17;
            UPDATE cards SET suspended=1, buriedUntil=3000000, revision=4;
            """)
    }
    let before = try await f.schedule()
    let card = try #require(await f.notes.note(id: created.note.id)).card
    let edited = try await f.notes.save(saveCommand(DeckID(), id: created.note.id, revision: .initial, back: "Changed"))
    #expect(edited.card == card)
    #expect(try await f.schedule() == before)
    let repeated = try await f.notes.save(saveCommand(deck, id: created.note.id, revision: edited.note.revision, back: "Changed again"))
    #expect(repeated.card.id == created.card.id && repeated.card.deckID == deck)
    #expect(try await f.schedule() == before)
    #expect(try await f.counts().prefix(3) == [1, 1, 1])
    try await f.database.checkIntegrity()
}

@Test func basicSaveAfterSuppressionAndReopenKeepsTombstoneAndSchedule() async throws {
    let f = try NoteFixture()
    let deck = try await f.deck()
    let saved = try await f.notes.save(saveCommand(deck))
    try await f.database.pool.write { try $0.execute(sql: """
        UPDATE cards SET generationState='suppressed', deletedAt=1234, revision=2;
        UPDATE card_schedules SET phase='review', stability=5, difficulty=3, repetitions=7, revision=9;
        """) }
    let schedule = try await f.schedule()
    try await f.writer.close()
    let reopened = try CollectionDatabase(url: f.directory.url.appendingPathComponent("notes.sqlite"))
    let writer = CollectionWriter(database: reopened, clock: f.clock)
    let notes = SQLiteNoteRepository(writer: writer, clock: f.clock)
    let updated = try await notes.save(saveCommand(deck, id: saved.note.id, revision: .initial, back: "Still suppressed"))
    #expect(updated.card.id == saved.card.id && updated.card.generationState == .suppressed)
    #expect(updated.card.deletedAt == EpochMilliseconds(1234).date)
    #expect(updated.card.revision == (try Revision(2)))
    let actual = try await reopened.pool.read { try scheduleSnapshot($0) }
    #expect(actual == schedule)
    let queries = SQLiteCollectionQueries(writer: writer, generation: UUID())
    #expect(try await queries.library(LibraryQuery()).cardCount == 0)
    #expect(try await reopened.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM cards") } == 1)
    try await writer.close()
}

@Test func failedBasicSaveRollsBackFieldsTagsMediaFTSEventAndJournalThenRetries() async throws {
    let f = try NoteFixture()
    defer { try? f.database.close() }
    let deck = try await f.deck()
    let before = try await f.counts()
    let create = saveCommand(deck, tags: ["New synthetic tag"])
    try await f.database.pool.write { try $0.execute(sql: """
        CREATE TRIGGER fail_note_event BEFORE INSERT ON domain_events BEGIN SELECT RAISE(ABORT, 'synthetic fault'); END;
        """) }
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await f.notes.save(create) }
    #expect(try await f.counts() == before)
    #expect(try await f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note_types") } == 0)
    try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_note_event") }
    let saved = try await f.notes.save(create)
    let baseline = try await f.counts()
    let bad = saveCommand(deck, id: saved.note.id, revision: .initial, back: "Must roll back", tags: ["Rolled back"],
        media: [NoteMediaReference(mediaID: MediaID(), fieldID: "audio", role: .audio)])
    await #expect(throws: CollectionRepositoryError.self) { try await f.notes.save(bad) }
    #expect(try await f.notes.note(id: saved.note.id) == saved)
    #expect(try await f.counts() == baseline)
    try await f.database.checkIntegrity()
}

@Test func concurrentNoteEditorsCommitOneWinnerAndReusedCommandsFail() async throws {
    let f = try NoteFixture()
    defer { try? f.database.close() }
    let deck = try await f.deck()
    let create = saveCommand(deck)
    let saved = try await f.notes.save(create)
    let commands = (0..<12).map { saveCommand(deck, id: saved.note.id, revision: .initial, back: "Window \($0)") }
    let results = await withTaskGroup(of: Bool.self) { group in
        for command in commands {
            group.addTask {
                do { _ = try await f.notes.save(command); return true }
                catch {
                    #expect(error as? CollectionRepositoryError == .revisionConflict(entity: .note(saved.note.id),
                        expected: .initial, actual: try! Revision(1)))
                    return false
                }
            }
        }
        var values = [Bool]()
        for await value in group { values.append(value) }
        return values
    }
    #expect(results.filter { $0 }.count == 1)
    let current = try #require(await f.notes.note(id: saved.note.id))
    #expect(current.note.revision == (try Revision(1)))
    await #expect(throws: CollectionRepositoryError.commandIDReused) {
        try await f.notes.save(saveCommand(deck, id: saved.note.id, commandID: create.commandID, back: "Different"))
    }
    await #expect(throws: CollectionRepositoryError.alreadyExists(.note(saved.note.id))) { try await f.notes.save(saveCommand(deck, id: saved.note.id)) }
    #expect(try await f.notes.save(create) == saved)
    #expect(try await f.notes.note(id: saved.note.id) == current)
}

@Test func invalidBasicContentMediaAndMissingDeckDoNotWriteAnything() async throws {
    let f = try NoteFixture()
    defer { try? f.database.close() }
    let deck = try await f.deck()
    let before = try await f.counts()
    for content in [BasicNoteContent(front: " \n", back: "B"), BasicNoteContent(front: "F", back: "\n"),
        BasicNoteContent(front: "F", back: "B", media: [NoteMediaReference(mediaID: MediaID(), fieldID: "front", role: .audio)]),
        BasicNoteContent(front: "F", back: "B", media: [NoteMediaReference(mediaID: MediaID(), fieldID: "image", role: .image, orderIndex: -1)])] {
        await #expect(throws: CollectionRepositoryError.self) {
            try await f.notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(), expectedRevision: nil,
                                                  initialDeckID: deck, content: content))
        }
    }
    let missing = DeckID()
    await #expect(throws: CollectionRepositoryError.notFound(.deck(missing))) { try await f.notes.save(saveCommand(missing)) }
    await #expect(throws: CollectionRepositoryError.validation(.emptyName)) { try await f.notes.save(saveCommand(deck, tags: [" "])) }
    #expect(try await f.counts() == before)
}

@Test func newBasicCardInheritsNearestDeckPresetWithoutMutatingParameters() async throws {
    let f = try NoteFixture()
    defer { try? f.database.close() }
    let root = try await f.deck()
    let child = try await f.deck(parent: root)
    try await f.database.pool.write { db in
        _ = try BasicNoteDefaults.parameterSet(db, deckID: root, now: 0)
        try db.execute(sql: """
            INSERT INTO scheduler_parameters SELECT 'custom-parameter', algorithmVersion, weightsJSON, .85,
                maximumIntervalDays, learningPolicyJSON, createdAt FROM scheduler_parameters;
            INSERT INTO deck_presets VALUES ('custom-preset','Synthetic',10,100,'custom-parameter','{"schemaVersion":1}',0);
            UPDATE decks SET presetID='custom-preset' WHERE id = ?;
            """, arguments: [root.rawValue.uuidString.lowercased()])
    }
    _ = try await f.notes.save(saveCommand(child))
    #expect(try await f.schedule()["parameterSetID"] == "custom-parameter".databaseValue)
}

@Test func sharedMediaReferencesValidateRolesSlotsAndPublishedStateAtomically() async throws {
    let f = try NoteFixture()
    defer { try? f.database.close() }
    let deck = try await f.deck()
    let asset = MediaID()
    let assetKey = asset.rawValue.uuidString.lowercased()
    try await f.database.pool.write { db in
        try db.execute(sql: "INSERT INTO media_assets VALUES (?, ?, ?, 'com.apple.m4a-audio', 12, 0, 'published')",
            arguments: [assetKey, String(repeating: "a", count: 64), "Media/" + String(repeating: "a", count: 64) + ".m4a"])
    }
    let ref = NoteMediaReference(mediaID: asset, fieldID: "audio", role: .audio)
    let one = try await f.notes.save(saveCommand(deck, media: [ref]))
    let two = try await f.notes.save(saveCommand(deck, media: [ref]))
    #expect(try await f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note_media") } == 2)
    let before = try await f.counts()
    for refs in [[ref, ref], [NoteMediaReference(mediaID: asset, fieldID: "image", role: .image)]] {
        await #expect(throws: CollectionRepositoryError.validation(.invalidField("media"))) {
            try await f.notes.save(saveCommand(deck, id: one.note.id, revision: .initial, media: refs))
        }
        #expect(try await f.counts() == before)
    }
    _ = try await f.notes.save(saveCommand(deck, id: one.note.id, revision: .initial))
    #expect(try await f.notes.note(id: two.note.id)?.content.media == [ref])
    #expect(try await f.database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM note_media") } == 1)
    try await f.database.pool.write { try $0.execute(sql: "UPDATE media_assets SET lifecycleState = 'orphaned'") }
    await #expect(throws: CollectionRepositoryError.notFound(.media(asset))) {
        try await f.notes.save(saveCommand(deck, id: two.note.id, revision: .initial, media: [ref]))
    }
    #expect(try await f.notes.note(id: two.note.id) == two)
}
