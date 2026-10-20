import Foundation

/// Renderable immutable content. The service validates availability before returning it.
public struct StudyPresentation: Equatable, Codable, Sendable {
    public let cardID: CardID
    /// Expected schedule revision, not the Note content revision.
    public let revision: Revision
    public let scheduleEpoch: Int64
    public let question: String
    public let answer: String
    public let pronunciation: String
    public let example: String
    public init(cardID: CardID, revision: Revision = .initial, question: String, answer: String, scheduleEpoch: Int64 = 0,
                pronunciation: String = "", example: String = "") {
        self.scheduleEpoch = scheduleEpoch
        self.cardID = cardID; self.revision = revision; self.question = question; self.answer = answer
        self.pronunciation = pronunciation; self.example = example
    }
}

public enum StudyCompletion: Equatable, Sendable {
    case noCards, availableViewed, future(Date), endedEarly
}

public enum StudyNext: Equatable, Sendable {
    case question(StudyPresentation)
    case completed(StudyCompletion)
}

/// Immutable command retained on failure, including event time and command identity.
public struct StudyRatingCommand: Equatable, Codable, Sendable {
    public let id: CommandID
    public let cardID: CardID
    public let expectedRevision: Revision
    public let scheduleEpoch: Int64
    public let durationMs: Int64
    public let seed: UInt64
    public let grade: Grade
    public let occurredAt: Date
    public init(id: CommandID = CommandID(), cardID: CardID, expectedRevision: Revision,
                grade: Grade, occurredAt: Date, scheduleEpoch: Int64 = 0, durationMs: Int64 = 0, seed: UInt64 = 0) {
        self.scheduleEpoch = scheduleEpoch; self.durationMs = durationMs; self.seed = seed
        self.id = id; self.cardID = cardID; self.expectedRevision = expectedRevision
        self.grade = grade; self.occurredAt = occurredAt
    }
}

/// Generation-scoped adapter. Never report a storage failure as an empty queue.
public protocol StudySessionService: Sendable {
    /// Re-read eligibility; preferred is only a hint for undoing a skip, never a bypass.
    func next(skipping: Set<CardID>, preferred: CardID?) async throws -> StudyNext
    /// Check generation/revision and return only after durable, idempotent commit.
    func rate(_ command: StudyRatingCommand) async throws
}
