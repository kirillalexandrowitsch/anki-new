import Foundation

public struct StudyDayRollover: Hashable, Codable, Sendable {
    public let hour: Int
    public let minute: Int
    public static let fourAM = StudyDayRollover(uncheckedHour: 4, minute: 0)

    private init(uncheckedHour: Int, minute: Int) {
        hour = uncheckedHour
        self.minute = minute
    }

    public init(hour: Int, minute: Int = 0) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw ValidationError.outOfRange(field: "studyDayRollover")
        }
        self.init(uncheckedHour: hour, minute: minute)
    }

    private enum CodingKeys: String, CodingKey { case hour, minute }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(hour: values.decode(Int.self, forKey: .hour),
                      minute: values.decode(Int.self, forKey: .minute))
    }
}

/// Gregorian local date, not a UTC timestamp. ISO lexical order equals calendar order.
public struct StudyDayKey: Hashable, Comparable, Codable, Sendable {
    public let rawValue: String

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            throw ValidationError.invalidStudyDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: date) == parts else {
            throw ValidationError.invalidStudyDate
        }
        rawValue = String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            throw ValidationError.invalidStudyDate
        }
        try self.init(year: year, month: month, day: day)
        guard rawValue == value else { throw ValidationError.invalidStudyDate }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct StudyDay: Equatable, Sendable {
    public let key: StudyDayKey
    public let timeZoneID: String
    public let start: Date
    public let end: Date

    /// Half-open [start, end); end is also the next study-day boundary.
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

public struct StudyDayCalculator: Sendable {
    public let timeZoneID: String
    public let rollover: StudyDayRollover
    private let calendar: Calendar

    public init(timeZoneID: String, rollover: StudyDayRollover = .fourAM) throws {
        guard let zone = TimeZone(identifier: timeZoneID) else {
            throw ValidationError.invalidTimeZone(timeZoneID)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone
        self.calendar = calendar
        self.timeZoneID = timeZoneID
        self.rollover = rollover
    }

    public func studyDay(clock: any Clock) throws -> StudyDay {
        try studyDay(containing: clock.now())
    }

    public func studyDay(containing instant: Date) throws -> StudyDay {
        let seconds = instant.timeIntervalSince1970
        guard seconds.isFinite, (-62_135_596_800..<253_402_300_800).contains(seconds) else {
            throw ValidationError.invalidStudyDate
        }
        var localDay = calendar.startOfDay(for: instant)
        // Compare civil boundaries, never subtract a fixed number of seconds from now.
        if instant < (try boundary(on: localDay)) {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: localDay) else {
                throw ValidationError.invalidStudyDate
            }
            localDay = previous
        }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: localDay) else {
            throw ValidationError.invalidStudyDate
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: localDay)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            throw ValidationError.invalidStudyDate
        }
        return try StudyDay(key: StudyDayKey(year: year, month: month, day: day), timeZoneID: timeZoneID,
                            start: boundary(on: localDay), end: boundary(on: nextDay))
    }

    private func boundary(on localDay: Date) throws -> Date {
        // A missing rollover (spring gap) uses the first existing time after it.
        // A repeated rollover (autumn fold) uses its first occurrence, once per date.
        guard let boundary = calendar.nextDate(
            // Calendar day addition can preserve 01:00 after a missing midnight.
            // Re-anchor to that date's start so a following 00:00 is not skipped.
            after: calendar.startOfDay(for: localDay).addingTimeInterval(-1),
            matching: DateComponents(hour: rollover.hour, minute: rollover.minute, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
        ) else { throw ValidationError.invalidStudyDate }
        return boundary
    }
}
