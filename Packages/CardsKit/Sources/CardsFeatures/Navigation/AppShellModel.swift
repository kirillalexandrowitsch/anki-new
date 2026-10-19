import CardsCore
import Foundation
import Observation

@MainActor @Observable
public final class AppShellModel {
    public var selection: MainSection = .today
    public private(set) var currentDate: Date
    private let clock: any CardsCore.Clock

    public init(clock: any CardsCore.Clock) {
        self.clock = clock
        self.currentDate = clock.now()
    }

    var studyClock: any CardsCore.Clock { clock }

    public func refreshDate() {
        currentDate = clock.now()
    }
}
