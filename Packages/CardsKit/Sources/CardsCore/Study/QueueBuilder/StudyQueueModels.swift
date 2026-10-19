import Foundation

public enum StudyQueueError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidHierarchy
    case conflictingSnapshot
    case invalidCard(CardID)
    case invalidHistory
    case staleGeneration
}

public struct StudyQueueLimits: Equatable, Sendable {
    public let new: Int
    public let review: Int
    public init(new: Int = 20, review: Int = 200) throws {
        guard new >= 0, review >= 0 else { throw StudyQueueError.invalidLimits }
        self.new = new; self.review = review
    }
    public static let standard = try! Self()
}

public enum StudyQueueScope: Equatable, Sendable {
    case collection
    case decks(Set<DeckID>)
}

public enum StudySiblingPolicy: Sendable { case buryUntilNextStudyDay, allow }

public struct StudyQueueConfiguration: Sendable {
    public let generation: UUID
    public let scope: StudyQueueScope
    public let calendar: StudyDayCalculator
    public let dailyLimits: StudyQueueLimits
    public let deckLimits: [DeckID: StudyQueueLimits]
    public let sessionLimit: Int?
    public let siblingPolicy: StudySiblingPolicy
    public init(generation: UUID, scope: StudyQueueScope = .collection, calendar: StudyDayCalculator,
                dailyLimits: StudyQueueLimits = .standard, deckLimits: [DeckID: StudyQueueLimits] = [:],
                sessionLimit: Int? = nil, siblingPolicy: StudySiblingPolicy = .buryUntilNextStudyDay) throws {
        guard sessionLimit.map({ $0 >= 0 }) ?? true else { throw StudyQueueError.invalidLimits }
        self.generation = generation; self.scope = scope; self.calendar = calendar
        self.dailyLimits = dailyLimits; self.deckLimits = deckLimits
        self.sessionLimit = sessionLimit; self.siblingPolicy = siblingPolicy
    }
}

public struct StudyQueueCard: Equatable, Sendable {
    public let card: Card
    public let schedule: CardScheduleSnapshot?
    public let noteIsDeleted: Bool
    public let templateIsValid: Bool
    public init(card: Card, schedule: CardScheduleSnapshot?, noteIsDeleted: Bool = false, templateIsValid: Bool = true) {
        self.card = card; self.schedule = schedule
        self.noteIsDeleted = noteIsDeleted; self.templateIsValid = templateIsValid
    }
}

/// Effective historical identity survives reset, move and deletion. Paths are event-time snapshots.
public struct StudyQueueEvent: Equatable, Sendable {
    public let commandID: CommandID
    public let cardID: CardID
    public let noteID: NoteID
    public let deckPath: [DeckID]
    public let phaseBefore: SchedulePhase
    public let studyDayKey: StudyDayKey
    public let timeZoneID: String
    public let siblingBuriedUntil: Date
    public let isVoided: Bool
    public init(commandID: CommandID, cardID: CardID, noteID: NoteID, deckPath: [DeckID],
                phaseBefore: SchedulePhase, studyDayKey: StudyDayKey, timeZoneID: String,
                siblingBuriedUntil: Date, isVoided: Bool = false) {
        self.commandID = commandID; self.cardID = cardID; self.noteID = noteID; self.deckPath = deckPath
        self.phaseBefore = phaseBefore; self.studyDayKey = studyDayKey; self.timeZoneID = timeZoneID
        self.siblingBuriedUntil = siblingBuriedUntil; self.isVoided = isVoided
    }
}

public struct StudyQueueSession: Equatable, Sendable {
    public let selectedCardIDs: Set<CardID>
    public let skippedCardIDs: Set<CardID>
    public let lastPresentedNoteID: NoteID?
    public init(selectedCardIDs: Set<CardID> = [], skippedCardIDs: Set<CardID> = [], lastPresentedNoteID: NoteID? = nil) {
        self.selectedCardIDs = selectedCardIDs; self.skippedCardIDs = skippedCardIDs
        self.lastPresentedNoteID = lastPresentedNoteID
    }
}

public struct StudyQueueSnapshot: Sendable {
    public let generation: UUID
    public let decks: [Deck]
    public let cards: [StudyQueueCard]
    public let events: [StudyQueueEvent]
    public let session: StudyQueueSession
    public init(generation: UUID, decks: [Deck], cards: [StudyQueueCard], events: [StudyQueueEvent] = [],
                session: StudyQueueSession = .init()) {
        self.generation = generation; self.decks = decks; self.cards = cards
        self.events = events; self.session = session
    }
}

public struct StudyQueueFuture: Equatable, Sendable {
    public let cardID: CardID
    public let availableAt: Date
}

public enum StudyQueueEmptyReason: Hashable, Sendable {
    case noCardsInScope, unavailable, dailyLimit, sessionLimit, skipped, futureOnly
}

public struct StudyQueueResult: Sendable {
    public let day: StudyDay
    public let ready: [StudyQueueCard]
    public let futureDue: StudyQueueFuture?
    public let emptyReasons: Set<StudyQueueEmptyReason>
}

/// Must read a coherent, current snapshot; throw storage/lifecycle errors, never substitute [].
public protocol StudyQueueSource: Sendable {
    func studyQueueSnapshot() async throws -> StudyQueueSnapshot
}

public struct StudyQueueService: Sendable {
    private let source: any StudyQueueSource
    private let clock: any Clock
    private let configuration: StudyQueueConfiguration
    public init(source: any StudyQueueSource, clock: any Clock, configuration: StudyQueueConfiguration) {
        self.source = source; self.clock = clock; self.configuration = configuration
    }
    /// Re-reads availability, scope, revisions, quotas and time before every presentation.
    public func next() async throws -> StudyQueueResult {
        let snapshot = try await source.studyQueueSnapshot()
        try Task.checkCancellation()
        return try QueueBuilder().build(snapshot, configuration: configuration, now: clock.now())
    }
}
