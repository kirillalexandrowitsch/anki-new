import Foundation

public enum RepositoryEntity: Equatable, Sendable {
    case note(NoteID)
    case media(MediaID)
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
    public let iconKey: String
    public let colorKey: String

    public init(commandID: CommandID, deckID: DeckID, expectedRevision: Revision?,
                parentID: DeckID? = nil, name: EntityName, description: String = "",
                iconKey: String = "rectangle.stack", colorKey: String = "accent") {
        self.commandID = commandID
        self.deckID = deckID
        self.expectedRevision = expectedRevision
        self.parentID = parentID
        self.name = name
        self.description = description
        self.iconKey = iconKey
        self.colorKey = colorKey
    }

    private enum CodingKeys: String, CodingKey {
        case commandID, deckID, expectedRevision, parentID, name, description, iconKey, colorKey
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(commandID: try c.decode(CommandID.self, forKey: .commandID),
                  deckID: try c.decode(DeckID.self, forKey: .deckID),
                  expectedRevision: try c.decodeIfPresent(Revision.self, forKey: .expectedRevision),
                  parentID: try c.decodeIfPresent(DeckID.self, forKey: .parentID),
                  name: try c.decode(EntityName.self, forKey: .name),
                  description: try c.decode(String.self, forKey: .description),
                  iconKey: try c.decodeIfPresent(String.self, forKey: .iconKey) ?? "rectangle.stack",
                  colorKey: try c.decodeIfPresent(String.self, forKey: .colorKey) ?? "accent")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(commandID, forKey: .commandID)
        try c.encode(deckID, forKey: .deckID)
        try c.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        // Preserve the canonical v1 request for replay of commands saved before T013.
        if iconKey != "rectangle.stack" { try c.encode(iconKey, forKey: .iconKey) }
        if colorKey != "accent" { try c.encode(colorKey, forKey: .colorKey) }
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
