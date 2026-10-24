import Foundation

/// Application history. A scheduled reminder never certifies OS banner delivery.
public enum LocalNotificationEvent: Equatable, Codable, Sendable {
    case backupSucceeded
    case backupFailed
    case reminderScheduled(nextFireAt: Date)

    public var kind: String {
        switch self {
        case .backupSucceeded: "backupSucceeded"
        case .backupFailed: "backupFailed"
        case .reminderScheduled: "reminderScheduled"
        }
    }
}

public struct LocalNotificationMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let event: LocalNotificationEvent
    public let createdAt: Date
    public let readAt: Date?
    public init(id: UUID, event: LocalNotificationEvent, createdAt: Date, readAt: Date?) {
        self.id = id; self.event = event; self.createdAt = createdAt; self.readAt = readAt
    }
}

public protocol LocalNotificationRepository: Sendable {
    /// Most recent first; the collection retains at most historyLimit messages.
    func observe() async throws -> QueryObservation<[LocalNotificationMessage]>
    func messages() async throws -> [LocalNotificationMessage]
    func record(id: UUID, event: LocalNotificationEvent) async throws
    /// Capture IDs from the presented snapshot so concurrent arrivals remain unread.
    func markRead(ids: [UUID]) async throws
}

public enum LocalNotificationPolicy {
    public static let historyLimit = 100
}

public protocol LocalNotificationAccess: CollectionAccess {
    func notifications(generation: UUID) async throws -> any LocalNotificationRepository
}
