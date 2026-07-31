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
    ///   - totalDays: **distinct civil days** anything was recorded on — the
    ///     number above this line. Not habit-days: the sum across habits showed
    ///     "4 days recorded" for one morning's four taps, which made this
    ///     sentence false. ``CompassDomain/Projection/daysRecorded``.
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

    // MARK: The store notice, shown and spoken

    /// The sentence the header shows when the store could not be opened.
    ///
    /// Kept here rather than inline in ``TodayView`` for the reason
    /// ``SettingsCopy`` exists: it makes a claim about what the app is and is
    /// not doing, and the two places that have to say it — the visible line and
    /// what VoiceOver reads — must be one string or they will drift apart. They
    /// already had.
    public static let storeNotice = "Compass cannot reach its store. Taps are not being saved."

    /// What VoiceOver reads for the header block, which is one element.
    ///
    /// **The notice was written on the screen and unreachable to anyone not
    /// looking at it.** The header's children are merged with
    /// `.accessibilityElement(children: .combine)` and the merged label is then
    /// replaced by the caption, so the element announced "0 days recorded" and
    /// the sentence explaining *why* it said zero was never spoken. For a
    /// VoiceOver user the degraded launch therefore read as an app that had
    /// forgotten everything — precisely the reading that notice exists to
    /// prevent.
    ///
    /// It leads with the caption rather than the notice because the caption is
    /// what the element is: the notice is the qualification, and a qualification
    /// spoken before the thing it qualifies is a sentence read backwards.
    public static func spokenHeader(caption: String, isStoreAvailable: Bool) -> String {
        isStoreAvailable ? caption : "\(caption). \(storeNotice)"
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
