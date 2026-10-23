import CardsCore
import Foundation
import GRDB

struct SQLiteDeckStudy: DeckStudyService {
    let writer: CollectionWriter
    let generation: UUID
    let clock: any CardsCore.Clock

    func defaults() async throws -> StudyPreferences { try await SQLiteStudyPreferences(writer: writer).load().value }

    static func validate(_ request: DeckStudyRequest, snapshot: StudyQueueSnapshot) throws {
        let decks = Dictionary(uniqueKeysWithValues: snapshot.decks.map { ($0.id, $0) })
        var cursor: DeckID? = request.scopeID, visited: Set<DeckID> = []
        var containsRoot = false
        while let id = cursor {
            guard visited.insert(id).inserted, let deck = decks[id], deck.deletedAt == nil else {
                throw CollectionRepositoryError.invalidHierarchy
            }
            if id == request.rootID { containsRoot = true }
            cursor = deck.parentID
        }
        guard containsRoot else { throw CollectionRepositoryError.invalidHierarchy }
    }
    func configuration(_ request: DeckStudyRequest) throws -> StudyQueueConfiguration {
        try StudyQueueConfiguration(generation: generation, scope: .decks([request.scopeID]),
            calendar: StudyDayCalculator(timeZoneID: TimeZone.current.identifier),
            dailyLimits: request.limits, sessionLimit: request.sessionLimit)
    }
    func preview(_ request: DeckStudyRequest) async throws -> DeckStudyPreview {
        let configuration = try configuration(request), now = clock.now()
        return try await writer.read { db in
            let snapshot = try ReviewSQL.snapshot(db, generation: generation, sessionID: nil, skipping: [])
            try Self.validate(request, snapshot: snapshot)
            let queue = try QueueBuilder().build(snapshot, configuration: configuration, now: now)
            let new = queue.ready.filter { $0.schedule?.phase == .new }.count
            let review = queue.ready.filter { $0.schedule?.phase == .review }.count
            let active = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM study_sessions WHERE mode='scheduled' AND status IN ('active','paused'))")!
            return DeckStudyPreview(asOf: now, new: new, review: review, learning: queue.ready.count - new - review,
                reasons: queue.emptyReasons, hasActiveSession: active)
        }
    }
    func start(_ request: DeckStudyRequest) async throws -> any StudyReviewSessionService {
        try await SQLiteStudySession.open(writer: writer, configuration: configuration(request), clock: clock,
                                          deckRequest: request)
    }
}
