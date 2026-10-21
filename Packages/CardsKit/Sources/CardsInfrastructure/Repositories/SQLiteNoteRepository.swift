import CardsCore
import Foundation
import GRDB

struct SQLiteNoteRepository: NoteRepository {
    let writer: CollectionWriter
    let clock: any CardsCore.Clock

    func note(id: NoteID) async throws -> SavedBasicNote? {
        try await writer.read { try Self.fetch($0, id: id) }
    }

    func save(_ command: SaveNoteCommand) async throws -> SavedBasicNote {
        let now = try EpochMilliseconds(date: clock.now()).rawValue
        return try await writer.execute(commandID: command.commandID, kind: "note.save.basic.v1", request: command) { db in
            try Self.apply(command, in: db, now: now)
        }
    }

    /// Reused by compound commands inside the same writer transaction.
    static func apply(_ command: SaveNoteCommand, in db: Database, now: Int64) throws -> SavedBasicNote {
        try command.content.validate()
        let key = Self.key(command.noteID)
        let current = try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE id = ?", arguments: [key])
        let revision: Revision
        if let expected = command.expectedRevision {
            guard let current, current["deletedAt"] == nil else {
                throw CollectionRepositoryError.notFound(.note(command.noteID))
            }
            let actual = try Revision(current["revision"])
            guard actual == expected else {
                throw CollectionRepositoryError.revisionConflict(entity: .note(command.noteID), expected: expected, actual: actual)
            }
            guard current["noteTypeID"] as String == Self.key(BasicNoteType.id) else {
                throw CollectionRepositoryError.validation(.invalidField("noteTypeID"))
            }
            guard current["contentVersion"] as Int == 1 else {
                throw CollectionRepositoryError.validation(.invalidField("contentVersion"))
            }
            revision = try expected.advanced()
        } else {
            guard current == nil else { throw CollectionRepositoryError.alreadyExists(.note(command.noteID)) }
            revision = .initial
        }
        try BasicNoteDefaults.installType(db)
        let fields = try BasicNoteDefaults.json(command.content)
        let normalized = try EntityName(command.content.front).normalizedValue
        if current == nil {
            try db.execute(sql: """
                INSERT INTO notes(id, noteTypeID, fieldsJSON, contentVersion, normalizedFront, createdAt, updatedAt)
                VALUES (?, ?, ?, 1, ?, ?, ?)
                """, arguments: [key, Self.key(BasicNoteType.id), fields, normalized, now, now])
        } else {
            try db.execute(sql: """
                UPDATE notes SET fieldsJSON = ?, normalizedFront = ?, updatedAt = ?, revision = ? WHERE id = ?
                """, arguments: [fields, normalized, now, revision.rawValue, key])
        }
        try Self.replaceTags(db, noteKey: key, names: command.tags)
        try Self.replaceMedia(db, noteKey: key, refs: command.content.media)
        if try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cards WHERE noteID = ? AND variantKey = ?)",
                              arguments: [key, BasicNoteType.variantKey])! {
            let parameter = try BasicNoteDefaults.parameterSet(db, deckID: command.initialDeckID, now: now)
            guard try String.fetchOne(db, sql: "SELECT algorithmVersion FROM scheduler_parameters WHERE id = ?",
                                      arguments: [parameter]) == "6" else {
                throw CollectionRepositoryError.integrityFailure
            }
            let card = Self.key(CardID())
            try db.execute(sql: """
                INSERT INTO cards(id, noteID, deckID, variantKey, templateID, createdAt) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [card, key, Self.key(command.initialDeckID), BasicNoteType.variantKey, BasicNoteType.templateID, now])
            try db.execute(sql: """
                INSERT INTO card_schedules(cardID, algorithmID, algorithmVersion, parameterSetID, phase)
                VALUES (?, 'fsrs', '6', ?, 'new')
                """, arguments: [card, parameter])
        }
        // Existing variants (including tombstones) and all schedule columns stay untouched.
        guard let saved = try Self.fetch(db, id: command.noteID) else {
            throw CollectionRepositoryError.integrityFailure
        }
        struct Event: Encodable { let schemaVersion = 1; let revision: Revision; let cardID: CardID }
        try db.execute(sql: """
            INSERT INTO domain_events(id, commandID, type, objectID, occurredAt, payloadVersion, payloadJSON)
            VALUES (?, ?, 'note.saved', ?, ?, 1, ?)
            """, arguments: [UUID().uuidString.lowercased(), Self.key(command.commandID), key, now,
                              BasicNoteDefaults.json(Event(revision: revision, cardID: saved.card.id))])
        return saved
    }

    private static func replaceTags(_ db: Database, noteKey: String, names: [String]) throws {
        try db.execute(sql: "DELETE FROM note_tags WHERE noteID = ?", arguments: [noteKey])
        var seen = Set<String>()
        for raw in names {
            let name = try EntityName(raw)
            guard seen.insert(name.normalizedValue).inserted else { continue }
            let id: String
            if let existing = try String.fetchOne(db, sql: "SELECT id FROM tags WHERE normalizedName = ? AND deletedAt IS NULL",
                                                  arguments: [name.normalizedValue]) { id = existing }
            else {
                id = key(TagID())
                try db.execute(sql: "INSERT INTO tags(id, name, normalizedName) VALUES (?, ?, ?)",
                               arguments: [id, name.displayValue, name.normalizedValue])
            }
            try db.execute(sql: "INSERT INTO note_tags(noteID, tagID) VALUES (?, ?)", arguments: [noteKey, id])
        }
    }

    private static func replaceMedia(_ db: Database, noteKey: String, refs: [NoteMediaReference]) throws {
        try db.execute(sql: "DELETE FROM note_media WHERE noteID = ?", arguments: [noteKey])
        for ref in refs {
            guard let uti = try String.fetchOne(db, sql: "SELECT uti FROM media_assets WHERE id = ? AND lifecycleState = 'published'",
                                                arguments: [key(ref.mediaID)]) else {
                throw CollectionRepositoryError.notFound(.media(ref.mediaID))
            }
            // Match the import allowlist; no filesystem or decoding work inside SQL commit.
            let isAudio = ["public.mp3", "com.apple.m4a-audio", "com.microsoft.waveform-audio"].contains(uti)
            guard MediaFiles.formats[uti] != nil, isAudio == (ref.role == .audio) else {
                throw CollectionRepositoryError.validation(.invalidField("media"))
            }
            try db.execute(sql: "INSERT INTO note_media(noteID, mediaID, fieldID, role, orderIndex) VALUES (?, ?, ?, ?, ?)",
                           arguments: [noteKey, key(ref.mediaID), ref.fieldID, ref.role.rawValue, ref.orderIndex])
        }
    }

    private static func fetch(_ db: Database, id: NoteID) throws -> SavedBasicNote? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE id = ? AND deletedAt IS NULL",
                                         arguments: [key(id)]) else { return nil }
        guard row["noteTypeID"] as String == key(BasicNoteType.id) else {
            throw CollectionRepositoryError.validation(.invalidField("noteTypeID"))
        }
        let content = try JSONDecoder().decode(BasicNoteContent.self, from: Data((row["fieldsJSON"] as String).utf8))
        try content.validate()
        guard let card = try Row.fetchOne(db, sql: "SELECT * FROM cards WHERE noteID = ? AND variantKey = ?",
                                          arguments: [key(id), BasicNoteType.variantKey]),
              let state = CardGenerationState(rawValue: card["generationState"]) else {
            throw CollectionRepositoryError.integrityFailure
        }
        let tags = try String.fetchAll(db, sql: """
            SELECT t.name FROM tags t JOIN note_tags nt ON nt.tagID = t.id
            WHERE nt.noteID = ? AND t.deletedAt IS NULL ORDER BY t.normalizedName, t.id
            """, arguments: [key(id)]).map { try EntityName($0) }
        let note = try Note(id: id, noteTypeID: BasicNoteType.id,
            fields: ["front": content.front, "back": content.back, "pronunciation": content.pronunciation],
            contentVersion: row["contentVersion"], createdAt: EpochMilliseconds(row["createdAt"]).date,
            updatedAt: EpochMilliseconds(row["updatedAt"]).date, revision: Revision(row["revision"]))
        let buried: Int64? = card["buriedUntil"]
        let deleted: Int64? = card["deletedAt"]
        return try SavedBasicNote(note: note, content: content, tags: tags,
            card: Card(id: CardID(uuidString: card["id"]), noteID: id, deckID: DeckID(uuidString: card["deckID"]),
                variantKey: card["variantKey"], templateID: card["templateID"], generationState: state,
                suspended: card["suspended"], buriedUntil: buried.map { EpochMilliseconds($0).date },
                createdAt: EpochMilliseconds(card["createdAt"]).date, revision: Revision(card["revision"]),
                deletedAt: deleted.map { EpochMilliseconds($0).date }))
    }

    private static func key<T>(_ id: EntityID<T>) -> String { id.rawValue.uuidString.lowercased() }
}
