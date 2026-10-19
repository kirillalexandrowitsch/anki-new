import Foundation

/// Stable IDs shared by persistence, rendering and future editors. Never localized.
public enum BasicNoteType {
    public static let id = NoteTypeID(UUID(uuidString: "00000000-0014-4000-8000-000000000001")!)
    public static let stableKey = "basic"
    public static let templateID = "basic.forward"
    public static let variantKey = "basic.forward"
    public static let fieldIDs = ["front", "back", "pronunciation", "examples", "audio", "image"]
}

public struct NoteExample: Equatable, Codable, Sendable {
    public let en: String
    public let ru: String
    public init(en: String, ru: String = "") { self.en = en; self.ru = ru }
}

public enum NoteMediaRole: String, Codable, Sendable { case audio, image }

public struct NoteMediaReference: Equatable, Codable, Sendable {
    public let mediaID: MediaID
    public let fieldID: String
    public let role: NoteMediaRole
    public let orderIndex: Int
    public init(mediaID: MediaID, fieldID: String, role: NoteMediaRole, orderIndex: Int = 0) {
        self.mediaID = mediaID; self.fieldID = fieldID; self.role = role; self.orderIndex = orderIndex
    }
}

/// Plain text only; examples and attachment slots retain structure in fieldsJSON v1.
public struct BasicNoteContent: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let front: String
    public let back: String
    public let pronunciation: String
    public let examples: [NoteExample]
    public let media: [NoteMediaReference]

    public init(front: String, back: String, pronunciation: String = "",
                examples: [NoteExample] = [], media: [NoteMediaReference] = []) {
        schemaVersion = 1
        self.front = front; self.back = back; self.pronunciation = pronunciation
        self.examples = examples; self.media = media
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ValidationError.invalidField("schemaVersion") }
        for (key, value) in [("front", front), ("back", back)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.invalidField(key)
            }
        }
        var slots = Set<String>()
        for ref in media {
            guard ref.fieldID == ref.role.rawValue, ref.orderIndex >= 0,
                  slots.insert("\(ref.fieldID):\(ref.orderIndex)").inserted else {
                throw ValidationError.invalidField("media")
            }
        }
    }
}

public struct SaveNoteCommand: Equatable, Codable, Sendable {
    public let commandID: CommandID
    public let noteID: NoteID
    public let expectedRevision: Revision?
    /// Only used to generate a missing variant; editing does not move existing Cards.
    public let initialDeckID: DeckID
    public let content: BasicNoteContent
    public let tags: [String]
    public init(commandID: CommandID, noteID: NoteID, expectedRevision: Revision?,
                initialDeckID: DeckID, content: BasicNoteContent, tags: [String] = []) {
        self.commandID = commandID; self.noteID = noteID; self.expectedRevision = expectedRevision
        self.initialDeckID = initialDeckID; self.content = content; self.tags = tags
    }
}

public struct SavedBasicNote: Equatable, Codable, Sendable {
    public let note: Note
    public let content: BasicNoteContent
    public let tags: [EntityName]
    /// Includes suppressed variants so ordinary Save cannot resurrect them.
    public let card: Card
    public init(note: Note, content: BasicNoteContent, tags: [EntityName], card: Card) {
        self.note = note; self.content = content; self.tags = tags; self.card = card
    }
}

public protocol NoteRepository: Sendable {
    func note(id: NoteID) async throws -> SavedBasicNote?
    func save(_ command: SaveNoteCommand) async throws -> SavedBasicNote
}

public struct SaveNote: Sendable {
    private let repository: any NoteRepository
    public init(repository: any NoteRepository) { self.repository = repository }
    public func execute(_ command: SaveNoteCommand) async throws -> SavedBasicNote {
        // Repository validates inside the transaction, after idempotent replay lookup.
        try await repository.save(command)
    }
}
