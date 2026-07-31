import SwiftUI

/// The colour of one habit row, and the only colour on the Today screen.
///
/// Each habit gets a colour and everything else here is greyscale. The palette
/// has four entries because four habits is the hard cap, and the bundle seeds
/// at that cap — so all four are on screen from the first launch.
///
/// A checked row is a **deep field** in the habit's hue with a paper-coloured
/// label and mark — not the saturated system colour with white on it. The
/// design records the measurements that forced that:
///
/// - the withdrawn intermediate, a 12% wash, measured **1.03:1** against the
///   unchecked 6% grey. Identical brightness. It was drawn, described as
///   reading "unmistakably as done at arm's length", then measured, found
///   false, and withdrawn mid-turn;
/// - the adopted deep field measures **4.95:1** against the unchecked grey, and
///   paper-on-field **4.8:1** — text passes for the first time, where white on
///   `#30B0C7` was 2.6:1.
///
/// Full monochrome was drawn and explicitly not recommended: colour is the only
/// thing that distinguishes two rows at a glance for someone tapping without
/// looking.
struct HabitTint: Equatable {

    /// The checked row's field in a light appearance.
    let field: Color

    /// The checked row's field in a dark appearance.
    let fieldDark: Color

    func field(for scheme: ColorScheme) -> Color {
        scheme == .dark ? fieldDark : field
    }

    /// Paper. The label and the mark on a checked row, in both appearances.
    static let paper = rgb(242, 239, 232)   // #F2EFE8

    /// The four habits, in the order `Projection.activeHabits` returns them.
    ///
    /// **Two of these eight values are the design's; six are derived, and the
    /// derivation is stated here because the design document does not carry
    /// them.**
    ///
    /// *Light.* `teal -> #1B6B7A` and `orange -> #8A4E00` are given verbatim.
    /// Indigo and pink are not given anywhere in the document, and no single
    /// rule reproduces the two that are — in HSB the teal keeps its hue and
    /// saturation and drops brightness to 61% of the system colour, the orange
    /// to 54%. What the two *do* share is luminance: 0.1215 and 0.1085. So the
    /// two missing fields keep the system colour's hue and saturation and take
    /// the brightness that lands on the mean of those, 0.1150. That reproduces
    /// the property the design actually argued from — the contrast measurement
    /// — rather than a factor it never states. Paper-on-field lands at 5.5:1
    /// for both, between the teal's 5.3:1 and the orange's 5.8:1.
    ///
    /// *Dark.* The document gives one value, teal "at 34% over black,
    /// i.e. rgb(22,68,76)". That is iOS's **dark-appearance** system teal
    /// `#40C8E0` multiplied by 0.34 — exactly, to the byte. So the rule is
    /// recovered rather than invented, and the other three follow from it.
    ///
    /// Recorded as an open question in `docs/open-questions.md`: six of these
    /// are the implementation's arithmetic, not the designer's eye.
    ///
    /// That entry used to add "and the third and fourth habits are unreachable
    /// in the app as built", which made it a note about code nobody could see.
    /// **It is not true and has not been since the seed became four.**
    /// `AppComposition.seededHabits` seeds Move, Read, Build and Reflect, so
    /// indigo and pink render on first launch before the user has done anything,
    /// and the settings sheet mints more habits after that. Six values chosen to
    /// satisfy a contrast measurement are now what the owner looks at every
    /// morning, and nobody has yet looked at them as colours.
    static let palette: [HabitTint] = [
        // teal   — #1B6B7A given;  #40C8E0 x 0.34 = rgb(22, 68, 76) given
        HabitTint(field: rgb(27, 107, 122), fieldDark: rgb(22, 68, 76)),
        // orange — #8A4E00 given;  #FF9F0A x 0.34
        HabitTint(field: rgb(138, 78, 0), fieldDark: rgb(87, 54, 3)),
        // indigo — derived from #5856D6;  #5E5CE6 x 0.34
        HabitTint(field: rgb(81, 80, 198), fieldDark: rgb(32, 31, 78)),
        // pink   — derived from #FF2D55;  #FF375F x 0.34
        HabitTint(field: rgb(183, 32, 61), fieldDark: rgb(87, 19, 32)),
    ]

    static func tint(at index: Int) -> HabitTint {
        palette[index % palette.count]
    }

    /// sRGB, written as bytes because that is how every value above was read
    /// off the design and computed.
    static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}
