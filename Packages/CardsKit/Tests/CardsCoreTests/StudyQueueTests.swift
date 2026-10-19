import CardsCore
import Foundation
import Testing

private let queueNow = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
private let queueGeneration = UUID()
private let queueParameters = SchedulerParameterSetID()
private func deck(_ parent: DeckID? = nil, id: DeckID = DeckID(), deleted: Bool = false) throws -> Deck {
    Deck(id: id, parentID: parent, name: try EntityName("Fixture"), deletedAt: deleted ? queueNow : nil)
}
private func entry(_ deck: DeckID, phase: SchedulePhase = .new, due: Date? = nil,
                   id: CardID = CardID(), note: NoteID = NoteID(), suspended: Bool = false,
                   burial: Date? = nil, deleted: Bool = false, state: CardGenerationState = .active,
                   noteDeleted: Bool = false, templateValid: Bool = true, epoch: Int64 = 0) -> StudyQueueCard {
    StudyQueueCard(card: Card(id: id, noteID: note, deckID: deck, variantKey: "forward", templateID: "basic",
                             generationState: state, suspended: suspended, buriedUntil: burial,
                             createdAt: queueNow.addingTimeInterval(-100), deletedAt: deleted ? queueNow : nil),
                   schedule: CardScheduleSnapshot(cardID: id, parameterSetID: queueParameters, phase: phase,
                                                  dueAt: due, scheduleEpoch: epoch),
                   noteIsDeleted: noteDeleted, templateIsValid: templateValid)
}
private func config(scope: StudyQueueScope = .collection, limits: StudyQueueLimits = .standard,
                    deckLimits: [DeckID: StudyQueueLimits] = [:], sessionLimit: Int? = nil,
                    siblings: StudySiblingPolicy = .buryUntilNextStudyDay,
                    calendar: StudyDayCalculator = try! .init(timeZoneID: "UTC")) throws -> StudyQueueConfiguration {
    try StudyQueueConfiguration(generation: queueGeneration, scope: scope, calendar: calendar,
                                dailyLimits: limits, deckLimits: deckLimits, sessionLimit: sessionLimit, siblingPolicy: siblings)
}
private func event(_ item: StudyQueueCard, path: [DeckID], phase: SchedulePhase? = nil,
                   day: StudyDay? = nil, voided: Bool = false, command: CommandID = CommandID()) throws -> StudyQueueEvent {
    let day = try day ?? StudyDayCalculator(timeZoneID: "UTC").studyDay(containing: queueNow)
    return StudyQueueEvent(commandID: command, cardID: item.card.id, noteID: item.card.noteID,
                           deckPath: path, phaseBefore: phase ?? item.schedule!.phase,
                           studyDayKey: day.key, timeZoneID: day.timeZoneID, siblingBuriedUntil: day.end, isVoided: voided)
}
private func build(_ decks: [Deck], _ cards: [StudyQueueCard], events: [StudyQueueEvent] = [],
                   session: StudyQueueSession = .init(), configuration: StudyQueueConfiguration? = nil,
                   now: Date = queueNow) throws -> StudyQueueResult {
    try QueueBuilder().build(.init(generation: queueGeneration, decks: decks, cards: cards, events: events, session: session),
                             configuration: configuration ?? config(), now: now)
}

@Test func queueParentScopeDeduplicatesAndOrdersWithoutOverbookingQuotas() throws {
    let root = try deck(), child = try deck(root.id), grandchild = try deck(child.id), other = try deck()
    let learning = entry(child.id, phase: .learning, due: queueNow)
    let relearning = entry(root.id, phase: .relearning, due: queueNow.addingTimeInterval(-1))
    let review = entry(grandchild.id, phase: .review, due: queueNow.addingTimeInterval(-100))
    let new = entry(root.id)
    let cards = [new, review, learning, relearning, new, entry(other.id), entry(child.id)]
    let cfg = try config(scope: .decks([root.id, child.id, grandchild.id]), limits: .init(new: 1, review: 1))
    let result = try build([root, child, grandchild, other, root], cards, configuration: cfg)
    #expect(result.ready.prefix(3).map(\.card.id) == [relearning.card.id, learning.card.id, review.card.id])
    #expect(result.ready.count == 4)
    #expect(Set(result.ready.map(\.card.id)).count == 4)
    #expect(!result.ready.contains { $0.card.deckID == other.id })
    #expect(try build([root, child, grandchild, other], cards.reversed(), configuration: cfg).ready == result.ready)
}

