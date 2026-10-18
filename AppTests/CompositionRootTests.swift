import CardsCore
import Foundation
import XCTest
@testable import AnkiNew

final class CompositionRootTests: XCTestCase {
    @MainActor func testRootInjectsServicesAndCreatesIndependentWindowModels() {
        struct FixedClock: CardsCore.Clock {
            func now() -> Date { Date(timeIntervalSince1970: 123) }
        }
        let root = CompositionRoot(clock: FixedClock())
        let first = root.makeShellModel()
        let second = root.makeShellModel()
        XCTAssertEqual(first.currentDate, Date(timeIntervalSince1970: 123))
        first.selection = .decks
        XCTAssertEqual(second.selection, .today)
    }
}
