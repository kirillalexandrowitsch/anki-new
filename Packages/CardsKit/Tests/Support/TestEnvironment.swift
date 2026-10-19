import CardsCore
import Foundation

/// Synchronous, thread-safe wall clock. Advance explicitly; no sleeps or real time.
public final class TestClock: CardsCore.Clock {
    private let lock = NSLock()
    private nonisolated(unsafe) var date: Date

    public init(date: Date = Date(timeIntervalSince1970: 1_792_368_000)) { self.date = date }
    public func now() -> Date { lock.withLock { date } }
    public func advance(by seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    public func set(_ date: Date) { lock.withLock { self.date = date } }
}

/// A new private directory for every instance, including concurrently running tests.
/// The seed determines content, never the directory name. No Application Support lookup.
public final class TestDirectory: Sendable {
    public let url: URL

    public init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("anki-new-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

public enum InjectedFault: Error, Equatable { case triggered }

/// Adapts existing internal migration/media/backup hooks; production API stays unchanged.
/// The Nth matching checkpoint throws once. Other checkpoints are counted too.
public final class FaultProbe<Point: Equatable & Sendable>: Sendable {
    private let lock = NSLock()
    private let target: Point
    private let occurrence: Int
    private nonisolated(unsafe) var matches = 0
    private nonisolated(unsafe) var visited: [Point] = []

    public init(at target: Point, occurrence: Int = 1) {
        precondition(occurrence > 0)
        self.target = target
        self.occurrence = occurrence
    }
    public var checkpoints: [Point] { lock.withLock { visited } }
    public func hit(_ point: Point) throws {
        try lock.withLock {
            visited.append(point)
            if point == target {
                matches += 1
                if matches == occurrence { throw InjectedFault.triggered }
            }
        }
    }
}
