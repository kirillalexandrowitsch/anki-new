import CardsCore
import Foundation
import Observation

/// Loads editor dependencies separately from the observed library query.
@MainActor @Observable
public final class EditorLauncherModel {
    public private(set) var errorMessage: String?
    public private(set) var isLoading = false
    public var editor: EditorModel?
    private let audioService: (any AudioPlayback)?
    private let preferences: AudioPreferences?
    private let workspace: EditorWorkspace
    private let clock: any CardsCore.Clock
    private var active = true

    public init(workspace: EditorWorkspace, clock: any CardsCore.Clock,
                audio: (any AudioPlayback)? = nil, preferences: AudioPreferences? = nil) {
        self.workspace = workspace; self.clock = clock; self.audioService = audio; self.preferences = preferences
    }
    public func open(noteID: NoteID? = nil, initialDeckID: DeckID? = nil) async {
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
            let audio: AudioPreviewModel?
            if let audioService, let preferences {
                audio = AudioPreviewModel(service: audioService, preferences: preferences, generation: workspace.generation)
            } else { audio = nil }
            if let initialDeckID, !decks.contains(where: { $0.id == initialDeckID }) {
                throw CollectionRepositoryError.notFound(.deck(initialDeckID))
            }
            let model = EditorModel(repository: workspace.notes, decks: decks, original: original, initialDeckID: initialDeckID, audio: audio)
            editor = model
        } catch { if active { errorMessage = "Не удалось открыть редактор. Повторите попытку." } }
    }
    public func stop() { active = false; editor?.stop(); editor = nil }
}
