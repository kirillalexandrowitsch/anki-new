import CardsCore
import Foundation
import GRDB

/// Callback state is independent of the returned sequence. The writer never retains its consumer.
final class QueryObservationState<Value: Sendable>: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var failure: (any Error)?
    private nonisolated(unsafe) var token: (any DatabaseCancellable)?
    private let continuation: AsyncThrowingStream<Value, any Error>.Continuation

    init(continuation: AsyncThrowingStream<Value, any Error>.Continuation) {
        self.continuation = continuation
    }
    func install(_ token: any DatabaseCancellable) {
        let ended = lock.withLock {
            if failure != nil { return true }
            self.token = token
            return false
        }
        if ended { token.cancel() }
    }
    func validate() throws {
        if let failure = lock.withLock({ failure }) { throw failure }
        if Task.isCancelled { throw CollectionRepositoryError.cancelled }
    }
    func yield(_ value: Value) {
        guard lock.withLock({ failure == nil }) else { return }
        continuation.yield(value)
    }
    func stop(_ error: any Error) {
        let retired: (any DatabaseCancellable)? = lock.withLock {
            guard failure == nil else { return nil }
            failure = error
            let retired = token
            token = nil
            return retired
        }
        retired?.cancel()
        continuation.finish(throwing: error)
    }
}
