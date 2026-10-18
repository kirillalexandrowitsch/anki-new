import CardsCore
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct WriterFixture {
    let directory: URL
    let database: CollectionDatabase
    let writer: CollectionWriter
    var decks: any DeckRepository { SQLiteDeckRepository(writer: writer) }
    var collection: any CollectionInfoRepository { SQLiteCollectionInfoRepository(writer: writer) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try CollectionDatabase(url: directory.appendingPathComponent("collection.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Fixture"),
                                                createdAt: EpochMilliseconds(1_700_000_000_000)))
        writer = CollectionWriter(database: database, clock: SystemClock())
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func journalCount() async throws -> Int {
        try await database.pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM processed_commands")! }
    }
}

private func command(id: DeckID = DeckID(), revision: Revision? = nil, name: String = "English",
                     commandID: CommandID = CommandID(), parent: DeckID? = nil) throws -> SaveDeckCommand {
    try SaveDeckCommand(commandID: commandID, deckID: id, expectedRevision: revision,
                        parentID: parent, name: EntityName(name), description: "Synthetic description")
}

@Test func duplicateCommandReturnsOriginalSnapshotEvenAfterLaterUpdateAndReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CollectionStore(root: root)
    let context = try await store.open()
    let decks = try await store.decks(generation: context.generation)
    let create = try command(name: "'); DELETE FROM decks; --")
    let original = try await decks.save(create)
    #expect(original.revision == .initial)
    #expect(try await decks.save(create) == original)
    let update = try command(id: create.deckID, revision: original.revision, name: "Edited")
    let edited = try await decks.save(update)
    #expect(edited.revision == (try Revision(1)))
    #expect(try await decks.save(create) == original)
    #expect(try await decks.deck(id: create.deckID) == edited)
    try await store.close(generation: context.generation)
    let reopened = CollectionStore(root: root)
    let next = try await reopened.open()
    let newDecks = try await reopened.decks(generation: next.generation)
    #expect(try await newDecks.save(update) == edited)
    #expect(try await newDecks.save(create) == original)
    #expect(try await newDecks.deck(id: create.deckID) == edited)
    try await reopened.close(generation: next.generation)
}

@Test func reusedCommandIDRejectsDifferentPayloadAndDifferentRepository() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let first = try command()
    let saved = try await fixture.decks.save(first)
    let changed = try command(id: first.deckID, name: "Other", commandID: first.commandID)
    await #expect(throws: CollectionRepositoryError.commandIDReused) { try await fixture.decks.save(changed) }
    let rename = try RenameCollectionCommand(commandID: first.commandID, expectedRevision: .initial,
                                              name: EntityName("Other"))
    await #expect(throws: CollectionRepositoryError.commandIDReused) { try await fixture.collection.rename(rename) }
    #expect(try await fixture.decks.deck(id: first.deckID) == saved)
    #expect(try await fixture.collection.info().name == EntityName("Fixture"))
    #expect(try await fixture.journalCount() == 1)
}

@Test func concurrentSavesWithOneBaseRevisionCommitExactlyOneWinner() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let base = try await fixture.decks.save(command())
    let requests = try (0..<20).map { try command(id: base.id, revision: base.revision, name: "Window \($0)") }
    let outcomes = await withTaskGroup(of: Result<Deck, CollectionRepositoryError>.self) { group in
        for request in requests {
            group.addTask {
                do { return .success(try await fixture.decks.save(request)) }
                catch { return .failure(error as? CollectionRepositoryError ?? .integrityFailure) }
            }
        }
        var results: [Result<Deck, CollectionRepositoryError>] = []
        for await result in group { results.append(result) }
        return results
    }
    var winners: [Deck] = []
    for result in outcomes {
        switch result {
        case .success(let deck): winners.append(deck)
        case .failure(let error):
            #expect(error == .revisionConflict(entity: .deck(base.id), expected: .initial, actual: try Revision(1)))
        }
    }
    #expect(winners.count == 1)
    #expect(try await fixture.decks.deck(id: base.id) == winners.first)
    #expect(try await fixture.journalCount() == 2)
}

@Test func concurrentDuplicateSavesApplyOnceAndAllReturnSameResult() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let base = try await fixture.decks.save(command())
    let update = try command(id: base.id, revision: base.revision, name: "Once")
    let results = try await withThrowingTaskGroup(of: Deck.self) { group in
        for _ in 0..<20 { group.addTask { try await fixture.decks.save(update) } }
        var values: [Deck] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(results.count == 20)
    #expect(results.allSatisfy { $0 == results.first })
    #expect(results.first?.revision == (try Revision(1)))
    #expect(try await fixture.journalCount() == 2)
}

