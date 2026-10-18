import Foundation

/// UTC timestamp for storage boundaries, distinct from an elapsed duration.
public struct EpochMilliseconds: Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int64
    public init(_ value: Int64) { rawValue = value }

    /// Explicitly quantize to the nearest millisecond (ties away from zero).
    /// Rounding avoids dropping a millisecond to Date's floating-point representation.
    public init(date: Date) throws {
        let value = (date.timeIntervalSince1970 * 1_000).rounded(.toNearestOrAwayFromZero)
        guard value.isFinite, value >= -9_223_372_036_854_775_808,
              value < 9_223_372_036_854_775_808 else {
            throw ValidationError.outOfRange(field: "epochMilliseconds")
        }
        rawValue = Int64(value)
    }

    public var date: Date { Date(timeIntervalSince1970: Double(rawValue) / 1_000) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Int64.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Nonnegative elapsed time (response/session durations), never a wall-clock date.
public struct DurationMilliseconds: Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int64
    public static let zero = DurationMilliseconds(unchecked: 0)
    private init(unchecked value: Int64) { rawValue = value }

    public init(_ value: Int64) throws {
        guard value >= 0 else { throw ValidationError.outOfRange(field: "durationMilliseconds") }
        self.init(unchecked: value)
    }

    public func adding(_ other: Self) throws -> Self {
        let (sum, overflow) = rawValue.addingReportingOverflow(other.rawValue)
        guard !overflow else { throw ValidationError.arithmeticOverflow }
        return try Self(sum)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Int64.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Whole long-term scheduler days. Not a count of collection calendar days;
/// no implicit conversion to milliseconds or a StudyDayKey is provided.
public struct SchedulerIntervalDays: Hashable, Comparable, Codable, Sendable {
    public let rawValue: Int
    public init(_ value: Int) throws {
        guard value >= 0 else { throw ValidationError.outOfRange(field: "schedulerIntervalDays") }
        rawValue = value
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Int.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
