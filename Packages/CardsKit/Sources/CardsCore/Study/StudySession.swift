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
    public let audioMediaID: MediaID?
    public init(cardID: CardID, revision: Revision = .initial, question: String, answer: String, scheduleEpoch: Int64 = 0,
                pronunciation: String = "", example: String = "", audioMediaID: MediaID? = nil) {
        self.scheduleEpoch = scheduleEpoch
        self.cardID = cardID; self.revision = revision; self.question = question; self.answer = answer
        self.pronunciation = pronunciation; self.example = example; self.audioMediaID = audioMediaID
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

/// Read-only availability check for a presentation held by an open window.
public protocol StudyAvailabilityService: StudySessionService {
    func isAvailable(cardID: CardID) async throws -> Bool
}

public enum StudyCheckpointPhase: String, Codable, Sendable { case question, answer, paused, summary }

/// Contains identities and UI progress only; render content is always read afresh.
public struct StudyCheckpoint: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var cardID: CardID?
    public var phase: StudyCheckpointPhase
    public var priorToPause: StudyCheckpointPhase
    public var skipped: Set<CardID>
    public var lastSkipped: CardID?
    public var activeDurationMs: Int64
    public var endedEarly: Bool
    public init(cardID: CardID?, phase: StudyCheckpointPhase, priorToPause: StudyCheckpointPhase = .question,
                skipped: Set<CardID> = [], lastSkipped: CardID? = nil, activeDurationMs: Int64 = 0, endedEarly: Bool = false) {
        self.cardID = cardID; self.phase = phase; self.priorToPause = priorToPause
        self.skipped = skipped; self.lastSkipped = lastSkipped; self.activeDurationMs = activeDurationMs; self.endedEarly = endedEarly
    }
}

public struct StudyProgress: Equatable, Sendable {
    public let checkpoint: StudyCheckpoint?
    public let ratings: Int
    public let uniqueCards: Int
    /// Counts in Grade.rawValue order (Again, Hard, Good, Easy).
    public let grades: [Int]
    public let lastRatingID: CommandID?
    public let activeDurationMs: Int64
    public init(checkpoint: StudyCheckpoint?, ratings: Int, uniqueCards: Int, grades: [Int],
                lastRatingID: CommandID?, activeDurationMs: Int64) {
        self.checkpoint = checkpoint; self.ratings = ratings; self.uniqueCards = uniqueCards
        self.grades = grades; self.lastRatingID = lastRatingID; self.activeDurationMs = activeDurationMs
    }
}

public protocol StudyProgressService: StudySessionService {
    func progress() async throws -> StudyProgress
    func checkpoint(_ value: StudyCheckpoint) async throws
    /// early=true ends the session as abandoned while retaining all committed reviews.
    func finish(early: Bool) async throws
}
