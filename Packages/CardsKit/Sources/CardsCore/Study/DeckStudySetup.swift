import Foundation

public struct DeckStudyRequest: Equatable, Sendable {
    public let rootID: DeckID
    public let scopeID: DeckID
    public let limits: StudyQueueLimits
    public let sessionLimit: Int?
    public init(rootID: DeckID, scopeID: DeckID, new: Int, review: Int, sessionLimit: Int?) throws {
        guard (0...9999).contains(new), (0...9999).contains(review),
              sessionLimit.map({ (0...9999).contains($0) }) ?? true else { throw StudyQueueError.invalidLimits }
        self.rootID = rootID; self.scopeID = scopeID
        self.limits = try StudyQueueLimits(new: new, review: review); self.sessionLimit = sessionLimit
    }
}

public struct DeckStudyPreview: Sendable {
    public let asOf: Date
    public let new: Int
    public let review: Int
    public let learning: Int
    public let reasons: Set<StudyQueueEmptyReason>
    public let hasActiveSession: Bool
    public var canStart: Bool { !hasActiveSession && new + review + learning > 0 }
    public init(asOf: Date, new: Int, review: Int, learning: Int,
                reasons: Set<StudyQueueEmptyReason>, hasActiveSession: Bool) {
        self.asOf = asOf; self.new = new; self.review = review; self.learning = learning
        self.reasons = reasons; self.hasActiveSession = hasActiveSession
    }
}

public enum DeckStudyError: Error, Equatable { case activeSession, emptyQueue }

public protocol DeckStudyService: Sendable {
    func defaults() async throws -> StudyPreferences
    func preview(_ request: DeckStudyRequest) async throws -> DeckStudyPreview
    func start(_ request: DeckStudyRequest) async throws -> any StudyReviewSessionService
}
public protocol DeckStudyWorkspaceAccess: CollectionAccess {
    func deckStudy(generation: UUID) async throws -> any DeckStudyService
}
