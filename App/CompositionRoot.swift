import CardsCore
import CardsFeatures
import CardsInfrastructure

/// One instance is owned by the App scene. No database or process-wide service singleton.
@MainActor
final class CompositionRoot {
    let clock: any CardsCore.Clock

    init(clock: any CardsCore.Clock = SystemClock()) {
        self.clock = clock
    }

    func makeShellModel() -> AppShellModel {
        AppShellModel(clock: clock)
    }
}
