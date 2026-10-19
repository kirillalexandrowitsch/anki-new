import CardsCore
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct QueryFixture: Sendable {
    let directory: URL
    let database: CollectionDatabase
    let writer: CollectionWriter
    let generation = UUID()
    let deck = DeckID()
    let child = DeckID()
    let deletedDeck = DeckID()
    let type = NoteTypeID()
    let tag = TagID()
    let notes: [NoteID]
    let cards: [CardID]
    var service: SQLiteCollectionQueries { SQLiteCollectionQueries(writer: writer, generation: generation) }
    let now = EpochMilliseconds(1_000)

    init(count: Int = 10, legacy: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try CollectionDatabase(url: directory.appendingPathComponent("collection.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Query fixture"), createdAt: EpochMilliseconds(0)),
            migrations: legacy ? CollectionMigrations.initial : CollectionMigrations.current)
        writer = CollectionWriter(database: database, clock: SystemClock())
        notes = (0..<count).map { _ in NoteID() }
        cards = (0..<count).map { _ in CardID() }
        try database.pool.write { db in
            try db.execute(sql: "INSERT INTO scheduler_parameters VALUES ('p','6','{\"schemaVersion\":1}',0.9,36500,'{\"schemaVersion\":1}',0)")
            for (id, name, parent, deleted) in [(deck, "Root %_", nil as DeckID?, nil as Int?),
                                               (child, "Child", deck, nil), (deletedDeck, "Deleted", nil, 1)] {
                try db.execute(sql: "INSERT INTO decks(id,parentID,name,normalizedName,deletedAt) VALUES (?,?,?,?,?)",
                               arguments: [QuerySQL.key(id), parent.map(QuerySQL.key), name, name.lowercased(), deleted])
            }
            try db.execute(sql: "INSERT INTO note_types VALUES (?,'test.basic','Basic',1,'{\"schemaVersion\":1}','{\"schemaVersion\":1}',0,NULL)", arguments: [QuerySQL.key(type)])
            try db.execute(sql: "INSERT INTO tags(id,name,normalizedName) VALUES (?,'Tag','tag')", arguments: [QuerySQL.key(tag)])
            for index in 0..<count {
                try db.execute(sql: "INSERT INTO notes VALUES (?,?,?,1,'shared',0,100,0,?)", arguments: [
                    QuerySQL.key(notes[index]), QuerySQL.key(type),
                    "{\"schemaVersion\":1,\"front\":\"Shared café\",\"back\":\"Перевод\",\"examples\":[{\"en\":\"Resilient example\",\"ru\":\"Пример\"}]}", index == 8 ? 1 : nil])
                try db.execute(sql: """
                    INSERT INTO cards(id,noteID,deckID,variantKey,templateID,generationState,suspended,buriedUntil,createdAt,deletedAt)
                    VALUES (?,?,?,'basic.forward','forward',?,?,?,0,?)
                    """, arguments: [QuerySQL.key(cards[index]), QuerySQL.key(notes[index]),
                        QuerySQL.key(index == 9 ? deletedDeck : (index % 2 == 0 ? deck : child)),
                        index == 5 ? "suppressed" : (index == 6 ? "orphaned" : "active"),
                        index == 3, index == 4 ? 1_001 : nil, index == 7 ? 1 : nil])
                if index != 0 {
                    try db.execute(sql: "INSERT INTO card_schedules(cardID,algorithmID,algorithmVersion,parameterSetID,phase,dueAt) VALUES (?,'fsrs','6','p',?,?)",
                        arguments: [QuerySQL.key(cards[index]), index == 4 ? "new" : (index == 2 ? "learning" : (index == 3 ? "relearning" : "review")), index == 2 ? 1_001 : 1_000])
                }
            }
            try db.execute(sql: "INSERT INTO note_tags VALUES (?,?)", arguments: [QuerySQL.key(notes[0]), QuerySQL.key(tag)])
            try db.execute(sql: "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,createdAt) VALUES (?,?,?,'reverse.backward','backward',0)",
                           arguments: [QuerySQL.key(CardID()), QuerySQL.key(notes[0]), QuerySQL.key(child)])
        }
    }
    func remove() { try? database.close(); try? FileManager.default.removeItem(at: directory) }
    func search(_ text: String) async throws -> LibrarySnapshot {
        try await service.library(LibraryQuery(filter: CardQueryFilter(search: text)))
    }
    func saveText(_ front: String, fail: Bool = false) async throws {
        let note = notes[0]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "front": front,
            "back": "Changed answer", "examples": [["en": "Fresh example", "ru": "Новый"]]]), as: UTF8.self)
        _ = try await writer.execute(commandID: CommandID(), kind: "test.note.save", request: front) { db in
            try db.execute(sql: "UPDATE notes SET fieldsJSON=?,normalizedFront=?,updatedAt=200,revision=revision+1 WHERE id=?",
                           arguments: [json, front.lowercased(), QuerySQL.key(note)])
            if fail { throw CollectionRepositoryError.insufficientSpace }
            return true
        }
    }
}

