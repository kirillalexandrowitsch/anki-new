import Foundation

/// Immutable confirmation snapshot. External live variants keep their shared Note alive.
public struct DeckDeletionTarget: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public struct Card: Equatable, Codable, Sendable {
        public let id: CardID
        public let revision: Revision
        public init(id: CardID, revision: Revision) { self.id = id; self.revision = revision }
    }
    public struct Note: Equatable, Codable, Sendable {
        public let id: NoteID
        public let revision: Revision
        public let externalCards: [CardID]
        public init(id: NoteID, revision: Revision, externalCards: [CardID]) {
            self.id = id; self.revision = revision; self.externalCards = externalCards
        }
    }
    public let root: Deck
    public let decks: [Deck]
    public let cards: [Card]
    public let notes: [Note]
    public var deletedNoteCount: Int { notes.filter { $0.externalCards.isEmpty }.count }
    public var sharedNoteCount: Int { notes.count - deletedNoteCount }
    public init(root: Deck, decks: [Deck], cards: [Card], notes: [Note]) {
        schemaVersion = 1; self.root = root; self.decks = decks; self.cards = cards; self.notes = notes
    }
}

public struct DeleteDeckCommand: Equatable, Codable, Sendable {
    public let id: CommandID
    public let target: DeckDeletionTarget
    public init(id: CommandID = CommandID(), target: DeckDeletionTarget) { self.id = id; self.target = target }
}

public struct DeckDeletionReceipt: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let batchID: UUID
    public let rootID: DeckID
    public init(batchID: UUID, rootID: DeckID) { schemaVersion = 1; self.batchID = batchID; self.rootID = rootID }
}

public protocol DeckDeletionService: Sendable {
    func target(deckID: DeckID) async throws -> DeckDeletionTarget
    func delete(_ command: DeleteDeckCommand) async throws -> DeckDeletionReceipt
}
