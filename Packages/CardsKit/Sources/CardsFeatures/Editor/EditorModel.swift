import CardsCore
import Foundation
import Observation

public enum EditorState: Equatable { case empty, valid, invalid, saving, conflict, failed, closed }
public enum EditorCloseChoice { case save, discard, cancel }

@MainActor @Observable
public final class EditorModel: Identifiable {
    public let id = UUID()
    public var draft: EditorDraft
    public let decks: [Deck]
    public private(set) var original: SavedBasicNote?
    public private(set) var latest: SavedBasicNote?
    public private(set) var errorMessage: String?
    public private(set) var isSaving = false
    public private(set) var hasConflict = false
    public private(set) var isClosed = false
    public var showsUnsavedWarning = false
    private let repository: any NoteRepository
    private var noteID: NoteID
    private var baseline: EditorDraft
    private var attempt: (draft: EditorDraft, commandID: CommandID)?

    public init(repository: any NoteRepository, decks: [Deck], original: SavedBasicNote? = nil) {
        self.repository = repository; self.decks = decks; self.original = original
        noteID = original?.note.id ?? NoteID()
        let initial = original.map(EditorDraft.init) ?? EditorDraft(deckID: decks.first?.id)
        baseline = initial; draft = initial
    }
    public var isDirty: Bool { draft != baseline }
    public var canSave: Bool { !isClosed && !isSaving && !hasConflict && draft.isValid }
    public var state: EditorState {
        if isClosed { return .closed }
        if isSaving { return .saving }
        if hasConflict { return .conflict }
        if errorMessage != nil { return .failed }
        if draft == EditorDraft(deckID: draft.deckID) { return .empty }
        return draft.isValid ? .valid : .invalid
    }

    /// All exit paths (button, Escape, Command-W, window close) use this gate.
    public func requestClose() {
        guard !isSaving, !isClosed else { return }
        if isDirty { showsUnsavedWarning = true }
        else { isClosed = true }
    }
    public func resolveClose(_ choice: EditorCloseChoice) async {
        guard !isSaving, !isClosed else { return }
        showsUnsavedWarning = false
        switch choice {
        case .cancel: break
        case .discard: isClosed = true
        case .save: _ = await save()
        }
    }

    @discardableResult public func save() async -> SavedBasicNote? {
        guard canSave, let deckID = draft.deckID else { return nil }
        let captured = draft
        if attempt?.draft != captured { attempt = (captured, CommandID()) }
        let command = SaveNoteCommand(commandID: attempt!.commandID, noteID: noteID,
            expectedRevision: original?.note.revision, initialDeckID: deckID,
            content: captured.content, tags: captured.tags)
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            let saved = try await SaveNote(repository: repository).execute(command)
            guard !isClosed else { return nil }
            original = saved; baseline = captured; isClosed = true
            return saved
        } catch {
            guard !isClosed else { return nil }
            switch error {
            case CollectionRepositoryError.revisionConflict:
                hasConflict = true
                latest = try? await repository.note(id: noteID)
                guard !isClosed else { return nil }
                errorMessage = "Карточка изменена в другом окне. Сравните версии и сохраните свой текст отдельной карточкой."
            case CollectionRepositoryError.staleContext, CollectionAccessError.staleContext:
                hasConflict = true
                errorMessage = "Коллекция закрыта. Скопируйте свой текст и откройте коллекцию заново."
            case CollectionRepositoryError.insufficientSpace:
                errorMessage = "Недостаточно места на диске. Черновик остаётся здесь. Освободите место и повторите сохранение."
            default:
                errorMessage = "Не удалось сохранить карточку. Черновик остаётся здесь. Проверьте доступ к диску и повторите попытку."
            }
            return nil
        }
    }

    /// Explicit fork, never a silent overwrite of the winner's revision.
    public func prepareSeparateCopy() {
        guard hasConflict, latest != nil, !isSaving, !isClosed else { return }
        original = nil; noteID = NoteID(); attempt = nil
        baseline = EditorDraft(deckID: draft.deckID)
        hasConflict = false; latest = nil; errorMessage = nil
    }
    public func stop() { isClosed = true; showsUnsavedWarning = false }
}
