import Foundation

public enum CollectionQueryError: Error, Equatable, Sendable {
    case invalidPage
    case searchTooLong
}

public struct QueryPage: Equatable, Sendable {
    public let offset: Int
    public let limit: Int
    public init(offset: Int = 0, limit: Int = 100) throws {
        guard offset >= 0, (1...100).contains(limit) else { throw CollectionQueryError.invalidPage }
        self.offset = offset
        self.limit = limit
    }
    public static let first = try! QueryPage()
}

public enum LibrarySort: String, CaseIterable, Sendable {
    case updatedNewest, updatedOldest, frontAscending, frontDescending, newFirst, studiedFirst
}

public struct CardQueryFilter: Equatable, Sendable {
    public let search: String
    public let deckID: DeckID?
    public let includeDescendants: Bool
    public let noteTypeID: NoteTypeID?
    public let tagID: TagID?
    public let phase: SchedulePhase?
    public let suspended: Bool?
    public init(search: String = "", deckID: DeckID? = nil, includeDescendants: Bool = false,
                noteTypeID: NoteTypeID? = nil, tagID: TagID? = nil,
                phase: SchedulePhase? = nil, suspended: Bool? = nil) throws {
        guard search.count <= 512 else { throw CollectionQueryError.searchTooLong }
        self.search = search
        self.deckID = deckID
        self.includeDescendants = includeDescendants
        self.noteTypeID = noteTypeID
        self.tagID = tagID
        self.phase = phase
        self.suspended = suspended
    }
    public static let all = try! CardQueryFilter()
}

public struct LibraryQuery: Equatable, Sendable {
    public let filter: CardQueryFilter
    public let sort: LibrarySort
    public let page: QueryPage
    public init(filter: CardQueryFilter = .all, sort: LibrarySort = .updatedNewest, page: QueryPage = .first) {
        self.filter = filter
        self.sort = sort
        self.page = page
    }
}

public struct CardCounts: Equatable, Sendable {
    public let cards: Int
    public let notes: Int
    public let new: Int
    public let learning: Int
    public let review: Int
    public let suspended: Int
    public let buried: Int
    public let availableNew: Int
    public let due: Int
    public init(cards: Int, notes: Int, new: Int, learning: Int, review: Int, suspended: Int,
                buried: Int, availableNew: Int, due: Int) {
        self.cards = cards; self.notes = notes; self.new = new; self.learning = learning
        self.review = review; self.suspended = suspended; self.buried = buried
        self.availableNew = availableNew; self.due = due
    }
}

public struct LibraryRow: Equatable, Sendable, Identifiable {
    public let id: CardID
    public let noteID: NoteID
    public let deckID: DeckID
    public let deckName: EntityName
    public let noteTypeID: NoteTypeID
    public let front: String
    public let back: String
    public let variantKey: String
    public let templateID: String
    public let phase: SchedulePhase
    public let suspended: Bool
    public let dueAt: EpochMilliseconds?
    public let updatedAt: EpochMilliseconds
    public let noteRevision: Revision
    public let cardRevision: Revision
    public init(id: CardID, noteID: NoteID, deckID: DeckID, deckName: EntityName, noteTypeID: NoteTypeID,
                front: String, back: String, variantKey: String, templateID: String, phase: SchedulePhase,
                suspended: Bool, dueAt: EpochMilliseconds?, updatedAt: EpochMilliseconds,
                noteRevision: Revision, cardRevision: Revision) {
        self.id = id; self.noteID = noteID; self.deckID = deckID; self.deckName = deckName
        self.noteTypeID = noteTypeID; self.front = front; self.back = back
        self.variantKey = variantKey; self.templateID = templateID; self.phase = phase
        self.suspended = suspended; self.dueAt = dueAt; self.updatedAt = updatedAt
        self.noteRevision = noteRevision; self.cardRevision = cardRevision
    }
}

public struct LibrarySnapshot: Equatable, Sendable {
    public let generation: UUID
    public let query: LibraryQuery
    public let rows: [LibraryRow]
    public let cardCount: Int
    public let noteCount: Int
    public var hasMore: Bool { query.page.offset < cardCount - rows.count }
    public init(generation: UUID, query: LibraryQuery, rows: [LibraryRow], cardCount: Int, noteCount: Int) {
        self.generation = generation; self.query = query; self.rows = rows
        self.cardCount = cardCount; self.noteCount = noteCount
    }
}

public struct DeckQuery: Equatable, Sendable {
    public let filter: CardQueryFilter
    public let nameSearch: String
    public let hierarchy: Bool
    public let page: QueryPage
    public init(filter: CardQueryFilter = .all, nameSearch: String = "", page: QueryPage = .first, hierarchy: Bool = false) throws {
        guard nameSearch.count <= 512 else { throw CollectionQueryError.searchTooLong }
        self.filter = filter; self.nameSearch = nameSearch; self.page = page; self.hierarchy = hierarchy
    }
    public static let all = try! DeckQuery()
}

public struct DeckQueryRow: Equatable, Sendable, Identifiable {
    public let deck: Deck
    public let counts: CardCounts
    public var id: DeckID { deck.id }
    public init(deck: Deck, counts: CardCounts) { self.deck = deck; self.counts = counts }
}

public struct DeckSnapshot: Equatable, Sendable {
    public let generation: UUID
    public let rows: [DeckQueryRow]
    public let deckCount: Int
    public let page: QueryPage
    public let asOf: EpochMilliseconds
    public init(generation: UUID, rows: [DeckQueryRow], deckCount: Int, page: QueryPage, asOf: EpochMilliseconds) {
        self.generation = generation; self.rows = rows; self.deckCount = deckCount
        self.page = page; self.asOf = asOf
    }
}

public struct TodaySnapshot: Equatable, Sendable {
    public let generation: UUID
    public let asOf: EpochMilliseconds
    public let counts: CardCounts
    public let decks: DeckSnapshot
    public init(generation: UUID, asOf: EpochMilliseconds, counts: CardCounts, decks: DeckSnapshot) {
        self.generation = generation; self.asOf = asOf; self.counts = counts; self.decks = decks
    }
}

public protocol CollectionQueryService: Sendable {
    func library(_ query: LibraryQuery) async throws -> LibrarySnapshot
    func decks(_ query: DeckQuery, asOf: EpochMilliseconds) async throws -> DeckSnapshot
    func today(_ query: DeckQuery, asOf: EpochMilliseconds) async throws -> TodaySnapshot
    func observeLibrary(_ query: LibraryQuery) async throws -> QueryObservation<LibrarySnapshot>
    func observeDecks(_ query: DeckQuery, asOf: EpochMilliseconds) async throws -> QueryObservation<DeckSnapshot>
    func observeToday(_ query: DeckQuery, asOf: EpochMilliseconds) async throws -> QueryObservation<TodaySnapshot>
}
