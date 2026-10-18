import CardsCore
import Foundation
import Testing

private func utc(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
private struct TestClock: CardsCore.Clock {
    let value: Date
    func now() -> Date { value }
}

private struct DayCase: Sendable {
    let zone: String
    let instant: String
    let key: String
    let start: String
    let end: String
}

private let dayCases: [DayCase] = [
    .init(zone: "UTC", instant: "2026-01-01T03:59:59Z", key: "2025-12-31",
          start: "2025-12-31T04:00:00Z", end: "2026-01-01T04:00:00Z"),
    .init(zone: "UTC", instant: "2026-01-01T04:00:00Z", key: "2026-01-01",
          start: "2026-01-01T04:00:00Z", end: "2026-01-02T04:00:00Z"),
    .init(zone: "Europe/Moscow", instant: "2026-10-18T00:59:59Z", key: "2026-10-17",
          start: "2026-10-17T01:00:00Z", end: "2026-10-18T01:00:00Z"),
    .init(zone: "Europe/Moscow", instant: "2026-10-18T01:00:00Z", key: "2026-10-18",
          start: "2026-10-18T01:00:00Z", end: "2026-10-19T01:00:00Z"),
    .init(zone: "Asia/Kathmandu", instant: "2026-10-17T22:15:00Z", key: "2026-10-18",
          start: "2026-10-17T22:15:00Z", end: "2026-10-18T22:15:00Z"),
    .init(zone: "America/New_York", instant: "2026-03-08T07:59:59Z", key: "2026-03-07",
          start: "2026-03-07T09:00:00Z", end: "2026-03-08T08:00:00Z"),
    .init(zone: "America/New_York", instant: "2026-03-08T08:00:00Z", key: "2026-03-08",
          start: "2026-03-08T08:00:00Z", end: "2026-03-09T08:00:00Z"),
    .init(zone: "America/New_York", instant: "2026-11-01T08:59:59Z", key: "2026-10-31",
          start: "2026-10-31T08:00:00Z", end: "2026-11-01T09:00:00Z"),
    .init(zone: "America/New_York", instant: "2026-11-01T09:00:00Z", key: "2026-11-01",
          start: "2026-11-01T09:00:00Z", end: "2026-11-02T09:00:00Z"),
    .init(zone: "Europe/Berlin", instant: "2026-03-29T01:59:59Z", key: "2026-03-28",
          start: "2026-03-28T03:00:00Z", end: "2026-03-29T02:00:00Z"),
    .init(zone: "Europe/Berlin", instant: "2026-10-25T02:59:59Z", key: "2026-10-24",
          start: "2026-10-24T02:00:00Z", end: "2026-10-25T03:00:00Z"),
    // Lord Howe changes its offset by 30 minutes, not one hour.
    .init(zone: "Australia/Lord_Howe", instant: "2026-10-03T16:59:59Z", key: "2026-10-03",
          start: "2026-10-02T17:30:00Z", end: "2026-10-03T17:00:00Z"),
    .init(zone: "Australia/Lord_Howe", instant: "2026-04-04T17:29:59Z", key: "2026-04-04",
          start: "2026-04-03T17:00:00Z", end: "2026-04-04T17:30:00Z"),
    .init(zone: "UTC", instant: "2024-03-01T03:00:00Z", key: "2024-02-29",
          start: "2024-02-29T04:00:00Z", end: "2024-03-01T04:00:00Z"),
]

@Test(arguments: dayCases)
private func studyDaysUseCollectionCalendar(test: DayCase) throws {
    let calculator = try StudyDayCalculator(timeZoneID: test.zone)
    let instant = utc(test.instant)
    let day = try calculator.studyDay(clock: TestClock(value: instant))
    #expect(day.key.rawValue == test.key)
    #expect(day.timeZoneID == test.zone)
    #expect(day.start == utc(test.start))
    #expect(day.end == utc(test.end))
    #expect(day.contains(instant))
    #expect(day.contains(day.start))
    #expect(!day.contains(day.end))
    #expect(try calculator.studyDay(containing: day.end).start == day.end)
    #expect(try calculator.studyDay(containing: day.start.addingTimeInterval(-0.001)).end == day.start)
}

@Test(arguments: ["2026-03-08T06:59:59Z", "2026-03-08T07:00:00Z", "2026-03-08T07:30:00Z"])
func nonexistentRolloverUsesFirstValidTime(instant: String) throws {
    let calculator = try StudyDayCalculator(timeZoneID: "America/New_York", rollover: .init(hour: 2, minute: 30))
    let date = utc(instant)
    let day = try calculator.studyDay(containing: date)
    let afterBoundary = date >= utc("2026-03-08T07:00:00Z")
    #expect(day.key.rawValue == (afterBoundary ? "2026-03-08" : "2026-03-07"))
    #expect((afterBoundary ? day.start : day.end) == utc("2026-03-08T07:00:00Z"))
}

@Test(arguments: ["2026-11-01T05:29:59Z", "2026-11-01T05:30:00Z", "2026-11-01T06:00:00Z", "2026-11-01T06:30:00Z"])
func repeatedRolloverOccursOnlyOnce(instant: String) throws {
    let calculator = try StudyDayCalculator(timeZoneID: "America/New_York", rollover: .init(hour: 1, minute: 30))
    let date = utc(instant)
    let day = try calculator.studyDay(containing: date)
    let afterBoundary = date >= utc("2026-11-01T05:30:00Z")
    #expect(day.key.rawValue == (afterBoundary ? "2026-11-01" : "2026-10-31"))
    #expect((afterBoundary ? day.start : day.end) == utc("2026-11-01T05:30:00Z"))
}

@Test func midnightAndSkippedCivilDate() throws {
    let midnight = try StudyDayCalculator(timeZoneID: "UTC", rollover: .init(hour: 0))
    #expect(try midnight.studyDay(containing: utc("2026-01-01T00:00:00Z")).key.rawValue == "2026-01-01")
    let samoa = try StudyDayCalculator(timeZoneID: "Pacific/Apia")
    let day = try samoa.studyDay(containing: utc("2011-12-30T13:59:59Z"))
    #expect(day.key.rawValue == "2011-12-29")
    #expect(day.start == utc("2011-12-29T14:00:00Z"))
    #expect(day.end == utc("2011-12-30T14:00:00Z"))
    #expect(try samoa.studyDay(containing: day.end).key.rawValue == "2011-12-31")
}

@Test func midnightRolloverHandlesMissingMidnightWithoutSkippingTheNextBoundary() throws {
    let calculator = try StudyDayCalculator(timeZoneID: "America/Sao_Paulo", rollover: .init(hour: 0))
    let day = try calculator.studyDay(containing: utc("2018-11-04T12:00:00Z"))
    #expect(day.key.rawValue == "2018-11-04")
    #expect(day.start == utc("2018-11-04T03:00:00Z"))
    #expect(day.end == utc("2018-11-05T02:00:00Z"))
    #expect(try calculator.studyDay(containing: day.end).key.rawValue == "2018-11-05")
}

@Test func invalidCalendarSettingsFailWithTypedErrors() throws {
    #expect(throws: ValidationError.invalidTimeZone("Invalid/Zone")) {
        try StudyDayCalculator(timeZoneID: "Invalid/Zone")
    }
    for (hour, minute) in [(-1, 0), (24, 0), (4, -1), (4, 60)] {
        #expect(throws: ValidationError.outOfRange(field: "studyDayRollover")) {
            try StudyDayRollover(hour: hour, minute: minute)
        }
    }
    #expect(throws: ValidationError.invalidStudyDate) { try StudyDayKey(year: 2026, month: 2, day: 29) }
    #expect(throws: ValidationError.invalidStudyDate) {
        try JSONDecoder().decode(StudyDayKey.self, from: Data("\"2026-1-01\"".utf8))
    }
    #expect(throws: ValidationError.outOfRange(field: "studyDayRollover")) {
        try JSONDecoder().decode(StudyDayRollover.self, from: Data("{\"hour\":24,\"minute\":0}".utf8))
    }
}

@Test(arguments: [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude])
func invalidStudyInstantsAreRejected(seconds: Double) throws {
    let calculator = try StudyDayCalculator(timeZoneID: "UTC")
    #expect(throws: ValidationError.invalidStudyDate) {
        try calculator.studyDay(containing: Date(timeIntervalSince1970: seconds))
    }
}
