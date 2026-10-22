import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class CardDeletionModel {
    public private(set) var isPresented = false
    public private(set) var isLoading = false
    public private(set) var isCommitting = false
    public private(set) var target: CardDeletionTarget?
    public private(set) var errorMessage: String?
    public private(set) var undoError: String?
    public private(set) var pending: [CardDeletionUndo] = []
    public private(set) var isUndoing = false
    private let service: any CardDeletionService
    private var active = true
    private var request = UUID()
    private var cardID: CardID?
    private var deleteCommand: DeleteCardCommand?
    private var undoCommands: [UUID: UndoCardDeletionCommand] = [:]

    public init(service: any CardDeletionService) { self.service = service }

    public func prepare(cardID: CardID) async {
        guard active, !isPresented, !isCommitting, !isUndoing else { return }
        self.cardID = cardID
        isPresented = true
        await loadTarget()
    }

    public func loadTarget() async {
        guard active, isPresented, !isLoading, !isCommitting, let cardID else { return }
        let token = UUID(); request = token
        target = nil; deleteCommand = nil; isLoading = true; errorMessage = nil
        do {
            let value = try await service.target(cardID: cardID)
            guard active, request == token, isPresented else { return }
            target = value; deleteCommand = DeleteCardCommand(target: value)
        } catch {
            guard active, request == token, isPresented else { return }
            errorMessage = "Карточка недоступна или изменилась. Загрузите её заново."
        }
        if request == token { isLoading = false }
    }

    public func cancel() {
        guard !isCommitting else { return }
        request = UUID(); isPresented = false; isLoading = false
        target = nil; deleteCommand = nil; cardID = nil; errorMessage = nil
    }

    public func confirm() async {
        guard active, isPresented, !isCommitting, !isLoading, let deleteCommand else { return }
        isCommitting = true; errorMessage = nil
        do {
            _ = try await service.delete(deleteCommand)
            guard active else { return }
            isCommitting = false; cancel()
            await refreshUndo()
        } catch {
            guard active else { return }
            isCommitting = false
            errorMessage = "Не удалось удалить карточку. Повторите попытку. Если карточка изменилась, загрузите её заново."
        }
    }

    public func refreshUndo() async {
        guard active else { return }
        do {
            let value = try await service.pendingUndo()
            guard active, !Task.isCancelled else { return }
            pending = value
        } catch {
            guard active, !Task.isCancelled else { return }
            pending = []
            undoError = "Не удалось проверить доступность отмены. Повторите попытку."
        }
    }

    /// View owns cancellation; the service, not this heartbeat, enforces the deadline at commit.
    public func watch() async {
        while active, !Task.isCancelled {
            await refreshUndo()
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }

    public func undo(batchID: UUID) async {
        guard active, !isUndoing, !isPresented, pending.contains(where: { $0.id == batchID }) else { return }
        let command = undoCommands[batchID] ?? UndoCardDeletionCommand(batchID: batchID)
        undoCommands[batchID] = command
        isUndoing = true; undoError = nil
        defer { isUndoing = false }
        do {
            _ = try await service.undo(command)
            guard active else { return }
            pending.removeAll { $0.id == batchID }
        } catch {
            guard active else { return }
            undoError = "Не удалось отменить удаление: 5 секунд истекли, карточка изменилась или хранилище недоступно."
        }
        await refreshUndo()
    }

    public func stop() {
        active = false; request = UUID(); isPresented = false
        target = nil; pending = []; deleteCommand = nil; undoCommands = [:]
    }
}
