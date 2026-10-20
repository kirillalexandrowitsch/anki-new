import CardsCore
import Foundation
import GRDB

/// SQLite mapping stays outside Core. Existing v1 tables and versioned event payloads suffice.
enum ReviewSQL {
    static func key<T>(_ id: EntityID<T>) -> String { id.rawValue.uuidString.lowercased() }
    static func json<T: Encodable>(_ value: T) throws -> String { try BasicNoteDefaults.json(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    static func date(_ value: Int64?) -> Date? { value.map { EpochMilliseconds($0).date } }
    static func ms(_ date: Date?) throws -> Int64? { try date.map { try EpochMilliseconds(date: $0).rawValue } }

    static func schedule(_ db: Database, cardID: CardID) throws -> CardScheduleSnapshot {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM card_schedules WHERE cardID = ?", arguments: [key(cardID)]),
              let phase = SchedulePhase(rawValue: r["phase"]) else { throw CollectionRepositoryError.integrityFailure }
        return try CardScheduleSnapshot(cardID: cardID, algorithmID: r["algorithmID"], algorithmVersion: r["algorithmVersion"],
            parameterSetID: SchedulerParameterSetID(uuidString: r["parameterSetID"]), phase: phase,
            stability: r["stability"], difficulty: r["difficulty"], dueAt: date(r["dueAt"]), lastReviewAt: date(r["lastReviewAt"]),
            repetitions: r["repetitions"], lapses: r["lapses"], learningStep: r["learningStep"],
            scheduleEpoch: r["scheduleEpoch"], revision: Revision(r["revision"]))
    }

    static func saveSchedule(_ db: Database, _ s: CardScheduleSnapshot, revision: Revision? = nil) throws {
        try db.execute(sql: """
            UPDATE card_schedules SET algorithmID=?, algorithmVersion=?, parameterSetID=?, phase=?, stability=?,
                difficulty=?, dueAt=?, lastReviewAt=?, repetitions=?, lapses=?, learningStep=?, scheduleEpoch=?, revision=?
            WHERE cardID=?
            """, arguments: [s.algorithmID, s.algorithmVersion, key(s.parameterSetID), s.phase.rawValue,
                s.stability, s.difficulty, ms(s.dueAt), ms(s.lastReviewAt), s.repetitions, s.lapses,
                s.learningStep, s.scheduleEpoch, (revision ?? s.revision).rawValue, key(s.cardID)])
        guard db.changesCount == 1 else { throw CollectionRepositoryError.integrityFailure }
    }

    static func parameters(_ db: Database, id: SchedulerParameterSetID) throws -> SchedulerParameterSet {
        guard let r = try Row.fetchOne(db, sql: "SELECT * FROM scheduler_parameters WHERE id=?", arguments: [key(id)]) else {
            throw CollectionRepositoryError.integrityFailure
        }
        struct Weights: Decodable { let schemaVersion: Int; let w: [Double] }
        let w = try decode(Weights.self, r["weightsJSON"])
        return try SchedulerParameterSet(schemaVersion: w.schemaVersion, id: id, algorithmVersion: r["algorithmVersion"],
            weights: w.w, desiredRetention: r["desiredRetention"], maximumIntervalDays: r["maximumIntervalDays"],
            learningPolicy: decode(LearningPolicy.self, r["learningPolicyJSON"]))
    }

    static func presentation(_ db: Database, cardID: CardID) throws -> StudyPresentation {
        guard let r = try Row.fetchOne(db, sql: """
            SELECT n.* FROM notes n JOIN cards c ON c.noteID=n.id WHERE c.id=? AND n.deletedAt IS NULL
            """, arguments: [key(cardID)]), r["noteTypeID"] as String == key(BasicNoteType.id),
              r["contentVersion"] as Int == 1 else { throw CollectionRepositoryError.reviewUnavailable }
        let content = try decode(BasicNoteContent.self, r["fieldsJSON"])
        try content.validate()
        let s = try schedule(db, cardID: cardID)
        return StudyPresentation(cardID: cardID, revision: s.revision, question: content.front, answer: content.back,
            scheduleEpoch: s.scheduleEpoch, pronunciation: content.pronunciation,
            example: content.examples.map { $0.en }.joined(separator: "\n"))
    }

    static func snapshot(_ db: Database, generation: UUID, sessionID: SessionID,
                         skipping: Set<CardID> = []) throws -> StudyQueueSnapshot {
        let decks = try Row.fetchAll(db, sql: "SELECT * FROM decks").map { r in
            try Deck(id: DeckID(uuidString: r["id"]), parentID: (r["parentID"] as String?).map { try DeckID(uuidString: $0) },
                name: EntityName(r["name"]), revision: Revision(r["revision"]), deletedAt: date(r["deletedAt"]))
        }
        let cards = try Row.fetchAll(db, sql: """
            SELECT c.*, n.deletedAt AS noteDeleted, n.noteTypeID, n.contentVersion, n.fieldsJSON,
                t.deletedAt AS typeDeleted, t.templatesJSON
            FROM cards c JOIN notes n ON n.id=c.noteID JOIN note_types t ON t.id=n.noteTypeID
            """).map { r -> StudyQueueCard in
                guard let state = CardGenerationState(rawValue: r["generationState"]) else {
                    throw CollectionRepositoryError.integrityFailure
                }
                let card = try Card(id: CardID(uuidString: r["id"]), noteID: NoteID(uuidString: r["noteID"]),
                    deckID: DeckID(uuidString: r["deckID"]), variantKey: r["variantKey"], templateID: r["templateID"],
                    generationState: state, suspended: r["suspended"], buriedUntil: date(r["buriedUntil"]),
                    createdAt: EpochMilliseconds(r["createdAt"]).date, revision: Revision(r["revision"]), deletedAt: date(r["deletedAt"]))
                // Only the delivered Basic renderer is supported; never present an unrenderable template.
                let basic = r["noteTypeID"] as String == key(BasicNoteType.id) && r["typeDeleted"] == nil &&
                    r["templatesJSON"] as String == BasicNoteDefaults.templates && r["contentVersion"] as Int == 1 &&
                    card.templateID == BasicNoteType.templateID && card.variantKey == BasicNoteType.variantKey
                let content = try? decode(BasicNoteContent.self, r["fieldsJSON"])
                let validContent = content.map { (try? $0.validate()) != nil } ?? false
                return StudyQueueCard(card: card, schedule: try schedule(db, cardID: card.id),
                    noteIsDeleted: r["noteDeleted"] != nil, templateIsValid: basic && validContent)
            }
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.payloadJSON, l.voidedBy FROM domain_events e JOIN review_logs l ON l.commandID=e.commandID
            WHERE e.type='review.rated'
            """)
        let events = try rows.map { r -> StudyQueueEvent in
            let e = try decode(ReviewReceipt.self, r["payloadJSON"]).queueEvent
            return StudyQueueEvent(commandID: e.commandID, cardID: e.cardID, noteID: e.noteID, deckPath: e.deckPath,
                phaseBefore: e.phaseBefore, studyDayKey: e.studyDayKey, timeZoneID: e.timeZoneID,
                siblingBuriedUntil: e.siblingBuriedUntil, isVoided: r["voidedBy"] != nil)
        }
        let selected = try Row.fetchAll(db, sql: """
            SELECT DISTINCT cardIdentitySnapshot FROM review_logs WHERE sessionID=? AND voidedBy IS NULL
            """, arguments: [key(sessionID)]).map { try CardID(uuidString: $0["cardIdentitySnapshot"]) }
        let lastNote = try String.fetchOne(db, sql: """
            SELECT c.noteID FROM session_items i JOIN cards c ON c.id=i.cardID
            WHERE i.sessionID=? AND i.stage IN ('question','answer','rated') ORDER BY i.queueOrdinal DESC LIMIT 1
            """, arguments: [key(sessionID)])
        return try StudyQueueSnapshot(generation: generation, decks: decks, cards: cards, events: events,
            session: StudyQueueSession(selectedCardIDs: Set(selected), skippedCardIDs: skipping,
                lastPresentedNoteID: lastNote.map { try NoteID(uuidString: $0) }))
    }

    static func event<T: Encodable>(_ db: Database, command: CommandID, type: String,
                                   object: String, at: Date, payload: T) throws {
        try db.execute(sql: """
            INSERT INTO domain_events(id,commandID,type,objectID,occurredAt,payloadVersion,payloadJSON) VALUES (?,?,?,?,?,1,?)
            """, arguments: [UUID().uuidString.lowercased(), key(command), type, object, ms(at), json(payload)])
    }
}
