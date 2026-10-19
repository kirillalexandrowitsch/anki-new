import CardsCore
import Foundation
import GRDB

/// All interpolated SQL is code-owned. User data is always bound.
enum QuerySQL {
    struct Scope {
        var conditions = ["c.deletedAt IS NULL", "n.deletedAt IS NULL", "d.deletedAt IS NULL", "c.generationState = 'active'"]
        var arguments = StatementArguments()
        var predicate: String { conditions.joined(separator: " AND ") }
        mutating func add(_ sql: String, _ values: StatementArguments = []) {
            conditions.append(sql); arguments += values
        }
    }
    static let joins = """
        FROM cards c JOIN notes n ON n.id = c.noteID JOIN decks d ON d.id = c.deckID
        LEFT JOIN card_schedules s ON s.cardID = c.id
        """
    static let phase = "coalesce(s.phase, 'new')"

    static func searchPattern(_ text: String) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let words = text.components(separatedBy: CharacterSet.alphanumerics.union(.nonBaseCharacters).inverted)
            .filter { !$0.isEmpty }
        // A literal punctuation-only search must not accidentally return the entire collection.
        return words.isEmpty ? "\"\u{1}\"" : words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
    }

    static func scope(_ filter: CardQueryFilter) -> Scope {
        var scope = Scope()
        if let pattern = searchPattern(filter.search) {
            scope.add("n.rowid IN (SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?)", [pattern])
        }
        if let deck = filter.deckID {
            scope.add(deckPredicate(descendants: filter.includeDescendants), [key(deck)])
        }
        if let type = filter.noteTypeID { scope.add("n.noteTypeID = ?", [key(type)]) }
        if let tag = filter.tagID {
            scope.add("""
                EXISTS(SELECT 1 FROM note_tags nt JOIN tags t ON t.id = nt.tagID
                WHERE nt.noteID = n.id AND t.id = ? AND t.deletedAt IS NULL)
                """, [key(tag)])
        }
        if let value = filter.phase { scope.add("\(phase) = ?", [value.rawValue]) }
        if let value = filter.suspended { scope.add("c.suspended = ?", [value]) }
        return scope
    }

    static func deckPredicate(descendants: Bool, column: String = "c.deckID") -> String {
        if !descendants { return "\(column) = ?" }
        return """
            \(column) IN (WITH RECURSIVE scope(id) AS (
                SELECT id FROM decks WHERE id = ? AND deletedAt IS NULL
                UNION SELECT d.id FROM decks d JOIN scope ON d.parentID = scope.id WHERE d.deletedAt IS NULL
            ) SELECT id FROM scope)
            """
    }

    static func order(_ sort: LibrarySort) -> String {
        switch sort {
        case .updatedNewest: "n.updatedAt DESC, c.id ASC"
        case .updatedOldest: "n.updatedAt ASC, c.id ASC"
        case .frontAscending: "n.normalizedFront ASC, c.id ASC"
        case .frontDescending: "n.normalizedFront DESC, c.id ASC"
        case .newFirst: "CASE WHEN \(phase) = 'new' THEN 0 ELSE 1 END ASC, c.id ASC"
        case .studiedFirst: "CASE WHEN \(phase) = 'new' THEN 1 ELSE 0 END ASC, c.id ASC"
        }
    }

    static func library(_ db: Database, query: LibraryQuery, generation: UUID) throws -> LibrarySnapshot {
        let scope = scope(query.filter)
        let counts = try Row.fetchOne(db, sql: "SELECT count(*) AS cards, count(DISTINCT n.id) AS notes \(joins) WHERE \(scope.predicate)",
                                      arguments: scope.arguments)!
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, n.id AS noteID, d.id AS deckID, d.name AS deckName, n.noteTypeID,
                \(SearchSchema.text("n", field: "front")) AS front, \(SearchSchema.text("n", field: "back")) AS back,
                c.variantKey, c.templateID, \(phase) AS phase, c.suspended, s.dueAt,
                n.updatedAt, n.revision AS noteRevision, c.revision AS cardRevision
            \(joins) WHERE \(scope.predicate) ORDER BY \(order(query.sort)) LIMIT ? OFFSET ?
            """, arguments: scope.arguments + [query.page.limit, query.page.offset])
        return try LibrarySnapshot(generation: generation, query: query, rows: rows.map { row in
            guard let phase = SchedulePhase(rawValue: row["phase"]) else { throw CollectionRepositoryError.integrityFailure }
            let due: Int64? = row["dueAt"]
            return try LibraryRow(id: CardID(uuidString: row["id"]), noteID: NoteID(uuidString: row["noteID"]),
                deckID: DeckID(uuidString: row["deckID"]), deckName: EntityName(row["deckName"]),
                noteTypeID: NoteTypeID(uuidString: row["noteTypeID"]), front: row["front"], back: row["back"],
                variantKey: row["variantKey"], templateID: row["templateID"], phase: phase,
                suspended: row["suspended"], dueAt: due.map(EpochMilliseconds.init),
                updatedAt: EpochMilliseconds(row["updatedAt"]), noteRevision: Revision(row["noteRevision"]),
                cardRevision: Revision(row["cardRevision"]))
        }, cardCount: counts["cards"], noteCount: counts["notes"])
    }

    static func aggregates(asOf: EpochMilliseconds) -> (String, StatementArguments) {
        ("""
        count(c.id) AS cards, count(DISTINCT c.noteID) AS notes,
        coalesce(sum(phase = 'new'), 0) AS newCount,
        coalesce(sum(phase IN ('learning', 'relearning')), 0) AS learning,
        coalesce(sum(phase = 'review'), 0) AS review,
        coalesce(sum(suspended = 1), 0) AS suspended,
        coalesce(sum(buriedUntil > ?), 0) AS buried,
        coalesce(sum(phase = 'new' AND suspended = 0 AND (buriedUntil IS NULL OR buriedUntil <= ?)), 0) AS availableNew,
        coalesce(sum(phase != 'new' AND suspended = 0 AND (buriedUntil IS NULL OR buriedUntil <= ?) AND dueAt <= ?), 0) AS due
        """, [asOf.rawValue, asOf.rawValue, asOf.rawValue, asOf.rawValue])
    }
    static func counts(_ row: Row) -> CardCounts {
        CardCounts(cards: row["cards"], notes: row["notes"], new: row["newCount"], learning: row["learning"],
                   review: row["review"], suspended: row["suspended"], buried: row["buried"],
                   availableNew: row["availableNew"], due: row["due"])
    }
    static func eligible(_ filter: CardQueryFilter) -> (String, StatementArguments) {
        let scope = scope(filter)
        return ("SELECT c.id, c.noteID, c.deckID, c.suspended, c.buriedUntil, s.dueAt, \(phase) AS phase \(joins) WHERE \(scope.predicate)", scope.arguments)
    }

    static func decks(_ db: Database, query: DeckQuery, asOf: EpochMilliseconds, generation: UUID) throws -> DeckSnapshot {
        let (eligibleSQL, eligibleArgs) = eligible(query.filter)
        let (aggregateSQL, aggregateArgs) = aggregates(asOf: asOf)
        var deckWhere = ["d.deletedAt IS NULL"]
        var args = StatementArguments()
        if let deck = query.filter.deckID {
            deckWhere.append(deckPredicate(descendants: query.filter.includeDescendants, column: "d.id"))
            args += [key(deck)]
        }
        if !query.nameSearch.isEmpty {
            deckWhere.append("d.name LIKE ? ESCAPE '\\'")
            let literal = query.nameSearch.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            args += ["%\(literal)%"]
        }
        let predicate = deckWhere.joined(separator: " AND ")
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM decks d WHERE \(predicate)", arguments: args)!
        // Page first, then aggregate in one statement. Empty decks are retained.
        let rows = try Row.fetchAll(db, sql: """
            WITH eligible AS (\(eligibleSQL)), page AS (
                SELECT d.* FROM decks d WHERE \(predicate) ORDER BY d.sortOrder, d.normalizedName, d.id LIMIT ? OFFSET ?
            ), totals AS (SELECT c.deckID, \(aggregateSQL) FROM eligible c
                WHERE c.deckID IN (SELECT id FROM page) GROUP BY c.deckID)
            SELECT p.*, coalesce(t.cards, 0) AS cards, coalesce(t.notes, 0) AS notes,
                coalesce(t.newCount, 0) AS newCount, coalesce(t.learning, 0) AS learning,
                coalesce(t.review, 0) AS review, coalesce(t.suspended, 0) AS suspended,
                coalesce(t.buried, 0) AS buried, coalesce(t.availableNew, 0) AS availableNew, coalesce(t.due, 0) AS due
            FROM page p LEFT JOIN totals t ON t.deckID = p.id ORDER BY p.sortOrder, p.normalizedName, p.id
            """, arguments: eligibleArgs + args + [query.page.limit, query.page.offset] + aggregateArgs)
        return try DeckSnapshot(generation: generation, rows: rows.map { row in
            let parent: String? = row["parentID"]
            return try DeckQueryRow(deck: Deck(id: DeckID(uuidString: row["id"]),
                parentID: parent.map { try DeckID(uuidString: $0) }, name: EntityName(row["name"]),
                description: row["description"], iconKey: row["iconKey"], colorKey: row["colorKey"], revision: Revision(row["revision"])), counts: counts(row))
        }, deckCount: count, page: query.page, asOf: asOf)
    }

    static func today(_ db: Database, query: DeckQuery, asOf: EpochMilliseconds, generation: UUID) throws -> TodaySnapshot {
        let (eligibleSQL, args) = eligible(query.filter)
        let (aggregateSQL, aggregateArgs) = aggregates(asOf: asOf)
        let row = try Row.fetchOne(db, sql: "WITH eligible AS (\(eligibleSQL)) SELECT \(aggregateSQL) FROM eligible c",
                                   arguments: args + aggregateArgs)!
        return try TodaySnapshot(generation: generation, asOf: asOf, counts: counts(row),
                                 decks: decks(db, query: query, asOf: asOf, generation: generation))
    }

    static func key<Tag>(_ id: EntityID<Tag>) -> String { id.rawValue.uuidString.lowercased() }
}
