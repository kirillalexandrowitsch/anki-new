import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct OnboardingFixture {
    let directory: TestDirectory
    let database: CollectionDatabase
    let writer: CollectionWriter
    let clock = TestClock(date: Date(timeIntervalSince1970: 1_792_368_000))
    var service: SQLiteOnboardingService { SQLiteOnboardingService(writer: writer, clock: clock) }
    init() throws {
        directory = try TestDirectory()
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("onboarding.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
    func counts() async throws -> [Int] {
        try await database.pool.read { db in
            try ["decks", "notes", "cards", "card_schedules", "processed_commands", "collection_settings", "domain_events", "note_types", "scheduler_parameters", "tags"].map {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")!
            }
        }
    }
    func command(demo: Bool = true) throws -> CompleteOnboardingCommand {
        try CompleteOnboardingCommand(commandID: CommandID(), deckID: DeckID(), name: EntityName("Мой английский"), includeDemo: demo)
    }
}

@Test func onboardingDemoReplaysAcrossCommandsAndReopenWithoutDuplicatingNotes() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let store = CollectionStore(root: directory.url)
    let context = try await store.open()
    let service = try await store.onboarding(generation: context.generation)
    #expect(try await service.isRequired())
    let command = try CompleteOnboardingCommand(commandID: CommandID(), deckID: DeckID(), name: EntityName("  Мой английский  "), includeDemo: true)
    let result = try await service.complete(command)
    #expect(result.deck.name.displayValue == "Мой английский" && result.demoCount == 3)
    #expect(try await service.complete(command) == result)
    let other = try CompleteOnboardingCommand(commandID: CommandID(), deckID: DeckID(), name: EntityName("Другое окно"), includeDemo: false)
    #expect(try await service.complete(other) == result)
    let queries = try await store.queries(generation: context.generation)
    let rows = try await queries.library(LibraryQuery())
    #expect(rows.cardCount == 3 && rows.noteCount == 3 && rows.rows.allSatisfy { $0.phase == .new })
    #expect(Set(rows.rows.map(\.front)) == Set(OnboardingDemo.notes.map(\.front)))
    let notes = try await store.notes(generation: context.generation)
    for row in rows.rows {
        let note = try #require(await notes.note(id: row.noteID))
        #expect(note.tags.map(\.displayValue) == [OnboardingDemo.tag])
        #expect(OnboardingDemo.notes.contains(note.content))
    }
    let today = try await (store.todayWorkspace(generation: context.generation)).queries.studyToday(asOf: Date(),
        calendar: StudyDayCalculator(timeZoneID: "UTC"))
    #expect(today.counts.new == 3 && today.counts.due == 0)
    #expect(today.ratings == 0 && today.uniqueCards == 0 && today.responseDurationMs == 0)
    try await store.close(generation: context.generation)
    let next = try await store.open()
    let reopened = try await store.onboarding(generation: next.generation)
    #expect(try await !reopened.isRequired())
    #expect(try await reopened.complete(command) == result)
    let final = try await (store.queries(generation: next.generation)).library(LibraryQuery())
    #expect(final.cardCount == 3 && final.noteCount == 3)
    await #expect(throws: CollectionRepositoryError.staleContext) { try await service.complete(command) }
    try await store.close(generation: next.generation)
}

@Test func onboardingEmptyChoiceNeverInstallsNotesOrDefaults() async throws {
    let f = try OnboardingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory.url) }
    let result = try await f.service.complete(f.command(demo: false))
    #expect(result.demoCount == 0)
    #expect(try await f.counts() == [1, 0, 0, 0, 1, 1, 0, 0, 0, 0])
    #expect(try await !f.service.isRequired())
    try await f.writer.close()
}

