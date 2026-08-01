import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// The 04:00 civil-day boundary, which is the whole reason `SystemClock` exists
/// and the only place a `Date` becomes a `Day`. `docs/technical.md` §3.
///
/// A wrong answer here is what makes the user stop trusting the app, which is
/// what makes him rebuild it. `.claude/skills/testing.md`.
@Suite("SystemClock — the 04:00 civil-day boundary")
struct SystemClockTests {

    private let clock = SystemClock(timeZone: surabaya)

    @Test("01:30 counts for the previous day")
    func lateNightBelongsToTheDayYouWereAwakeFor() {
        #expect(clock.day(for: instant("2026-07-31T01:30:00+07:00")) == day("2026-07-30"))
    }

    @Test("00:30 counts for the previous day")
    func justAfterMidnightBelongsToTheDayYouWereAwakeFor() {
        #expect(clock.day(for: instant("2026-07-31T00:30:00+07:00")) == day("2026-07-30"))
    }

    @Test("23:59 counts for the day it is written on")
    func lastMinuteOfTheCivilDay() {
        #expect(clock.day(for: instant("2026-07-31T23:59:59+07:00")) == day("2026-07-31"))
    }

    @Test("the boundary is closed at 04:00 and open just before it")
    func theBoundaryItself() {
        #expect(clock.day(for: instant("2026-07-31T03:59:59+07:00")) == day("2026-07-30"))
        #expect(clock.day(for: instant("2026-07-31T04:00:00+07:00")) == day("2026-07-31"))
    }

    @Test("today() reads the injected instant")
    func todayUsesNow() {
        #expect(frozenClock(at: "2026-07-31T01:30:00+07:00").today() == day("2026-07-30"))
        #expect(frozenClock(at: "2026-07-31T09:00:00+07:00").today() == day("2026-07-31"))
    }

    @Test("the cutoff hour is the one constant in Domain")
    func cutoffComesFromDomain() {
        #expect(DayBoundary.cutoffHour == 4)
        #expect(
            clock.day(for: instant("2026-07-31T01:30:00+07:00"))
                == clock.day(for: instant("2026-07-31T01:30:00+07:00"), cutoffHour: 4)
        )
    }

    @Test("zoneOffset is recorded in minutes")
    func zoneOffsetInMinutes() {
        #expect(clock.zoneOffsetMinutes(at: instant("2026-07-31T09:00:00+07:00")) == 420)
    }

    @Test("recordedAt is an integer count of milliseconds")
    func millisecondsAreIntegers() {
        #expect(clock.milliseconds(at: Date(timeIntervalSince1970: 1_784_000_000)) == 1_784_000_000_000)
    }

    // MARK: DST, travel, and the arithmetic that has no calendar in it

    @Test("DST forward: the label does not move")
    func springForward() {
        let newYork = SystemClock(timeZone: TimeZone(identifier: "America/New_York")!)
        // 01:30 EST, before the 02:00 jump — still the previous civil day.
        #expect(newYork.day(for: instant("2026-03-08T01:30:00-05:00")) == day("2026-03-07"))
        // 05:00 EDT, after it — the new civil day, one hour shorter and no wiser.
        #expect(newYork.day(for: instant("2026-03-08T05:00:00-04:00")) == day("2026-03-08"))
    }

    @Test("DST backward: 01:30 happens twice and lands on the same day both times")
    func fallBack() {
        let newYork = SystemClock(timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(newYork.day(for: instant("2026-11-01T01:30:00-04:00")) == day("2026-10-31"))
        #expect(newYork.day(for: instant("2026-11-01T01:30:00-05:00")) == day("2026-10-31"))
    }

    @Test("travel: one instant, two zones, two labels")
    func surabayaToNewYork() {
        let moment = instant("2026-07-31T10:00:00+07:00")
        let newYork = SystemClock(timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(SystemClock(timeZone: surabaya).day(for: moment) == day("2026-07-31"))
        #expect(newYork.day(for: moment) == day("2026-07-30"))
    }

    @Test("leap day is a day like any other")
    func leapDay() {
        #expect(clock.day(for: instant("2028-02-29T12:00:00+07:00")) == day("2028-02-29"))
        #expect(clock.day(for: instant("2028-03-01T02:00:00+07:00")) == day("2028-02-29"))
    }

    @Test("instants before 1970 floor in the right direction")
    func beforeTheUnixEpoch() {
        let utc = SystemClock(timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(utc.day(for: instant("1969-12-31T23:00:00+00:00")) == day("1969-12-31"))
        #expect(utc.day(for: instant("1970-01-01T02:00:00+00:00")) == day("1969-12-31"))
        #expect(utc.day(for: instant("1970-01-01T04:00:00+00:00")) == day("1970-01-01"))
    }

    // MARK: When the widget has to redraw

    /// The widget's whole refresh policy is one instant: the moment what it drew
    /// stops being true. Everything on it is a fact about today, so that moment
    /// is the 04:00 boundary and nothing else.
    ///
    /// These assert the **property** rather than the arithmetic — the answer is
    /// the first instant of the next civil day, and one second earlier is still
    /// this one — because that is the sentence the widget depends on, and the one
    /// that has to survive a timezone doing something awkward.
    @Test("the next day starts at the next 04:00, and not a second earlier")
    func nextDayStartIsTheBoundary() {
        for iso in [
            "2026-07-31T09:00:00+07:00",   // an ordinary afternoon
            "2026-07-31T03:59:59+07:00",   // one second before the roll
            "2026-07-31T04:00:00+07:00",   // exactly on it
            "2026-07-31T23:59:59+07:00",   // late evening
            "2026-07-31T01:30:00+07:00",   // the 01:30 case the boundary exists for
        ] {
            let now = instant(iso)
            let next = clock.nextDayStart(after: now)

            #expect(next > now, "\(iso): the redraw moment is in the past")
            #expect(clock.day(for: next) == clock.day(for: now).adding(1), "\(iso)")
            #expect(clock.day(for: next.addingTimeInterval(-1)) == clock.day(for: now), "\(iso)")
        }
    }

    @Test("the redraw moment survives both DST transitions")
    func nextDayStartAcrossDST() {
        // The hour that moves is exactly the error `addingTimeInterval(86_400)`
        // would make, and a widget that redrew an hour late would show yesterday's
        // booleans on the one morning of the year the user is most likely to
        // notice.
        let newYork = SystemClock(timeZone: TimeZone(identifier: "America/New_York")!)
        for iso in [
            "2026-03-07T12:00:00-05:00",   // the day before spring forward
            "2026-03-08T12:00:00-04:00",   // the day of
            "2026-10-31T12:00:00-04:00",   // the day before fall back
            "2026-11-01T12:00:00-05:00",   // the day of
        ] {
            let now = instant(iso)
            let next = newYork.nextDayStart(after: now)

            #expect(next > now, "\(iso): the redraw moment is in the past")
            #expect(newYork.day(for: next) == newYork.day(for: now).adding(1), "\(iso)")
            #expect(
                newYork.day(for: next.addingTimeInterval(-1)) == newYork.day(for: now), "\(iso)"
            )
        }
    }
}