@Test func queueFutureLearningNeverBecomesReadyEarlyAndReportsNextTime() throws {
    let d = try deck(), later = queueNow.addingTimeInterval(60)
    let card = entry(d.id, phase: .learning, due: later)
    let cfg = try config(limits: .init(new: 0, review: 0), sessionLimit: 0)
    let result = try build([d], [card], configuration: cfg)
    #expect(result.ready.isEmpty)
    #expect(result.futureDue?.cardID == card.card.id)
    #expect(result.futureDue?.availableAt == later)
    #expect(result.emptyReasons == [.futureOnly])
    #expect(try build([d], [card], configuration: cfg, now: later.addingTimeInterval(-0.001)).ready.isEmpty)
    #expect(try build([d], [card], configuration: cfg, now: later).ready == [card])
    let review = entry(d.id, phase: .review, due: later.addingTimeInterval(30))
    #expect(try build([d], [review]).futureDue?.availableAt == later.addingTimeInterval(30))
}

@Test func queueUniqueDailyQuotasSurviveAgainResetMoveAndUndo() throws {
    let root = try deck(), child = try deck(root.id), other = try deck()
    let original = entry(child.id), review = entry(child.id, phase: .review, due: queueNow)
    let newEvent = try event(original, path: [child.id, root.id])
    let reviewEvent = try event(review, path: [child.id, root.id])
    let againEvent = try event(review, path: [child.id, root.id], phase: .relearning)
    let cfg = try config(limits: .init(new: 2, review: 2), siblings: .allow)
    let nextNew = entry(other.id), nextReview = entry(other.id, phase: .review, due: queueNow)
    let events = [newEvent, newEvent, reviewEvent, againEvent, againEvent]
    let result = try build([root, child, other], [nextNew, nextReview], events: events, configuration: cfg)
    #expect(result.ready.count == 2) // Unique review consumed once, repeated Again consumed none.
    let full = try config(limits: .init(new: 1, review: 1), siblings: .allow)
    let blocked = try build([root, child, other], [nextNew, nextReview], events: events, configuration: full)
    #expect(blocked.emptyReasons == [.dailyLimit])
    // Reset same identity/new epoch and moving decks cannot release its already consumed slot.
    let reset = entry(other.id, id: original.card.id, note: original.card.noteID, epoch: 9)
    #expect(try build([root, child, other], [reset, nextNew], events: events, configuration: full).ready == [reset])
    let undone = try event(original, path: [child.id, root.id], voided: true)
    #expect(try build([root, child, other], [nextNew], events: [undone], configuration: full).ready == [nextNew])
}

@Test func queueAppliesEveryAncestorAndReservesSiblingDeckBudgets() throws {
    let root = try deck(), a = try deck(root.id), b = try deck(root.id)
    let one = entry(a.id), two = entry(b.id)
    let cfg = try config(limits: .init(new: 10, review: 10), deckLimits: [root.id: .init(new: 1, review: 1)])
    #expect(try build([root, a, b], [one, two], configuration: cfg).ready.count == 1)
    let used = try event(one, path: [a.id, root.id])
    #expect(try build([root, a, b], [two], events: [used], configuration: cfg).emptyReasons == [.dailyLimit])
    let strict = try config(deckLimits: [a.id: .init(new: 0, review: 0)])
    #expect(try build([root, a, b], [one, two], configuration: strict).ready == [two])
    let moved = entry(b.id, id: one.card.id, note: one.card.noteID)
    let perDeck = try config(deckLimits: [b.id: .init(new: 0, review: 0)])
    #expect(try build([root, a, b], [moved], events: [used], configuration: perDeck).ready.isEmpty)
}

@Test func queueSessionCountsUniqueCardsButAllowsFinishingLearningAndSkipIsExplicit() throws {
    let d = try deck(), seen = entry(d.id), next = entry(d.id)
    let learning = entry(d.id, phase: .relearning, due: queueNow)
    let cfg = try config(sessionLimit: 1)
    let session = StudyQueueSession(selectedCardIDs: [seen.card.id])
    let result = try build([d], [seen, next, learning], session: session, configuration: cfg)
    #expect(result.ready == [learning, seen])
    #expect(try build([d], [next], session: session, configuration: cfg).emptyReasons == [.sessionLimit])
    #expect(try build([d], [learning], session: .init(skippedCardIDs: [learning.card.id]), configuration: cfg).emptyReasons == [.skipped])
    #expect(try build([d], [seen, next], configuration: cfg).ready.count == 1)
}

