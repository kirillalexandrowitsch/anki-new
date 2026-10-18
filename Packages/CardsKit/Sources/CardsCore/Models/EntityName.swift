import Foundation

/// Display text is trimmed NFC. Uniqueness uses NFC + locale-independent case folding.
/// Callers supply only active siblings (decks) or the collection's active tags.
public struct EntityName: Hashable, Codable, Sendable {
    public let displayValue: String
    public let normalizedValue: String

    public init(_ input: String) throws {
        let display = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !display.isEmpty else { throw ValidationError.emptyName }
        displayValue = display
        normalizedValue = display.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    /// Exclude the entity being renamed before checking its peers.
    public func validateUniqueness(among peers: [Self]) throws {
        guard !peers.contains(where: { $0.normalizedValue == normalizedValue }) else {
            throw ValidationError.duplicateName(normalized: normalizedValue)
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(displayValue)
    }
}
