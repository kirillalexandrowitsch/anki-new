import CardsCore
import CardsFeatures
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

private struct DeckSetupFixture {
    let directory: TestDirectory
    let clock: TestClock
    let store: CollectionStore
    let context: CollectionContext
    let root: Deck
    let child: Deck
    let other: Deck
    let service: any DeckStudyService
    let preferences: any StudyPreferencesRepository
    let notes: any NoteRepository
    static func make() async throws -> Self {
        let directory = try TestDirectory(), clock = TestClock()
        let store = CollectionStore(root: directory.url, clock: clock)
        let context = try await store.open()
        let repository = try await store.decks(generation: context.generation)
        func deck(_ name: String, parent: DeckID? = nil) async throws -> Deck {
            try await CreateDeck(repository: repository).execute(DeckInput(name: name), id: DeckID(), commandID: CommandID(), parentID: parent)
        }
        let root = try await deck("Root"), child = try await deck("Child", parent: root.id), other = try await deck("Other")
        let notes = try await store.notes(generation: context.generation)
        for (id, prefix) in [(root.id, "Root"), (child.id, "Child"), (other.id, "Other")] {
            for index in 0..<3 {
                _ = try await notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(), expectedRevision: nil,
                    initialDeckID: id, content: BasicNoteContent(front: "\(prefix) \(index)", back: "Synthetic")))
            }
        }
        return try await Self(directory: directory, clock: clock, store: store, context: context, root: root, child: child, other: other,
            service: store.deckStudy(generation: context.generation), preferences: store.studyPreferences(generation: context.generation), notes: notes)
    }
    func request(scope: DeckID? = nil, new: Int = 2, review: Int = 5, session: Int? = nil) throws -> DeckStudyRequest {
        try DeckStudyRequest(rootID: root.id, scopeID: scope ?? root.id, new: new, review: review, sessionLimit: session)
    }
}

@Test @MainActor func deckSetupDraftCancelInvalidInputChildScopeAndNoteRouteKeepPreferences() async throws {
    let f = try await DeckSetupFixture.make()
    let saved = try await f.preferences.save(SaveStudyPreferences(expectedRevision: .initial, value: StudyPreferences(newLimit: 7, reviewLimit: 11)))
    let workspace = try await f.store.deckWorkspace(generation: f.context.generation)
    let rows = try await workspace.queries.decks(DeckQuery(hierarchy: true), asOf: EpochMilliseconds(0)).rows
    let decks = DecksModel(workspace: workspace, clock: TestClock(), studyService: f.service,
                           makeStudy: { StudySessionModel(service: $0, clock: TestClock()) })
    let setup = DeckStudySetupModel(root: f.root, rows: rows, service: f.service,
                                    makeStudy: { StudySessionModel(service: $0, clock: TestClock()) })
    await setup.load(); await setup.refresh()
    #expect(setup.newText == "7" && setup.reviewText == "11")
    #expect(Set(setup.scopes.map(\.id)) == [f.root.id, f.child.id])
    #expect(setup.preview?.new == 6 && setup.canStart)
    for invalid in ["", "-1", "1.5", "10000", " 2", "١", "999999999999999999999999"] {
        setup.newText = invalid; await setup.refresh()
        #expect(!setup.canStart && setup.unavailableReason != nil)
    }
    setup.newText = "2"; setup.reviewText = "1"; setup.sessionText = "0"
    await setup.refresh(); #expect(!setup.canStart)
    setup.sessionText = "1"; setup.scopeID = f.child.id
    await setup.refresh(); #expect(setup.preview?.new == 1 && setup.canStart)
    setup.stop(); await setup.start(); #expect(setup.study == nil)
    #expect(try await f.preferences.load() == saved)
    decks.setupStudy(f.root); #expect(decks.studySetup != nil); decks.closeStudySetup(); #expect(decks.studySetup == nil)
    let editor = EditorLauncherModel(workspace: try await f.store.editorWorkspace(generation: f.context.generation), clock: TestClock())
    await editor.open(initialDeckID: f.child.id)
    let draft = try #require(editor.editor)
    #expect(draft.draft.deckID == f.child.id && !draft.isDirty)
    draft.requestClose(); #expect(draft.isClosed && !draft.showsUnsavedWarning)
    editor.stop(); decks.stop()
    try await f.store.close(generation: f.context.generation)
}

