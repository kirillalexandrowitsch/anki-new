import Foundation

public enum RepositoryEntity: Equatable, Sendable {
    case deck(DeckID)
    case collection(CollectionID)
}

/// Recoverable business failures and sanitized technical codes, never a database connection/error.
public enum CollectionRepositoryError: Error, Equatable, Sendable {
    case notFound(RepositoryEntity)
    case alreadyExists(RepositoryEntity)
    case revisionConflict(entity: RepositoryEntity, expected: Revision, actual: Revision)
    case validation(ValidationError)
    case invalidHierarchy
    case commandIDReused
    case unsupportedCommandResult
    case staleContext
    case cancelled
    case integrityFailure
    case insufficientSpace
    case permissionDenied
    case storage(code: Int32)
}

public struct SaveDeckCommand: Equatable, Codable, Sendable {
    public let commandID: CommandID
    public let deckID: DeckID
    /// nil creates a new ID; a value updates exactly that revision.
    public let expectedRevision: Revision?
    public let parentID: DeckID?
    public let name: EntityName
    public let description: String

    public init(commandID: CommandID, deckID: DeckID, expectedRevision: Revision?,
                parentID: DeckID? = nil, name: EntityName, description: String = "") {
        self.commandID = commandID
        self.deckID = deckID
        self.expectedRevision = expectedRevision
        self.parentID = parentID
        self.name = name
        self.description = description
    }
}

public protocol DeckRepository: Sendable {
    func deck(id: DeckID) async throws -> Deck?
    func save(_ command: SaveDeckCommand) async throws -> Deck
}

public struct CollectionInfo: Equatable, Codable, Sendable {
    public let id: CollectionID
    public let name: EntityName
    public let revision: Revision

    public init(id: CollectionID, name: EntityName, revision: Revision) {
        self.id = id
        self.name = name
        self.revision = revision
    }
}

public struct RenameCollectionCommand: Equatable, Codable, Sendable {
    public let commandID: CommandID
    public let expectedRevision: Revision
    public let name: EntityName

    public init(commandID: CommandID, expectedRevision: Revision, name: EntityName) {
        self.commandID = commandID
        self.expectedRevision = expectedRevision
        self.name = name
    }
}

public protocol CollectionInfoRepository: Sendable {
    func info() async throws -> CollectionInfo
    func rename(_ command: RenameCollectionCommand) async throws -> CollectionInfo
}
