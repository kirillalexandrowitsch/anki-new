import CardsCore
import Foundation
import GRDB

/// One transaction, the same queue policy and exclusions as SQLiteStudySession.next.
enum TodayStudySQL {
    static func fetch(_ db: Database, generation: UUID, asOf: Date, calendar: StudyDayCalculator) throws -> TodayStudySnapshot {
        let session = try Row.fetchOne(db, sql: "SELECT * FROM study_sessions WHERE mode='scheduled' AND status IN ('active','paused')")
        let sessionID = try session.map { try SessionID(uuidString: $0["id"]) }
        let configuration: StudyQueueConfiguration
        if let session {
            configuration = try ReviewSQL.decode(StoredStudyPolicy.self, session["studyPolicyJSON"]).configuration(generation: generation)
        } else {
            configuration = try StudyQueueConfiguration(generation: generation, calendar: calendar,
                dailyLimits: SQLiteStudyPreferences.fetch(db).value.limits)
        }
        let skipped = try session.flatMap { try SQLiteStudySession.savedCheckpoint($0) }?.skipped ?? []
        let source = try ReviewSQL.snapshot(db, generation: generation, sessionID: sessionID, skipping: skipped)
        let queue = try QueueBuilder().build(source, configuration: configuration, now: asOf)
        func counts(_ cards: [StudyQueueCard]) -> TodayQueueCounts {
            let new = cards.filter { $0.schedule?.phase == .new }.count
            return TodayQueueCounts(new: new, due: cards.count - new)
        }
        let readyByDeck = Dictionary(grouping: queue.ready, by: { $0.card.deckID })
        let byID = Dictionary(uniqueKeysWithValues: source.decks.map { ($0.id, $0) })
        let decks = source.decks.filter { deck in
            var cursor: Deck? = deck
            while let current = cursor {
                if current.deletedAt != nil { return false }
                cursor = current.parentID.flatMap { byID[$0] }
            }
            return true
        }.sorted {
            let order = $0.name.displayValue.localizedStandardCompare($1.name.displayValue)
            return order == .orderedSame ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : order == .orderedAscending
        }.map { TodayDeckRow(deck: $0, counts: counts(readyByDeck[$0.id] ?? [])) }
        let stats = try Row.fetchOne(db, sql: """
            SELECT count(*) AS ratings, count(DISTINCT cardIdentitySnapshot) AS cards,
                coalesce(sum(durationMs),0) AS duration FROM review_logs
            WHERE voidedBy IS NULL AND studyDayKey=? AND timezoneID=?
            """, arguments: [queue.day.key.rawValue, queue.day.timeZoneID])!
        let futurePhase = queue.futureDue.flatMap { future in source.cards.first { $0.card.id == future.cardID }?.schedule?.phase }
        return TodayStudySnapshot(generation: generation, asOf: asOf, day: queue.day, counts: counts(queue.ready), decks: decks,
            resumableSessionID: sessionID, nextAvailableAt: queue.futureDue?.availableAt,
            futureIsLearning: futurePhase == .learning || futurePhase == .relearning,
            emptyReasons: queue.emptyReasons, ratings: stats["ratings"], uniqueCards: stats["cards"], responseDurationMs: stats["duration"])
    }
}

extension SQLiteCollectionQueries: TodayQueryService {
    func studyToday(asOf: Date, calendar: StudyDayCalculator) async throws -> TodayStudySnapshot {
        try await writer.read { try TodayStudySQL.fetch($0, generation: generation, asOf: asOf, calendar: calendar) }
    }
    func observeStudyToday(asOf: Date, calendar: StudyDayCalculator) async throws -> QueryObservation<TodayStudySnapshot> {
        try await writer.observe(tables: ["notes", "cards", "decks", "card_schedules", "note_types",
                                         "review_logs", "domain_events", "study_sessions", "session_items", "collection_settings"]) {
            try TodayStudySQL.fetch($0, generation: generation, asOf: asOf, calendar: calendar)
        }
    }
}
