import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class DecksModel {
    public private(set) var rows: [DeckQueryRow] = []
    public private(set) var deckCount = 0
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    public private(set) var pageOffset = 0
    public private(set) var refreshID = UUID()
    public var editor: DeckEditorModel?
    private let workspace: DeckWorkspace
    private let clock: any CardsCore.Clock
    private var observation: QueryObservation<DeckSnapshot>?
    private var active = true

    public init(workspace: DeckWorkspace, clock: any CardsCore.Clock) {
        self.workspace = workspace; self.clock = clock
    }

    public func create() {
        guard active else { return }
        editor = DeckEditorModel(repository: workspace.repository)
    }
    public func edit(_ deck: Deck) {
        guard active else { return }
        editor = DeckEditorModel(repository: workspace.repository, original: deck)
    }
    public func previousPage() { pageOffset = max(0, pageOffset - 100) }
    public func nextPage() { if pageOffset + rows.count < deckCount { pageOffset += 100 } }
    public func reload() { refreshID = UUID() }

    /// The View owns this task; disappearance/page change cancels its observation.
    public func observe() async {
        guard active else { return }
        let offset = pageOffset
        let request = refreshID
        isLoading = true
        errorMessage = nil
        var installed: QueryObservation<DeckSnapshot>?
        defer { installed?.cancel() }
        do {
            let query = try DeckQuery(page: QueryPage(offset: offset))
            let source = try await workspace.queries.observeDecks(query, asOf: EpochMilliseconds(date: clock.now()))
            installed = source
            guard active, !Task.isCancelled, offset == pageOffset, request == refreshID else { return }
            observation = source
            for try await snapshot in source {
                guard active, !Task.isCancelled, snapshot.generation == workspace.generation,
                      offset == pageOffset, request == refreshID else { return }
                rows = snapshot.rows
                deckCount = snapshot.deckCount
                isLoading = false
            }
        } catch {
            guard active, !Task.isCancelled, offset == pageOffset, request == refreshID else { return }
            isLoading = false
            errorMessage = "Не удалось загрузить колоды. Повторите попытку."
        }
    }

    public func stop() {
        active = false
        observation?.cancel()
        editor?.stop()
        editor = nil
        rows = []
    }
}