@Test func journalInsertFailureRollsBackMutationAndRevisionAndAllowsSameCommandRetry() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let original = try await fixture.decks.save(command())
    let update = try command(id: original.id, revision: original.revision, name: "After retry")
    try await fixture.database.pool.write { db in
        try db.execute(sql: """
            CREATE TRIGGER fail_journal BEFORE INSERT ON processed_commands
            BEGIN SELECT RAISE(ABORT, 'synthetic commit failure'); END
            """)
    }
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await fixture.decks.save(update) }
    #expect(try await fixture.decks.deck(id: original.id) == original)
    #expect(try await fixture.journalCount() == 1)
    try await fixture.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_journal") }
    let retried = try await fixture.decks.save(update)
    #expect(retried.revision == (try Revision(1)))
    #expect(try await fixture.decks.save(update) == retried)
    #expect(try await fixture.journalCount() == 2)
    try await fixture.database.checkIntegrity()
}

@Test func transactionFailureRollsBackAllTablesIncludingEarlierWrites() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let request = try command()
    await #expect(throws: CollectionRepositoryError.insufficientSpace) {
        try await fixture.writer.execute(commandID: request.commandID, kind: "fixture", request: request) { db -> Deck in
            try db.execute(sql: "UPDATE collection_meta SET name = 'Partial', settingsRevision = 1")
            try db.execute(sql: "INSERT INTO decks(id, name, normalizedName) VALUES (?, 'Partial', 'partial')",
                           arguments: [request.deckID.rawValue.uuidString.lowercased()])
            throw CollectionRepositoryError.insufficientSpace
        }
    }
    #expect(try await fixture.collection.info().name == EntityName("Fixture"))
    #expect(try await fixture.collection.info().revision == .initial)
    #expect(try await fixture.decks.deck(id: request.deckID) == nil)
    #expect(try await fixture.journalCount() == 0)
    _ = try await fixture.decks.save(request)
}

@Test func repositoryValidatesMissingIDsDuplicateNamesAndHierarchyWithoutJournalingFailures() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let first = try await fixture.decks.save(command(name: "Café"))
    let duplicate = try command(name: "  CAFE\u{301}  ")
    await #expect(throws: CollectionRepositoryError.validation(.duplicateName(normalized: "café"))) {
        try await fixture.decks.save(duplicate)
    }
    let idCollision = try command(id: first.id)
    await #expect(throws: CollectionRepositoryError.alreadyExists(.deck(first.id))) { try await fixture.decks.save(idCollision) }
    let missing = try command(revision: .initial)
    await #expect(throws: CollectionRepositoryError.notFound(.deck(missing.deckID))) { try await fixture.decks.save(missing) }
    let absentParent = DeckID()
    let childOfMissing = try command(parent: absentParent)
    await #expect(throws: CollectionRepositoryError.notFound(.deck(absentParent))) { try await fixture.decks.save(childOfMissing) }
    let child = try await fixture.decks.save(command(parent: first.id))
    let cycle = try command(id: first.id, revision: .initial, parent: child.id)
    await #expect(throws: CollectionRepositoryError.invalidHierarchy) { try await fixture.decks.save(cycle) }
    let selfParent = try command(id: first.id, revision: .initial, parent: first.id)
    await #expect(throws: CollectionRepositoryError.invalidHierarchy) { try await fixture.decks.save(selfParent) }
    #expect(try await fixture.journalCount() == 2)
    #expect(try await fixture.decks.deck(id: first.id) == first)
}

@Test func unknownOrDamagedCommandResultsNeverReapplyMutation() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let request = try command()
    let original = try await fixture.decks.save(request)
    for (version, json, expected) in [
        (2, "{\"schemaVersion\":1}", CollectionRepositoryError.unsupportedCommandResult),
        (1, "{\"schemaVersion\":2,\"kind\":\"deck.save.v1\",\"request\":\"x\"}", .unsupportedCommandResult),
        (1, "{\"schemaVersion\":1}", .integrityFailure),
    ] {
        try await fixture.database.pool.write {
            try $0.execute(sql: "UPDATE processed_commands SET resultVersion = ?, resultJSON = ?", arguments: [version, json])
        }
        await #expect(throws: expected) { try await fixture.decks.save(request) }
        #expect(try await fixture.decks.deck(id: request.deckID) == original)
        #expect(try await fixture.journalCount() == 1)
    }
}

