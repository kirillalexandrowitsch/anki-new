import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class DeckEditorModel: Identifiable {
    public let id = UUID()
    public let original: Deck?
    public var input: DeckInput
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var nameError: String?
    public private(set) var hasConflict = false
    private let repository: any DeckRepository
    private let parentID: DeckID?
    private let deckID: DeckID
    private var attempt: (input: DeckInput, commandID: CommandID)?
    private var active = true

    public init(repository: any DeckRepository, original: Deck? = nil, parentID: DeckID? = nil) {
        self.parentID = parentID
        self.repository = repository
        self.original = original
        self.deckID = original?.id ?? DeckID()
        self.input = original.map(DeckInput.init) ?? DeckInput()
    }

    public var requiredNameError: String? {
        (try? EntityName(input.name)) == nil ? "Введите название колоды." : nil
    }
    public var canSave: Bool { active && !isSaving && !hasConflict && requiredNameError == nil }

    /// Cancel is only possible before commit starts. During a transaction the modal stays open.
    public func cancel() {
        guard !isSaving else { return }
        active = false
    }

    public func save() async -> Deck? {
        guard canSave else { return nil }
        let captured = input
        if attempt?.input != captured { attempt = (captured, CommandID()) }
        let commandID = attempt!.commandID
        isSaving = true
        nameError = nil
        errorMessage = nil
        defer { isSaving = false }
        do {
            let result: Deck
            if let original {
                result = try await UpdateDeck(repository: repository).execute(captured, original: original,
                                                                              commandID: commandID)
            } else {
                result = try await CreateDeck(repository: repository).execute(captured, id: deckID,
                                                                              commandID: commandID, parentID: parentID)
            }
            guard active else { return nil }
            active = false
            return result
        } catch {
            guard active else { return nil }
            switch error {
            case ValidationError.emptyName, CollectionRepositoryError.validation(.emptyName):
                nameError = "Введите название колоды."
            case ValidationError.duplicateName, CollectionRepositoryError.validation(.duplicateName):
                nameError = "Колода с таким названием уже существует. Выберите другое название."
            case CollectionRepositoryError.revisionConflict:
                hasConflict = true
                errorMessage = "Колода изменена в другом окне. Ваш черновик остаётся здесь. Скопируйте нужный текст, закройте диалог и откройте колоду заново."
            case CollectionRepositoryError.staleContext, CollectionAccessError.staleContext:
                hasConflict = true
                errorMessage = "Коллекция закрыта. Откройте её заново, чтобы продолжить."
            case CollectionRepositoryError.insufficientSpace:
                errorMessage = "Недостаточно места. Освободите место на диске и повторите сохранение."
            default:
                errorMessage = "Не удалось сохранить колоду. Черновик сохранён в диалоге. Повторите попытку."
            }
            return nil
        }
    }

    public func clearNameError() { nameError = nil }

    /// Closing the collection invalidates even a delayed response from a retired writer.
    public func stop() { active = false }
}
