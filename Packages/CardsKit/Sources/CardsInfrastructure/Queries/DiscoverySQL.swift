import CardsCore
import Foundation
import GRDB

extension SQLiteCollectionQueries: DiscoveryQueryService {
    func observeGlobalSearch(_ text: String, asOf: EpochMilliseconds) async throws -> QueryObservation<GlobalSearchSnapshot> {
        let filter = try CardQueryFilter(search: text)
        let decks = try DeckQuery(nameSearch: text, page: QueryPage(limit: 6))
        return try await writer.observe { db in
            try GlobalSearchSnapshot(generation: generation,
                cards: QuerySQL.library(db, query: LibraryQuery(filter: filter, sort: .frontAscending,
                    page: QueryPage(limit: 6)), generation: generation),
                decks: QuerySQL.decks(db, query: decks, asOf: asOf, generation: generation))
        }
    }
    func observeDailyWord(day: Int, excluding: NoteID?) async throws -> QueryObservation<DailyWord?> {
        try await writer.observe { db in try DiscoverySQL.word(db, day: day, excluding: excluding, generation: generation) }
    }
}

enum DiscoverySQL {
    static func word(_ db: Database, day: Int, excluding: NoteID?, generation: UUID) throws -> DailyWord? {
        // One candidate per Note, regardless of how many variants it owns. No full collection in UI memory.
        let candidates = """
            SELECT n.id, n.fieldsJSON, min(c.id) AS cardID
            \(QuerySQL.joins) WHERE \(QuerySQL.scope(.all).predicate)
            AND n.noteTypeID = ? AND trim(\(SearchSchema.text("n", field: "front"))) != ''
            AND trim(\(SearchSchema.text("n", field: "back"))) != '' GROUP BY n.id
            """
        let args: StatementArguments = [QuerySQL.key(BasicNoteType.id)]
        let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM (\(candidates))", arguments: args)!
        guard total > 0 else { return nil }
        var filtered = candidates
        var values = args
        if let excluding {
            filtered = "SELECT * FROM (\(candidates)) WHERE id != ?"
            values += [QuerySQL.key(excluding)]
        }
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM (\(filtered))", arguments: values)!
        // With one Note, Another is disabled; an explicit exclusion never returns the same Note.
        guard count > 0 else { return nil }
        let offset = ((day % count) + count) % count
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM (\(filtered)) ORDER BY id LIMIT 1 OFFSET ?",
                                        arguments: values + [offset]) else { return nil }
        let json: String = row["fieldsJSON"]
        let content = try JSONDecoder().decode(BasicNoteContent.self, from: Data(json.utf8))
        try content.validate()
        return try DailyWord(generation: generation, noteID: NoteID(uuidString: row["id"]),
            cardID: CardID(uuidString: row["cardID"]), content: content, hasAlternative: total > 1)
    }
}
