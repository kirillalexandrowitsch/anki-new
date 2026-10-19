import CardsCore
import CardsInfrastructure
import Foundation
import Testing

@Test func queueRepeatedActualFSRSAgainFinishesLearningWithoutSpendingAnotherUniqueSlot() throws {
    let now = Date(timeIntervalSince1970: 1_792_411_200)
    let generation = UUID(), deckID = DeckID(), noteID = NoteID(), cardID = CardID()
    let calendar = try StudyDayCalculator(timeZoneID: "UTC")
    let day = try calendar.studyDay(containing: now)
    let deck = Deck(id: deckID, name: try EntityName("Synthetic learning"))
    let card = Card(id: cardID, noteID: noteID, deckID: deckID, variantKey: "forward", templateID: "basic", createdAt: now)
    let otherID = CardID()
    let other = Card(id: otherID, noteID: NoteID(), deckID: deckID, variantKey: "forward", templateID: "basic", createdAt: now)
    let parameters = FSRS6Scheduler.defaultParameters(id: SchedulerParameterSetID())
    let cfg = try StudyQueueConfiguration(generation: generation, calendar: calendar,
        dailyLimits: .init(new: 1, review: 0), sessionLimit: 1)
    var schedule = CardScheduleSnapshot(cardID: cardID, parameterSetID: parameters.id)
    let untouched = StudyQueueCard(card: other, schedule: .init(cardID: otherID, parameterSetID: parameters.id))
    var events: [StudyQueueEvent] = []
    var time = now
    for grade in [Grade.again, .again, .again, .good, .good] {
        let current = StudyQueueCard(card: card, schedule: schedule)
        let snapshot = StudyQueueSnapshot(generation: generation, decks: [deck], cards: [current, untouched], events: events,
            session: .init(selectedCardIDs: [cardID]))
        let ready = try QueueBuilder().build(snapshot, configuration: cfg, now: time)
        #expect(ready.ready == [current])
        let result = try FSRS6Scheduler().apply(.init(schedule: schedule, nowUTC: time, parameters: parameters, seed: 18), grade: grade)
        events.append(.init(commandID: CommandID(), cardID: cardID, noteID: noteID, deckPath: [deckID],
            phaseBefore: schedule.phase, studyDayKey: day.key, timeZoneID: day.timeZoneID, siblingBuriedUntil: day.end))
        schedule = result.after
        let waitingSnapshot = StudyQueueSnapshot(generation: generation, decks: [deck],
            cards: [.init(card: card, schedule: schedule), untouched], events: events, session: .init(selectedCardIDs: [cardID]))
        let waiting = try QueueBuilder().build(waitingSnapshot, configuration: cfg, now: time)
        #expect(waiting.ready.isEmpty)
        if schedule.phase != .review {
            #expect(waiting.futureDue?.availableAt == schedule.dueAt)
            #expect(waiting.emptyReasons.contains(.futureOnly))
        }
        time = try #require(schedule.dueAt)
    }
    #expect(schedule.phase == .review)
    #expect(schedule.repetitions == 5)
    #expect(events.filter { $0.phaseBefore == .new }.count == 1)
}
