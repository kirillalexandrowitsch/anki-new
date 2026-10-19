import Foundation
import FSRS
import Testing
@testable import CardsInfrastructure

private struct Reference: Decodable {
    let cases: [Vector]
    struct Vector: Decodable {
        let name: String
        let input: Snapshot
        let now: Double
        let outputs: [Output]
    }
    struct Output: Decodable {
        let rating: Int
        let card: Snapshot
    }
    struct Snapshot: Decodable {
        let due, stability, difficulty, elapsed_days, scheduled_days: Double
        let learning_steps, reps, lapses, state: Int
        let last_review: Double?

        var card: Card {
            Card(due: Date(timeIntervalSince1970: due), stability: stability,
                 difficulty: difficulty, elapsedDays: elapsed_days, scheduledDays: scheduled_days,
                 learningSteps: learning_steps, reps: reps, lapses: lapses,
                 state: CardState(rawValue: state)!,
                 lastReview: last_review.map { Date(timeIntervalSince1970: $0) })
        }
    }
}

@Test func fsrs6MatchesIndependentReferenceForEveryRatingAndPhase() async throws {
    let url = try #require(Bundle.module.url(forResource: "fsrs6-reference", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    let scheduler = FSRS6Configuration.makeScheduler()
    #expect(scheduler.version == .v6)
    #expect(scheduler.parameters.w.count == 21)
    #expect(scheduler.parameters.enableFuzz == false)
    #expect(reference.cases.count == 9)
    for vector in reference.cases {
        let input = vector.input.card
        let now = Date(timeIntervalSince1970: vector.now)
        let preview = try scheduler.repeat(card: input, now: now)
        #expect(vector.outputs.map(\.rating) == [1, 2, 3, 4])
        for output in vector.outputs {
            let grade = try #require(Rating(rawValue: output.rating))
            let item = try scheduler.next(card: input, now: now, grade: grade)
            #expect(preview[grade] == item, "preview/apply \(vector.name) \(grade)")
            let actual = item.card
            let expected = output.card.card
            #expect(abs(actual.stability - expected.stability) < 1e-7, "\(vector.name) \(grade)")
            #expect(abs(actual.difficulty - expected.difficulty) < 1e-7)
            #expect(actual.due == expected.due)
            #expect(actual.elapsedDays == expected.elapsedDays)
            #expect(actual.scheduledDays == expected.scheduledDays)
            #expect(actual.learningSteps == expected.learningSteps)
            #expect(actual.reps == expected.reps)
            #expect(actual.lapses == expected.lapses)
            #expect(actual.state == expected.state)
            #expect(actual.lastReview == expected.lastReview)
        }
    }
    // Share the immutable upstream scheduler across tasks; results must remain deterministic.
    let vector = try #require(reference.cases.first)
    let card = vector.input.card
    let now = Date(timeIntervalSince1970: vector.now)
    let expected = try scheduler.next(card: card, now: now, grade: .good)
    try await withThrowingTaskGroup(of: RecordLogItem.self) { group in
        for _ in 0..<32 {
            group.addTask { try scheduler.next(card: card, now: now, grade: .good) }
        }
        for try await result in group { #expect(result == expected) }
    }
}
