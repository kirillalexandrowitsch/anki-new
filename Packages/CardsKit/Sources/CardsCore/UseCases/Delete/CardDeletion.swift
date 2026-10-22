import Foundation

/// Confirmation applies to exactly this Card and Note revision, never all Note variants.
public struct CardDeletionTarget: Equatable, Codable, Sendable, Identifiable {
    public let id: CardID
    public let noteID: NoteID
    public let cardRevision: Revision
    public let noteRevision: Revision
    public let front: String
    public let variantKey: String
    public let otherCardCount: Int
    public init(id: CardID, noteID: NoteID, cardRevision: Revision, noteRevision: Revision,
                front: String, variantKey: String, otherCardCount: Int) {
        self.id = id; self.noteID = noteID; self.cardRevision = cardRevision; self.noteRevision = noteRevision
        self.front = front; self.variantKey = variantKey; self.otherCardCount = otherCardCount
    }
}

public struct DeleteCardCommand: Equatable, Codable, Sendable {
    public let id: CommandID
    public let target: CardDeletionTarget
    public init(id: CommandID = CommandID(), target: CardDeletionTarget) { self.id = id; self.target = target }
}

public struct CardDeletionReceipt: Equatable, Codable, Sendable {
    public let schemaVersion = 1
    public let batchID: UUID
    public let cardID: CardID
    public init(batchID: UUID, cardID: CardID) { self.batchID = batchID; self.cardID = cardID }
}

public struct CardDeletionUndo: Equatable, Sendable, Identifiable {
    public let receipt: CardDeletionReceipt
    public let front: String
    public let remainingSeconds: Double
    public var id: UUID { receipt.batchID }
    public init(receipt: CardDeletionReceipt, front: String, remainingSeconds: Double) {
        self.receipt = receipt; self.front = front; self.remainingSeconds = remainingSeconds
    }
}

public struct UndoCardDeletionCommand: Equatable, Codable, Sendable {
    public let id: CommandID
    public let batchID: UUID
    public init(id: CommandID = CommandID(), batchID: UUID) { self.id = id; self.batchID = batchID }
}

public protocol CardDeletionService: Sendable {
    func target(cardID: CardID) async throws -> CardDeletionTarget
    func delete(_ command: DeleteCardCommand) async throws -> CardDeletionReceipt
    func pendingUndo() async throws -> [CardDeletionUndo]
    func undo(_ command: UndoCardDeletionCommand) async throws -> CardDeletionReceipt
}
