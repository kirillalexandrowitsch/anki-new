import CardsCore
import CardsTestSupport
@testable import CardsInfrastructure
import Foundation
import GRDB
import Testing

/// A single file-backed path across the same services used by the app. SQL is
/// read-only here: the fixture itself is created exclusively through commands.
@Test func firstVerticalFourGradesRetryReopenCSVAndExactBackup() async throws {
    let directory = try TestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.url) }
    let root = directory.url.appendingPathComponent("source")
    let clock = TestClock(date: Date(timeIntervalSince1970: 1_792_368_000))
    let store = CollectionStore(root: root, clock: clock)
    let context = try await store.open()
    let decks = try await store.decks(generation: context.generation)
    let deck = try await decks.save(SaveDeckCommand(commandID: CommandID(), deckID: DeckID(),
        expectedRevision: nil, name: EntityName("Synthetic M1")))
    let notes = try await store.notes(generation: context.generation)
    let media = try await store.media(generation: context.generation)
    let png = try #require(Bundle.module.url(forResource: "pixel", withExtension: "png", subdirectory: "Fixtures/synthetic-v1"))
    let asset = try await media.importFile(png)
    var expectedContent: [NoteID: BasicNoteContent] = [:]
    for grade in Grade.allCases {
        let content = BasicNoteContent(front: "Synthetic \(grade.rawValue), \"café\"",
            back: "Ответ \(grade.rawValue)\nвторая строка", pronunciation: "/test/",
            examples: [NoteExample(en: "Line one\nline two", ru: "Пример")],
            media: [NoteMediaReference(mediaID: asset.id, fieldID: "image", role: .image)])
        let saved = try await notes.save(SaveNoteCommand(commandID: CommandID(), noteID: NoteID(),
            expectedRevision: nil, initialDeckID: deck.id, content: content, tags: ["M1", "Тест"]))
        expectedContent[saved.note.id] = content
    }
    let service = try await store.studySession(generation: context.generation)
    let query = StatsQuery(asOf: clock.now(), period: .week,
        calendar: try StudyDayCalculator(timeZoneID: TimeZone.current.identifier))
    for grade in Grade.allCases {
        guard case .question(let question) = try await service.next(skipping: [], preferred: nil) else {
            Issue.record("Expected one of four new cards"); return
        }
        let command = StudyRatingCommand(cardID: question.cardID, expectedRevision: question.revision,
            grade: grade, occurredAt: clock.now(), scheduleEpoch: question.scheduleEpoch, durationMs: 1000)
        try await service.rate(command)
        // Lost acknowledgement / duplicate submission must have one durable effect.
        try await service.rate(command)
        let queries = try await store.statsWorkspace(generation: context.generation).queries
        #expect(try await queries.statistics(query).totals.ratings == grade.rawValue)
    }
    let progress = try #require(service as? any StudyProgressService)
    try await progress.checkpoint(StudyCheckpoint(cardID: nil, phase: .summary, activeDurationMs: 4321))
    try await progress.finish(early: false)
    let queries = try await store.statsWorkspace(generation: context.generation).queries
    let stats = try await queries.statistics(query)
    #expect(stats.totals == StatsTotals(ratings: 4, uniqueCards: 4, grades: [1,1,1,1], responseDurationMs: 4000))
    #expect(stats.totals.successRate == 0.75 && stats.startedSessionActiveDurationMs == 4321)
    try await store.close(generation: context.generation)
    let reopened = try await store.open()
    let reopenedQueries = try await store.queries(generation: reopened.generation)
    let reopenedStats = try await store.statsWorkspace(generation: reopened.generation).queries
    #expect(try await reopenedStats.statistics(query).totals == stats.totals)
    #expect(try await reopenedQueries.library(LibraryQuery()).cardCount == 4)
    let csv = directory.url.appendingPathComponent("vertical.csv")
    try await store.export(to: csv, format: .csv, generation: reopened.generation)
    var rows: [[String]] = []
    try DelimitedTextParser.read(csv) { rows.append($0) }
    #expect(rows.count == 5 && rows[0] == CollectionExporter.columns)
    #expect(Set(try rows.dropFirst().map { try NoteID(uuidString: $0[0]) }) == Set(expectedContent.keys))
    for row in rows.dropFirst() {
        let content = try #require(expectedContent[NoteID(uuidString: row[0])])
        #expect(row[1] == content.front && row[2] == content.back && row[3] == content.pronunciation)
        #expect(try JSONDecoder().decode([NoteExample].self, from: Data(row[4].utf8)) == content.examples)
        #expect(Set(try JSONDecoder().decode([String].self, from: Data(row[5].utf8))) == Set(["M1", "Тест"]))
        #expect(row[6] == "Synthetic M1")
    }
    func dump(_ root: URL, _ context: CollectionContext) throws -> [String: [String]] {
        let reader = try CollectionMigrations.readOnlyQueue(RestoreJournal.container(root, context.id).appendingPathComponent("collection.sqlite"))
        defer { try? reader.close() }
        return try reader.read { db in
            var result: [String: [String]] = [:]
            for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'") {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")").map { row in
                    "quote(\"\(row["name"] as String)\")"
                }.joined(separator: " || '|' || ")
                result[table] = try String.fetchAll(db, sql: "SELECT \(columns) FROM \"\(table)\" ORDER BY 1")
            }
            return result
        }
    }
    let expected = try dump(root, reopened)
    let backup = directory.url.appendingPathComponent("vertical.cardsbackup")
    try await store.export(to: backup, format: .cardsbackup, generation: reopened.generation)
    let liveAfterBackup = try dump(root, reopened)
    var expectedLive = expected
    expectedLive["local_notifications"] = liveAfterBackup["local_notifications"]
    #expect(liveAfterBackup == expectedLive)
    #expect(try await store.notifications(generation: reopened.generation).messages().map(\.event) == [.backupSucceeded])
    let targetRoot = directory.url.appendingPathComponent("separate-collection")
    let target = CollectionStore(root: targetRoot, clock: clock)
    let empty = try await target.open()
    #expect(empty.id != reopened.id)
    let restored = try await target.restoreBackup(from: backup, generation: empty.generation)
    #expect(restored.id == reopened.id)
    #expect(try dump(targetRoot, restored) == expected)
    #expect(try dump(root, reopened) == liveAfterBackup)
    let restoredMedia = try await target.media(generation: restored.generation)
    #expect(try Data(contentsOf: await restoredMedia.fileURL(id: asset.id)) == Data(contentsOf: png))
    let restoredQueries = try await target.statsWorkspace(generation: restored.generation).queries
    #expect(try await restoredQueries.statistics(query).totals == stats.totals)
    let restoredNotes = try await target.notes(generation: restored.generation)
    for (id, content) in expectedContent { #expect(try await restoredNotes.note(id: id)?.content == content) }
    try await target.close(generation: restored.generation)
    let targetReopened = try await target.open()
    #expect(try dump(targetRoot, targetReopened) == expected)
    try await target.close(generation: targetReopened.generation)
    try await store.close(generation: reopened.generation)
}
