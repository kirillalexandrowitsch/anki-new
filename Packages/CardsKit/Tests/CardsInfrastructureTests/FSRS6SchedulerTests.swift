import CardsCore
import CardsInfrastructure
import Foundation
import Testing

private let scheduler = FSRS6Scheduler()
private let parameterID = SchedulerParameterSetID(UUID(uuidString: "00000000-0014-4000-8000-000000000002")!)
private let cardID = CardID(UUID(uuidString: "00000000-0017-4000-8000-000000000001")!)
private let now = Date(timeIntervalSince1970: 1_735_732_800)

private func parameters(weights: [Double]? = nil, retention: Double = 0.9, maximum: Int = 36_500,
                        policy: LearningPolicy = LearningPolicy(), version: String = "6",
                        schema: Int = 1, id: SchedulerParameterSetID = parameterID) -> SchedulerParameterSet {
    SchedulerParameterSet(schemaVersion: schema, id: id, algorithmVersion: version,
        weights: weights ?? FSRS6Scheduler.defaultParameters(id: parameterID).weights,
        desiredRetention: retention, maximumIntervalDays: maximum, learningPolicy: policy)
}

private func input(_ s: CardScheduleSnapshot? = nil, time: Date = now,
                   p: SchedulerParameterSet = parameters(), seed: UInt64 = 17) -> SchedulingInput {
    SchedulingInput(schedule: s ?? CardScheduleSnapshot(cardID: cardID, parameterSetID: parameterID),
                    nowUTC: time, parameters: p, seed: seed)
}

private struct Oracle: Decodable {
    let cases: [Vector]
    struct Vector: Decodable {
        let name: String
        let input: Snapshot
        let now: Double
        let outputs: [Output]
    }
    struct Output: Decodable { let rating: Int; let card: Snapshot }
    struct Snapshot: Decodable {
        let due, stability, difficulty, elapsed_days, scheduled_days: Double
        let learning_steps, reps, lapses, state: Int
        let last_review: Double?

        func schedule() throws -> CardScheduleSnapshot {
            let phase = try #require([0: SchedulePhase.new, 1: .learning, 2: .review, 3: .relearning][state])
            return CardScheduleSnapshot(cardID: cardID, parameterSetID: parameterID, phase: phase,
                stability: state == 0 ? nil : stability, difficulty: state == 0 ? nil : difficulty,
                dueAt: Date(timeIntervalSince1970: due), lastReviewAt: last_review.map(Date.init(timeIntervalSince1970:)),
                repetitions: reps, lapses: lapses, learningStep: state == 1 || state == 3 ? learning_steps : nil,
                scheduleEpoch: 7, revision: try Revision(42))
        }
    }
}

@Test func schedulerAdapterMatchesIndependentOracleAllGradesAndPhases() throws {
    let url = try #require(Bundle.module.url(forResource: "fsrs6-reference", withExtension: "json", subdirectory: "Fixtures"))
    let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    #expect(oracle.cases.count == 9)
    for vector in oracle.cases {
        let original = try vector.input.schedule()
        let request = input(original, time: Date(timeIntervalSince1970: vector.now))
        let preview = try scheduler.preview(request)
        for output in vector.outputs {
            let grade = try #require(Grade(rawValue: output.rating))
            let actual = try scheduler.apply(request, grade: grade)
            let expected = try output.card.schedule()
            #expect(preview[grade] == actual, "\(vector.name) \(grade)")
            #expect(actual.before == original)
            #expect(actual.after.cardID == original.cardID)
            #expect(actual.after.scheduleEpoch == 7 && actual.after.revision.rawValue == 43)
            #expect(actual.after.parameterSetID == parameterID)
            #expect(actual.after.phase == expected.phase)
            #expect(abs(try #require(actual.after.stability) - output.card.stability) < 1e-7)
            #expect(abs(try #require(actual.after.difficulty) - output.card.difficulty) < 1e-7)
            #expect(actual.after.dueAt == expected.dueAt)
            #expect(actual.after.lastReviewAt == expected.lastReviewAt)
            #expect(actual.after.repetitions == expected.repetitions && actual.after.lapses == expected.lapses)
            #expect(actual.after.learningStep == expected.learningStep)
            #expect(actual.metadata.elapsedDays.rawValue == Int(output.card.elapsed_days))
            #expect(actual.metadata.scheduledDays.rawValue == Int(output.card.scheduled_days))
            #expect(actual.metadata.parameters == request.parameters)
            #expect(actual.metadata.seed == 17 && actual.metadata.nowUTC == request.nowUTC)
            #expect(actual.metadata.grade == grade && actual.metadata.schemaVersion == 1)
        }
    }
}