@Test func queueSiblingsBuryAcrossScopesUntilCalendarBoundaryAndUndoRestores() throws {
    let root = try deck(), other = try deck(), note = NoteID()
    let one = entry(root.id, note: note), sibling = entry(other.id, note: note)
    let third = entry(other.id)
    #expect(try build([root, other], [one, sibling]).ready.count == 1)
    let rated = try event(one, path: [root.id])
    let cfg = try config(scope: .decks([other.id]))
    let result = try build([root, other], [sibling], events: [rated], configuration: cfg)
    #expect(result.emptyReasons == [.futureOnly])
    #expect(result.futureDue?.availableAt == rated.siblingBuriedUntil)
    #expect(try build([root, other], [sibling], events: [rated], configuration: cfg, now: rated.siblingBuriedUntil).ready == [sibling])
    #expect(try build([root, other], [sibling], events: [event(one, path: [root.id], voided: true)], configuration: cfg).ready == [sibling])
    let allow = try config(siblings: .allow)
    let ordered = try build([root, other], [sibling, third], events: [rated],
                            session: .init(lastPresentedNoteID: note), configuration: allow)
    #expect(ordered.ready.first == third)
    #expect(try build([root, other], [sibling], events: [rated], session: .init(lastPresentedNoteID: note), configuration: allow).ready == [sibling])
}

@Test func queueAvailabilityAndEmptyReasonsRemainDistinct() throws {
    let root = try deck(), deleted = try deck(root.id, deleted: true)
    let excluded = [entry(root.id, suspended: true), entry(root.id, deleted: true), entry(root.id, state: .suppressed),
                    entry(root.id, state: .orphaned), entry(root.id, noteDeleted: true), entry(root.id, templateValid: false), entry(deleted.id)]
    #expect(try build([root, deleted], excluded).emptyReasons == [.unavailable])
    #expect(try build([root], []).emptyReasons == [.noCardsInScope])
    #expect(try build([root], [entry(root.id)], configuration: config(scope: .decks([]))).emptyReasons == [.noCardsInScope])
    let buried = entry(root.id, burial: queueNow.addingTimeInterval(40))
    #expect(try build([root], [buried]).futureDue?.availableAt == queueNow.addingTimeInterval(40))
    #expect(try build([root], [buried], now: queueNow.addingTimeInterval(40)).ready == [buried])
}

@Test(arguments: [
    ("2026-03-08T07:59:59Z", "2026-03-08T08:00:00Z", 23),
    ("2026-11-01T08:59:59Z", "2026-11-01T09:00:00Z", 25)
]) func queueDailyQuotaAndSiblingBurialFollowDST(input: (String, String, Int)) throws {
    let before = ISO8601DateFormatter().date(from: input.0)!, boundary = ISO8601DateFormatter().date(from: input.1)!
    let calendar = try StudyDayCalculator(timeZoneID: "America/New_York")
    let day = try calendar.studyDay(containing: before)
    #expect(day.end.timeIntervalSince(day.start) == Double(input.2 * 3600))
    let d = try deck(), one = entry(d.id), sibling = entry(d.id, note: one.card.noteID), new = entry(d.id)
    let rated = try event(one, path: [d.id], day: day)
    let cfg = try config(limits: .init(new: 1, review: 0), calendar: calendar)
    #expect(try build([d], [new], events: [rated], configuration: cfg, now: before).emptyReasons == [.dailyLimit])
    #expect(try build([d], [new], events: [rated], configuration: cfg, now: boundary).ready == [new])
    let unrestricted = try config(calendar: calendar)
    #expect(try build([d], [sibling], events: [rated], configuration: unrestricted, now: before).futureDue?.availableAt == boundary)
    #expect(try build([d], [sibling], events: [rated], configuration: unrestricted, now: boundary).ready == [sibling])
}

@Test func queueRejectsCorruptSnapshotsInsteadOfClaimingCompletion() throws {
    let d = try deck(), item = entry(d.id)
    let missing = StudyQueueCard(card: item.card, schedule: nil)
    #expect(throws: StudyQueueError.invalidCard(item.card.id)) { try build([d], [missing]) }
    let noDue = entry(d.id, phase: .learning)
    #expect(throws: StudyQueueError.invalidCard(noDue.card.id)) { try build([d], [noDue]) }
    let nan = entry(d.id, phase: .review, due: Date(timeIntervalSince1970: .nan))
    #expect(throws: StudyQueueError.invalidCard(nan.card.id)) { try build([d], [nan]) }
    let mismatch = StudyQueueCard(card: item.card, schedule: entry(d.id).schedule)
    #expect(throws: StudyQueueError.invalidCard(item.card.id)) { try build([d], [mismatch]) }
    #expect(throws: StudyQueueError.conflictingSnapshot) { try build([d], [item, missing]) }
    #expect(throws: StudyQueueError.invalidHierarchy) { try build([deck(d.id, id: d.id)], []) }
    #expect(throws: StudyQueueError.invalidHierarchy) { try build([deck(DeckID())], []) }
    #expect(throws: StudyQueueError.invalidHierarchy) { try build([d], [entry(DeckID())]) }
    #expect(throws: StudyQueueError.invalidHierarchy) { try build([d], [], configuration: config(scope: .decks([DeckID()]))) }
    #expect(throws: StudyQueueError.invalidLimits) { try StudyQueueLimits(new: -1) }
    #expect(throws: StudyQueueError.invalidLimits) { try config(sessionLimit: -1) }
    let stale = StudyQueueSnapshot(generation: UUID(), decks: [d], cards: [item])
    #expect(throws: StudyQueueError.staleGeneration) { try QueueBuilder().build(stale, configuration: config(), now: queueNow) }
}

