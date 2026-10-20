import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class LibraryModel {
    public private(set) var rows: [LibraryRow] = []
    public private(set) var cardCount = 0
    public private(set) var noteCount = 0
    public private(set) var offset = 0
    public private(set) var requestID = UUID()
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    public var selection: CardID?
    public var search = "" {
        didSet { if search != oldValue { offset = 0; restart() } }
    }
    public let launcher: EditorLauncherModel
    public private(set) var inspectedNote: SavedBasicNote?
    public private(set) var inspectorError: String?
    private let workspace: EditorWorkspace
    private var observation: QueryObservation<LibrarySnapshot>?
    private var active = true
    private var inspectionID = UUID()

    public init(workspace: EditorWorkspace, clock: any CardsCore.Clock,
                audio: (any AudioPlayback)? = nil, preferences: AudioPreferences? = nil) {
        self.workspace = workspace
        launcher = EditorLauncherModel(workspace: workspace, clock: clock, audio: audio, preferences: preferences)
    }
    public var selectedRow: LibraryRow? { rows.first { $0.id == selection } }
    public var hasMore: Bool { offset + rows.count < cardCount }
    public func reload() { restart(clear: false) }
    public func page(_ delta: Int) {
        guard !isLoading, delta < 0 ? offset > 0 : hasMore else { return }
        offset = max(0, offset + (delta < 0 ? -100 : 100))
        restart()
    }
    private func restart(clear: Bool = true) {
        observation?.cancel()
        requestID = UUID()
        isLoading = true
        errorMessage = nil
        if clear {
            rows = []; selection = nil; inspectedNote = nil; inspectorError = nil
            cardCount = 0; noteCount = 0
        }
    }
    /// Owned by the View task; every query change cancels the previous subscription.
    public func observe() async {
        guard active else { return }
        let request = requestID
        let offset = offset
        isLoading = true; errorMessage = nil
        var installed: QueryObservation<LibrarySnapshot>?
        defer { installed?.cancel() }
        do {
            let query = try LibraryQuery(filter: CardQueryFilter(search: search), page: QueryPage(offset: offset))
            let source = try await workspace.queries.observeLibrary(query)
            installed = source
            guard active, !Task.isCancelled, request == requestID else { return }
            observation = source
            for try await snapshot in source {
                guard active, !Task.isCancelled, request == requestID,
                      snapshot.generation == workspace.generation else { return }
                if snapshot.rows.isEmpty && offset > 0 {
                    self.offset = max(0, ((max(1, snapshot.cardCount) - 1) / 100) * 100)
                    restart()
                    return
                }
                rows = snapshot.rows; cardCount = snapshot.cardCount; noteCount = snapshot.noteCount
                if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
                isLoading = false
            }
        } catch {
            guard active, !Task.isCancelled, request == requestID else { return }
            isLoading = false
            errorMessage = search.count > 512 ? "Поиск: не больше 512 символов. Сократите запрос."
                : "Не удалось загрузить карточки. Повторите попытку."
        }
    }
    public func inspect() async {
        let request = UUID()
        inspectionID = request
        inspectedNote = nil; inspectorError = nil
        guard active, let row = selectedRow else { return }
        do {
            let note = try await workspace.notes.note(id: row.noteID)
            guard active, !Task.isCancelled, inspectionID == request, selectedRow == row else { return }
            guard let note else {
                inspectorError = "Запись недоступна. Повторите попытку."
                return
            }
            guard note.note.revision == row.noteRevision else { return }
            inspectedNote = note
        } catch {
            guard active, !Task.isCancelled, inspectionID == request, selectedRow == row else { return }
            inspectorError = "Не удалось загрузить содержимое. Повторите попытку."
        }
    }
    public func stop() {
        active = false
        observation?.cancel()
        inspectionID = UUID()
        launcher.stop()
        rows = []; selection = nil; inspectedNote = nil
    }
}

extension LibraryRow {
    public var directionTitle: String {
        variantKey == BasicNoteType.variantKey ? "Лицевая → оборотная" : variantKey
    }
    public var statusTitle: String {
        if suspended { return "Приостановлена" }
        switch phase {
        case .new: return "Новая"
        case .learning: return "Изучение"
        case .review: return "На повторении"
        case .relearning: return "Переучивание"
        }
    }
}
