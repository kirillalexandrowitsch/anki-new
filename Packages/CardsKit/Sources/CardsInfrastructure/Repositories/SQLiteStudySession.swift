import CardsCore
import Foundation
import GRDB

struct StoredStudyPolicy: Codable, Sendable {
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
struct SQLiteStudySession: StudyReviewSessionService, StudyProgressService {
    let sessionID: SessionID
    let reviews: SQLiteReviewRepository

    static func open(writer: CollectionWriter, configuration: StudyQueueConfiguration,
                     clock: any CardsCore.Clock, useCollectionPreferences: Bool = false,
                     deckRequest: DeckStudyRequest? = nil) async throws -> SQLiteStudySession {
        let pair = try await writer.mediaAccess { pool in
            try pool.write { db -> (SessionID, StudyQueueConfiguration) in
                if let r = try Row.fetchOne(db, sql: "SELECT * FROM study_sessions WHERE mode='scheduled' AND status IN ('active','paused')") {
                    if deckRequest != nil { throw DeckStudyError.activeSession }
                    let policy = try ReviewSQL.decode(StoredStudyPolicy.self, r["studyPolicyJSON"])
                    let id = try SessionID(uuidString: r["id"])
                    return try (id, policy.configuration(generation: configuration.generation))
                }
                let configuration = try StudyQueueConfiguration(generation: configuration.generation,
                    scope: configuration.scope, calendar: configuration.calendar,
                    dailyLimits: useCollectionPreferences ? SQLiteStudyPreferences.fetch(db).value.limits : configuration.dailyLimits,
                    deckLimits: configuration.deckLimits, sessionLimit: configuration.sessionLimit,
                    siblingPolicy: configuration.siblingPolicy)
                if let deckRequest {
                    let snapshot = try ReviewSQL.snapshot(db, generation: configuration.generation, sessionID: nil, skipping: [])
                    try SQLiteDeckStudy.validate(deckRequest, snapshot: snapshot)
                    let queue = try QueueBuilder().build(snapshot, configuration: configuration, now: clock.now())
                    guard !queue.ready.isEmpty else { throw DeckStudyError.emptyQueue }
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
                let session = try Self.resumableSession(db, id: sessionID)
                let saved = try Self.savedCheckpoint(session)
                // The checkpoint is authoritative after a crash; a rated item can never be selected
                // merely because an old checkpoint still mentions it.
                let exclusions = saved?.skipped ?? skipping
                let currentCard = try String.fetchOne(db, sql: "SELECT cardID FROM session_items WHERE sessionID=? AND stage IN ('question','answer') ORDER BY queueOrdinal DESC LIMIT 1",
                    arguments: [ReviewSQL.key(sessionID)])
                let currentID = try currentCard.map { try CardID(uuidString: $0) }
                let preferred = preferred ?? currentID
                let snapshot = try ReviewSQL.snapshot(db, generation: configuration.generation, sessionID: sessionID, skipping: exclusions)
                let queue = try QueueBuilder().build(snapshot, configuration: configuration, now: now)
                guard let chosen = queue.ready.first(where: { $0.card.id == preferred }) ?? queue.ready.first else {
                    if let future = queue.futureDue { return .completed(.future(future.availableAt)) }
                    return .completed(queue.emptyReasons.contains(.skipped) ? .availableViewed : .noCards)
                }
                let value = try ReviewSQL.presentation(db, cardID: chosen.card.id)
                try db.execute(sql: "UPDATE session_items SET stage='queued' WHERE sessionID=? AND stage IN ('question','answer') AND cardID!=?",
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

    private static func resumableSession(_ db: Database, id: SessionID) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM study_sessions WHERE id=? AND status IN ('active','paused')",
            arguments: [ReviewSQL.key(id)]) else { throw CollectionRepositoryError.reviewUnavailable }
        return row
    }

    static func savedCheckpoint(_ row: Row) throws -> StudyCheckpoint? {
        // v1 scopeJSON before T022 contained only schemaVersion.
        struct Envelope: Decodable { let checkpoint: StudyCheckpoint? }
        let value = try ReviewSQL.decode(Envelope.self, row["scopeJSON"]).checkpoint
        if let value, value.schemaVersion != 1 { throw CollectionRepositoryError.unsupportedCommandResult }
        return value
    }

    func progress() async throws -> StudyProgress {
        try await reviews.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM study_sessions WHERE id=?",
                arguments: [ReviewSQL.key(sessionID)]) else { throw CollectionRepositoryError.reviewUnavailable }
            let stats = try Row.fetchOne(db, sql: "SELECT count(*) AS ratings, count(DISTINCT cardIdentitySnapshot) AS cards FROM review_logs WHERE sessionID=? AND voidedBy IS NULL",
                arguments: [ReviewSQL.key(sessionID)])!
            let grades = try (1...4).map { grade in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM review_logs WHERE sessionID=? AND voidedBy IS NULL AND grade=?",
                    arguments: [ReviewSQL.key(sessionID), grade])!
            }
            let last = try String.fetchOne(db, sql: "SELECT commandID FROM review_logs WHERE sessionID=? AND voidedBy IS NULL ORDER BY rowid DESC LIMIT 1",
                arguments: [ReviewSQL.key(sessionID)])
            return try StudyProgress(checkpoint: Self.savedCheckpoint(row), ratings: stats["ratings"], uniqueCards: stats["cards"],
                grades: grades, lastRatingID: last.map { try CommandID(uuidString: $0) }, activeDurationMs: row["activeDurationMs"])
        }
    }