private struct QueueClock: CardsCore.Clock { func now() -> Date { queueNow } }
private enum QueueReadError: Error { case unavailable }
private actor ChangingQueueSource: StudyQueueSource {
    var value: StudyQueueSnapshot
    var shouldFail = false
    init(_ value: StudyQueueSnapshot) { self.value = value }
    func set(_ value: StudyQueueSnapshot) { self.value = value }
    func fail() { shouldFail = true }
    func studyQueueSnapshot() async throws -> StudyQueueSnapshot {
        if shouldFail { throw QueueReadError.unavailable }
        return value
    }
}

@Test func queueServiceRechecksFreshEligibilityAndPropagatesStorageAndGenerationErrors() async throws {
    let d = try deck(), item = entry(d.id)
    let source = ChangingQueueSource(.init(generation: queueGeneration, decks: [d], cards: [item]))
    let service = StudyQueueService(source: source, clock: QueueClock(), configuration: try config())
    #expect(try await service.next().ready == [item])
    let suspended = entry(d.id, id: item.card.id, note: item.card.noteID, suspended: true)
    await source.set(.init(generation: queueGeneration, decks: [d], cards: [suspended]))
    #expect(try await service.next().emptyReasons == [.unavailable])
    await source.set(.init(generation: UUID(), decks: [], cards: []))
    await #expect(throws: StudyQueueError.staleGeneration) { try await service.next() }
    await source.fail()
    await #expect(throws: QueueReadError.self) { try await service.next() }
}

@Test func queueHistoryValidationAndStoredDayIdentityAreExplicit() throws {
    let d = try deck(), item = entry(d.id)
    let day = try StudyDayCalculator(timeZoneID: "UTC").studyDay(containing: queueNow)
    let emptyPath = try event(item, path: [])
    #expect(throws: StudyQueueError.invalidHistory) { try build([d], [item], events: [emptyPath]) }
    let cyclicPath = try event(item, path: [d.id, d.id])
    #expect(throws: StudyQueueError.invalidHistory) { try build([d], [item], events: [cyclicPath]) }
    let command = CommandID()
    #expect(throws: StudyQueueError.conflictingSnapshot) {
        try build([d], [item], events: [event(item, path: [d.id], command: command),
                                       event(item, path: [d.id], voided: true, command: command)])
    }
    let unknownZone = StudyQueueEvent(commandID: CommandID(), cardID: item.card.id, noteID: item.card.noteID,
        deckPath: [d.id], phaseBefore: .new, studyDayKey: day.key, timeZoneID: "Invalid/Zone", siblingBuriedUntil: day.end)
    #expect(throws: StudyQueueError.invalidHistory) { try build([d], [item], events: [unknownZone]) }
    let cfg = try config(limits: .init(new: 1, review: 0), siblings: .allow)
    let next = entry(d.id)
    let historicalDay = try StudyDayCalculator(timeZoneID: "UTC").studyDay(containing: day.start.addingTimeInterval(-1))
    #expect(try build([d], [next], events: [event(item, path: [d.id], day: historicalDay)], configuration: cfg).ready == [next])
    // Persisted timezone is not reinterpreted through the current calendar.
    let otherZone = try StudyDayCalculator(timeZoneID: "Europe/Moscow").studyDay(containing: queueNow)
    #expect(try build([d], [next], events: [event(item, path: [d.id], day: otherZone)], configuration: cfg).ready == [next])
    #expect(throws: StudyQueueError.invalidHierarchy) { try build([d], [], configuration: config(deckLimits: [DeckID(): .standard])) }
    let badVersion = StudyQueueCard(card: item.card,
        schedule: .init(schemaVersion: 2, cardID: item.card.id, parameterSetID: queueParameters))
    #expect(throws: StudyQueueError.invalidCard(item.card.id)) { try build([d], [badVersion]) }
}
