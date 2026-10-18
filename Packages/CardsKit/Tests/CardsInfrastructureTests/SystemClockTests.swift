import CardsInfrastructure
import Foundation
import Testing

@Test func systemClockReturnsCurrentWallTime() {
    let before = Date()
    let date = SystemClock().now()
    let after = Date()
    #expect(date >= before && date <= after)
}
