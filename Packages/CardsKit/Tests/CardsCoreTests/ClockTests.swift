import CardsCore
import CardsTestSupport
import Foundation
import Testing

@Test func clockCanBeImplementedWithoutPlatformOrDatabaseDependencies() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let clock: any CardsCore.Clock = TestClock(date: date)
    #expect(clock.now() == date)
}

@Test func testClockMovesOnlyWhenExplicitlyAdvanced() {
    let clock = TestClock()
    let initial = clock.now()
    clock.advance(by: 86_400)
    #expect(clock.now() == initial.addingTimeInterval(86_400))
    clock.set(initial)
    #expect(clock.now() == initial)
}
