import CardsCore
import Foundation
import Observation

/// Minimal editor entry points, using bounded queries. Full library tools belong to later tasks.
@MainActor @Observable
public final class EditorLauncherModel {
    public private(set) var rows: [LibraryRow] = []
    public private(set) var hasMore = false
    public private(set) var offset = 0
    public private(set) var errorMessage: String?
    public private(set) var isLoading = false
    public var editor: EditorModel?
    private let workspace: EditorWorkspace
    private let clock: any CardsCore.Clock
    private var active = true

    public init(workspace: EditorWorkspace, clock: any CardsCore.Clock) { self.workspace = workspace; self.clock = clock }
    public func load() async {
        guard active else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let source = try await workspace.queries.library(LibraryQuery(page: QueryPage(offset: offset)))
            guard active, !Task.isCancelled, source.generation == workspace.generation else { return }
            rows = source.rows; hasMore = source.hasMore
        } catch { if active { errorMessage = "Не удалось загрузить карточки. Повторите попытку." } }
    }
    public func page(_ delta: Int) async { offset = max(0, offset + delta * 100); await load() }
    public func open(noteID: NoteID? = nil) async {
        guard active, editor == nil, !isLoading else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            var decks: [Deck] = []
            var offset = 0
            while true {
                let page = try await workspace.queries.decks(DeckQuery(page: QueryPage(offset: offset)),
                    asOf: EpochMilliseconds(date: clock.now()))
                guard active, !Task.isCancelled, page.generation == workspace.generation else { return }
                decks += page.rows.map(\.deck)
                offset += page.rows.count
                if offset >= page.deckCount || page.rows.isEmpty { break }
            }
            let original: SavedBasicNote?
            if let noteID {
                guard let saved = try await workspace.notes.note(id: noteID) else {
                    throw CollectionRepositoryError.notFound(.note(noteID))
                }
                original = saved
            } else { original = nil }
            guard active, !Task.isCancelled else { return }
            editor = EditorModel(repository: workspace.notes, decks: decks, original: original)
        } catch { if active { errorMessage = "Не удалось открыть редактор. Повторите попытку." } }
    }
    public func stop() { active = false; editor?.stop(); editor = nil; rows = [] }
}
