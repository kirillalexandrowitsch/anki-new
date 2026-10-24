import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class DecksModel {
    public private(set) var rows: [DeckQueryRow] = []
    public private(set) var hierarchy = DeckHierarchy(rows: [])
    public private(set) var deckCount = 0
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    public private(set) var actionError: String?
    public private(set) var isMutating = false
    public private(set) var refreshID = UUID()
    public private(set) var browser: DeckBrowserPreferences
    public var search = ""
    public var favoritesOnly = false
    public var editor: DeckEditorModel?
    private var requestedDeck: DeckID?
    public func showDeck(_ id: DeckID) { resetFilters(); requestedDeck = id; reload() }
    public var inspectedID: DeckID?
    public var studySetup: DeckStudySetupModel?
    public let deletion: DeckDeletionModel?
    private let studyService: (any DeckStudyService)?
    private let makeStudy: (@MainActor (any StudyReviewSessionService) -> StudySessionModel)?
    public var canSetupStudy: Bool { studyService != nil && makeStudy != nil }
    public var inspectedRow: DeckQueryRow? { rows.first { $0.id == inspectedID } }
    public func setupStudy(_ deck: Deck) {
        guard active, !isMutating, let studyService, let makeStudy else { return }
        studySetup = DeckStudySetupModel(root: deck, rows: rows, service: studyService, makeStudy: makeStudy)
    }
    public func closeStudySetup() { studySetup?.stop(); studySetup = nil }
    public var moveEditor: DeckMoveModel?
    public private(set) var canUndoMove = false
    private var undoMove: (deck: Deck, parent: DeckID?, commandID: CommandID)?
    private var favoriteAttempt: (deck: Deck, commandID: CommandID)?
    private let workspace: DeckWorkspace
    private let clock: any CardsCore.Clock
    private let preferences: (any DeckBrowserPreferencesStore)?
    private var observation: QueryObservation<DeckSnapshot>?
    private var active = true

    public init(workspace: DeckWorkspace, clock: any CardsCore.Clock,
                preferences: (any DeckBrowserPreferencesStore)? = nil,
                studyService: (any DeckStudyService)? = nil,
                makeStudy: (@MainActor (any StudyReviewSessionService) -> StudySessionModel)? = nil) {
        deletion = workspace.deletions.map { DeckDeletionModel(service: $0) }
        self.workspace = workspace; self.clock = clock; self.preferences = preferences
        self.studyService = studyService; self.makeStudy = makeStudy
        self.browser = preferences?.loadDeckBrowser() ?? .init()
    }
    public var hasFilter: Bool { favoritesOnly || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var matchingRows: [DeckQueryRow] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { (!favoritesOnly || $0.deck.isFavorite) &&
            (text.isEmpty || $0.deck.name.displayValue.localizedStandardContains(text)) }
    }
    public var visibleRows: [DeckQueryRow] {
        browser.layout == .grid || hasFilter ? matchingRows : hierarchy.visible(expanded: browser.expanded)
    }
    public func resetFilters() { search = ""; favoritesOnly = false }
    public func setLayout(_ value: DeckBrowserLayout) {
        var next = browser; next.layout = value; saveBrowser(next)
    }
    public func toggleExpanded(_ id: DeckID) {
        var next = browser
        if !next.expanded.insert(id).inserted { next.expanded.remove(id) }
        saveBrowser(next)
    }
    private func saveBrowser(_ value: DeckBrowserPreferences) {
        guard active else { return }
        do { try preferences?.saveDeckBrowser(value); browser = value; actionError = nil }
        catch { actionError = "Не удалось сохранить вид колод. Повторите попытку." }
    }
    public func create(parentID: DeckID? = nil) {
        guard active else { return }
        editor = DeckEditorModel(repository: workspace.repository, parentID: parentID)
    }
    public func edit(_ deck: Deck) {
        guard active else { return }
        editor = DeckEditorModel(repository: workspace.repository, original: deck)
    }
    public func move(_ deck: Deck) {
        guard active, !isMutating else { return }
        moveEditor = DeckMoveModel(original: deck, rows: rows, repository: workspace.repository)
    }
    public func completeMove(_ result: Deck, from parent: DeckID?) {
        guard active else { return }
        undoMove = (result, parent, CommandID()); canUndoMove = true
        moveEditor = nil; actionError = nil
    }
    public func undoLastMove() async {
        guard active, !isMutating, let undoMove else { return }
        isMutating = true; actionError = nil
        defer { isMutating = false }
        do {
            _ = try await MoveDeck(repository: workspace.repository).execute(undoMove.deck, to: undoMove.parent,
                                                                            commandID: undoMove.commandID)
            guard active else { return }
            self.undoMove = nil; canUndoMove = false
        } catch {
            guard active else { return }
            actionError = "Не удалось отменить перенос: колода или её расположение могли измениться. Обновите список."
        }
    }
    public func toggleFavorite(_ deck: Deck) async {
        guard active, !isMutating else { return }
        if favoriteAttempt?.deck != deck { favoriteAttempt = (deck, CommandID()) }
        let commandID = favoriteAttempt!.commandID
        isMutating = true; actionError = nil
        defer { isMutating = false }
        do {
            _ = try await SetDeckFavorite(repository: workspace.repository).execute(deck, favorite: !deck.isFavorite,
                                                                                   commandID: commandID)
            guard active else { return }
            favoriteAttempt = nil
        } catch {
            guard active else { return }
            actionError = "Не удалось изменить избранное. Обновите список или повторите попытку."
        }
    }
    public func reload() { refreshID = UUID() }

    /// Complete forest in one read snapshot; View lifetime owns and cancels observation.
    public func observe() async {
        guard active else { return }
        let request = refreshID
        isLoading = true; errorMessage = nil
        var installed: QueryObservation<DeckSnapshot>?
        defer { installed?.cancel() }
        do {
            let query = try DeckQuery(hierarchy: true)
            let source = try await workspace.queries.observeDecks(query, asOf: EpochMilliseconds(date: clock.now()))
            installed = source
            guard active, !Task.isCancelled, request == refreshID else { return }
            observation = source
            for try await snapshot in source {
                guard active, !Task.isCancelled, snapshot.generation == workspace.generation,
                      request == refreshID else { return }
                if let inspectedID, !snapshot.rows.contains(where: { $0.id == inspectedID }) { self.inspectedID = nil }
                if let undoMove, !snapshot.rows.contains(where: { $0.id == undoMove.deck.id }) {
                    self.undoMove = nil; canUndoMove = false
                }
                if let requestedDeck {
                    inspectedID = snapshot.rows.first { $0.id == requestedDeck }?.id
                    self.requestedDeck = nil
                }
                rows = snapshot.rows; hierarchy = DeckHierarchy(rows: snapshot.rows); deckCount = snapshot.deckCount; isLoading = false
            }
        } catch {
            guard active, !Task.isCancelled, request == refreshID else { return }
            isLoading = false
            errorMessage = "Не удалось загрузить колоды. Повторите попытку."
        }
    }
    public func stop() {
        active = false; deletion?.stop(); closeStudySetup(); inspectedID = nil; observation?.cancel(); editor?.stop(); moveEditor?.stop()
        editor = nil; moveEditor = nil; rows = []; hierarchy = DeckHierarchy(rows: []); undoMove = nil; canUndoMove = false
    }
}
