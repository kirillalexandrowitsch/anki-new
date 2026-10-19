import GRDB

/// v2: derived search data. Never modify the delivered v1 migration.
enum SearchSchema {
    static func text(_ alias: String, field: String) -> String {
        "CASE WHEN json_type(\(alias).fieldsJSON, '$.\(field)') = 'text' THEN json_extract(\(alias).fieldsJSON, '$.\(field)') ELSE '' END"
    }
    static func examples(_ alias: String) -> String {
        """
        coalesce((SELECT group_concat(
            coalesce(CASE WHEN json_type(value, '$.en') = 'text' THEN json_extract(value, '$.en') END, '') || ' ' ||
            coalesce(CASE WHEN json_type(value, '$.ru') = 'text' THEN json_extract(value, '$.ru') END, ''), ' ')
            FROM json_each(\(alias).fieldsJSON, '$.examples') WHERE type = 'object'), '')
        """
    }
    static func create(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE notes_fts USING fts5(front, back, examples,
                tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER notes_search_insert AFTER INSERT ON notes WHEN NEW.deletedAt IS NULL BEGIN
                INSERT INTO notes_fts(rowid, front, back, examples)
                VALUES (NEW.rowid, \(text("NEW", field: "front")), \(text("NEW", field: "back")), \(examples("NEW")));
            END;
            CREATE TRIGGER notes_search_delete AFTER DELETE ON notes BEGIN
                DELETE FROM notes_fts WHERE rowid = OLD.rowid;
            END;
            CREATE TRIGGER notes_search_update AFTER UPDATE ON notes BEGIN
                DELETE FROM notes_fts WHERE rowid = OLD.rowid;
                INSERT INTO notes_fts(rowid, front, back, examples)
                SELECT NEW.rowid, \(text("NEW", field: "front")), \(text("NEW", field: "back")), \(examples("NEW")) WHERE NEW.deletedAt IS NULL;
            END;
            INSERT INTO notes_fts(rowid, front, back, examples)
                SELECT n.rowid, \(text("n", field: "front")), \(text("n", field: "back")), \(examples("n"))
                FROM notes n WHERE n.deletedAt IS NULL;
            CREATE INDEX notes_library_updated ON notes(updatedAt, id) WHERE deletedAt IS NULL;
            CREATE INDEX notes_library_front ON notes(normalizedFront, id) WHERE deletedAt IS NULL;
            """)
    }
}