private enum QueryTestError: Error { case timeout, ended }
private func next<Value>(_ observation: QueryObservation<Value>) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            var iterator = observation.makeAsyncIterator()
            guard let value = try await iterator.next() else { throw QueryTestError.ended }
            return value
        }
        group.addTask { try await Task.sleep(for: .seconds(5)); throw QueryTestError.timeout }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
private func waitForNoObservers(_ writer: CollectionWriter) async throws {
    for _ in 0..<500 {
        if await writer.observationCount == 0 { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw QueryTestError.timeout
}

@Test func querySaveCommitUpdatesListAndFTSAndRollbackKeepsBoth() async throws {
    let fixture = try QueryFixture()
    defer { fixture.remove() }
    let all = try await fixture.service.observeLibrary(LibraryQuery())
    let old = try await fixture.service.observeLibrary(LibraryQuery(filter: CardQueryFilter(search: "cafe")))
    let fresh = try await fixture.service.observeLibrary(LibraryQuery(filter: CardQueryFilter(search: "replacement")))
    #expect(try await next(all).cardCount == 6)
    #expect(try await next(old).cardCount == 6)
    #expect(try await next(fresh).cardCount == 0)
    await #expect(throws: CollectionRepositoryError.insufficientSpace) { try await fixture.saveText("Rolledback", fail: true) }
    #expect(try await fixture.search("rolledback").cardCount == 0)
    #expect(try await fixture.search("cafe").cardCount == 6)
    try await fixture.saveText("Replacement")
    let saved = try await next(all)
    #expect(saved.rows.filter { $0.noteID == fixture.notes[0] }.count == 2)
    #expect(saved.rows.filter { $0.noteID == fixture.notes[0] }.allSatisfy {
        $0.front == "Replacement" && $0.back == "Changed answer" && $0.noteRevision.rawValue == 1
    })
    #expect(try await next(old).cardCount == 4)
    #expect(try await next(fresh).cardCount == 2)
    #expect(try await fixture.search("fresh").cardCount == 2)
    #expect(try await fixture.search("changed").cardCount == 2)
    #expect(try await fixture.search("перев").cardCount == 4)
    #expect(try await fixture.search("resilient").cardCount == 4)
    try await fixture.saveText("Replacement") // repeated content/revision update must not duplicate tokens
    #expect(try await fixture.search("replacement").cardCount == 2)
    all.cancel(); old.cancel(); fresh.cancel()
    try await waitForNoObservers(fixture.writer)
}

