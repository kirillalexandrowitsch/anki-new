import CardsCore
import Foundation

/// Value snapshot; opening and typing never mutate the collection.
public struct EditorDraft: Equatable, Sendable {
    public var deckID: DeckID?
    public var front = ""
    public var back = ""
    public var pronunciation = ""
    public var examples: [NoteExample] = []
    public var tags: [String] = []
    public var media: [NoteMediaReference] = []

    public init(deckID: DeckID? = nil) { self.deckID = deckID }
    public init(saved: SavedBasicNote) {
        deckID = saved.card.deckID
        front = saved.content.front; back = saved.content.back
        pronunciation = saved.content.pronunciation; examples = saved.content.examples
        media = saved.content.media; tags = saved.tags.map(\.displayValue)
    }
    public var content: BasicNoteContent {
        BasicNoteContent(front: front, back: back, pronunciation: pronunciation, examples: examples, media: media)
    }
    public var frontError: String? { front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Введите слово или фразу." : nil }
    public var backError: String? { back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Введите перевод." : nil }
    public var isValid: Bool { deckID != nil && (try? content.validate()) != nil }
}