@Test func schedulerPreviewReplayConcurrencyAndVersionedRoundTrip() async throws {
    let request = input(seed: UInt64.max)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(request.schedule)
    let expected = try scheduler.preview(request)
    #expect(try scheduler.preview(request) == expected)
    #expect(try encoder.encode(request.schedule) == before)
    for grade in Grade.allCases {
        let result = expected[grade]
        let persisted = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(SchedulingResult.self, from: persisted) == result)
        #expect(result.metadata.adapterVersion == FSRS6Scheduler.adapterVersion)
        #expect(result.metadata.upstreamRevision == FSRS6Scheduler.upstreamRevision)
        let otherSeed = try scheduler.apply(input(seed: 0), grade: grade)
        #expect(otherSeed.after == result.after) // fuzz is disabled, seed is still recorded
        #expect(otherSeed.metadata.seed == 0)
    }
    try await withThrowingTaskGroup(of: RatingOptions.self) { group in
        for _ in 0..<32 { group.addTask { try scheduler.preview(request) } }
        for try await result in group { #expect(result == expected) }
    }
    var object = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
    object.removeValue(forKey: "schemaVersion")
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(CardScheduleSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private func assertStep(_ s: CardScheduleSnapshot, time: Date, grade: Grade,
                        phase: SchedulePhase, step: Int?, seconds: Double) throws -> CardScheduleSnapshot {
    let result = try scheduler.apply(input(s, time: time), grade: grade)
    #expect(result.after.phase == phase && result.after.learningStep == step)
    #expect(result.after.dueAt == time.addingTimeInterval(seconds))
    #expect(result.after.repetitions == s.repetitions + 1)
    return result.after
}

@Test func schedulerShortStepsHaveOneOwnerAndRepeatWithoutDoubleApplication() throws {
    let fresh = input().schedule
    let first = try assertStep(fresh, time: now, grade: .again, phase: .learning, step: 0, seconds: 60)
    _ = try assertStep(first, time: now.addingTimeInterval(60), grade: .hard, phase: .learning, step: 0, seconds: 360)
    let second = try assertStep(first, time: now.addingTimeInterval(60), grade: .good, phase: .learning, step: 1, seconds: 600)
    _ = try assertStep(second, time: now.addingTimeInterval(660), grade: .hard, phase: .learning, step: 1, seconds: 360)
    let reset = try assertStep(second, time: now.addingTimeInterval(660), grade: .again, phase: .learning, step: 0, seconds: 60)
    #expect(reset.lapses == 0)
    for grade in [Grade.good, .easy] {
        #expect(try scheduler.apply(input(second, time: now.addingTimeInterval(660)), grade: grade).after.phase == .review)
    }
    let review = try scheduler.apply(input(), grade: .easy).after
    let reviewTime = try #require(review.dueAt)
    let relearn = try assertStep(review, time: reviewTime, grade: .again, phase: .relearning, step: 0, seconds: 600)
    #expect(relearn.lapses == 1)
    let again = try assertStep(relearn, time: reviewTime.addingTimeInterval(600), grade: .again,
                               phase: .relearning, step: 0, seconds: 600)
    #expect(again.lapses == 1)
    _ = try assertStep(relearn, time: reviewTime.addingTimeInterval(600), grade: .hard,
                       phase: .relearning, step: 0, seconds: 900)
    for grade in [Grade.good, .easy] {
        #expect(try scheduler.apply(input(relearn, time: reviewTime.addingTimeInterval(600)), grade: grade).after.phase == .review)
    }
}

@Test func schedulerParameterChangesCustomStepsAndMaximumIntervalAreExplicit() throws {
    let newID = SchedulerParameterSetID()
    let custom = parameters(policy: LearningPolicy(learningSteps: ["2m", "20m"], relearningSteps: ["5m"]), id: newID)
    let preview = try scheduler.preview(input(p: custom))
    #expect(preview[.again].after.dueAt == now.addingTimeInterval(120))
    #expect(preview[.hard].after.dueAt == now.addingTimeInterval(660))
    #expect(preview[.good].after.dueAt == now.addingTimeInterval(1200))
    #expect(preview[.good].before.parameterSetID == parameterID && preview[.good].after.parameterSetID == newID)
    let single = try scheduler.preview(input(p: parameters(policy: LearningPolicy(learningSteps: ["3m"]))))
    #expect(single[.hard].after.dueAt == now.addingTimeInterval(300)) // 4.5m rounds to 5m
    #expect(single[.good].after.phase == .review)
    let noSteps = parameters(policy: LearningPolicy(learningSteps: [], relearningSteps: []))
    for grade in Grade.allCases {
        #expect(try scheduler.apply(input(p: noSteps), grade: grade).after.phase == .review)
    }
    let review = try scheduler.apply(input(), grade: .easy).after
    let time = try #require(review.dueAt)
    let capped = try scheduler.preview(input(review, time: time, p: parameters(maximum: 1)))
    let uncapped = try scheduler.preview(input(review, time: time))
    for grade in [Grade.hard, .good, .easy] {
        #expect(capped[grade].after.dueAt == time.addingTimeInterval(86_400))
        #expect(capped[grade].metadata.scheduledDays.rawValue == 1)
        #expect(capped[grade].after.stability == uncapped[grade].after.stability)
    }
    #expect(capped[.again].after.dueAt == time.addingTimeInterval(600))
    #expect(try scheduler.apply(input(review, time: time, p: noSteps), grade: .again).after.phase == .review)
    let changed = try scheduler.apply(input(p: parameters(retention: 0.8)), grade: .easy)
    #expect(changed.after.dueAt != preview[.easy].after.dueAt)
    #expect(changed.metadata.parameters.desiredRetention == 0.8)
}

@Test func schedulerRejectsInvalidParametersBeforeUpstreamFallbackOrClamping() throws {
    let weights = parameters().weights
    var invalid: [SchedulerParameterSet] = [
        parameters(weights: []), parameters(weights: Array(weights.prefix(19))),
        parameters(retention: .nan), parameters(retention: .infinity), parameters(retention: 0),
        parameters(retention: 1), parameters(maximum: 0), parameters(maximum: 36_501),
        parameters(policy: LearningPolicy(enableFuzz: true)),
        parameters(policy: LearningPolicy(enableShortTerm: false)),
    ]
    for i in weights.indices {
        for value in [Double.nan, .infinity, -.infinity, -1, 1e100] {
            var bad = weights
            bad[i] = value
            invalid.append(parameters(weights: bad))
        }
    }
    for steps in [["0m"], ["1h"], ["01m"], ["-1m"], ["1440m"], ["1m", "1m"], ["10m", "1m"],
                  ["999999999999999999999999999999m"], (1...65).map { "\($0)m" }] {
        invalid.append(parameters(policy: LearningPolicy(learningSteps: steps)))
        invalid.append(parameters(policy: LearningPolicy(relearningSteps: steps)))
    }
    for p in invalid {
        #expect(throws: SchedulingError.invalidParameters) { try scheduler.preview(input(p: p)) }
        #expect(throws: SchedulingError.invalidParameters) { try scheduler.apply(input(p: p), grade: .good) }
    }
    for p in [parameters(version: "5"), parameters(schema: 2), parameters(policy: LearningPolicy(schemaVersion: 2))] {
        #expect(throws: SchedulingError.unsupportedVersion) { try scheduler.preview(input(p: p)) }
    }
}

/// JSON mutations exercise actual persisted envelopes; nonconforming floats can
/// only be introduced here by an explicit decoder setting, never by production JSON.
private func changed(_ s: CardScheduleSnapshot, _ fields: [String: Any]) throws -> CardScheduleSnapshot {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
    fields.forEach { object[$0.key] = $0.value }
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    return try decoder.decode(CardScheduleSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func schedulerRejectsCorruptSnapshotsVersionsClockSkewAndOverflow() throws {
    let fresh = input().schedule
    let review = try scheduler.apply(input(), grade: .easy).after
    let learning = try scheduler.apply(input(), grade: .good).after
    let badFields: [[String: Any]] = [
        ["stability": NSNull()], ["stability": "NaN"], ["stability": "Infinity"], ["stability": 0],
        ["difficulty": NSNull()], ["difficulty": "NaN"], ["difficulty": 11],
        ["dueAt": NSNull()], ["lastReviewAt": NSNull()], ["repetitions": -1], ["repetitions": 0],
        ["lapses": -1], ["lapses": 2], ["scheduleEpoch": -1], ["learningStep": 0],
        ["dueAt": now.timeIntervalSinceReferenceDate - 1],
    ]
    for fields in badFields {
        let bad = try changed(review, fields)
        #expect(throws: SchedulingError.invalidSnapshot) { try scheduler.preview(input(bad)) }
    }
    for fields in [["learningStep": -1], ["learningStep": 2]] {
        let bad = try changed(learning, fields)
        #expect(throws: SchedulingError.invalidSnapshot) { try scheduler.preview(input(bad)) }
    }
    #expect(throws: SchedulingError.invalidSnapshot) {
        try scheduler.preview(input(learning, p: parameters(policy: LearningPolicy(learningSteps: []))))
    }
    for fields in [["stability": 0], ["difficulty": 0], ["repetitions": 1], ["learningStep": 0]] {
        let bad = try changed(fresh, fields)
        #expect(throws: SchedulingError.invalidSnapshot) { try scheduler.preview(input(bad)) }
    }
    for fields in [["schemaVersion": 2], ["algorithmID": "other"], ["algorithmVersion": "5"]] as [[String: Any]] {
        let bad = try changed(fresh, fields)
        #expect(throws: SchedulingError.unsupportedVersion) { try scheduler.preview(input(bad)) }
    }
    for field in ["repetitions", "revision"] {
        let bad = try changed(review, [field: Int64.max])
        #expect(throws: SchedulingError.counterOverflow) { try scheduler.preview(input(bad)) }
    }
    for time in [now.addingTimeInterval(-1), Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
        #expect(throws: SchedulingError.invalidTime) { try scheduler.preview(input(review, time: time)) }
    }
    #expect(throws: SchedulingError.invalidTime) {
        try scheduler.preview(input(time: Date(timeIntervalSince1970: 253_402_300_799)))
    }
    // Milliseconds are retained, and a backwards clock within one UTC day is rejected.
    let fractional = now.addingTimeInterval(0.125)
    let result = try scheduler.apply(input(time: fractional), grade: .again)
    #expect(result.after.dueAt == fractional.addingTimeInterval(60))
    #expect(throws: SchedulingError.invalidTime) { try scheduler.preview(input(result.after, time: fractional.addingTimeInterval(-0.001))) }
}
