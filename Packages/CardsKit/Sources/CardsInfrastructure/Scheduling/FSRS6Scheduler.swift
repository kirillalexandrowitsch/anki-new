import CardsCore
import Foundation
import FSRS
import struct FSRS.Card

/// No retained mutable upstream scheduler, clock, persistence, or UI dependency.
public struct FSRS6Scheduler: Scheduler {
    public static let adapterVersion = "fsrs6-steps-v1"
    public static let upstreamRevision = "4fbaf20184d62f82a9f44f343337c61a2c5483e9"

    public init() {}

    public static func defaultParameters(id: SchedulerParameterSetID) -> SchedulerParameterSet {
        FSRS6Configuration.parameters(id: id)
    }

    public func preview(_ input: SchedulingInput) throws -> RatingOptions {
        let scheduler = try validatedScheduler(input)
        return try RatingOptions(
            again: calculate(input, grade: .again, scheduler: scheduler),
            hard: calculate(input, grade: .hard, scheduler: scheduler),
            good: calculate(input, grade: .good, scheduler: scheduler),
            easy: calculate(input, grade: .easy, scheduler: scheduler))
    }

    public func apply(_ input: SchedulingInput, grade: Grade) throws -> SchedulingResult {
        try calculate(input, grade: grade, scheduler: validatedScheduler(input))
    }

    private func validatedScheduler(_ input: SchedulingInput) throws -> FSRS {
        let p = input.parameters
        let s = input.schedule
        guard p.schemaVersion == 1, p.algorithmVersion == "6", p.learningPolicy.schemaVersion == 1,
              s.schemaVersion == 1, s.algorithmID == "fsrs", s.algorithmVersion == "6" else {
            throw SchedulingError.unsupportedVersion
        }
        guard p.weights.count == 21, p.weights.allSatisfy(\.isFinite),
              p.desiredRetention.isFinite, (0.01...0.99).contains(p.desiredRetention),
              (1...36_500).contains(p.maximumIntervalDays),
              !p.learningPolicy.enableFuzz, p.learningPolicy.enableShortTerm,
              validSteps(p.learningPolicy.learningSteps), validSteps(p.learningPolicy.relearningSteps) else {
            throw SchedulingError.invalidParameters
        }
        // Reject values that the dependency would silently migrate/clamp. Metadata must
        // describe the exact weights used, including the dynamic relearning ceiling.
        let scheduler = FSRS(parameters: FSRSParameters(
            requestRetention: p.desiredRetention, maximumInterval: Double(p.maximumIntervalDays),
            w: p.weights, enableFuzz: false, enableShortTerm: true,
            learningSteps: p.learningPolicy.learningSteps, relearningSteps: p.learningPolicy.relearningSteps))
        guard scheduler.version == .v6, scheduler.parameters.w == p.weights else {
            throw SchedulingError.invalidParameters
        }
        guard validDate(input.nowUTC), s.dueAt.map(validDate) ?? true,
              s.lastReviewAt.map(validDate) ?? true else { throw SchedulingError.invalidTime }
        if let last = s.lastReviewAt, input.nowUTC < last { throw SchedulingError.invalidTime }
        guard s.repetitions >= 0, s.lapses >= 0, s.lapses <= s.repetitions, s.scheduleEpoch >= 0 else {
            throw SchedulingError.invalidSnapshot
        }
        guard s.repetitions < Int.max, s.lapses < Int.max, s.revision.rawValue < Int64.max else {
            throw SchedulingError.counterOverflow
        }
        if s.phase == .new {
            guard s.stability == nil, s.difficulty == nil, s.lastReviewAt == nil,
                  s.repetitions == 0, s.lapses == 0, s.learningStep == nil else {
                throw SchedulingError.invalidSnapshot
            }
        } else {
            guard let stability = s.stability, stability.isFinite, (0.001...36_500).contains(stability),
                  let difficulty = s.difficulty, difficulty.isFinite, (1...10).contains(difficulty),
                  let due = s.dueAt, let last = s.lastReviewAt, due >= last, s.repetitions > 0 else {
                throw SchedulingError.invalidSnapshot
            }
            if s.phase == .review {
                guard s.learningStep == nil else { throw SchedulingError.invalidSnapshot }
            } else {
                let steps = s.phase == .learning ? p.learningPolicy.learningSteps : p.learningPolicy.relearningSteps
                guard let step = s.learningStep, steps.indices.contains(step),
                      s.phase != .relearning || s.lapses > 0 else { throw SchedulingError.invalidSnapshot }
            }
        }
        return scheduler
    }

