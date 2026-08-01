import CompassDomain
import Foundation

/// The ``Clock`` adapter, and **the only place in the codebase where a `Date`
/// becomes a ``Day``.** `docs/technical.md` §3.
///
/// `CompassDomain` may never call `Date()`, `Calendar.current` or
/// `TimeZone.current`; time enters it through this port. The conversion applies
/// the **04:00 civil-day boundary** — a check-in at 01:30 counts for the day the
/// user was awake for. One constant, in Domain, zero UI, and it removes the
/// single most common "I did it but the app says I didn't" moment.
///
/// The conversion is integer arithmetic on the UTC offset, not `Calendar`:
/// ``Day`` is a label with no instant, and routing the label through a
/// calendar's locale and DST machinery is how the label acquires an instant
/// again. `TimeZone.secondsFromGMT(for:)` already accounts for DST at that
/// instant, which is the only calendar fact this needs.
public struct SystemClock: Clock {

    /// 1970-01-01, the day the Unix epoch starts on. The conversion below is in
    /// days since that day; this rebases them onto ``Day``'s 2000-01-01 origin
    /// without repeating the constant.
    private static let unixEpochDay = Day(year: 1970, month: 1, day: 1)

    /// The zone the civil day is labelled in. Injected rather than read at the
    /// point of use so the boundary is testable without changing the machine's
    /// timezone.
    public let timeZone: TimeZone

    private let source: @Sendable () -> Date

    public init(
        timeZone: TimeZone = .current,
        now source: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeZone = timeZone
        self.source = source
    }

    public func now() -> Date { source() }

    public func today(cutoffHour: Int = DayBoundary.cutoffHour) -> Day {
        day(for: now(), cutoffHour: cutoffHour)
    }

    /// The civil day `date` belongs to, with the day starting at `cutoffHour`
    /// local time. 01:30 with a cutoff of 4 is the previous day; 04:00 exactly
    /// is the new one.
    public func day(for date: Date, cutoffHour: Int = DayBoundary.cutoffHour) -> Day {
        let local = Int(date.timeIntervalSince1970.rounded(.down))
            + timeZone.secondsFromGMT(for: date)
        let shifted = local - cutoffHour * 3_600
        return SystemClock.unixEpochDay.adding(SystemClock.floorDiv(shifted, 86_400))
    }

    /// The instant the civil day after `date` begins — the next 04:00 local.
    ///
    /// **The widget's redraw moment, and nothing else's.** A Home Screen widget
    /// renders from a timeline WidgetKit asks for in advance, so it has to say
    /// when what it drew stops being true. Everything on it is a fact about
    /// *today*, and the only scheduled moment today stops being today is the
    /// boundary — so this is the whole refresh policy, with no guessed interval,
    /// no periodic wake-up and no push.
    ///
    /// The offset is resolved **twice**, deliberately. Adding a day's worth of
    /// seconds to an instant is wrong across a DST transition by exactly the hour
    /// that moved: the first pass finds the candidate using the offset in force
    /// now, and the second corrects it using the offset in force there.
    /// `SystemClockTests` pins the property rather than the arithmetic — the
    /// result is the first instant of the next civil day, and one second earlier
    /// is still this one.
    public func nextDayStart(
        after date: Date, cutoffHour: Int = DayBoundary.cutoffHour
    ) -> Date {
        let tomorrow = day(for: date, cutoffHour: cutoffHour).adding(1)
        let localSeconds = (tomorrow - SystemClock.unixEpochDay) * 86_400 + cutoffHour * 3_600

        func instant(usingOffsetAt reference: Date) -> Date {
            Date(
                timeIntervalSince1970:
                    Double(localSeconds - timeZone.secondsFromGMT(for: reference))
            )
        }

        return instant(usingOffsetAt: instant(usingOffsetAt: date))
    }

    /// The device's UTC offset in minutes at `date`, for `Event.zoneOffset`.
    ///
    /// The ``Clock`` port in `docs/technical.md` §2 declares only `now()` and
    /// `today(cutoffHour:)`, so this is a method on the adapter and not on the
    /// port — see the note in `EventJournal.swift` on who stamps an event.
    public func zoneOffsetMinutes(at date: Date) -> Int {
        timeZone.secondsFromGMT(for: date) / 60
    }

    /// Milliseconds since the Unix epoch, as an integer. `recordedAt` is an
    /// integer count because there is no floating point anywhere in a digested
    /// value. `docs/technical.md` §3.
    public func milliseconds(at date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1_000).rounded())
    }

    /// Floor division. Swift's `/` truncates toward zero, which would put every
    /// instant before 1970 on the wrong side of a day boundary.
    private static func floorDiv(_ lhs: Int, _ rhs: Int) -> Int {
        let quotient = lhs / rhs
        return (lhs % rhs != 0 && (lhs < 0) != (rhs < 0)) ? quotient - 1 : quotient
    }
}
