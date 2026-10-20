import CardsCore
import Foundation
import GRDB

enum ReviewCheckpoint: Sendable { case beforeCommit, afterCommit }
typealias ReviewFault = @Sendable (ReviewCheckpoint) throws -> Void

struct SQLiteReviewRepository: ReviewRepository {
    let writer: CollectionWriter
    let configuration: StudyQueueConfiguration
    let scheduler: any Scheduler
    let clock: any CardsCore.Clock
    var fault: ReviewFault? = nil

    func rateCard(_ command: RateCardCommand) async throws -> ReviewReceipt {
        let receipt = try await writer.execute(commandID: command.rating.id, kind: "review.rate.v1", request: command) { db in
            let c = command.rating
            guard (0...60_000).contains(c.durationMs) else {
                throw CollectionRepositoryError.validation(.outOfRange(field: "durationMs"))
            }
            let session = try Self.session(db, id: command.sessionID)
            guard let item = try Row.fetchOne(db, sql: """
                SELECT * FROM session_items WHERE sessionID=? AND cardID=? AND stage IN ('question','answer')
                ORDER BY queueOrdinal DESC LIMIT 1
                """, arguments: [ReviewSQL.key(command.sessionID), ReviewSQL.key(c.cardID)]) else {
                throw CollectionRepositoryError.reviewUnavailable
            }
            let before = try ReviewSQL.schedule(db, cardID: c.cardID)
            guard before.revision == c.expectedRevision else {
                throw CollectionRepositoryError.revisionConflict(entity: .card(c.cardID), expected: c.expectedRevision, actual: before.revision)
            }
            guard before.scheduleEpoch == c.scheduleEpoch else { throw CollectionRepositoryError.reviewUnavailable }
            let snapshot = try ReviewSQL.snapshot(db, generation: configuration.generation, sessionID: command.sessionID)
            // Both event-time and current availability must permit the Card. A stale question cannot bypass a burial/quota.
            let eventNow = try EpochMilliseconds(date: c.occurredAt).date
            for now in [eventNow, clock.now()] {
                let queue = try QueueBuilder().build(snapshot, configuration: configuration, now: now)
                guard queue.ready.contains(where: { $0.card.id == c.cardID }) else { throw CollectionRepositoryError.reviewUnavailable }
            }
            let parameters = try ReviewSQL.parameters(db, id: before.parameterSetID)
            let calculated = try scheduler.apply(SchedulingInput(schedule: before, nowUTC: eventNow,
                parameters: parameters, seed: c.seed), grade: c.grade)
            try ReviewSQL.saveSchedule(db, calculated.after)
            let after = try ReviewSQL.schedule(db, cardID: c.cardID)
            let result = SchedulingResult(before: before, after: after, metadata: calculated.metadata)
            let card = snapshot.cards.first { $0.card.id == c.cardID }!.card
            var path = [DeckID](), cursor: DeckID? = card.deckID
            while let id = cursor { path.append(id); cursor = snapshot.decks.first { $0.id == id }?.parentID }
            let day = try configuration.calendar.studyDay(containing: eventNow)
            let event = StudyQueueEvent(commandID: c.id, cardID: c.cardID, noteID: card.noteID, deckPath: path,
                phaseBefore: before.phase, studyDayKey: day.key, timeZoneID: day.timeZoneID, siblingBuriedUntil: day.end)
            let revision = try Revision(session["revision"]).advanced()
            let noteRevision = try Revision(Int64.fetchOne(db, sql: "SELECT revision FROM notes WHERE id=?",
                arguments: [ReviewSQL.key(card.noteID)])!)
            let receipt = ReviewReceipt(command: command, scheduling: result, queueEvent: event, itemID: item["id"],
                sessionRevision: revision, cardRevision: card.revision, noteRevision: noteRevision)
            try db.execute(sql: """
                INSERT INTO review_logs(id,commandID,cardID,cardIdentitySnapshot,sessionID,ratedAt,studyDayKey,timezoneID,
                    deckIDSnapshot,grade,phaseBefore,durationMs,beforeJSON,afterJSON,parameterSetID,scheduleEpoch)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [UUID().uuidString.lowercased(), ReviewSQL.key(c.id), ReviewSQL.key(c.cardID),
                    ReviewSQL.key(c.cardID), ReviewSQL.key(command.sessionID), ReviewSQL.ms(eventNow), day.key.rawValue,
                    day.timeZoneID, ReviewSQL.key(card.deckID), c.grade.rawValue, before.phase.rawValue, c.durationMs,
                    ReviewSQL.json(before), ReviewSQL.json(after), ReviewSQL.key(after.parameterSetID), after.scheduleEpoch])
            try db.execute(sql: "UPDATE session_items SET stage='rated', eligibleAt=? WHERE id=?",
                arguments: [ReviewSQL.ms(after.dueAt), receipt.itemID])
            try db.execute(sql: "UPDATE study_sessions SET revision=?, lastActivityAt=? WHERE id=?",
                arguments: [revision.rawValue, ReviewSQL.ms(eventNow), ReviewSQL.key(command.sessionID)])
            try ReviewSQL.event(db, command: c.id, type: "review.rated", object: ReviewSQL.key(c.cardID), at: eventNow, payload: receipt)
            try fault?(.beforeCommit)
            return receipt
        }
        try fault?(.afterCommit)
        return receipt
    }

    func undoRating(_ command: UndoRatingCommand) async throws -> ReviewUndoResult {
        let result = try await writer.execute(commandID: command.id, kind: "review.undo.v1", request: command) { db in
            let session = try Self.session(db, id: command.sessionID)
            guard let row = try Row.fetchOne(db, sql: """
                SELECT e.payloadJSON FROM review_logs l JOIN domain_events e ON e.commandID=l.commandID AND e.type='review.rated'
                WHERE l.sessionID=? AND l.voidedBy IS NULL ORDER BY l.rowid DESC LIMIT 1
                """, arguments: [ReviewSQL.key(command.sessionID)]) else { throw CollectionRepositoryError.undoConflict }
            let receipt = try ReviewSQL.decode(ReviewReceipt.self, row["payloadJSON"])
            guard receipt.schemaVersion == 1, receipt.command.rating.id == command.ratingID,
                  receipt.sessionRevision == (try Revision(session["revision"])) else { throw CollectionRepositoryError.undoConflict }
            let cardID = receipt.command.rating.cardID
            let current = try ReviewSQL.schedule(db, cardID: cardID)
            guard current == receipt.scheduling.after else { throw CollectionRepositoryError.undoConflict }
            let snapshot = try ReviewSQL.snapshot(db, generation: configuration.generation, sessionID: command.sessionID)
            guard let card = snapshot.cards.first(where: { $0.card.id == cardID }),
                  card.card.revision == receipt.cardRevision, card.card.deckID == receipt.queueEvent.deckPath.first,
                  card.card.deletedAt == nil, !card.card.suspended, !card.noteIsDeleted, card.templateIsValid,
                  card.card.generationState == .active,
                  try Int64.fetchOne(db, sql: "SELECT revision FROM notes WHERE id=?",
                    arguments: [ReviewSQL.key(card.card.noteID)]) == receipt.noteRevision.rawValue,
                  receipt.queueEvent.deckPath.allSatisfy({ id in snapshot.decks.contains { $0.id == id && $0.deletedAt == nil } }) else {
                throw CollectionRepositoryError.undoConflict
            }
            let revision = try current.revision.advanced()
            try ReviewSQL.saveSchedule(db, receipt.scheduling.before, revision: revision)
            let restored = try ReviewSQL.schedule(db, cardID: cardID)
            try db.execute(sql: "UPDATE review_logs SET voidedBy=? WHERE commandID=? AND voidedBy IS NULL",
                arguments: [ReviewSQL.key(command.id), ReviewSQL.key(command.ratingID)])
            guard db.changesCount == 1 else { throw CollectionRepositoryError.undoConflict }
            try db.execute(sql: "UPDATE session_items SET stage='queued' WHERE sessionID=? AND stage IN ('question','answer')",
                arguments: [ReviewSQL.key(command.sessionID)])
            try db.execute(sql: "UPDATE session_items SET stage='answer', eligibleAt=? WHERE id=? AND stage='rated'",
                arguments: [ReviewSQL.ms(restored.dueAt), receipt.itemID])
            guard db.changesCount == 1 else { throw CollectionRepositoryError.undoConflict }
            let sessionRevision = try receipt.sessionRevision.advanced()
            try db.execute(sql: "UPDATE study_sessions SET revision=?, lastActivityAt=? WHERE id=?",
                arguments: [sessionRevision.rawValue, ReviewSQL.ms(command.occurredAt), ReviewSQL.key(command.sessionID)])
            let result = try ReviewUndoResult(command: command, restored: restored, presentation: ReviewSQL.presentation(db, cardID: cardID))
            try ReviewSQL.event(db, command: command.id, type: "review.undone", object: ReviewSQL.key(cardID), at: command.occurredAt, payload: result)
            try fault?(.beforeCommit)
            return result
        }
        try fault?(.afterCommit)
        return result
    }

    func effectiveStatistics() async throws -> EffectiveReviewStatistics {
        try await writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS ratings, count(DISTINCT cardIdentitySnapshot) AS cards, coalesce(sum(durationMs),0) AS duration
                FROM review_logs WHERE voidedBy IS NULL
                """)!
            return EffectiveReviewStatistics(ratings: row["ratings"], uniqueCards: row["cards"], durationMs: row["duration"])
        }
    }

    static func session(_ db: Database, id: SessionID) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM study_sessions WHERE id=? AND mode='scheduled' AND status='active'",
            arguments: [ReviewSQL.key(id)]) else { throw CollectionRepositoryError.reviewUnavailable }
        return row
    }
}
