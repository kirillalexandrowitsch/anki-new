import Foundation

public struct QueueBuilder: Sendable {
    public init() {}

    public func build(_ snapshot: StudyQueueSnapshot, configuration: StudyQueueConfiguration,
                      now: Date) throws -> StudyQueueResult {
        guard snapshot.generation == configuration.generation else { throw StudyQueueError.staleGeneration }
        let day = try configuration.calendar.studyDay(containing: now)
        let decks = try unique(snapshot.decks, id: \.id)
        var paths: [DeckID: [DeckID]] = [:]
        for id in decks.keys {
            var path: [DeckID] = [], cursor: DeckID? = id
            while let current = cursor {
                guard !path.contains(current), let deck = decks[current] else { throw StudyQueueError.invalidHierarchy }
                path.append(current); cursor = deck.parentID
            }
            paths[id] = path
        }
        if case let .decks(roots) = configuration.scope, !roots.isSubset(of: Set(decks.keys)) {
            throw StudyQueueError.invalidHierarchy
        }
        guard Set(configuration.deckLimits.keys).isSubset(of: Set(decks.keys)) else {
            throw StudyQueueError.invalidHierarchy
        }
        let events = try unique(snapshot.events, id: \.commandID).values.filter { !$0.isVoided }
        var newUsage: [Bucket: Set<CardID>] = [:], reviewUsage: [Bucket: Set<CardID>] = [:]
        var siblingBurials: [NoteID: [CardID: Date]] = [:]
        for event in events {
            guard !event.deckPath.isEmpty, Set(event.deckPath).count == event.deckPath.count,
                  validDate(event.siblingBuriedUntil), TimeZone(identifier: event.timeZoneID) != nil else {
                throw StudyQueueError.invalidHistory
            }
            if event.siblingBuriedUntil > now {
                let previous = siblingBurials[event.noteID, default: [:]][event.cardID] ?? now
                siblingBurials[event.noteID, default: [:]][event.cardID] = max(previous, event.siblingBuriedUntil)
            }
            guard event.studyDayKey == day.key, event.timeZoneID == day.timeZoneID else { continue }
            let buckets: [Bucket] = [.collection] + event.deckPath.map { .deck($0) }
            for bucket in buckets {
                if event.phaseBefore == .new { newUsage[bucket, default: []].insert(event.cardID) }
                if event.phaseBefore == .review { reviewUsage[bucket, default: []].insert(event.cardID) }
            }
        }
        let cards = try unique(snapshot.cards, id: \.card.id).values
        var candidates: [(item: StudyQueueCard, availableAt: Date)] = []
        var reasons: Set<StudyQueueEmptyReason> = [], scopedCount = 0
        for item in cards {
            let card = item.card
            guard let path = paths[card.deckID] else { throw StudyQueueError.invalidHierarchy }
            if case let .decks(roots) = configuration.scope, roots.isDisjoint(with: path) { continue }
            scopedCount += 1
            guard path.allSatisfy({ decks[$0]?.deletedAt == nil }), card.deletedAt == nil,
                  !item.noteIsDeleted, item.templateIsValid, card.generationState == .active,
                  !card.suspended else { reasons.insert(.unavailable); continue }
            guard validDate(card.createdAt), card.buriedUntil.map(validDate) ?? true,
                  let schedule = item.schedule, schedule.cardID == card.id, schedule.schemaVersion == 1,
                  schedule.dueAt.map(validDate) ?? (schedule.phase == .new) else {
                throw StudyQueueError.invalidCard(card.id)
            }
            if snapshot.session.skippedCardIDs.contains(card.id) { reasons.insert(.skipped); continue }
            var availableAt = schedule.phase == .new ? now : schedule.dueAt!
            if let burial = card.buriedUntil { availableAt = max(availableAt, burial) }
            if configuration.siblingPolicy == .buryUntilNextStudyDay {
                for (sourceID, until) in siblingBurials[card.noteID, default: [:]] where sourceID != card.id {
                    availableAt = max(availableAt, until)
                }
            }
            candidates.append((item, availableAt))
        }
        candidates.sort { lhs, rhs in
            let lReady = lhs.availableAt <= now, rReady = rhs.availableAt <= now
            if lReady != rReady { return lReady }
            let lp = priority(lhs.item.schedule!.phase), rp = priority(rhs.item.schedule!.phase)
            if lp != rp { return lp < rp }
            // Burial gates eligibility; after it expires, retain the original overdue order.
            let lDue = lhs.item.schedule!.phase == .new ? now : lhs.item.schedule!.dueAt!
            let rDue = rhs.item.schedule!.phase == .new ? now : rhs.item.schedule!.dueAt!
            if lDue != rDue { return lDue < rDue }
            if lhs.item.card.createdAt != rhs.item.card.createdAt { return lhs.item.card.createdAt < rhs.item.card.createdAt }
            return lhs.item.card.id.rawValue.uuidString < rhs.item.card.id.rawValue.uuidString
        }
        var ready: [StudyQueueCard] = [], future: StudyQueueFuture?
        var selected = snapshot.session.selectedCardIDs, notes = Set<NoteID>()
        for (item, availableAt) in candidates {
            let card = item.card, phase = item.schedule!.phase
            let learning = phase == .learning || phase == .relearning
            if !learning {
                if let limit = configuration.sessionLimit, !selected.contains(card.id), selected.count >= limit {
                    reasons.insert(.sessionLimit); continue
                }
                let usage = phase == .new ? newUsage : reviewUsage
                let buckets: [(Bucket, StudyQueueLimits)] = [(.collection, configuration.dailyLimits)] +
                    paths[card.deckID]!.compactMap { id in configuration.deckLimits[id].map { (.deck(id), $0) } }
                guard buckets.allSatisfy({ bucket, limits in
                    let used = usage[bucket, default: []]
                    return used.contains(card.id) || used.count < (phase == .new ? limits.new : limits.review)
                }) else { reasons.insert(.dailyLimit); continue }
            }
            if availableAt > now {
                let value = StudyQueueFuture(cardID: card.id, availableAt: availableAt)
                if future == nil || availableAt < future!.availableAt ||
                    (availableAt == future!.availableAt && card.id.rawValue.uuidString < future!.cardID.rawValue.uuidString) {
                    future = value
                }
                continue
            }
            // A preview must not reserve both directions before the first rating buries siblings.
            if configuration.siblingPolicy == .buryUntilNextStudyDay, !notes.insert(card.noteID).inserted { continue }
            ready.append(item); selected.insert(card.id)
            if !learning {
                for bucket in [Bucket.collection] + paths[card.deckID]!.map({ .deck($0) }) {
                    if phase == .new { newUsage[bucket, default: []].insert(card.id) }
                    else { reviewUsage[bucket, default: []].insert(card.id) }
                }
            }
        }
        // Avoid an adjacent sibling when another question is ready, even from a lower priority phase.
        if let lastNote = snapshot.session.lastPresentedNoteID, ready.first?.card.noteID == lastNote,
           let alternate = ready.firstIndex(where: { $0.card.noteID != lastNote }) {
            ready.insert(ready.remove(at: alternate), at: 0)
        }
        if ready.isEmpty {
            if scopedCount == 0 { reasons.insert(.noCardsInScope) }
            if future != nil { reasons.insert(.futureOnly) }
        } else { reasons = [] }
        return StudyQueueResult(day: day, ready: ready, futureDue: future, emptyReasons: reasons)
    }

    private enum Bucket: Hashable { case collection, deck(DeckID) }
    private func priority(_ phase: SchedulePhase) -> Int {
        switch phase { case .learning, .relearning: 0; case .review: 1; case .new: 2 }
    }
    private func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (-62_135_596_800..<253_402_300_800).contains(seconds)
    }
    private func unique<T: Equatable, ID: Hashable>(_ rows: [T], id: KeyPath<T, ID>) throws -> [ID: T] {
        var result: [ID: T] = [:]
        for row in rows {
            if let previous = result[row[keyPath: id]], previous != row { throw StudyQueueError.conflictingSnapshot }
            result[row[keyPath: id]] = row
        }
        return result
    }
}
