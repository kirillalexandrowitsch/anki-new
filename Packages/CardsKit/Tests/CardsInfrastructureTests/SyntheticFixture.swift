import CardsCore
@testable import CardsInfrastructure
import CardsTestSupport
import CryptoKit
import Foundation
import GRDB

/// Test-only SQL seeding: no unfinished production Note/Study commands are implied.
struct SyntheticSeed: Decodable, Sendable {
    struct Deck: Decodable, Sendable { let id: Int; let name: String; let parent: Int? }
    struct Note: Decodable, Sendable { let id: Int; let front: String; let back: String; let example: String }
    struct Card: Decodable, Sendable {
        let id: Int; let note: Int; let deck: Int; let variant: String
        let phase: String; let dueOffset: Int64; let suspended: Bool?
    }
    struct Media: Decodable, Sendable {
        let id: Int; let note: Int; let file: String; let uti: String; let role: String; let sha256: String
    }
    let schemaVersion: Int
    let seed: Int
    let nowMilliseconds: Int64
    let decks: [Deck]
    let notes: [Note]
    let cards: [Card]
    let media: [Media]

    static var directory: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        .appendingPathComponent("synthetic-v1") }
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("seed.json")))
    }
    // Stable namespace + seed + entity number, independent of run order and OS randomness.
    func key(_ value: Int) -> String { String(format: "00000000-0012-4000-8000-%012d", value) }
}

final class SyntheticFixture: Sendable {
    let temporary: TestDirectory
    let seed: SyntheticSeed
    let clock: TestClock
    let database: CollectionDatabase
    var databaseURL: URL { temporary.url.appendingPathComponent("collection.sqlite") }

    init() throws {
        let temporary = try TestDirectory()
        let seed = try SyntheticSeed.load()
        guard seed.schemaVersion == 1, seed.seed == 12 else { throw CollectionDatabaseError.inconsistentSchema }
        self.temporary = temporary
        self.seed = seed
        clock = TestClock(date: Date(timeIntervalSince1970: Double(seed.nowMilliseconds) / 1000))
        database = try CollectionDatabase(url: temporary.url.appendingPathComponent("collection.sqlite"),
            newCollection: NewCollectionMetadata(id: CollectionID(uuidString: seed.key(1)),
                name: EntityName("Синтетическая коллекция T012"), createdAt: EpochMilliseconds(seed.nowMilliseconds)))
        do { try populate() }
        catch { try? database.close(); throw error }
    }
    deinit { try? database.close() }

    private func populate() throws {
        let s = seed
        let mediaDirectory = temporary.url.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: false)
        for media in s.media {
            let bytes = try Data(contentsOf: SyntheticSeed.directory.appendingPathComponent(media.file))
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == media.sha256 else {
                throw CollectionDatabaseError.integrityFailure
            }
            let file = mediaDirectory.appendingPathComponent(media.sha256 + "." + URL(fileURLWithPath: media.file).pathExtension)
            try bytes.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        }
        try database.pool.write { db in
            try db.execute(sql: "INSERT INTO scheduler_parameters VALUES (?,'6','{\"schemaVersion\":1}',0.9,36500,'{\"schemaVersion\":1}',?)",
                           arguments: [s.key(2), s.nowMilliseconds])
            try db.execute(sql: "INSERT INTO note_types VALUES (?,'test.basic','Синтетический',1,'{\"schemaVersion\":1}','{\"schemaVersion\":1}',0,NULL)", arguments: [s.key(3)])
            for deck in s.decks {
                let name = try EntityName(deck.name)
                try db.execute(sql: "INSERT INTO decks(id,parentID,name,normalizedName) VALUES (?,?,?,?)",
                    arguments: [s.key(deck.id), deck.parent.map(s.key), name.displayValue, name.normalizedValue])
            }
            for note in s.notes {
                let json = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "front": note.front,
                    "back": note.back, "examples": [["en": "Synthetic example", "ru": note.example]]], options: [.sortedKeys])
                try db.execute(sql: "INSERT INTO notes VALUES (?,?,?,1,?,?,?,0,NULL)", arguments: [s.key(note.id), s.key(3),
                    String(decoding: json, as: UTF8.self), EntityName(note.front).normalizedValue, s.nowMilliseconds, s.nowMilliseconds])
            }
            for card in s.cards {
                try db.execute(sql: "INSERT INTO cards(id,noteID,deckID,variantKey,templateID,suspended,createdAt) VALUES (?,?,?,?,'front',?,?)",
                    arguments: [s.key(card.id), s.key(card.note), s.key(card.deck), card.variant, card.suspended ?? false, s.nowMilliseconds])
                try db.execute(sql: "INSERT INTO card_schedules(cardID,algorithmID,algorithmVersion,parameterSetID,phase,dueAt) VALUES (?,'fsrs','6',?,?,?)",
                    arguments: [s.key(card.id), s.key(2), card.phase, s.nowMilliseconds + card.dueOffset])
            }
            for media in s.media {
                let path = "Media/" + media.sha256 + "." + URL(fileURLWithPath: media.file).pathExtension
                let bytes = try Data(contentsOf: temporary.url.appendingPathComponent(path))
                try db.execute(sql: "INSERT INTO media_assets VALUES (?,?,?,?,?,?,'published')", arguments: [
                    s.key(media.id), media.sha256, path, media.uti, bytes.count, s.nowMilliseconds])
                try db.execute(sql: "INSERT INTO note_media VALUES (?,?,'front',?,0)", arguments: [s.key(media.note), s.key(media.id), media.role])
            }
        }
    }

    /// Logical digest excludes SQLite page layout, WAL and temporary absolute paths.
    /// Only a hash leaves this helper, never row contents.
    func fingerprint() throws -> String {
        try database.pool.read { db in
            var bytes = Data()
            for table in ["collection_meta", "scheduler_parameters", "note_types", "decks", "notes", "cards", "card_schedules", "media_assets", "note_media"] {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
                    "quote(\"\(row["name"] as String)\")"
                }.joined(separator: " || '|' || ")
                let rows = try String.fetchAll(db, sql: "SELECT \(columns) FROM \(table) ORDER BY 1")
                bytes.append(contentsOf: (table + "\n" + rows.joined(separator: "\n") + "\n").utf8)
            }
            for media in seed.media {
                let path = "Media/" + media.sha256 + "." + URL(fileURLWithPath: media.file).pathExtension
                bytes.append(try Data(contentsOf: temporary.url.appendingPathComponent(path)))
            }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }
}