@Test func deckSetupStartPersistsOnlySelectedSessionAndHonorsQuotaAfterReopen() async throws {
    let f = try await DeckSetupFixture.make()
    let saved = try await f.preferences.load()
    let request = try f.request(scope: f.child.id, new: 2, review: 4, session: 1)
    #expect(try await f.service.preview(request).new == 1)
    let service = try await f.service.start(request)
    let id = service.sessionID
    let first: StudyPresentation
    if case let .question(value) = try await service.next(skipping: [], preferred: nil) { first = value }
    else { Issue.record("Expected child question"); return }
    #expect(first.question.hasPrefix("Child"))
    #expect(try await f.service.preview(request).hasActiveSession)
    await #expect(throws: DeckStudyError.activeSession) { try await f.service.start(request) }
    try await service.rate(StudyRatingCommand(cardID: first.cardID, expectedRevision: first.revision, grade: .easy,
        occurredAt: TestClock().now(), scheduleEpoch: first.scheduleEpoch))
    if case .completed = try await service.next(skipping: [], preferred: nil) {} else { Issue.record("Session limit ignored") }
    #expect(try await f.preferences.load() == saved)
    try await f.store.close(generation: f.context.generation)
    let reopened = try await f.store.open()
    let resumed = try await f.store.studySession(generation: reopened.generation)
    #expect(resumed.sessionID == id)
    if case .completed = try await resumed.next(skipping: [], preferred: nil) {} else { Issue.record("Reopen lost scoped policy") }
    try await (resumed as! any StudyProgressService).finish(early: false)
    let next = try await f.store.deckStudy(generation: reopened.generation)
    // One new consumed today; new=1 has no quota even in another subtree.
    let exhausted = try DeckStudyRequest(rootID: f.root.id, scopeID: f.root.id, new: 1, review: 0, sessionLimit: nil)
    #expect(try await next.preview(exhausted).reasons.contains(.dailyLimit))
    #expect(try await f.store.studyPreferences(generation: reopened.generation).load() == saved)
    let normal = try await f.store.studySession(generation: reopened.generation)
    if case .question = try await normal.next(skipping: [], preferred: nil) {} else { Issue.record("Normal session inherited temporary quota") }
    await #expect(throws: CollectionRepositoryError.staleContext) { try await f.service.preview(request) }
    try await f.store.close(generation: reopened.generation)
}

@Test func deckSetupRejectsEmptyStaleScopeAndChangedQueueBeforeCreatingSession() async throws {
    let f = try await DeckSetupFixture.make()
    let repository = try await f.store.decks(generation: f.context.generation)
    let empty = try await CreateDeck(repository: repository).execute(DeckInput(name: "Empty"), id: DeckID(), commandID: CommandID())
    let request = try DeckStudyRequest(rootID: empty.id, scopeID: empty.id, new: 20, review: 20, sessionLimit: nil)
    let preview = try await f.service.preview(request)
    #expect(!preview.canStart && preview.reasons.contains(.noCardsInScope))
    await #expect(throws: DeckStudyError.emptyQueue) { try await f.service.start(request) }
    let invalid = try f.request(scope: f.other.id)
    await #expect(throws: CollectionRepositoryError.invalidHierarchy) { try await f.service.preview(invalid) }
    await #expect(throws: CollectionRepositoryError.invalidHierarchy) { try await f.service.start(invalid) }
    let child = try f.request(scope: f.child.id)
    #expect(try await f.service.preview(child).canStart)
    _ = try await MoveDeck(repository: repository).execute(f.child, to: f.other.id, commandID: CommandID())
    await #expect(throws: CollectionRepositoryError.invalidHierarchy) { try await f.service.start(child) }
    let zero = try f.request(new: 0, review: 0)
    await #expect(throws: DeckStudyError.emptyQueue) { try await f.service.start(zero) }
    // No failed launch left an active session behind.
    #expect(try await f.service.preview(f.request()).hasActiveSession == false)
    try await f.store.close(generation: f.context.generation)
}

@Test func deckSetupReviewQuotaAndLearningBypassUseRealSchedules() async throws {
    let f = try await DeckSetupFixture.make()
    let initial = try await f.service.start(f.request(scope: f.child.id, new: 3, review: 0))
    for _ in 0..<3 {
        guard case let .question(card) = try await initial.next(skipping: [], preferred: nil) else {
            Issue.record("Expected three new child cards"); return
        }
        try await initial.rate(StudyRatingCommand(cardID: card.cardID, expectedRevision: card.revision, grade: .easy,
            occurredAt: f.clock.now(), scheduleEpoch: card.scheduleEpoch))
    }
    try await (initial as! any StudyProgressService).finish(early: false)
    f.clock.advance(by: 100 * 86_400)
    let request = try f.request(scope: f.child.id, new: 0, review: 1)
    let preview = try await f.service.preview(request)
    #expect(preview.new == 0 && preview.review == 1 && preview.learning == 0 && preview.canStart)
    let review = try await f.service.start(request)
    guard case let .question(card) = try await review.next(skipping: [], preferred: nil) else {
        Issue.record("Expected due review"); return
    }
    try await review.rate(StudyRatingCommand(cardID: card.cardID, expectedRevision: card.revision, grade: .again,
        occurredAt: f.clock.now(), scheduleEpoch: card.scheduleEpoch))
    try await (review as! any StudyProgressService).finish(early: true)
    let library = try await f.store.queries(generation: f.context.generation).library(LibraryQuery())
    let due = try #require(library.rows.first { $0.id == card.cardID }?.dueAt)
    f.clock.set(Date(timeIntervalSince1970: Double(due.rawValue) / 1000))
    let zero = try f.request(scope: f.child.id, new: 0, review: 0, session: 0)
    let learning = try await f.service.preview(zero)
    #expect(learning.new == 0 && learning.review == 0 && learning.learning == 1 && learning.canStart)
    let next = try await f.service.start(zero)
    guard case let .question(relearning) = try await next.next(skipping: [], preferred: nil) else {
        Issue.record("Learning must bypass quotas"); return
    }
    #expect(relearning.cardID == card.cardID)
    #expect(try await f.preferences.load() == StudyPreferencesSnapshot())
    try await f.store.close(generation: f.context.generation)
}
