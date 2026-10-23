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

    public func execute(_ input: DeckInput, id: DeckID, commandID: CommandID, parentID: DeckID? = nil) async throws -> Deck {
        try await repository.save(SaveDeckCommand(commandID: commandID, deckID: id, expectedRevision: nil, parentID: parentID,
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

/// The repository validates hierarchy and revision atomically, including after a stale UI preview.
public struct MoveDeck: Sendable {
    private let repository: any DeckRepository
    public init(repository: any DeckRepository) { self.repository = repository }
    public func execute(_ original: Deck, to parentID: DeckID?, commandID: CommandID) async throws -> Deck {
        guard original.id != parentID else { throw CollectionRepositoryError.invalidHierarchy }
        return try await repository.save(SaveDeckCommand(commandID: commandID, deckID: original.id,
            expectedRevision: original.revision, parentID: parentID, name: original.name,
            description: original.description, iconKey: original.iconKey, colorKey: original.colorKey))
    }
}

public struct SetDeckFavorite: Sendable {
    private let repository: any DeckRepository
    public init(repository: any DeckRepository) { self.repository = repository }
    public func execute(_ original: Deck, favorite: Bool, commandID: CommandID) async throws -> Deck {
        try await repository.save(SaveDeckCommand(commandID: commandID, deckID: original.id,
            expectedRevision: original.revision, parentID: original.parentID, name: original.name,
            description: original.description, iconKey: original.iconKey, colorKey: original.colorKey,
            favorite: favorite))
    }
}

/// A complete query forest; parent paths also provide unambiguous labels for duplicate leaf names.
public struct DeckHierarchy: Sendable {
    public let rows: [DeckQueryRow]
    private let byID: [DeckID: DeckQueryRow]
    private let groups: [DeckID?: [DeckQueryRow]]
    public init(rows: [DeckQueryRow]) {
        self.rows = rows
        self.byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        self.groups = Dictionary(grouping: rows, by: \.deck.parentID)
    }
    public func ancestors(of id: DeckID) -> [DeckQueryRow] {
        var path: [DeckQueryRow] = []
        var seen: Set<DeckID> = [id]
        var parent = byID[id]?.deck.parentID
        while let id = parent, seen.insert(id).inserted, let row = byID[id] {
            path.insert(row, at: 0)
            parent = row.deck.parentID
        }
        return path
    }
    public func path(_ id: DeckID) -> String {
        (ancestors(of: id) + (byID[id].map { [$0] } ?? [])).map(\.deck.name.displayValue).joined(separator: " / ")
    }
    public func canMove(_ id: DeckID, to parent: DeckID) -> Bool {
        byID[parent] != nil && id != parent && !ancestors(of: parent).contains { $0.id == id }
    }
    public func children(of parent: DeckID?) -> [DeckQueryRow] { groups[parent] ?? [] }
    public func visible(expanded: Set<DeckID>) -> [DeckQueryRow] {
        // Iterative traversal avoids recursion limits for deeply nested collections.
        var pending = Array((groups[nil] ?? []).reversed())
        var result: [DeckQueryRow] = []
        var seen: Set<DeckID> = []
        while let row = pending.popLast() {
            guard seen.insert(row.id).inserted else { continue }
            result.append(row)
            if expanded.contains(row.id) { pending.append(contentsOf: (groups[row.id] ?? []).reversed()) }
        }
        return result
    }
}
