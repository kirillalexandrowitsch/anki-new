import CardsCore
import Foundation

public struct SystemClock: CardsCore.Clock {
    public init() {}

    public func now() -> Date { Date() }
}
