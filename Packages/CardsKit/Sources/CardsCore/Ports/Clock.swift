import Foundation

/// Wall-clock access is injected. Study-day rules and scheduling belong to later tasks.
public protocol Clock: Sendable {
    func now() -> Date
}
