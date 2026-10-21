import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct PreferencesFixture {
    let directory: TestDirectory
    let database: CollectionDatabase
    let writer: CollectionWriter
    let clock = TestClock(date: Date(timeIntervalSince1970: 1_792_368_000))
    var repository: SQLiteStudyPreferences { SQLiteStudyPreferences(writer: writer) }
    init() throws {
        directory = try TestDirectory()
        database = try CollectionDatabase(url: directory.url.appendingPathComponent("preferences.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(), name: EntityName("Synthetic"), createdAt: EpochMilliseconds(0)))
        writer = CollectionWriter(database: database, clock: clock)
    }
}

@Test func preferencesReplayConflictAndFailureAreAtomic() async throws {
    let f = try PreferencesFixture()
    #expect(try await f.repository.load() == StudyPreferencesSnapshot())
    let command = try SaveStudyPreferences(expectedRevision: .initial, value: StudyPreferences(newLimit: 0, reviewLimit: 9999))
    let saved = try await f.repository.save(command)
    #expect(try await f.repository.save(command) == saved)
    #expect(saved.revision.rawValue == 1)
    do { _ = try await f.repository.save(SaveStudyPreferences(expectedRevision: .initial, value: .standard)); Issue.record("Expected conflict") }
    catch let error as CollectionRepositoryError {
        guard case .revisionConflict = error else { throw error }
    }
    try await f.database.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_preferences BEFORE UPDATE ON collection_settings BEGIN SELECT RAISE(ABORT, 'synthetic'); END") }
    let failed = SaveStudyPreferences(expectedRevision: saved.revision, value: .standard)
    await #expect(throws: CollectionRepositoryError.integrityFailure) { try await f.repository.save(failed) }
    #expect(try await f.repository.load() == saved)
    #expect(try await f.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM processed_commands") } == 1)
    try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_preferences") }
    #expect(try await f.repository.save(failed).value == .standard)
    try await f.writer.close()
    await #expect(throws: CollectionRepositoryError.staleContext) { try await f.repository.load() }
}

@MainActor @Test func preferencesDebounceInvalidInputAndWriteErrorRestoreSavedValues() async throws {
    let f = try PreferencesFixture()
    let model = StudyPreferencesModel(repository: f.repository)
    await model.load()
    model.edit(.new, text: "7")
    // A later invalid draft cancels the earlier valid debounce.
    model.edit(.new, text: "")
    try await Task.sleep(for: .milliseconds(550))
    #expect(try await f.repository.load().value == .standard)
    for invalid in ["-", "-1", "1.5", "10000", "999999999999999999999999", "abc", " 5", "١"] {
        model.edit(.new, text: invalid)
        #expect(!model.isValid)
        await model.persist()
        #expect(try await f.repository.load().value == .standard)
    }
    model.endEditing(); #expect(model.newText == "20")
    model.edit(.new, text: "2")
    model.edit(.new, text: "3")
    for _ in 0..<150 {
        if model.saved?.value.newLimit == 3 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await f.repository.load().value.newLimit == 3)
    try await f.database.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_preferences BEFORE UPDATE ON collection_settings BEGIN SELECT RAISE(ABORT, 'synthetic'); END") }
    model.edit(.new, text: "9"); await model.persist()
    #expect(model.newText == "3" && model.error != nil)
    #expect(try await f.repository.load().value.newLimit == 3)
    try await f.database.pool.write { try $0.execute(sql: "DROP TRIGGER fail_preferences") }
    model.edit(.review, text: "17"); model.endEditing()
    for _ in 0..<150 {
        if model.saved?.value.reviewLimit == 17 { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try await f.repository.load().value.reviewLimit == 17)
    model.edit(.new, text: "99"); model.stop()
    try await Task.sleep(for: .milliseconds(450))
    #expect(try await f.repository.load().value.newLimit == 3)
    try await f.writer.close()
}

@Test func preferencesSurviveReopenDriveTodayAndKeepSessionPolicy() async throws {
    let directory = try TestDirectory()
    let store = CollectionStore(root: directory.url)
    var context = try await store.open()
    let onboarding = try await store.onboarding(generation: context.generation)
    _ = try await onboarding.complete(CompleteOnboardingCommand(commandID: CommandID(), deckID: DeckID(), name: EntityName("Synthetic"), includeDemo: true))
    let repository = try await store.studyPreferences(generation: context.generation)
    var saved = try await repository.save(SaveStudyPreferences(expectedRevision: .initial, value: StudyPreferences(newLimit: 1, reviewLimit: 2)))
    let calendar = try StudyDayCalculator(timeZoneID: TimeZone.current.identifier)
    let queries = try await store.todayWorkspace(generation: context.generation).queries
    let observation = try await queries.observeStudyToday(asOf: Date(), calendar: calendar)
    var iterator = observation.makeAsyncIterator()
    #expect(try await iterator.next()?.counts.new == 1)
    let session = try await store.studySession(generation: context.generation)
    saved = try await repository.save(SaveStudyPreferences(expectedRevision: saved.revision, value: StudyPreferences(newLimit: 0, reviewLimit: 0)))
    #expect(try await queries.studyToday(asOf: Date(), calendar: calendar).counts.new == 1)
    if case .question = try await session.next(skipping: [], preferred: nil) {} else { Issue.record("Persisted session policy lost") }
    try await (session as! any StudyProgressService).finish(early: false)
    // Observation sees the collection settings once the saved session is finished.
    var updated = try await iterator.next()
    if updated?.counts.new != 0 { updated = try await iterator.next() }
    #expect(updated?.counts.new == 0)
    observation.cancel()
    try await store.close(generation: context.generation)
    context = try await store.open()
    let reopened = try await store.studyPreferences(generation: context.generation)
    #expect(try await reopened.load() == saved)
    let rows = try await store.queries(generation: context.generation).library(LibraryQuery())
    #expect(rows.noteCount == 3 && rows.cardCount == 3)
    let next = try await store.studySession(generation: context.generation)
    if case .completed = try await next.next(skipping: [], preferred: nil) {} else { Issue.record("New session ignored zero limit") }
    try await store.close(generation: context.generation)
}

@MainActor @Test func preferencesAppearancePersistsInSeparateDefaultsWithoutEditorAutosave() async throws {
    let name = "anki.preferences.test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let appearance = AppearanceModel(store: UserDefaultsPreferences(defaults: defaults))
    appearance.set(theme: .dark); appearance.set(language: .en)
    let reopened = AppearanceModel(store: UserDefaultsPreferences(defaults: UserDefaults(suiteName: name)!))
    #expect(reopened.value == AppPreferences(theme: .dark, language: .en))
    #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
    let f = try PreferencesFixture()
    let deck = try await SQLiteDeckRepository(writer: f.writer).save(SaveDeckCommand(commandID: CommandID(),
        deckID: DeckID(), expectedRevision: nil, name: EntityName("Synthetic draft deck")))
    let editor = EditorModel(repository: SQLiteNoteRepository(writer: f.writer, clock: f.clock), decks: [deck])
    editor.draft.front = "Unsaved question"; editor.draft.back = "Unsaved answer"
    let draft = editor.draft
    let preferences = StudyPreferencesModel(repository: f.repository)
    await preferences.load(); preferences.edit(.review, text: "17"); await preferences.persist()
    // Preference changes never invoke Note Save or install a type/schedule.
    #expect(try await f.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM notes") } == 0)
    #expect(defaults.object(forKey: "study.preferences.v1") == nil)
    #expect(try await f.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collection_settings WHERE key LIKE 'app.%'") } == 0)
    #expect(editor.draft == draft && editor.isDirty && !editor.isClosed)
    editor.requestClose(); await editor.resolveClose(.discard)
    #expect(try await f.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM notes") } == 0)
    preferences.stop(); try await f.writer.close()
}

@MainActor private final class FailingAppPreferences: AppPreferencesStore {
    var persisted = AppPreferences(theme: .light)
    func load() -> AppPreferences { persisted }
    func save(_ value: AppPreferences) throws { throw CollectionRepositoryError.permissionDenied }
}
@MainActor @Test func preferencesAppearanceFailureShowsPersistedValue() {
    let model = AppearanceModel(store: FailingAppPreferences())
    model.set(theme: .dark)
    #expect(model.value.theme == .light && model.error != nil)
    model.set(language: .en)
    #expect(model.value.language == .ru && model.error != nil)
}
