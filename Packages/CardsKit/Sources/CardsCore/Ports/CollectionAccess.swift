import Foundation

public struct CollectionContext: Equatable, Sendable {
    public let generation: UUID
    public let id: CollectionID
    public let name: EntityName

    public init(generation: UUID = UUID(), id: CollectionID, name: EntityName) {
        self.generation = generation
        self.id = id
        self.name = name
    }
}

public enum CollectionAccessError: Error, Equatable, Sendable {
    case locked
    case alreadyOpen
    case invalidContainer
    case unsupportedVersion
    case staleContext
    case fileSystem(Int32)
}

/// One application-owned collection. Implementations keep connections and leases private.
public protocol CollectionAccess: Sendable {
    func open() async throws -> CollectionContext
    func close(generation: UUID) async throws
}
