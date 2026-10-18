import Foundation

/// The phantom tag prevents accidentally passing a NoteID where a CardID is required.
public struct EntityID<Tag>: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public init(uuidString: String) throws {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw ValidationError.invalidUUID(uuidString)
        }
        self.init(uuid)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(uuidString: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }
}

public enum CollectionIdentity: Sendable {}
public enum DeckIdentity: Sendable {}
public enum NoteIdentity: Sendable {}
public enum CardIdentity: Sendable {}
public enum NoteTypeIdentity: Sendable {}
public enum PresetIdentity: Sendable {}
public enum CommandIdentity: Sendable {}
public enum SessionIdentity: Sendable {}
public enum TagIdentity: Sendable {}
public enum MediaIdentity: Sendable {}

public typealias CollectionID = EntityID<CollectionIdentity>
public typealias DeckID = EntityID<DeckIdentity>
public typealias NoteID = EntityID<NoteIdentity>
public typealias CardID = EntityID<CardIdentity>
public typealias NoteTypeID = EntityID<NoteTypeIdentity>
public typealias PresetID = EntityID<PresetIdentity>
public typealias CommandID = EntityID<CommandIdentity>
public typealias SessionID = EntityID<SessionIdentity>
public typealias TagID = EntityID<TagIdentity>
public typealias MediaID = EntityID<MediaIdentity>

public struct Revision: Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int64
    public static let initial = Revision(unchecked: 0)

    private init(unchecked value: Int64) { rawValue = value }

    public init(_ value: Int64) throws {
        guard value >= 0 else { throw ValidationError.outOfRange(field: "revision") }
        self.init(unchecked: value)
    }

    public func advanced() throws -> Self {
        let (next, overflow) = rawValue.addingReportingOverflow(1)
        guard !overflow else { throw ValidationError.arithmeticOverflow }
        return try Self(next)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Int64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