@Test func queryFiltersLiteralFTSAndCardVersusNoteCounts() async throws {
    let f = try QueryFixture()
    defer { f.remove() }
    for term in ["SHA", "cafe", "CAFÉ", "перев", "resil", "пример", "shared example"] {
        #expect(try await f.search(term).cardCount == 6)
    }
    for term in ["", "   "] { #expect(try await f.search(term).noteCount == 5) }
    for term in ["' OR 1=1 --", "\"*:^(){}", "front:missing OR shared", "shared NOT example", "absent"] {
        #expect(try await f.search(term).cardCount == 0)
    }
    let exact = try await f.service.library(LibraryQuery(filter: CardQueryFilter(deckID: f.deck)))
    #expect(exact.cardCount == 3)
    let subtree = try await f.service.library(LibraryQuery(filter: CardQueryFilter(deckID: f.deck, includeDescendants: true)))
    #expect(subtree.cardCount == 6 && subtree.noteCount == 5)
    #expect(try await f.service.library(LibraryQuery(filter: CardQueryFilter(tagID: f.tag))).cardCount == 2)
    #expect(try await f.service.library(LibraryQuery(filter: CardQueryFilter(search: "shared", deckID: f.deck,
        includeDescendants: true, noteTypeID: f.type, tagID: f.tag, phase: .new, suspended: false))).cardCount == 2)
    #expect(try await f.service.library(LibraryQuery(filter: CardQueryFilter(noteTypeID: NoteTypeID()))).cardCount == 0)
    #expect(try await f.service.library(LibraryQuery(filter: CardQueryFilter(noteTypeID: f.type, phase: .relearning, suspended: true))).cardCount == 1)
    #expect(try await f.service.library(LibraryQuery(filter: CardQueryFilter(deckID: DeckID(), includeDescendants: true))).rows.isEmpty)
    try await f.database.pool.write { db in try db.execute(sql: "UPDATE tags SET deletedAt=1") }
    #expect(try await f.service.library(LibraryQuery(filter: CardQueryFilter(tagID: f.tag))).cardCount == 0)
    let deckSearch = try await f.service.decks(DeckQuery(nameSearch: "%_"), asOf: f.now)
    #expect(deckSearch.deckCount == 1 && deckSearch.rows.first?.id == f.deck)
    #expect(throws: CollectionQueryError.invalidPage) { try QueryPage(offset: -1) }
    #expect(throws: CollectionQueryError.invalidPage) { try QueryPage(limit: 101) }
    #expect(throws: CollectionQueryError.searchTooLong) { try CardQueryFilter(search: String(repeating: "a", count: 513)) }
}

@Test func queryStablePaginationAcrossEqualSortKeysAndFilteredCounts() async throws {
    let f = try QueryFixture(count: 215)
    defer { f.remove() }
    for sort in LibrarySort.allCases {
        let expected = try await f.database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT c.id \(QuerySQL.joins) WHERE c.deletedAt IS NULL AND n.deletedAt IS NULL AND d.deletedAt IS NULL AND c.generationState='active' ORDER BY \(QuerySQL.order(sort))")
        }
        var found: [String] = []
        for offset in stride(from: 0, to: expected.count, by: 100) {
            let page = try await f.service.library(LibraryQuery(sort: sort, page: QueryPage(offset: offset)))
            #expect(page.rows.count <= 100 && page.cardCount == expected.count && page.noteCount == expected.count - 1)
            #expect(page.hasMore == (offset + page.rows.count < expected.count))
            found += page.rows.map { QuerySQL.key($0.id) }
        }
        #expect(found == expected && Set(found).count == expected.count)
        #expect(try await f.service.library(LibraryQuery(sort: sort, page: QueryPage(offset: 10_000))).rows.isEmpty)
    }
    let filtered = try await f.service.library(LibraryQuery(filter: CardQueryFilter(search: "resil", deckID: f.child), page: QueryPage(limit: 1)))
    #expect(filtered.rows.count == 1 && filtered.cardCount > 1 && filtered.hasMore)
}

@Test func queryTodayAndDeckCountsAgreeOnAvailabilityAtBoundary() async throws {
    let f = try QueryFixture()
    defer { f.remove() }
    let today = try await f.service.today(.all, asOf: f.now)
    #expect(today.counts == CardCounts(cards: 6, notes: 5, new: 3, learning: 2, review: 1, suspended: 1, buried: 1, availableNew: 2, due: 1))
    #expect(today.decks.deckCount == 2)
    #expect(today.decks.rows.reduce(0) { $0 + $1.counts.cards } == today.counts.cards)
    #expect(today.decks.rows.reduce(0) { $0 + $1.counts.notes } == 6) // one Note spans both decks
    let later = try await f.service.today(.all, asOf: EpochMilliseconds(1_001))
    #expect(later.counts.availableNew == 3 && later.counts.due == 2 && later.counts.buried == 0)
    let emptyDeck = try await f.service.decks(DeckQuery(filter: CardQueryFilter(search: "missing")), asOf: f.now)
    #expect(emptyDeck.rows.count == 2 && emptyDeck.rows.allSatisfy { $0.counts.cards == 0 })
    let observed = try await f.service.observeToday(.all, asOf: f.now)
    #expect(try await next(observed) == today)
    try await f.database.pool.write { try $0.execute(sql: "UPDATE cards SET suspended=1 WHERE id=?", arguments: [QuerySQL.key(f.cards[1])]) }
    #expect(try await next(observed).counts.due == 0)
    observed.cancel()
    try await waitForNoObservers(f.writer)
}

