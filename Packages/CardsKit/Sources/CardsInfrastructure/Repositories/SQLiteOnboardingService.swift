import CardsCore
import Foundation
import GRDB

struct SQLiteOnboardingService: OnboardingService {
    let writer: CollectionWriter
    let clock: any CardsCore.Clock
    static let completionKey = "onboarding.v1"

    func isRequired() async throws -> Bool {
        try await writer.read { db in
            // Previously used collections, including tombstones, never receive unsolicited demo content.
            try Self.result(db) == nil && !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM decks)")!
        }
    }

    func complete(_ command: CompleteOnboardingCommand) async throws -> OnboardingResult {
        let now = try EpochMilliseconds(date: clock.now()).rawValue
        return try await writer.execute(commandID: command.commandID, kind: "onboarding.complete.v1", request: command) { db in
            if let completed = try Self.result(db) { return completed }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM decks)") == false else {
                throw CollectionRepositoryError.validation(.invalidField("onboardingAlreadyStarted"))
            }
            let deck = try SQLiteDeckRepository.apply(SaveDeckCommand(commandID: command.commandID,
                deckID: command.deckID, expectedRevision: nil, name: command.name), in: db)
            if command.includeDemo {
                for content in OnboardingDemo.notes {
                    _ = try SQLiteNoteRepository.apply(SaveNoteCommand(commandID: command.commandID,
                        noteID: NoteID(), expectedRevision: nil, initialDeckID: deck.id, content: content,
                        tags: [OnboardingDemo.tag]), in: db, now: now)
                }
            }
            let result = OnboardingResult(deck: deck, demoCount: command.includeDemo ? OnboardingDemo.notes.count : 0)
            try db.execute(sql: "INSERT INTO collection_settings(key, valueJSON) VALUES (?, ?)",
                arguments: [Self.completionKey, BasicNoteDefaults.json(result)])
            return result
        }
    }

    private static func result(_ db: Database) throws -> OnboardingResult? {
        guard let json = try String.fetchOne(db, sql: "SELECT valueJSON FROM collection_settings WHERE key = ?",
                                             arguments: [completionKey]) else { return nil }
        let result = try JSONDecoder().decode(OnboardingResult.self, from: Data(json.utf8))
        guard result.schemaVersion == 1 else { throw CollectionRepositoryError.unsupportedCommandResult }
        return result
    }
}
