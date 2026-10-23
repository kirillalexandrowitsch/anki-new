import Foundation

public enum Grade: Int, CaseIterable, Codable, Sendable {
    case again = 1, hard = 2, good = 3, easy = 4
}

public enum SchedulePhase: String, CaseIterable, Codable, Sendable {
    case new, learning, review, relearning
}

public enum CardGenerationState: String, Codable, Sendable {
    case active, suppressed, orphaned
}

/// Immutable transfer values. Persistence records and editor drafts are separate types.
public struct Deck: Equatable, Codable, Sendable, Identifiable {
    public let id: DeckID
    public let parentID: DeckID?
    public let name: EntityName
    public let description: String
    public let iconKey: String
    public let colorKey: String
    public let isFavorite: Bool
    public let revision: Revision
    public let deletedAt: Date?

    public init(id: DeckID, parentID: DeckID? = nil, name: EntityName,
                description: String = "", iconKey: String = "rectangle.stack", colorKey: String = "accent", isFavorite: Bool = false, revision: Revision = .initial, deletedAt: Date? = nil) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.description = description
        self.iconKey = iconKey
        self.colorKey = colorKey
        self.isFavorite = isFavorite
        self.revision = revision
        self.deletedAt = deletedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, name, description, iconKey, colorKey, isFavorite, revision, deletedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(DeckID.self, forKey: .id),
                  parentID: try c.decodeIfPresent(DeckID.self, forKey: .parentID),
                  name: try c.decode(EntityName.self, forKey: .name),
                  description: try c.decode(String.self, forKey: .description),
                  iconKey: try c.decodeIfPresent(String.self, forKey: .iconKey) ?? "rectangle.stack",
                  colorKey: try c.decodeIfPresent(String.self, forKey: .colorKey) ?? "accent",
                  isFavorite: try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
                  revision: try c.decode(Revision.self, forKey: .revision),
                  deletedAt: try c.decodeIfPresent(Date.self, forKey: .deletedAt))
    }

}

public struct Note: Equatable, Codable, Sendable, Identifiable {
    public let id: NoteID
    public let noteTypeID: NoteTypeID
    /// Plain text by stable field ID; rich content/attachments are introduced with the editor.
    public let fields: [String: String]
    public let contentVersion: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let revision: Revision
    public let deletedAt: Date?

    public init(id: NoteID, noteTypeID: NoteTypeID, fields: [String: String], contentVersion: Int = 1,
                createdAt: Date, updatedAt: Date, revision: Revision = .initial, deletedAt: Date? = nil) {
        self.id = id
        self.noteTypeID = noteTypeID
        self.fields = fields
        self.contentVersion = contentVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.deletedAt = deletedAt
    }
}

/// Schedule is independent: suspension, burial and deletion never become scheduling phases.
public struct Card: Equatable, Codable, Sendable, Identifiable {
    public let id: CardID
    public let noteID: NoteID
    public let deckID: DeckID
    public let variantKey: String
    public let templateID: String
    public let generationState: CardGenerationState
    public let suspended: Bool
    public let buriedUntil: Date?
    public let createdAt: Date
    public let revision: Revision
    public let deletedAt: Date?

    public init(id: CardID, noteID: NoteID, deckID: DeckID, variantKey: String, templateID: String,
                generationState: CardGenerationState = .active, suspended: Bool = false,
                buriedUntil: Date? = nil, createdAt: Date, revision: Revision = .initial, deletedAt: Date? = nil) {
        self.id = id
        self.noteID = noteID
        self.deckID = deckID
        self.variantKey = variantKey
        self.templateID = templateID
        self.generationState = generationState
        self.suspended = suspended
        self.buriedUntil = buriedUntil
        self.createdAt = createdAt
        self.revision = revision
        self.deletedAt = deletedAt
    }
}