    private func validSteps(_ steps: [String]) -> Bool {
        guard steps.count <= 64 else { return false }
        var previous = 0
        for step in steps {
            guard step.last == "m", let minutes = Int(step.dropLast()),
                  minutes > previous, minutes < 1440, step == "\(minutes)m" else { return false }
            previous = minutes
        }
        return true
    }

    private func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_800
    }

    private func calculate(_ input: SchedulingInput, grade: Grade, scheduler: FSRS) throws -> SchedulingResult {
        let s = input.schedule
        let card = Card(due: s.dueAt ?? input.nowUTC, stability: s.stability ?? 0,
                             difficulty: s.difficulty ?? 0, learningSteps: s.learningStep ?? 0,
                             reps: s.repetitions, lapses: s.lapses, state: state(s.phase), lastReview: s.lastReviewAt)
        let item: RecordLogItem
        do { item = try scheduler.next(card: card, now: input.nowUTC, grade: rating(grade)) }
        catch { throw SchedulingError.calculationFailed }
        let next = item.card
        guard next.stability.isFinite, (0.001...36_500).contains(next.stability),
              next.difficulty.isFinite, (1...10).contains(next.difficulty),
              next.elapsedDays.isFinite, (0...3_652_059).contains(next.elapsedDays),
              next.scheduledDays.isFinite, (0...36_502).contains(next.scheduledDays),
              next.elapsedDays.rounded() == next.elapsedDays,
              next.scheduledDays.rounded() == next.scheduledDays,
              next.reps == s.repetitions + 1,
              next.lapses == s.lapses + (s.phase == .review && grade == .again ? 1 : 0),
              next.lastReview == input.nowUTC, next.state != .new else {
            throw SchedulingError.calculationFailed
        }
        let days = min(Int(next.scheduledDays), input.parameters.maximumIntervalDays)
        let due = next.state == .review ? input.nowUTC.addingTimeInterval(Double(days) * 86_400) : next.due
        guard validDate(due), due > input.nowUTC else { throw SchedulingError.invalidTime }
        let after = CardScheduleSnapshot(
            cardID: s.cardID, parameterSetID: input.parameters.id, phase: phase(next.state),
            stability: next.stability, difficulty: next.difficulty, dueAt: due, lastReviewAt: input.nowUTC,
            repetitions: next.reps, lapses: next.lapses,
            learningStep: next.state == .review ? nil : next.learningSteps,
            scheduleEpoch: s.scheduleEpoch, revision: try s.revision.advanced())
        return SchedulingResult(before: s, after: after, metadata: SchedulingMetadata(
            schemaVersion: 1, adapterVersion: Self.adapterVersion, upstreamRevision: Self.upstreamRevision,
            parameters: input.parameters, nowUTC: input.nowUTC, seed: input.seed, grade: grade,
            elapsedDays: try SchedulerIntervalDays(Int(next.elapsedDays)), scheduledDays: try SchedulerIntervalDays(days)))
    }

    private func rating(_ grade: Grade) -> Rating {
        switch grade {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        }
    }

    private func state(_ phase: SchedulePhase) -> CardState {
        switch phase {
        case .new: .new
        case .learning: .learning
        case .review: .review
        case .relearning: .relearning
        }
    }

    private func phase(_ state: CardState) -> SchedulePhase {
        switch state {
        case .new: .new
        case .learning: .learning
        case .review: .review
        case .relearning: .relearning
        }
    }
}
