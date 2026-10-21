import Foundation

public struct TodayQueueCounts: Equatable, Sendable {
    public let new: Int
    public let due: Int
    public var total: Int { new + due }
    public init(new: Int, due: Int) { self.new = new; self.due = due }
}

public struct TodayDeckRow: Equatable, Sendable, Identifiable {
    public let deck: Deck
    public let counts: TodayQueueCounts
    public var id: DeckID { deck.id }
    public init(deck: Deck, counts: TodayQueueCounts) { self.deck = deck; self.counts = counts }
}

public struct TodayStudySnapshot: Equatable, Sendable {
    public let generation: UUID
    public let asOf: Date
    public let day: StudyDay
    public let counts: TodayQueueCounts
    public let decks: [TodayDeckRow]
    public let resumableSessionID: SessionID?
    public let nextAvailableAt: Date?
    public let futureIsLearning: Bool
    public let emptyReasons: Set<StudyQueueEmptyReason>
    public let ratings: Int
    public let uniqueCards: Int
    public let responseDurationMs: Int64
    public init(generation: UUID, asOf: Date, day: StudyDay, counts: TodayQueueCounts, decks: [TodayDeckRow],
                resumableSessionID: SessionID?, nextAvailableAt: Date?, futureIsLearning: Bool,
                emptyReasons: Set<StudyQueueEmptyReason>, ratings: Int, uniqueCards: Int, responseDurationMs: Int64) {
        self.generation = generation; self.asOf = asOf; self.day = day; self.counts = counts; self.decks = decks
        self.resumableSessionID = resumableSessionID; self.nextAvailableAt = nextAvailableAt
        self.futureIsLearning = futureIsLearning; self.emptyReasons = emptyReasons
        self.ratings = ratings; self.uniqueCards = uniqueCards; self.responseDurationMs = responseDurationMs
    }
}

public protocol TodayQueryService: Sendable {
    func studyToday(asOf: Date, calendar: StudyDayCalculator) async throws -> TodayStudySnapshot
    func observeStudyToday(asOf: Date, calendar: StudyDayCalculator) async throws -> QueryObservation<TodayStudySnapshot>
}

public struct TodayWorkspace: Sendable {
    public let generation: UUID
    public let queries: any TodayQueryService
    public init(generation: UUID, queries: any TodayQueryService) { self.generation = generation; self.queries = queries }
}

public protocol TodayWorkspaceAccess: CollectionAccess {
    func todayWorkspace(generation: UUID) async throws -> TodayWorkspace
}
