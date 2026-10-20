import Foundation

public struct RateCardCommand: Equatable, Codable, Sendable {
    public let sessionID: SessionID
    public let rating: StudyRatingCommand
    public init(sessionID: SessionID, rating: StudyRatingCommand) {
        self.sessionID = sessionID; self.rating = rating
    }
}

public struct UndoRatingCommand: Equatable, Codable, Sendable {
    public let id: CommandID
    public let ratingID: CommandID
    public let sessionID: SessionID
    public let occurredAt: Date
    public init(id: CommandID = CommandID(), ratingID: CommandID, sessionID: SessionID, occurredAt: Date) {
        self.id = id; self.ratingID = ratingID; self.sessionID = sessionID; self.occurredAt = occurredAt
    }
}

public struct ReviewReceipt: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let command: RateCardCommand
    public let scheduling: SchedulingResult
    public let queueEvent: StudyQueueEvent
    public let itemID: String
    public let sessionRevision: Revision
    public let cardRevision: Revision
    public let noteRevision: Revision
    public init(command: RateCardCommand, scheduling: SchedulingResult, queueEvent: StudyQueueEvent,
                itemID: String, sessionRevision: Revision, cardRevision: Revision, noteRevision: Revision) {
        schemaVersion = 1; self.command = command; self.scheduling = scheduling; self.queueEvent = queueEvent
        self.itemID = itemID; self.sessionRevision = sessionRevision
        self.cardRevision = cardRevision; self.noteRevision = noteRevision
    }
}

public struct ReviewUndoResult: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let command: UndoRatingCommand
    public let restored: CardScheduleSnapshot
    public let presentation: StudyPresentation
    public init(command: UndoRatingCommand, restored: CardScheduleSnapshot, presentation: StudyPresentation) {
        schemaVersion = 1; self.command = command; self.restored = restored; self.presentation = presentation
    }
}

public struct EffectiveReviewStatistics: Equatable, Sendable {
    public let ratings: Int
    public let uniqueCards: Int
    public let durationMs: Int64
    public init(ratings: Int, uniqueCards: Int, durationMs: Int64) {
        self.ratings = ratings; self.uniqueCards = uniqueCards; self.durationMs = durationMs
    }
}

public protocol ReviewRepository: Sendable {
    func rateCard(_ command: RateCardCommand) async throws -> ReviewReceipt
    func undoRating(_ command: UndoRatingCommand) async throws -> ReviewUndoResult
    func effectiveStatistics() async throws -> EffectiveReviewStatistics
}

public struct RateCard: Sendable {
    private let repository: any ReviewRepository
    public init(repository: any ReviewRepository) { self.repository = repository }
    public func execute(_ command: RateCardCommand) async throws -> ReviewReceipt {
        try await repository.rateCard(command)
    }
}

public struct UndoRating: Sendable {
    private let repository: any ReviewRepository
    public init(repository: any ReviewRepository) { self.repository = repository }
    public func execute(_ command: UndoRatingCommand) async throws -> ReviewUndoResult {
        try await repository.undoRating(command)
    }
}

public protocol StudyReviewSessionService: StudySessionService {
    var sessionID: SessionID { get }
    func undoRating(_ command: UndoRatingCommand) async throws -> ReviewUndoResult
}

public protocol StudyWorkspaceAccess: CollectionAccess {
    func studySession(generation: UUID) async throws -> any StudyReviewSessionService
}