    func checkpoint(_ value: StudyCheckpoint) async throws {
        guard value.schemaVersion == 1, value.activeDurationMs >= 0 else { throw CollectionRepositoryError.integrityFailure }
        struct Envelope: Encodable { let schemaVersion = 1; let checkpoint: StudyCheckpoint }
        let now = reviews.clock.now()
        try await reviews.writer.mediaAccess { pool in
            try pool.write { db in
                _ = try Self.resumableSession(db, id: sessionID)
                // Skip is persisted without any ReviewLog or schedule mutation.
                try db.execute(sql: "UPDATE session_items SET stage='queued' WHERE sessionID=? AND stage='skipped'",
                    arguments: [ReviewSQL.key(sessionID)])
                for id in value.skipped {
                    try db.execute(sql: "UPDATE session_items SET stage='skipped' WHERE sessionID=? AND cardID=? AND stage!='rated'",
                        arguments: [ReviewSQL.key(sessionID), ReviewSQL.key(id)])
                }
                if let id = value.cardID, value.phase != .summary {
                    let stage = value.phase == .answer || (value.phase == .paused && value.priorToPause == .answer) ? "answer" : "question"
                    try db.execute(sql: "UPDATE session_items SET stage=? WHERE sessionID=? AND cardID=? AND stage IN ('question','answer')",
                        arguments: [stage, ReviewSQL.key(sessionID), ReviewSQL.key(id)])
                }
                try db.execute(sql: "UPDATE study_sessions SET scopeJSON=?, status=?, activeDurationMs=max(activeDurationMs,?), lastActivityAt=? WHERE id=?",
                    arguments: [ReviewSQL.json(Envelope(checkpoint: value)), value.phase == .paused ? "paused" : "active",
                        value.activeDurationMs, ReviewSQL.ms(now), ReviewSQL.key(sessionID)])
            }
        }
    }

    func finish(early: Bool) async throws {
        let now = reviews.clock.now()
        try await reviews.writer.mediaAccess { pool in
            try pool.write { db in
                // Idempotent after a lost acknowledgement; never reopens an ended session.
                try db.execute(sql: "UPDATE study_sessions SET status=?, endedAt=?, lastActivityAt=? WHERE id=? AND status IN ('active','paused')",
                    arguments: [early ? "abandoned" : "completed", ReviewSQL.ms(now), ReviewSQL.ms(now), ReviewSQL.key(sessionID)])
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
