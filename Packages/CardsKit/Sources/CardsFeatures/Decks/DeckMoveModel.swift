import CardsCore
import Foundation
import Observation

@MainActor @Observable public final class DeckMoveModel: Identifiable {
    public let id = UUID()
    public let original: Deck
    public let hierarchy: DeckHierarchy
    public var parentID: DeckID?
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var hasConflict = false
    private let repository: any DeckRepository
    private var attempt: (parent: DeckID?, id: CommandID)?
    private var active = true
    public init(original: Deck, rows: [DeckQueryRow], repository: any DeckRepository) {
        self.original = original; self.hierarchy = DeckHierarchy(rows: rows)
        self.parentID = original.parentID; self.repository = repository
    }
    public var destinations: [DeckQueryRow] { hierarchy.rows.filter { hierarchy.canMove(original.id, to: $0.id) } }
    public var canSave: Bool {
        active && !isSaving && !hasConflict && parentID != original.parentID &&
        (parentID.map { hierarchy.canMove(original.id, to: $0) } ?? true)
    }
    public func save() async -> Deck? {
        guard canSave else { return nil }
        let parent = parentID
        if attempt == nil || attempt?.parent != parent { attempt = (parent, CommandID()) }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            let result = try await MoveDeck(repository: repository).execute(original, to: parent, commandID: attempt!.id)
            guard active else { return nil }
            active = false
            return result
        } catch {
            guard active else { return nil }
            switch error {
            case CollectionRepositoryError.revisionConflict:
                hasConflict = true
                errorMessage = "Колода изменена. Закройте диалог и откройте её заново."
            case CollectionRepositoryError.invalidHierarchy:
                errorMessage = "Нельзя переместить колоду в себя или своё поддерево. Выберите другое место."
            case CollectionRepositoryError.validation(.duplicateName):
                errorMessage = "В этом месте уже есть колода с таким названием."
            default:
                errorMessage = "Не удалось переместить колоду. Обновите список или повторите попытку."
            }
            return nil
        }
    }
    public func stop() { active = false }
}
