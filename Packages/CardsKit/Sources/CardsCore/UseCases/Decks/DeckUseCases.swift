import Foundation

/// Uncommitted input. Name normalization and required-name validation happen in Core.
public struct DeckInput: Equatable, Sendable {
    public var name: String
    public var description: String
    public var iconKey: String
    public var colorKey: String

    public init(name: String = "", description: String = "", iconKey: String = "rectangle.stack",
                colorKey: String = "accent") {
        self.name = name; self.description = description
        self.iconKey = iconKey; self.colorKey = colorKey
    }

    public init(deck: Deck) {
        self.init(name: deck.name.displayValue, description: deck.description,
                  iconKey: deck.iconKey, colorKey: deck.colorKey)
    }
}

public struct CreateDeck: Sendable {
    private let repository: any DeckRepository
    public init(repository: any DeckRepository) { self.repository = repository }

    public func execute(_ input: DeckInput, id: DeckID, commandID: CommandID) async throws -> Deck {
        try await repository.save(SaveDeckCommand(commandID: commandID, deckID: id, expectedRevision: nil,
            name: EntityName(input.name), description: input.description,
            iconKey: input.iconKey, colorKey: input.colorKey))
    }
}

public struct UpdateDeck: Sendable {
    private let repository: any DeckRepository
    public init(repository: any DeckRepository) { self.repository = repository }

    public func execute(_ input: DeckInput, original: Deck, commandID: CommandID) async throws -> Deck {
        try await repository.save(SaveDeckCommand(commandID: commandID, deckID: original.id,
            expectedRevision: original.revision, parentID: original.parentID,
            name: EntityName(input.name), description: input.description,
            iconKey: input.iconKey, colorKey: input.colorKey))
    }
}

/// Generation-scoped ports; no database or platform implementation crosses this boundary.
public struct DeckWorkspace: Sendable {
    public let generation: UUID
    public let repository: any DeckRepository
    public let queries: any CollectionQueryService
    public init(generation: UUID, repository: any DeckRepository, queries: any CollectionQueryService) {
        self.generation = generation; self.repository = repository; self.queries = queries
    }
}

public protocol DeckWorkspaceAccess: CollectionAccess {
    func deckWorkspace(generation: UUID) async throws -> DeckWorkspace
}
