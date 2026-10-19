import CardsCore
import FSRS

/// Verified initial profile shared by persistence and the domain adapter.
/// Keep library types inside Infrastructure; never rely on FSRS's v5 defaults.
enum FSRS6Configuration {
    static func parameters(id: SchedulerParameterSetID) -> SchedulerParameterSet {
        let p = makeScheduler().parameters
        return SchedulerParameterSet(id: id, weights: p.w, desiredRetention: p.requestRetention,
                                     maximumIntervalDays: Int(p.maximumInterval),
                                     learningPolicy: LearningPolicy(learningSteps: p.learningSteps,
                                                                    relearningSteps: p.relearningSteps))
    }
    static func makeScheduler() -> FSRS {
        FSRS(parameters: FSRSParameters(
            requestRetention: 0.9,
            maximumInterval: 36_500,
            w: [
                0.212, 1.2931, 2.3065, 8.2956, 6.4133,
                0.8334, 3.0194, 0.001, 1.8722, 0.1666,
                0.796, 1.4835, 0.0614, 0.2629, 1.6483,
                0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
            ],
            enableFuzz: false,
            enableShortTerm: true,
            learningSteps: ["1m", "10m"],
            relearningSteps: ["10m"]
        ))
    }
}
