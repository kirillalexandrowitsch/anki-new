import Foundation

/// Retain while consuming; cancel on screen close. Iterator ownership also keeps it alive.
public final class QueryObservation<Value: Sendable>: AsyncSequence, Sendable {
    public typealias Element = Value
    private let stream: AsyncThrowingStream<Value, any Error>
    private let stop: @Sendable () -> Void
    private let validate: @Sendable () throws -> Void

    public init(stream: AsyncThrowingStream<Value, any Error>, cancel: @escaping @Sendable () -> Void,
                validate: @escaping @Sendable () throws -> Void) {
        self.stream = stream; self.stop = cancel; self.validate = validate
    }
    public func cancel() { stop() }
    deinit { stop() }
    public func makeAsyncIterator() -> Iterator {
        Iterator(owner: self, iterator: stream.makeAsyncIterator())
    }
    public struct Iterator: AsyncIteratorProtocol {
        private let owner: QueryObservation
        private var iterator: AsyncThrowingStream<Value, any Error>.Iterator
        fileprivate init(owner: QueryObservation, iterator: AsyncThrowingStream<Value, any Error>.Iterator) {
            self.owner = owner; self.iterator = iterator
        }
        public mutating func next() async throws -> Value? {
            let owner = owner
            return try await withTaskCancellationHandler {
                try owner.validate()
                let value = try await iterator.next()
                try owner.validate() // reject buffered values from a retired generation
                return value
            } onCancel: { owner.cancel() }
        }
    }
}
