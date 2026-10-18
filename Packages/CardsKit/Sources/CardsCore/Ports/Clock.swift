import Foundation

/// Injected wall time for scheduling and calendar boundaries. Elapsed active time
/// must use a monotonic source (e.g. Swift.ContinuousClock), never subtract wall dates.
public protocol Clock: Sendable {
    func now() -> Date
}
