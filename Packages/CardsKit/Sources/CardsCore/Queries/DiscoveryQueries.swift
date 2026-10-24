import Foundation

public struct GlobalSearchSnapshot: Equatable, Sendable {
    public let generation: UUID
    public let cards: LibrarySnapshot
    public let decks: DeckSnapshot
    public init(generation: UUID, cards: LibrarySnapshot, decks: DeckSnapshot) {
        self.generation = generation; self.cards = cards; self.decks = decks
    }
}

public struct DailyWord: Equatable, Sendable {
    public let generation: UUID
    public let noteID: NoteID
    public let cardID: CardID
    public let content: BasicNoteContent
    public let hasAlternative: Bool
    public init(generation: UUID, noteID: NoteID, cardID: CardID, content: BasicNoteContent, hasAlternative: Bool) {
        self.generation = generation; self.noteID = noteID; self.cardID = cardID
        self.content = content; self.hasAlternative = hasAlternative
    }
}

public protocol DiscoveryQueryService: Sendable {
    func observeGlobalSearch(_ text: String, asOf: EpochMilliseconds) async throws -> QueryObservation<GlobalSearchSnapshot>
    func observeDailyWord(day: Int, excluding: NoteID?) async throws -> QueryObservation<DailyWord?>
}

public enum DailyWordDay {
    /// Local calendar day, refreshed on foreground and heartbeat, independent of study quotas.
    public static func number(at date: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return Int(floor((utc.date(from: components) ?? date).timeIntervalSince1970 / 86_400))
    }
}