@Test func queryFTSTombstoneRestorePurgeAndReopen() async throws {
    let f = try QueryFixture()
    defer { f.remove() }
    try await f.saveText("Unique")
    for (deleted, expected) in [(true, 0), (false, 2), (true, 0), (false, 2)] {
        try await f.database.pool.write { db in
            try db.execute(sql: "UPDATE notes SET deletedAt=? WHERE id=?", arguments: [deleted ? 1 : nil, QuerySQL.key(f.notes[0])])
            // FTS itself must agree, not merely the outer deletedAt predicate.
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'unique'") == (deleted ? 0 : 1))
        }
        #expect(try await f.search("unique").cardCount == expected)
    }
    try await f.writer.close()
    let reopened = try CollectionDatabase(url: f.directory.appendingPathComponent("collection.sqlite"))
    defer { try? reopened.close() }
    try await reopened.pool.write { db in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'unique'") == 1)
        try db.execute(sql: "DELETE FROM cards WHERE noteID=?", arguments: [QuerySQL.key(f.notes[0])])
        try db.execute(sql: "DELETE FROM notes WHERE id=?", arguments: [QuerySQL.key(f.notes[0])])
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'unique'") == 0)
        try db.execute(sql: "INSERT INTO notes_fts(notes_fts, rank) VALUES ('integrity-check', 1)")
    }
}

@Test func queryUpgradeIndexesExistingV1NotesAndPreservesVerifiedBackup() async throws {
    let f = try QueryFixture(legacy: true)
    defer { f.remove() }
    try f.database.close()
    let url = f.directory.appendingPathComponent("collection.sqlite")
    let upgraded = try CollectionDatabase(url: url)
    defer { try? upgraded.close() }
    let backupURL = try #require(upgraded.migrationBackupURL)
    let backup = try CollectionDatabase(url: backupURL, migrations: CollectionMigrations.initial)
    defer { try? backup.close() }
    #expect(try await backup.metadata().schemaVersion == 1)
    #expect(try await upgraded.metadata().schemaVersion == 2)
    try await upgraded.pool.write { db in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'resilient'") == 9)
        try db.execute(sql: "INSERT INTO notes_fts(notes_fts, rank) VALUES ('integrity-check', 1)")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM cards") == 11)
    }
}

@Test func queryExplicitCancellationTaskCancellationAndReleaseStopObservers() async throws {
    let f = try QueryFixture()
    defer { f.remove() }
    let subscription = try await f.service.observeLibrary(LibraryQuery())
    _ = try await next(subscription)
    #expect(await f.writer.observationCount == 1)
    subscription.cancel()
    await #expect(throws: CollectionRepositoryError.cancelled) { try await next(subscription) }
    try await waitForNoObservers(f.writer)
    let taskSubscription = try await f.service.observeLibrary(LibraryQuery())
    _ = try await next(taskSubscription)
    let started = AsyncStream<Void>.makeStream()
    let task = Task {
        var iterator = taskSubscription.makeAsyncIterator()
        started.continuation.yield(())
        return try await iterator.next()
    }
    var signals = started.stream.makeAsyncIterator()
    _ = await signals.next()
    task.cancel()
    _ = try? await task.value
    try await waitForNoObservers(f.writer)
    do {
        let released = try await f.service.observeDecks(.all, asOf: f.now)
        _ = try await next(released)
        withExtendedLifetime(released) {}
    }
    try await waitForNoObservers(f.writer)
}

