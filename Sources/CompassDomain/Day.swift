import Foundation

/// A civil date label. `docs/technical.md` §3, `docs/achievement-protocol.md` §2.1.
///
/// `Day` is **not** a `Date`. It has no instant, no timezone and no locale, so
/// streak arithmetic is integer arithmetic on labels and DST, leap seconds and
/// flying between timezones cannot corrupt it.
///
/// - Internal representation is the ordinal: days since 2000-01-01, proleptic
///   Gregorian, civil.
/// - On-disk representation is **always** the ISO string `"2026-07-31"`, never
///   the ordinal. The integer is for arithmetic; the string is for a human
///   reading the log with `grep`, which is a large part of why the log is text.
///
/// A `Day` is never derived from a `Date` inside `CompassDomain`. That
/// conversion happens once, in `CompassInfrastructure`'s `SystemClock`, at the
/// moment of the tap, applying the ``DayBoundary/cutoffHour`` day-start hour.
public struct Day: Hashable, Comparable, Codable, Sendable, Strideable, CustomStringConvertible {

    /// Days since 2000-01-01, proleptic Gregorian, civil.
    public let ordinal: Int

    public init(ordinal: Int) {
        self.ordinal = ordinal
    }

    /// Traps on a date that does not exist. Every caller inside the app builds a
    /// `Day` from the clock or from ``init(iso:)``, both of which are validated.
    public init(year: Int, month: Int, day: Int) {
        precondition((1...12).contains(month), "Day: month \(month) out of range")
        precondition(
            (1...Day.daysInMonth(year: year, month: month)).contains(day),
            "Day: \(year)-\(month)-\(day) does not exist"
        )
        self.ordinal = Day.ordinal(year: year, month: month, day: day)
    }

    /// Parses exactly `"YYYY-MM-DD"`, zero-padded, and nothing else. Returns
    /// `nil` for anything the format does not describe, including dates that do
    /// not exist.
    public init?(iso: String) {
        let bytes = Array(iso.utf8)
        guard bytes.count == 10,
              bytes[4] == UInt8(ascii: "-"),
              bytes[7] == UInt8(ascii: "-")
        else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var accumulator = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                accumulator = accumulator * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return accumulator
        }

        guard let year = number(0..<4),
              let month = number(5..<7),
              let day = number(8..<10),
              (1...12).contains(month),
              (1...Day.daysInMonth(year: year, month: month)).contains(day)
        else { return nil }

        self.ordinal = Day.ordinal(year: year, month: month, day: day)
    }

    // MARK: Civil components

    public var year: Int { Day.civil(fromOrdinal: ordinal).year }
    public var month: Int { Day.civil(fromOrdinal: ordinal).month }
    public var day: Int { Day.civil(fromOrdinal: ordinal).day }

    /// The on-disk and on-screen form: `"2026-07-31"`.
    public var iso: String {
        let civil = Day.civil(fromOrdinal: ordinal)
        let year = civil.year < 0
            ? "-" + Day.pad(-civil.year, width: 4)
            : Day.pad(civil.year, width: 4)
        return year + "-" + Day.pad(civil.month, width: 2) + "-" + Day.pad(civil.day, width: 2)
    }

    public var description: String { iso }

    // MARK: Arithmetic

    /// Integer arithmetic on labels. No calendar, no timezone.
    public func adding(_ days: Int) -> Day {
        Day(ordinal: ordinal + days)
    }

    public static func + (day: Day, days: Int) -> Day { day.adding(days) }
    public static func - (day: Day, days: Int) -> Day { day.adding(-days) }

    /// Whole days from `rhs` to `lhs`.
    public static func - (lhs: Day, rhs: Day) -> Int { lhs.ordinal - rhs.ordinal }

    public func advanced(by n: Int) -> Day { adding(n) }
    public func distance(to other: Day) -> Int { other.ordinal - ordinal }

    // MARK: Codable — the ISO string, never the ordinal

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = Day(iso: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Day must be an ISO civil date \"YYYY-MM-DD\", got \"\(raw)\""
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }

    // MARK: Civil calendar, as pure integer arithmetic

    /// Days from 1970-01-01 to 2000-01-01.
    private static let epochOffset = 10_957

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: isLeapYear(year) ? 29 : 28
        default: 0
        }
    }

    /// Howard Hinnant's `days_from_civil`, rebased on 2000-01-01. Proleptic
    /// Gregorian, valid for any year, no `Calendar` and no `TimeZone`.
    private static func ordinal(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468 - epochOffset
    }

    /// Howard Hinnant's `civil_from_days`, rebased on 2000-01-01.
    private static func civil(fromOrdinal ordinal: Int) -> (year: Int, month: Int, day: Int) {
        let z = ordinal + epochOffset + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth + (shiftedMonth < 10 ? 3 : -9)
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}
