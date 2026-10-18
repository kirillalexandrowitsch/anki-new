import CardsCore
import Foundation
import Testing

@Test(arguments: ["", " ", "\n\t\r", "\u{00A0}\u{2003}"])
func emptyNamesAreRejected(input: String) {
    #expect(throws: ValidationError.emptyName) { try EntityName(input) }
}

@Test(arguments: [
    ("  Cafe\u{301}\n", "Café", "café"),
    ("АНГЛИЙСКИЙ", "АНГЛИЙСКИЙ", "английский"),
    ("Straße", "Straße", "strasse"),
    ("I", "I", "i"),
    ("ΟΣ", "ΟΣ", "οσ"),
])
func namesHaveStableDisplayAndComparisonValues(input: String, display: String, normalized: String) throws {
    let name = try EntityName(input)
    #expect(name.displayValue == display)
    #expect(name.normalizedValue == normalized)
    #expect(try JSONDecoder().decode(EntityName.self, from: JSONEncoder().encode(name)) == name)
}

@Test(arguments: [("Cafe\u{301}", "CAFÉ"), ("deck", " DECK "), ("Straße", "STRASSE"), ("Σ", "ς")])
func equivalentNamesConflict(first: String, second: String) throws {
    let name = try EntityName(first)
    #expect(throws: ValidationError.duplicateName(normalized: name.normalizedValue)) {
        try name.validateUniqueness(among: [EntityName(second)])
    }
    try name.validateUniqueness(among: []) // A different parent/scope is not a duplicate.
}

@Test func normalizationPreservesMeaningfulDifferences() throws {
    try EntityName("café").validateUniqueness(among: [EntityName("cafe")])
    try EntityName("a  b").validateUniqueness(among: [EntityName("a b")])
    try EntityName("it's").validateUniqueness(among: [EntityName("its")])
    #expect(throws: ValidationError.emptyName) {
        try JSONDecoder().decode(EntityName.self, from: Data(#"" ""#.utf8))
    }
}

@Test func typedIDsAndImmutableSnapshotsRoundTrip() throws {
    let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    let noteID = NoteID(uuid)
    #expect(try NoteID(uuidString: uuid.uuidString) == noteID)
    #expect(throws: ValidationError.invalidUUID("bad")) { try CardID(uuidString: "bad") }
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    #expect(String(decoding: try encoder.encode(noteID), as: UTF8.self) == "\"12345678-1234-1234-1234-123456789abc\"")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let deck = Deck(id: DeckID(), name: try EntityName("English"))
    let note = Note(id: noteID, noteTypeID: NoteTypeID(), fields: ["front": "word", "back": "слово"],
                    createdAt: now, updatedAt: now)
    let card = Card(id: CardID(), noteID: note.id, deckID: deck.id,
                    variantKey: "basic.forward", templateID: "basic.front", suspended: true,
                    buriedUntil: now, createdAt: now)
    #expect(try decoder.decode(Deck.self, from: encoder.encode(deck)) == deck)
    #expect(try decoder.decode(Note.self, from: encoder.encode(note)) == note)
    #expect(try decoder.decode(Card.self, from: encoder.encode(card)) == card)
    #expect(Grade.allCases.map(\.rawValue) == [1, 2, 3, 4])
    #expect(SchedulePhase.allCases.map(\.rawValue) == ["new", "learning", "review", "relearning"])
    #expect(throws: (any Error).self) { try decoder.decode(Grade.self, from: Data("5".utf8)) }
}

@Test func numericUnitsValidateBoundsAndDecoding() throws {
    #expect(try Revision.initial.advanced().rawValue == 1)
    #expect(throws: ValidationError.outOfRange(field: "revision")) { try Revision(-1) }
    #expect(throws: ValidationError.arithmeticOverflow) { try Revision(Int64.max).advanced() }
    #expect(try DurationMilliseconds(1_000).adding(DurationMilliseconds(500)).rawValue == 1_500)
    #expect(throws: ValidationError.arithmeticOverflow) {
        try DurationMilliseconds(Int64.max).adding(DurationMilliseconds(1))
    }
    #expect(throws: ValidationError.outOfRange(field: "durationMilliseconds")) { try DurationMilliseconds(-1) }
    #expect(throws: ValidationError.outOfRange(field: "schedulerIntervalDays")) { try SchedulerIntervalDays(-1) }
    #expect(throws: ValidationError.outOfRange(field: "revision")) {
        try JSONDecoder().decode(Revision.self, from: Data("-1".utf8))
    }
    #expect(throws: ValidationError.outOfRange(field: "durationMilliseconds")) {
        try JSONDecoder().decode(DurationMilliseconds.self, from: Data("-1".utf8))
    }
    #expect(throws: ValidationError.outOfRange(field: "schedulerIntervalDays")) {
        try JSONDecoder().decode(SchedulerIntervalDays.self, from: Data("-1".utf8))
    }
}

@Test(arguments: [(1_800_000_000.125, Int64(1_800_000_000_125)), (-0.25, -250), (0.0, 0)])
func epochConversionsAreExplicit(seconds: Double, milliseconds: Int64) throws {
    let instant = try EpochMilliseconds(date: Date(timeIntervalSince1970: seconds))
    #expect(instant.rawValue == milliseconds)
    #expect(instant.date.timeIntervalSince1970 == seconds)
    #expect(try JSONDecoder().decode(EpochMilliseconds.self, from: JSONEncoder().encode(instant)) == instant)
}

@Test(arguments: [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude, 9_223_372_036_854_776.0])
func unrepresentableInstantsFail(seconds: Double) {
    #expect(throws: ValidationError.outOfRange(field: "epochMilliseconds")) {
        try EpochMilliseconds(date: Date(timeIntervalSince1970: seconds))
    }
}

@Test(arguments: [Int64(-1_000), 0, 1_700_000_000_000, 1_800_000_000_000])
func dateRoundTripPreservesEveryMillisecondNearEpochAndCurrentDates(base: Int64) throws {
    for value in base..<(base + 1_000) {
        let timestamp = EpochMilliseconds(value)
        #expect(try EpochMilliseconds(date: timestamp.date) == timestamp)
    }
}
