import Foundation

/// Pure calculation port. Only the review transaction may persist a result.
public protocol Scheduler: Sendable {
    func preview(_ input: SchedulingInput) throws -> RatingOptions
    func apply(_ input: SchedulingInput, grade: Grade) throws -> SchedulingResult
}

public enum SchedulingError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidParameters
    case invalidSnapshot
    case invalidTime
    case counterOverflow
    case calculationFailed
}

/// Raw persisted values are validated by the adapter before entering the algorithm.
public struct LearningPolicy: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let enableFuzz: Bool
    public let enableShortTerm: Bool
    public let learningSteps: [String]
    public let relearningSteps: [String]

    public init(schemaVersion: Int = 1, enableFuzz: Bool = false, enableShortTerm: Bool = true,
                learningSteps: [String] = ["1m", "10m"], relearningSteps: [String] = ["10m"]) {
        self.schemaVersion = schemaVersion
        self.enableFuzz = enableFuzz
        self.enableShortTerm = enableShortTerm
        self.learningSteps = learningSteps
        self.relearningSteps = relearningSteps
    }
}

public struct SchedulerParameterSet: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let id: SchedulerParameterSetID
    public let algorithmVersion: String
    public let weights: [Double]
    public let desiredRetention: Double
    public let maximumIntervalDays: Int
    public let learningPolicy: LearningPolicy

    public init(schemaVersion: Int = 1, id: SchedulerParameterSetID, algorithmVersion: String = "6",
                weights: [Double], desiredRetention: Double = 0.9, maximumIntervalDays: Int = 36_500,
                learningPolicy: LearningPolicy = LearningPolicy()) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.algorithmVersion = algorithmVersion
        self.weights = weights
        self.desiredRetention = desiredRetention
        self.maximumIntervalDays = maximumIntervalDays
        self.learningPolicy = learningPolicy
    }
}

/// Complete scheduling state, independent of Card content and availability.
/// Unknown versions are preserved on decode and rejected by Scheduler, never defaulted.
public struct CardScheduleSnapshot: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let cardID: CardID
    public let algorithmID: String
    public let algorithmVersion: String
    public let parameterSetID: SchedulerParameterSetID
    public let phase: SchedulePhase
    public let stability: Double?
    public let difficulty: Double?
    public let dueAt: Date?
    public let lastReviewAt: Date?
    public let repetitions: Int
    public let lapses: Int
    public let learningStep: Int?
    public let scheduleEpoch: Int64
    public let revision: Revision

    public init(schemaVersion: Int = 1, cardID: CardID, algorithmID: String = "fsrs",
                algorithmVersion: String = "6", parameterSetID: SchedulerParameterSetID,
                phase: SchedulePhase = .new, stability: Double? = nil, difficulty: Double? = nil,
                dueAt: Date? = nil, lastReviewAt: Date? = nil, repetitions: Int = 0,
                lapses: Int = 0, learningStep: Int? = nil, scheduleEpoch: Int64 = 0,
                revision: Revision = .initial) {
        self.schemaVersion = schemaVersion
        self.cardID = cardID
        self.algorithmID = algorithmID
        self.algorithmVersion = algorithmVersion
        self.parameterSetID = parameterSetID
        self.phase = phase
        self.stability = stability
        self.difficulty = difficulty
        self.dueAt = dueAt
        self.lastReviewAt = lastReviewAt
        self.repetitions = repetitions
        self.lapses = lapses
        self.learningStep = learningStep
        self.scheduleEpoch = scheduleEpoch
        self.revision = revision
    }
}

public struct SchedulingInput: Equatable, Sendable {
    public let schedule: CardScheduleSnapshot
    public let nowUTC: Date
    public let parameters: SchedulerParameterSet
    public let seed: UInt64

    public init(schedule: CardScheduleSnapshot, nowUTC: Date, parameters: SchedulerParameterSet, seed: UInt64) {
        self.schedule = schedule
        self.nowUTC = nowUTC
        self.parameters = parameters
        self.seed = seed
    }
}

public struct SchedulingMetadata: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let adapterVersion: String
    public let upstreamRevision: String
    public let parameters: SchedulerParameterSet
    public let nowUTC: Date
    public let seed: UInt64
    public let grade: Grade
    public let elapsedDays: SchedulerIntervalDays
    public let scheduledDays: SchedulerIntervalDays

    public init(schemaVersion: Int, adapterVersion: String, upstreamRevision: String,
                parameters: SchedulerParameterSet, nowUTC: Date, seed: UInt64, grade: Grade,
                elapsedDays: SchedulerIntervalDays, scheduledDays: SchedulerIntervalDays) {
        self.schemaVersion = schemaVersion
        self.adapterVersion = adapterVersion
        self.upstreamRevision = upstreamRevision
        self.parameters = parameters
        self.nowUTC = nowUTC
        self.seed = seed
        self.grade = grade
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
    }
}

public struct SchedulingResult: Equatable, Codable, Sendable {
    public let before: CardScheduleSnapshot
    public let after: CardScheduleSnapshot
    public let metadata: SchedulingMetadata

    public init(before: CardScheduleSnapshot, after: CardScheduleSnapshot, metadata: SchedulingMetadata) {
        self.before = before
        self.after = after
        self.metadata = metadata
    }
}

/// Exactly four ordered options, no missing dictionary entry or manual rating.
public struct RatingOptions: Equatable, Sendable {
    public let again: SchedulingResult
    public let hard: SchedulingResult
    public let good: SchedulingResult
    public let easy: SchedulingResult

    public init(again: SchedulingResult, hard: SchedulingResult, good: SchedulingResult, easy: SchedulingResult) {
        self.again = again
        self.hard = hard
        self.good = good
        self.easy = easy
    }

    public subscript(grade: Grade) -> SchedulingResult {
        switch grade {
        case .again: again
        case .hard: hard
        case .good: good
        case .easy: easy
        }
    }
}
