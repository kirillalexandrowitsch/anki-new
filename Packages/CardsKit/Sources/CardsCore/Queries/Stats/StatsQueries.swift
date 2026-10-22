import Foundation

public enum StatsPeriod: Int, CaseIterable, Sendable { case week = 7, month = 30, year = 365 }

public struct StatsQuery: Sendable {
    public let asOf: Date
    public let period: StatsPeriod
    public let calendar: StudyDayCalculator
    public init(asOf: Date, period: StatsPeriod, calendar: StudyDayCalculator) {
        self.asOf = asOf; self.period = period; self.calendar = calendar
    }
}

public struct StatsTotals: Equatable, Sendable {
    public let ratings: Int
    public let uniqueCards: Int
    /// Again, Hard, Good, Easy, in that order. Counts are ratings, not unique Cards.
    public let grades: [Int]
    public let responseDurationMs: Int64
    public var successRate: Double? {
        ratings == 0 ? nil : Double(ratings - grades[0]) / Double(ratings)
    }
    public init(ratings: Int, uniqueCards: Int, grades: [Int], responseDurationMs: Int64) {
        self.ratings = ratings; self.uniqueCards = uniqueCards; self.grades = grades
        self.responseDurationMs = responseDurationMs
    }
}

public struct StatsDay: Equatable, Sendable, Identifiable {
    public let day: StudyDay
    public let totals: StatsTotals
    public var id: StudyDayKey { day.key }
    public init(day: StudyDay, totals: StatsTotals) { self.day = day; self.totals = totals }
}

public struct StatsSnapshot: Equatable, Sendable {
    public let generation: UUID
    public let days: [StatsDay]
    public let totals: StatsTotals
    /// Persisted foreground duration of scheduled sessions STARTED in this period.
    /// Session time survives Undo and is not a sum of ReviewLog response times.
    public let startedSessionActiveDurationMs: Int64
    public init(generation: UUID, days: [StatsDay], totals: StatsTotals, startedSessionActiveDurationMs: Int64) {
        self.generation = generation; self.days = days; self.totals = totals
        self.startedSessionActiveDurationMs = startedSessionActiveDurationMs
    }
}

public protocol StatsQueryService: Sendable {
    func statistics(_ query: StatsQuery) async throws -> StatsSnapshot
    func observeStatistics(_ query: StatsQuery) async throws -> QueryObservation<StatsSnapshot>
}
public struct StatsWorkspace: Sendable {
    public let generation: UUID
    public let queries: any StatsQueryService
    public init(generation: UUID, queries: any StatsQueryService) { self.generation = generation; self.queries = queries }
}
public protocol StatsWorkspaceAccess: CollectionAccess {
    func statsWorkspace(generation: UUID) async throws -> StatsWorkspace
}
