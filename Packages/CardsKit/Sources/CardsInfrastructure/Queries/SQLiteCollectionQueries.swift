import CardsCore
import Foundation

struct SQLiteCollectionQueries: CollectionQueryService {
    let writer: CollectionWriter
    let generation: UUID
    func library(_ query: LibraryQuery) async throws -> LibrarySnapshot {
        try await writer.read { try QuerySQL.library($0, query: query, generation: generation) }
    }
    func decks(_ query: DeckQuery, asOf: EpochMilliseconds) async throws -> DeckSnapshot {
        try await writer.read { try QuerySQL.decks($0, query: query, asOf: asOf, generation: generation) }
    }
    func today(_ query: DeckQuery, asOf: EpochMilliseconds) async throws -> TodaySnapshot {
        try await writer.read { try QuerySQL.today($0, query: query, asOf: asOf, generation: generation) }
    }
    func observeLibrary(_ query: LibraryQuery) async throws -> QueryObservation<LibrarySnapshot> {
        try await writer.observe { try QuerySQL.library($0, query: query, generation: generation) }
    }
    func observeDecks(_ query: DeckQuery, asOf: EpochMilliseconds) async throws -> QueryObservation<DeckSnapshot> {
        try await writer.observe { try QuerySQL.decks($0, query: query, asOf: asOf, generation: generation) }
    }
    func observeToday(_ query: DeckQuery, asOf: EpochMilliseconds) async throws -> QueryObservation<TodaySnapshot> {
        try await writer.observe { try QuerySQL.today($0, query: query, asOf: asOf, generation: generation) }
    }
}