@Test func queryCloseRejectsBufferedSnapshotsAndOldGenerationAfterImmediateReopen() async throws {
    let f = try QueryFixture()
    defer { f.remove() }
    let buffered = try await f.service.observeLibrary(LibraryQuery())
    let active = try await f.service.observeDecks(.all, asOf: f.now)
    _ = try await next(active)
    try await f.writer.close()
    #expect(await f.writer.observationCount == 0)
    await #expect(throws: CollectionRepositoryError.staleContext) { try await next(buffered) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await next(active) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await f.service.library(LibraryQuery()) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await f.service.observeLibrary(LibraryQuery()) }
    let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: storeRoot) }
    let store = CollectionStore(root: storeRoot)
    let first = try await store.open()
    let old = try await store.queries(generation: first.generation)
    let observation = try await old.observeToday(.all, asOf: f.now)
    _ = try await next(observation)
    try await store.close(generation: first.generation)
    let second = try await store.open()
    #expect(second.generation != first.generation)
    await #expect(throws: CollectionRepositoryError.staleContext) { try await old.library(LibraryQuery()) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await next(observation) }
    let current = try await store.queries(generation: second.generation)
    #expect(try await current.library(LibraryQuery()).generation == second.generation)
    try await store.close(generation: second.generation)
}

private final class StatementCounter: Sendable {
    let lock = NSLock()
    nonisolated(unsafe) var statements = 0
    func record(_ sql: String) { if sql.hasPrefix("SELECT ") || sql.hasPrefix("WITH ") { lock.withLock { statements += 1 } } }
    var count: Int { lock.withLock { statements } }
}

@Test func queryPagesUseConstantStatementCountsInsteadOfNPlusOne() async throws {
    let f = try QueryFixture(count: 215)
    defer { f.remove() }
    for limit in [1, 100] {
        try await f.database.pool.read { db in
            let library = StatementCounter()
            db.trace { library.record($0.description) }
            let page = try QuerySQL.library(db, query: LibraryQuery(page: QueryPage(limit: limit)), generation: f.generation)
            db.trace(nil)
            #expect(page.rows.count == limit && library.count == 2)
            let today = StatementCounter()
            db.trace { today.record($0.description) }
            _ = try QuerySQL.today(db, query: .all, asOf: f.now, generation: f.generation)
            db.trace(nil)
            #expect(today.count == 3)
        }
    }
}

@Test func querySortsHaveExplicitDirectionAndDeckRenameIsObserved() async throws {
    let f = try QueryFixture()
    defer { f.remove() }
    try await f.saveText("Aardvark")
    #expect(try await f.service.library(LibraryQuery(sort: .frontAscending)).rows.first?.noteID == f.notes[0])
    #expect(try await f.service.library(LibraryQuery(sort: .frontDescending)).rows.last?.noteID == f.notes[0])
    #expect(try await f.service.library(LibraryQuery(sort: .updatedNewest)).rows.first?.updatedAt.rawValue == 200)
    #expect(try await f.service.library(LibraryQuery(sort: .updatedOldest)).rows.first?.updatedAt.rawValue == 100)
    #expect(try await f.service.library(LibraryQuery(sort: .newFirst)).rows.prefix(3).allSatisfy { $0.phase == .new })
    #expect(try await f.service.library(LibraryQuery(sort: .studiedFirst)).rows.suffix(3).allSatisfy { $0.phase == .new })
    let observed = try await f.service.observeDecks(.all, asOf: f.now)
    _ = try await next(observed)
    let repository = SQLiteDeckRepository(writer: f.writer)
    _ = try await repository.save(SaveDeckCommand(commandID: CommandID(), deckID: f.deck,
        expectedRevision: .initial, name: EntityName("Renamed")))
    #expect(try await next(observed).rows.first { $0.id == f.deck }?.deck.name.displayValue == "Renamed")
    let library = try await f.service.library(LibraryQuery(filter: CardQueryFilter(deckID: f.deck)))
    #expect(library.rows.allSatisfy { $0.deckName.displayValue == "Renamed" })
    observed.cancel()
    try await waitForNoObservers(f.writer)
}
