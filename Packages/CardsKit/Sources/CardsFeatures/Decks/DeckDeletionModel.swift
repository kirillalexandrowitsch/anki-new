import CardsCore
import Foundation
import Observation

@MainActor @Observable public final class DeckDeletionModel {
    public private(set) var isPresented = false
    public private(set) var isLoading = false
    public private(set) var isCommitting = false
    public private(set) var target: DeckDeletionTarget?
    public private(set) var errorMessage: String?
    private let service: any DeckDeletionService
    private var active = true
    private var request = UUID()
    private var deckID: DeckID?
    private var command: DeleteDeckCommand?

    public init(service: any DeckDeletionService) { self.service = service }
    public func prepare(deckID: DeckID) async {
        guard active, !isPresented else { return }
        self.deckID = deckID; isPresented = true
        await loadTarget()
    }
    public func loadTarget() async {
        guard active, isPresented, !isLoading, !isCommitting, let deckID else { return }
        let token = UUID(); request = token
        isLoading = true; target = nil; command = nil; errorMessage = nil
        do {
            let value = try await service.target(deckID: deckID)
            guard active, request == token, isPresented else { return }
            target = value; command = DeleteDeckCommand(target: value)
        } catch {
            guard active, request == token, isPresented else { return }
            errorMessage = "Колода недоступна. Обновите область удаления."
        }
        if request == token { isLoading = false }
    }
    public func cancel() {
        guard !isCommitting else { return }
        request = UUID(); isPresented = false; isLoading = false
        target = nil; command = nil; deckID = nil; errorMessage = nil
    }
    public func confirm() async {
        guard active, isPresented, !isLoading, !isCommitting, let command else { return }
        isCommitting = true; errorMessage = nil
        do {
            _ = try await service.delete(command)
            guard active else { return }
            isCommitting = false; cancel()
        } catch {
            guard active else { return }
            isCommitting = false
            errorMessage = "Не удалось удалить колоду. Повторите ту же команду или обновите область удаления, если данные изменились."
        }
    }
    public func stop() {
        active = false; request = UUID(); isPresented = false; target = nil; command = nil
    }
}