@Test func collectionRenameUsesOwnRevisionAndPersistsReplayAcrossReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CollectionStore(root: root)
    let context = try await store.open()
    let repository = try await store.collectionInfo(generation: context.generation)
    let initial = try await repository.info()
    let rename = try RenameCollectionCommand(commandID: CommandID(), expectedRevision: initial.revision,
                                              name: EntityName("Renamed collection"))
    let result = try await repository.rename(rename)
    #expect(result.revision == (try Revision(1)))
    let conflict = try RenameCollectionCommand(commandID: CommandID(), expectedRevision: .initial,
                                               name: EntityName("Stale window"))
    await #expect(throws: CollectionRepositoryError.revisionConflict(entity: .collection(initial.id),
        expected: .initial, actual: try Revision(1))) { try await repository.rename(conflict) }
    #expect(try await repository.rename(rename) == result)
    try await store.close(generation: context.generation)
    let next = try await store.open()
    #expect(next.name == result.name)
    let reopened = try await store.collectionInfo(generation: next.generation)
    #expect(try await reopened.info() == result)
    #expect(try await reopened.rename(rename) == result)
    try await store.close(generation: next.generation)
}

@Test func oldRepositoriesRejectReadWriteAndReplayAfterCloseAndReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CollectionStore(root: root)
    let context = try await store.open()
    let decks = try await store.decks(generation: context.generation)
    let info = try await store.collectionInfo(generation: context.generation)
    let request = try command()
    let original = try await decks.save(request)
    try await store.close(generation: context.generation)
    let next = try await store.open()
    await #expect(throws: CollectionRepositoryError.staleContext) { try await decks.save(request) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await decks.deck(id: request.deckID) }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await info.info() }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await store.decks(generation: context.generation) }
    let current = try await store.decks(generation: next.generation)
    #expect(try await current.deck(id: request.deckID) == original)
    try await store.close(generation: next.generation)
}

@Test func cancellationBeforeTransactionDoesNotCreateJournalOrMutation() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let request = try command()
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await fixture.decks.save(request)
    }
    await #expect(throws: CollectionRepositoryError.cancelled) { try await cancelled.value }
    #expect(try await fixture.journalCount() == 0)
    #expect(try await fixture.decks.deck(id: request.deckID) == nil)
    _ = try await fixture.decks.save(request)
}

@Test func immediateReopenAfterAsyncCloseNeverRetainsThePreviousLease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = CollectionStore(root: root)
    let second = CollectionStore(root: root)
    var identity: CollectionID?
    for _ in 0..<100 {
        for store in [first, second] {
            let context = try await store.open()
            if let identity { #expect(context.id == identity) }
            else { identity = context.id }
            let repository = try await store.collectionInfo(generation: context.generation)
            #expect(try await repository.info().id == context.id)
            try await store.close(generation: context.generation)
            await #expect(throws: CollectionRepositoryError.staleContext) { try await repository.info() }
        }
    }
}

@Test func explicitLeaseReleaseIsImmediateAndNeverClosesAReusedDescriptor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("collection.lock")
    let retired = try CollectionLease(url: url)
    #expect(throws: CollectionAccessError.locked) { try CollectionLease(url: url) }
    retired.release()
    let current = try CollectionLease(url: url)
    retired.release() // must not accidentally close the new owner's potentially reused FD
    #expect(throws: CollectionAccessError.locked) { try CollectionLease(url: url) }
    withExtendedLifetime((retired, current)) {}
    #expect(FileManager.default.fileExists(atPath: url.path))
    current.release()
    let next = try CollectionLease(url: url)
    withExtendedLifetime(next) {}
}

@Test func cancellationDuringCommitStillReturnsCommittedOutcome() async throws {
    let fixture = try WriterFixture()
    defer { fixture.remove() }
    let request = try command()
    let gate = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream()
    let commit = Task {
        try await fixture.writer.execute(commandID: request.commandID, kind: "fixture", request: request) { db in
            entered.continuation.yield(())
            gate.wait()
            try db.execute(sql: "INSERT INTO decks(id, name, normalizedName) VALUES (?, ?, ?)",
                arguments: [request.deckID.rawValue.uuidString.lowercased(), request.name.displayValue,
                            request.name.normalizedValue])
            return Deck(id: request.deckID, name: request.name)
        }
    }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    commit.cancel()
    gate.signal()
    #expect(try await commit.value.revision == .initial)
    #expect(try await fixture.journalCount() == 1)
}