@Test func onboardingFailureAtSecondNoteOrCompletionRollsBackEveryStepAndRetries() async throws {
    for failureSQL in [
        "CREATE TRIGGER fail_onboarding BEFORE INSERT ON notes WHEN (SELECT count(*) FROM notes) = 1 BEGIN SELECT RAISE(ABORT, 'synthetic'); END",
        "CREATE TRIGGER fail_onboarding BEFORE INSERT ON collection_settings BEGIN SELECT RAISE(ABORT, 'synthetic'); END"
    ] {
        let f = try OnboardingFixture()
        defer { try? FileManager.default.removeItem(at: f.directory.url) }
        let command = try f.command()
        try await f.database.pool.write { try $0.execute(sql: failureSQL) }
        await #expect(throws: CollectionRepositoryError.integrityFailure) { try await f.service.complete(command) }
        #expect(try await f.counts() == Array(repeating: 0, count: 10))
        #expect(try await f.service.isRequired())
        try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_onboarding") }
        #expect(try await f.service.complete(command).demoCount == 3)
        #expect(try await f.counts() == [1, 3, 3, 3, 1, 1, 3, 1, 1, 1])
        try await f.writer.close()
    }
}

@Test func onboardingConcurrentWindowsCreateOneDeckAndThreeNotes() async throws {
    let f = try OnboardingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory.url) }
    let a = try f.command(), b = try f.command()
    async let first = f.service.complete(a)
    async let second = f.service.complete(b)
    let results = try await (first, second)
    #expect(results.0 == results.1)
    #expect(try await f.counts() == [1, 3, 3, 3, 2, 1, 3, 1, 1, 1])
    try await f.writer.close()
}

@Test func onboardingDoesNotOfferDemoToExistingCollectionsIncludingDeletedDecks() async throws {
    let f = try OnboardingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory.url) }
    _ = try await CreateDeck(repository: SQLiteDeckRepository(writer: f.writer)).execute(
        DeckInput(name: "Existing"), id: DeckID(), commandID: CommandID())
    #expect(try await !f.service.isRequired())
    try await f.database.pool.write { try $0.execute(sql: "UPDATE decks SET deletedAt = 1") }
    #expect(try await !f.service.isRequired())
    await #expect(throws: CollectionRepositoryError.validation(.invalidField("onboardingAlreadyStarted"))) {
        try await f.service.complete(f.command())
    }
    #expect(try await f.counts() == [1, 0, 0, 0, 1, 0, 0, 0, 0, 0])
    try await f.writer.close()
}

@MainActor @Test func onboardingCancelAndFailedSaveKeepCollectionEmptyAndDraftRetryable() async throws {
    let f = try OnboardingFixture()
    defer { try? FileManager.default.removeItem(at: f.directory.url) }
    let model = OnboardingModel(service: f.service)
    await model.load()
    #expect(model.isRequired && model.showsWelcome && !model.includeDemo)
    model.create(); #expect(model.showsCreator && !model.canSave)
    model.name = "Draft"; model.includeDemo = true
    model.cancel()
    #expect(!model.showsCreator && !model.showsWelcome && model.isRequired)
    #expect(model.name.isEmpty && !model.includeDemo)
    #expect(try await f.counts() == Array(repeating: 0, count: 10))
    model.create(); model.name = "Retry"; model.includeDemo = true
    try await f.database.pool.write { db in
        try db.execute(sql: "CREATE TRIGGER fail_onboarding BEFORE INSERT ON notes BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
    }
    #expect(await !model.save())
    #expect(model.errorMessage != nil && model.showsCreator && model.canSave && model.name == "Retry" && model.includeDemo)
    #expect(try await f.counts() == Array(repeating: 0, count: 10))
    try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_onboarding") }
    #expect(await model.save())
    #expect(!model.isRequired && !model.showsCreator && model.result?.demoCount == 3)
    let relaunched = OnboardingModel(service: f.service)
    await relaunched.load()
    #expect(!relaunched.isRequired && relaunched.result == nil)
    model.stop(); #expect(!model.canSave)
    try await f.writer.close()
}
