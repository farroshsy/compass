import Foundation
import Testing

@testable import CompassDomain

// Day arithmetic is where the real bugs live, and a wrong answer here is what
// makes the user stop trusting the app — which is what makes him rebuild it.
// `docs/technical.md` §9.1.

@Suite("Day — the ordinal")
struct DayOrdinalTests {

    @Test("The epoch is 2000-01-01")
    func epoch() {
        #expect(Day(year: 2000, month: 1, day: 1).ordinal == 0)
        #expect(Day(ordinal: 0).iso == "2000-01-01")
    }

    @Test("A known day has a known ordinal")
    func knownOrdinal() {
        // 26 years (7 of them leap) to 2026-01-01, then 211 days to 07-31.
        #expect(Day(year: 2026, month: 7, day: 31).ordinal == 9708)
    }

    @Test("Civil components round-trip for every ordinal across four centuries")
    func roundTrip() {
        for ordinal in stride(from: -36_600, through: 73_100, by: 1) {
            let subject = Day(ordinal: ordinal)
            let rebuilt = Day(year: subject.year, month: subject.month, day: subject.day)
            #expect(rebuilt == subject, "ordinal \(ordinal) did not round-trip")
        }
    }

    @Test("Days before the epoch are negative and still exact")
    func beforeEpoch() {
        #expect(Day(year: 1999, month: 12, day: 31).ordinal == -1)
        #expect(Day(ordinal: -1).iso == "1999-12-31")
        #expect(Day(year: 1900, month: 1, day: 1).ordinal == -36_524)
    }
}

@Suite("Day — arithmetic")
struct DayArithmeticTests {

    @Test("Crossing a month boundary is one integer step")
    func monthBoundary() {
        #expect(day("2026-01-31").adding(1) == day("2026-02-01"))
        #expect(day("2026-02-01").adding(-1) == day("2026-01-31"))
        #expect(day("2026-04-30") + 1 == day("2026-05-01"))
        #expect(day("2026-03-01") - 1 == day("2026-02-28"))
    }

    @Test("February ends on the 28th in a common year and the 29th in a leap year")
    func februaryLength() {
        #expect(day("2026-02-28").adding(1) == day("2026-03-01"))
        #expect(day("2024-02-28").adding(1) == day("2024-02-29"))
        #expect(day("2024-02-29").adding(1) == day("2024-03-01"))
        // 1900 and 2100 are not leap years; 2000 is.
        #expect(day("2100-02-28").adding(1) == day("2100-03-01"))
        #expect(day("2000-02-28").adding(1) == day("2000-02-29"))
    }

    @Test("Crossing a year boundary is one integer step")
    func yearBoundary() {
        #expect(day("2025-12-31").adding(1) == day("2026-01-01"))
        #expect(day("2026-01-01").adding(-1) == day("2025-12-31"))
        #expect(day("2024-12-31").adding(1) == day("2025-01-01"))
    }

    @Test("Distance counts whole days across a common and a leap year")
    func distance() {
        #expect(day("2026-01-01") - day("2025-01-01") == 365)
        #expect(day("2025-01-01") - day("2024-01-01") == 366)
        #expect(day("2026-01-01").distance(to: day("2026-12-31")) == 364)
        #expect(day("2026-07-31").distance(to: day("2026-07-31")) == 0)
    }

    @Test("Adding a whole month day by day lands where a calendar would")
    func walkAMonth() {
        var subject = day("2026-01-15")
        for _ in 0..<31 { subject = subject.adding(1) }
        #expect(subject == day("2026-02-15"))
    }

    @Test("Adding a whole year day by day lands where a calendar would")
    func walkAYear() {
        var subject = day("2025-03-01")
        for _ in 0..<365 { subject = subject.adding(1) }
        #expect(subject == day("2026-03-01"))

        // 2024 is a leap year, so the same walk lands one day short.
        var leap = day("2024-03-01")
        for _ in 0..<365 { leap = leap.adding(1) }
        #expect(leap == day("2025-03-01"))
    }

    @Test("A gap of exactly one day is a gap of exactly one")
    func oneDayGap() {
        let first = day("2026-07-30")
        let third = day("2026-08-01")
        #expect(third - first == 2)
        #expect(first.adding(1) == day("2026-07-31"))
    }

    @Test("Comparison is integer comparison on the ordinal")
    func comparison() {
        #expect(day("2026-07-30") < day("2026-07-31"))
        #expect(day("2026-08-01") > day("2026-07-31"))
        #expect(!(day("2026-07-31") < day("2026-07-31")))
        #expect(Array(day("2026-07-30")...day("2026-08-02")).count == 4)
    }
}

@Suite("Day — encoding")
struct DayEncodingTests {

    @Test("A Day encodes as an ISO string, never as the ordinal")
    func encodesAsISOString() throws {
        let subject = day("2026-07-31")
        let encoded = try JSONEncoder().encode(subject)
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(text == "\"2026-07-31\"")
        #expect(!text.contains("9708"))
        #expect(!text.contains("ordinal"))
    }

    @Test("A Day nested in an object still encodes as an ISO string")
    func encodesInsideAnObject() throws {
        struct Wrapper: Codable { let day: Day }
        let encoded = try JSONEncoder().encode(Wrapper(day: day("2026-01-02")))
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text == #"{"day":"2026-01-02"}"#)
    }

    @Test("Components are zero-padded")
    func zeroPadding() {
        #expect(day("2026-01-02").iso == "2026-01-02")
        #expect(Day(year: 2026, month: 1, day: 2).description == "2026-01-02")
        #expect(Day(year: 999, month: 12, day: 31).iso == "0999-12-31")
    }

    @Test("Encoding round-trips through a decoder")
    func roundTrip() throws {
        for candidate in ["2000-01-01", "1999-12-31", "2024-02-29", "2026-07-31", "2999-12-31"] {
            let subject = day(candidate)
            let decoded = try JSONDecoder().decode(
                Day.self, from: try JSONEncoder().encode(subject)
            )
            #expect(decoded == subject)
            #expect(decoded.iso == candidate)
        }
    }

    @Test("Decoding rejects anything that is not a zero-padded civil date")
    func rejectsMalformed() {
        for candidate in [
            "\"2026-13-01\"",   // month 13
            "\"2026-02-30\"",   // day does not exist
            "\"2026-7-31\"",    // not zero-padded
            "\"2026-07-31T00:00:00Z\"",
            "\"\"",
            "\"not a day\"",
            "9708",             // the ordinal is never the on-disk form
        ] {
            let data = Data(candidate.utf8)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(Day.self, from: data)
            }
        }
    }

    @Test("A malformed ISO string fails to parse rather than trapping")
    func isoParsing() {
        #expect(Day(iso: "2026-02-29") == nil)  // 2026 is not a leap year
        #expect(Day(iso: "2024-02-29") != nil)
        #expect(Day(iso: "2026-00-01") == nil)
        #expect(Day(iso: "2026-01-00") == nil)
        #expect(Day(iso: "20260731") == nil)
    }
}
