import CardsCore
import Foundation
import GRDB

private struct StoredStudyPolicy: Codable, Sendable {
    let schemaVersion: Int
    let scope: StudyQueueScope
    let timeZoneID: String
    let rollover: StudyDayRollover
    let limits: StudyQueueLimits
    let deckLimits: [DeckID: StudyQueueLimits]
    let sessionLimit: Int?
    let siblingPolicy: StudySiblingPolicy
    init(_ c: StudyQueueConfiguration) {
        schemaVersion = 1; scope = c.scope; timeZoneID = c.calendar.timeZoneID; rollover = c.calendar.rollover
        limits = c.dailyLimits; deckLimits = c.deckLimits; sessionLimit = c.sessionLimit; siblingPolicy = c.siblingPolicy
    }
    func configuration(generation: UUID) throws -> StudyQueueConfiguration {
        guard schemaVersion == 1 else { throw CollectionRepositoryError.unsupportedCommandResult }
        return try StudyQueueConfiguration(generation: generation, scope: scope,
            calendar: StudyDayCalculator(timeZoneID: timeZoneID, rollover: rollover),
            dailyLimits: StudyQueueLimits(new: limits.new, review: limits.review),
            deckLimits: deckLimits, sessionLimit: sessionLimit, siblingPolicy: siblingPolicy)
    }
}

/// The collection writer serializes every decision with rating/undo. No cached success or queue.
struct SQLiteStudySession: StudyReviewSessionService {
    let sessionID: SessionID
    let reviews: SQLiteReviewRepository

    static func open(writer: CollectionWriter, configuration: StudyQueueConfiguration,
                     clock: any CardsCore.Clock) async throws -> SQLiteStudySession {
        let pair = try await writer.mediaAccess { pool in
            try pool.write { db -> (SessionID, StudyQueueConfiguration) in
                if let r = try Row.fetchOne(db, sql: "SELECT * FROM study_sessions WHERE mode='scheduled' AND status IN ('active','paused')") {
                    let policy = try ReviewSQL.decode(StoredStudyPolicy.self, r["studyPolicyJSON"])
                    let id = try SessionID(uuidString: r["id"])
                    try db.execute(sql: "UPDATE study_sessions SET status='active' WHERE id=?", arguments: [ReviewSQL.key(id)])
                    return try (id, policy.configuration(generation: configuration.generation))
                }
                let id = SessionID(), now = try ReviewSQL.ms(clock.now())
                try db.execute(sql: """
                    INSERT INTO study_sessions(id,mode,scopeJSON,startedAt,lastActivityAt,status,studyPolicyJSON)
                    VALUES (?,'scheduled',?,?,?,'active',?)
                    """, arguments: [ReviewSQL.key(id), "{\"schemaVersion\":1}", now, now, ReviewSQL.json(StoredStudyPolicy(configuration))])
                return (id, configuration)
            }
        }
        return SQLiteStudySession(sessionID: pair.0,
            reviews: SQLiteReviewRepository(writer: writer, configuration: pair.1, scheduler: FSRS6Scheduler(), clock: clock))
    }

    func next(skipping: Set<CardID>, preferred: CardID?) async throws -> StudyNext {
        let sessionID = sessionID, configuration = reviews.configuration, now = reviews.clock.now()
        return try await reviews.writer.mediaAccess { pool in
            try pool.write { db in
                _ = try SQLiteReviewRepository.session(db, id: sessionID)
                let snapshot = try ReviewSQL.snapshot(db, generation: configuration.generation, sessionID: sessionID, skipping: skipping)
                let queue = try QueueBuilder().build(snapshot, configuration: configuration, now: now)
                guard let chosen = queue.ready.first(where: { $0.card.id == preferred }) ?? queue.ready.first else {
                    if let future = queue.futureDue { return .completed(.future(future.availableAt)) }
                    return .completed(queue.emptyReasons.contains(.skipped) ? .availableViewed : .noCards)
                }
                let value = try ReviewSQL.presentation(db, cardID: chosen.card.id)
                try db.execute(sql: "UPDATE session_items SET stage='skipped' WHERE sessionID=? AND stage IN ('question','answer') AND cardID!=?",
                    arguments: [ReviewSQL.key(sessionID), ReviewSQL.key(chosen.card.id)])
                let current = try Row.fetchOne(db, sql: """
                    SELECT id FROM session_items WHERE sessionID=? AND cardID=? AND stage IN ('question','answer')
                    ORDER BY queueOrdinal DESC LIMIT 1
                    """, arguments: [ReviewSQL.key(sessionID), ReviewSQL.key(chosen.card.id)])
                if let current {
                    // Recovery always hides the answer. Undo returns its own revealed presentation directly.
                    try db.execute(sql: "UPDATE session_items SET stage='question' WHERE id=?", arguments: [current["id"] as String])
                } else {
                    let ordinal = try Int64.fetchOne(db, sql: "SELECT coalesce(max(queueOrdinal),-1)+1 FROM session_items WHERE sessionID=?",
                        arguments: [ReviewSQL.key(sessionID)])!
                    try db.execute(sql: """
                        INSERT INTO session_items(id,sessionID,cardID,queueOrdinal,stage,eligibleAt,presentedAt)
                        VALUES (?,?,?,?,'question',?,?)
                        """, arguments: [UUID().uuidString.lowercased(), ReviewSQL.key(sessionID), ReviewSQL.key(chosen.card.id),
                            ordinal, ReviewSQL.ms(chosen.schedule?.dueAt), ReviewSQL.ms(now)])
                }
                return .question(value)
            }
        }
    }

    func rate(_ command: StudyRatingCommand) async throws {
        _ = try await RateCard(repository: reviews).execute(RateCardCommand(sessionID: sessionID, rating: command))
    }
    func undoRating(_ command: UndoRatingCommand) async throws -> ReviewUndoResult {
        guard command.sessionID == sessionID else { throw CollectionRepositoryError.undoConflict }
        return try await UndoRating(repository: reviews).execute(command)
    }
}
