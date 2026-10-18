import CardsCore
import Foundation
import Testing

private struct FixedClock: CardsCore.Clock {
    let date: Date
    func now() -> Date { date }
}

@Test func clockCanBeImplementedWithoutPlatformOrDatabaseDependencies() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let clock: any CardsCore.Clock = FixedClock(date: date)
    #expect(clock.now() == date)
}
