import Foundation

/// A civil (Gregorian) calendar date with no time or time zone attached.
///
/// Task identity is keyed on local dates ("2026-10-02"), never on 24-hour
/// intervals, so DST shifts and time-zone changes cannot create or skip days.
/// Day arithmetic is pure integer math on the civil date; the time zone only
/// matters when converting to or from an absolute `Date`.
public struct LocalDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local date of `date` as seen in `timeZone`. Always Gregorian, even
    /// if the device uses another calendar, so stored keys stay stable.
    public init(_ date: Date, in timeZone: TimeZone) {
        let c = Self.gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    public var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public init(ordinal z0: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    public func adding(days: Int) -> LocalDay { LocalDay(ordinal: ordinal + days) }

    /// Whole calendar days from `self` to `other` (positive if `other` is later).
    public func days(until other: LocalDay) -> Int { other.ordinal - ordinal }

    /// The weekday of this date (1970-01-01 was a Thursday).
    public var weekday: Weekday {
        let r = ((ordinal % 7) + 7 + 4) % 7 // 0 = Sunday
        return Weekday(rawValue: r + 1)!
    }

    /// The absolute time of `hour:minute` on this date in `timeZone`. If that
    /// wall-clock time does not exist (DST gap), Foundation moves it forward.
    public func date(hour: Int = 0, minute: Int = 0, in timeZone: TimeZone) -> Date {
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return Self.gregorian(timeZone).date(from: comps)!
    }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool { lhs.ordinal < rhs.ordinal }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }
}

extension LocalDay: CustomStringConvertible, Codable {
    /// ISO "yyyy-MM-dd".
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public init?(string: String) {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = LocalDay(string: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad LocalDay \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public enum Weekday: Int, Codable, CaseIterable, Comparable, Sendable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}
