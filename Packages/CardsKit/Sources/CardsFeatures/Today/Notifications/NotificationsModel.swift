import CardsCore
import Foundation
import Observation

@MainActor @Observable public final class NotificationsModel {
    public var isPresented = false
    public private(set) var messages: [LocalNotificationMessage] = []
    public private(set) var loaded = false
    public private(set) var saving = false
    public private(set) var error: String?
    public private(set) var reloadID = UUID()
    private let repository: any LocalNotificationRepository
    private var observation: QueryObservation<[LocalNotificationMessage]>?
    private var active = true

    public init(repository: any LocalNotificationRepository) { self.repository = repository }
    public var unreadCount: Int { messages.filter { $0.readAt == nil }.count }
    public func reload() {
        observation?.cancel(); loaded = false; error = nil; reloadID = UUID()
    }
    public func observe() async {
        guard active else { return }
        let request = reloadID
        var installed: QueryObservation<[LocalNotificationMessage]>?
        defer { installed?.cancel() }
        do {
            let source = try await repository.observe(); installed = source
            guard active, !Task.isCancelled, request == reloadID else { return }
            observation = source
            for try await value in source {
                guard active, !Task.isCancelled, request == reloadID else { return }
                messages = value; loaded = true
            }
        } catch {
            guard active, !Task.isCancelled, request == reloadID else { return }
            loaded = true; self.error = "Не удалось загрузить уведомления. Повторите попытку."
        }
    }
    @discardableResult public func markRead(ids: [UUID]) async -> Bool {
        guard active, !saving else { return false }
        saving = true; error = nil
        defer { saving = false }
        do {
            try await repository.markRead(ids: ids)
            guard active, !Task.isCancelled else { return false }
            return true
        } catch {
            guard active, !Task.isCancelled else { return false }
            self.error = "Не удалось отметить сообщения прочитанными. Повторите действие."
            return false
        }
    }
    public func stop() {
        active = false; isPresented = false; observation?.cancel(); messages = []; reloadID = UUID()
    }
}

extension LocalNotificationEvent {
    var title: String {
        switch self {
        case .backupSucceeded: "Резервное копирование завершено"
        case .backupFailed: "Ошибка резервного копирования"
        case .reminderScheduled: "Напоминание запланировано"
        }
    }
    var detail: String {
        switch self {
        case .backupSucceeded: "Проверенная копия коллекции сохранена на этом устройстве."
        case .backupFailed: "Резервное копирование не завершено. Проверьте доступ к папке и повторите с новым именем файла."
        case .reminderScheduled: "Расписание сохранено. Системный баннер может быть отложен или подавлен настройками macOS."
        }
    }
    var symbol: String {
        switch self {
        case .backupSucceeded: "checkmark.circle.fill"
        case .backupFailed: "exclamationmark.triangle.fill"
        case .reminderScheduled: "bell.badge"
        }
    }
}
