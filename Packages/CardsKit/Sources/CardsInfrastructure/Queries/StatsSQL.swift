import CardsCore
import Foundation
import GRDB

/// All aggregates belong to the same read transaction and never join live Cards/decks.
enum StatsSQL {
    static func totals(_ db: Database, predicate: String, arguments: StatementArguments) throws -> StatsTotals {
        let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS ratings, count(DISTINCT cardIdentitySnapshot) AS cards,
                coalesce(sum(durationMs),0) AS duration,
                coalesce(sum(grade=1),0) AS again, coalesce(sum(grade=2),0) AS hard,
                coalesce(sum(grade=3),0) AS good, coalesce(sum(grade=4),0) AS easy
            FROM review_logs WHERE voidedBy IS NULL AND \(predicate)
            """, arguments: arguments)!
        return StatsTotals(ratings: row["ratings"], uniqueCards: row["cards"],
            grades: [row["again"], row["hard"], row["good"], row["easy"]], responseDurationMs: row["duration"])
    }

    static func fetch(_ db: Database, query: StatsQuery, generation: UUID) throws -> StatsSnapshot {
        // Match Today while a saved session policy is active, including rollover/timezone.
        let calendar: StudyDayCalculator
        if let policy = try String.fetchOne(db, sql: "SELECT studyPolicyJSON FROM study_sessions WHERE mode='scheduled' AND status IN ('active','paused')") {
            calendar = try ReviewSQL.decode(StoredStudyPolicy.self, policy).configuration(generation: generation).calendar
        } else { calendar = query.calendar }
        var day = try calendar.studyDay(containing: query.asOf)
        var days: [StudyDay] = [day]
        for _ in 1..<query.period.rawValue {
            day = try calendar.studyDay(containing: day.start.addingTimeInterval(-0.001))
            days.append(day)
        }
        days.reverse()
        let start = days[0], end = days[days.count - 1]
        let arguments: StatementArguments = [start.key.rawValue, end.key.rawValue, calendar.timeZoneID]
        let predicate = "studyDayKey>=? AND studyDayKey<=? AND timezoneID=?"
        let total = try totals(db, predicate: predicate, arguments: arguments)
        // One grouped query for the chart; gaps remain explicit zero days.
        let rows = try Row.fetchAll(db, sql: """
            SELECT studyDayKey, count(*) AS ratings, count(DISTINCT cardIdentitySnapshot) AS cards,
                coalesce(sum(durationMs),0) AS duration,
                coalesce(sum(grade=1),0) AS again, coalesce(sum(grade=2),0) AS hard,
                coalesce(sum(grade=3),0) AS good, coalesce(sum(grade=4),0) AS easy
            FROM review_logs WHERE voidedBy IS NULL AND \(predicate) GROUP BY studyDayKey
            """, arguments: arguments)
        let byDay = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["studyDayKey"] as String, StatsTotals(ratings: row["ratings"], uniqueCards: row["cards"],
                grades: [row["again"], row["hard"], row["good"], row["easy"]], responseDurationMs: row["duration"]))
        })
        let empty = StatsTotals(ratings: 0, uniqueCards: 0, grades: [0,0,0,0], responseDurationMs: 0)
        let active = try Int64.fetchOne(db, sql: """
            SELECT coalesce(sum(activeDurationMs),0) FROM study_sessions
            WHERE mode='scheduled' AND startedAt>=? AND startedAt<?
                AND json_extract(studyPolicyJSON,'$.timeZoneID')=?
            """, arguments: [ReviewSQL.ms(start.start), ReviewSQL.ms(end.end), calendar.timeZoneID])!
        return StatsSnapshot(generation: generation, days: days.map { StatsDay(day: $0, totals: byDay[$0.key.rawValue] ?? empty) },
            totals: total, startedSessionActiveDurationMs: active)
    }
}

extension SQLiteCollectionQueries: StatsQueryService {
    func statistics(_ query: StatsQuery) async throws -> StatsSnapshot {
        try await writer.read { try StatsSQL.fetch($0, query: query, generation: generation) }
    }
    func observeStatistics(_ query: StatsQuery) async throws -> QueryObservation<StatsSnapshot> {
        try await writer.observe(tables: ["review_logs", "study_sessions"]) {
            try StatsSQL.fetch($0, query: query, generation: generation)
        }
    }
}
