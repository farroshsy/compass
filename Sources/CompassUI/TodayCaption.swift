import CompassDomain
import Foundation

/// The line under the number: "128 days recorded since 5 December 2025".
///
/// The bare word "days" used to sit here, under a 64pt number. The design
/// replaced both, and recorded why: **the number carries no signal.** 128 to
/// 129 is imperceptible, and it was nonetheless the largest thing on the
/// screen. The date is a fact that cannot reset, cannot be gamed, and implies
/// no target — which is the same reason `.claude/skills/ui.md` puts total days
/// on the screen and keeps the current streak off it.
///
/// A free function with the locale injected, rather than a computed property on
/// the model, so the sentence is assertable without depending on where the test
/// machine thinks it is.
public enum TodayCaption {

    /// - Parameters:
    ///   - totalDays: habit-days recorded, the number above this line.
    ///   - firstDay: the earliest day any habit was checked in on, or `nil` when
    ///     nothing has been recorded yet.
    public static func text(
        totalDays: Int,
        firstDay: Day?,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let unit = totalDays == 1 ? "day" : "days"

        // Nothing recorded yet: there is no date to be since. The empty screen
        // says what it is rather than inventing a start.
        guard let firstDay else {
            return "\(totalDays) \(unit) recorded"
        }
        return "\(totalDays) \(unit) recorded since \(formatted(firstDay, locale: locale))"
    }

    /// Renders a ``Day`` as a human date in the reader's locale.
    ///
    /// A `Day` has no instant, no timezone and no locale — that is the whole
    /// point of the type — so this is the one place a civil label is turned back
    /// into a `Date`, and it does it in **UTC** so the conversion cannot move
    /// the label across a boundary. The design's example, "5 December 2025", is
    /// what `en_GB` produces; `en_US` produces "December 5, 2025". Both are
    /// right for their reader.
    static func formatted(_ day: Day, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return day.iso }
        calendar.timeZone = utc

        let components = DateComponents(year: day.year, month: day.month, day: day.day)
        guard let date = calendar.date(from: components) else { return day.iso }

        let style = Date.FormatStyle(
            date: .long,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: utc
        )
        return date.formatted(style)
    }
}
