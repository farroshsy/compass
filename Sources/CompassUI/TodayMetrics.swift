import CompassDomain
import SwiftUI

/// Every number on the Today screen, in one place, so that the screen and the
/// test that pins it read from the same source.
///
/// This exists for one reason: the design's load-bearing finding is that **four
/// habit rows still fit at AX5**, which validates the four-habit hard cap in
/// `docs/product.md` against the worst case. That finding was made by drawing
/// the screen once. A number changed six months from now would silently
/// invalidate it, and nothing would say so — so the arithmetic behind it lives
/// here and `TodayMetricsTests` asserts it.
///
/// `.claude/skills/testing.md` and `docs/technical.md` §9 both refuse SwiftUI
/// snapshot tests, and this is the honest alternative: not a rendering of the
/// screen, but the layout budget the screen is built from.
public enum TodayMetrics {

    // MARK: The frame — iPhone 16 Pro, 402 x 874 logical points

    public static let frameWidth: CGFloat = 402
    public static let frameHeight: CGFloat = 874

    /// The safe area the status bar and the sensor housing take at the top.
    public static let safeAreaTop: CGFloat = 62

    /// The home-indicator zone at the bottom, below ``bottomInset``.
    public static let homeIndicatorZone: CGFloat = 34

    // MARK: Insets

    public static let horizontalMargin: CGFloat = 20

    /// The header sits 28pt below the safe area.
    public static let headerTopInset: CGFloat = 28

    /// The last row sits 24pt above the home indicator. `.claude/skills/ui.md`.
    public static let bottomInset: CGFloat = 24

    /// `Spacer(minLength: 32)` between the header and the rows. Information at
    /// the top, out of thumb reach; actions at the bottom, in the thumb arc.
    public static let minimumSpacer: CGFloat = 32

    /// 362pt. Full width minus both margins.
    public static let contentWidth = frameWidth - 2 * horizontalMargin

    // MARK: Header

    /// Between the number block and the spine.
    public static let headerSpacing: CGFloat = 20

    /// SF Rounded, bold, and **fixed**. Dynamic Type rule 2: it is a graphic,
    /// not text. Left to scale, its caption grows to 49pt and stands almost as
    /// tall as it, destroying the one hierarchy on the screen.
    public static let numberPointSize: CGFloat = 44
    public static let numberLineHeight: CGFloat = 52
    public static let numberTracking: CGFloat = -0.8

    /// Dynamic Type rule 1: **clamp the display, never the controls.** The
    /// header is information read at a glance and stops growing here; the rows
    /// are the product and take no clamp at all, because someone who needs AX5
    /// needs it on the thing they tap.
    public static let headerClamp: DynamicTypeSize = .accessibility2

    // MARK: The settings glyph

    // SF Symbols `gearshape`, 17pt, 30% ink, a 44 x 44 hit target centred at
    // (371, 128) in the 402 x 874 frame — top-right, on the number's cap line.
    //
    // The design records it as a decision taken on the user's behalf: an
    // addition to a screen whose rule is that nothing may be added, "justified
    // only because the sheet is already budgeted and otherwise unreachable". It
    // was deliberately not built while the sheet did not exist, because a glyph
    // that opens nothing is a control that lies. The sheet exists now, so it
    // ships at the position that was measured rather than the one that looks
    // right. `docs/open-questions.md`.

    /// The glyph itself. Small on purpose: this is the deliberately hard-to-reach
    /// entrance to the one surface off the launch path.
    public static let settingsGlyphPointSize: CGFloat = 17

    /// 30% ink. It must be legible and must not compete with the number.
    public static let settingsGlyphInk: Double = 0.30

    /// 44 x 44, the whole reason the glyph overhangs the margin: at 17pt the
    /// symbol is nowhere near a thumb-sized target, so the target is grown
    /// around it rather than the glyph being grown to meet it.
    public static let settingsTarget: CGFloat = 44

    /// How far the target overhangs the 20pt margin, so the **glyph's** trailing
    /// edge lands on the margin line while the target still reaches 44.
    public static let settingsOverhang: CGFloat = 11

    /// The target's top edge, measured from the top of the header content.
    /// Everything else about the position follows from this and the frame.
    public static let settingsTopOffset: CGFloat = 16

    /// The design's measured centre, derived rather than restated: 402 − 20
    /// margin − 22 half-target + 11 overhang = 371.
    public static let settingsCentreX =
        frameWidth - horizontalMargin - settingsTarget / 2 + settingsOverhang

    /// 62 safe area + 28 header inset + 16 offset + 22 half-target = 128.
    public static let settingsCentreY =
        safeAreaTop + headerTopInset + settingsTopOffset + settingsTarget / 2

    // MARK: The 28-dot spine

    /// How many days the spine shows. ``TodayModel/spineLength`` reads it from
    /// here: how many dots there are is a fact about the graphic, and the model
    /// and the layout must not be able to disagree about it.
    ///
    /// **The value itself moved to `CompassDomain` in week 1b**, for the same
    /// reason `Projection.habitCap` lives beside the fold rather than beside the
    /// layout: the launch cache carries the strip, and it is written by
    /// `CompassInfrastructure`, which cannot import `CompassUI`. Two constants
    /// would be two things that can disagree, and the one that was wrong would
    /// be the one nobody is looking at. This stays the only place the *layout*
    /// asks the question. `docs/technical.md` §4.
    public static let spineLength = TodaySnapshot.spineLength

    public static let spineDot: CGFloat = 9
    public static let spineGap: CGFloat = 2

    /// Dynamic Type rule 4: the spine does not scale, and that is accepted. It
    /// is a display, it is already `accessibilityHidden`, and the honest
    /// alternative — showing fewer days — would change what the graphic claims.
    public static func spineWidth(_ count: Int = spineLength) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * spineDot + CGFloat(count - 1) * spineGap
    }

    // MARK: Habit rows

    /// A hard cap, not a default. `docs/product.md`.
    ///
    /// Read from Domain rather than restated here. The cap is a product rule
    /// about how many habits exist, enforced where habits are created; this
    /// target only has to fit them on the screen. Two constants would be two
    /// things that can disagree.
    public static let habitCap = Projection.habitCap

    public static let rowSpacing: CGFloat = 12

    /// Fixed at every non-accessibility size. `.claude/skills/ui.md`.
    public static let rowHeight: CGFloat = 76

    /// At accessibility sizes the row stops being fixed and grows with its
    /// name, from this floor.
    public static let rowAccessibilityMinHeight: CGFloat = 88

    public static let rowVerticalPadding: CGFloat = 14
    public static let rowHorizontalPadding: CGFloat = 20
    public static let rowCornerRadius: CGFloat = 16
    public static let nameTracking: CGFloat = -0.45

    // MARK: The mark

    /// A rounded square, not a check-circle: the same form as one cell in the
    /// seal die, so the daily gesture and the sealed record are one shape at two
    /// scales.
    public static let markSide: CGFloat = 20

    /// 5 at 20pt, 12 at the 48pt the design drew at AX5.
    public static let markCornerRatio: CGFloat = 0.25

    /// The unchecked mark's stroke, at 45% ink. The design records this as a
    /// deliberate deviation from `.claude/skills/ui.md`'s `opacity(0.25)`, on
    /// contrast grounds: 3.3:1 instead of 1.82:1.
    ///
    /// Two values rather than a ramp because the design drew exactly two, and
    /// the pair is not proportional — the mark grows 2.4x from 20 to 48 while
    /// the stroke grows 1.4x, because a proportionally scaled stroke on a 48pt
    /// square reads as a filled square.
    public static let markStroke: CGFloat = 1.7
    public static let markStrokeAccessibility: CGFloat = 2.4

    // MARK: Dynamic Type, as arithmetic

    /// Apple's published iOS Dynamic Type point sizes, in the order of
    /// ``DynamicTypeSize/allCases``, for the two text styles this screen uses.
    ///
    /// A table rather than a call into `UIFont`, because this has to evaluate
    /// under `swift test` on macOS with no simulator, and because a test that
    /// asks the system for the answer cannot detect the system changing it.
    ///
    /// **One correction to the design document, recorded rather than hidden.**
    /// Its AX5 metric table gives `title3 20 -> 49` and `title2 22 -> 53`. Both
    /// are one row off Apple's table, which gives title3 53 and title2 56 at
    /// AX5 — 49 is Apple's *subheadline* AX5 value. Every other row in the
    /// design's table (body 53, footnote 44, caption2 42, largeTitle 60,
    /// subheadline-at-accessibility2 30) matches Apple exactly, so the two
    /// title rows are a transcription slip and the rest cross-validates this
    /// table. The four-habit finding survives the correction — see
    /// `TodayMetricsTests` — which is the only reason it is safe to correct.
    private static let subheadlineRamp: [CGFloat] =
        [12, 13, 14, 15, 17, 19, 21, 25, 30, 35, 42, 49]
    private static let title3Ramp: [CGFloat] =
        [17, 18, 19, 20, 22, 24, 26, 31, 37, 43, 48, 53]

    private static func index(of size: DynamicTypeSize) -> Int {
        DynamicTypeSize.allCases.firstIndex(of: size) ?? 3
    }

    /// ``headerClamp`` applied. This is the whole of Dynamic Type rule 1.
    public static func clampedForHeader(_ size: DynamicTypeSize) -> DynamicTypeSize {
        min(size, headerClamp)
    }

    /// The caption under the number, at the size the header will actually
    /// render it — clamped.
    public static func captionPointSize(at size: DynamicTypeSize) -> CGFloat {
        subheadlineRamp[index(of: clampedForHeader(size))]
    }

    /// The habit name. **Unclamped** — the rows take no clamp.
    public static func namePointSize(at size: DynamicTypeSize) -> CGFloat {
        title3Ramp[index(of: size)]
    }

    /// The design's own pairs — 20pt name at line-height 24, 49pt name at 59,
    /// 30pt caption at 36 — all sit within a point of 1.2x.
    public static let lineHeightFactor: CGFloat = 1.2

    public static func captionLineHeight(at size: DynamicTypeSize) -> CGFloat {
        (captionPointSize(at: size) * lineHeightFactor).rounded()
    }

    /// Dynamic Type rule 3: two lines above `accessibility1`. `lineLimit(1)` at
    /// 49pt truncates any name longer than about eight characters, and renaming
    /// is a supported feature — so a user can silently make their own row
    /// unreadable.
    public static func nameLineLimit(at size: DynamicTypeSize) -> Int {
        size > .accessibility1 ? 2 : 1
    }

    public static func markStrokeWidth(at size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? markStrokeAccessibility : markStroke
    }

    /// The row's height for a name of `nameLines` lines. Fixed below the
    /// accessibility sizes; above them the row grows with its name from
    /// ``rowAccessibilityMinHeight``.
    ///
    /// `nameLines` used to be absent, and the row was documented as "the row's
    /// height for a **single-line** name" while ``nameLineLimit(at:)`` returns 2
    /// above `accessibility1`. That was safe while the four names were compiled
    /// into the bundle and known to be short; it stopped being safe the moment
    /// the settings sheet could accept any name at all.
    ///
    /// It is clamped to ``nameLineLimit(at:)``, so asking for two lines below
    /// `accessibility2` gives the fixed 76pt row: a name cannot wrap where the
    /// line limit is 1.
    public static func rowHeight(at size: DynamicTypeSize, nameLines: Int = 1) -> CGFloat {
        guard size.isAccessibilitySize else { return rowHeight }
        let lines = CGFloat(max(1, min(nameLines, nameLineLimit(at: size))))
        let name = (namePointSize(at: size) * lineHeightFactor).rounded()
        return max(rowAccessibilityMinHeight, lines * name + 2 * rowVerticalPadding)
    }

    /// The header block: the number, its caption, the gap, and the spine.
    ///
    /// `captionLines` is a parameter because it is the one quantity here that
    /// depends on text: at AX5 the caption is 30pt in 362 points and the
    /// sentence "128 days recorded since 5 December 2025" takes two lines.
    public static func headerHeight(
        at size: DynamicTypeSize,
        captionLines: Int = 2
    ) -> CGFloat {
        numberLineHeight
            + CGFloat(captionLines) * captionLineHeight(at: size)
            + headerSpacing
            + spineDot
    }

    /// Points left over on the frame after the header, the minimum spacer and
    /// `habitCount` rows, `wrappedNames` of which take two lines. Negative means
    /// the content is taller than the frame.
    ///
    /// **This is the assertion behind the four-habit cap.** The design drew the
    /// screen at AX5 with four habits and found it fits with room to spare;
    /// this is that finding as arithmetic, so a future change to any number
    /// above breaks a test instead of breaking the screen.
    ///
    /// ### The budget re-derived for wrapped names
    ///
    /// The finding was made with four short, compiled-in names. Names are now
    /// typed by the user, and ``nameLineLimit(at:)`` gives them a second line
    /// above `accessibility1`, so the worst case is no longer the one that was
    /// measured. At AX5 a wrapped row costs one extra 64pt line against the 137pt
    /// the single-line case leaves spare:
    ///
    /// | wrapped names | spare at AX5 |
    /// |---|---|
    /// | 0 | 137 |
    /// | 1 | 73 |
    /// | 2 | 9 |
    /// | 3 | −55 |
    /// | 4 | −119 |
    ///
    /// Three wrapped names overflow the frame, and at AX3 four wrapped names
    /// overflow it by 23. `TodayMetricsTests` pins every one of those numbers.
    ///
    /// **What was done about it: the layout survives the overflow; the sheet is
    /// not constrained.** The alternative was a length limit on habit names, and
    /// it was rejected because it cannot deliver what it costs. **A character
    /// count does not bound rendered width:** ten wide glyphs wrap where fifteen
    /// narrow ones do not, so no cap written in characters can *guarantee* a
    /// single line. And the cap it would take to come close — around ten
    /// characters of average text in the ~262pt a name gets at AX5 — refuses
    /// "Read a book" and "Meditate daily". That is a permanent constraint on the
    /// one thing a habit is, bought in exchange for a guarantee that still would
    /// not hold. And no arrangement of the other
    /// numbers recovers the space: four two-line AX5 rows need 660pt against the
    /// 541pt between the header and the home indicator, so even collapsing the
    /// 32pt spacer entirely leaves it 87pt short.
    ///
    /// So ``TodayView`` lets the screen scroll **when, and only when, the content
    /// does not fit** — the content is given a minimum height of the viewport and
    /// bottom alignment, so in every case that fits, which is every non-
    /// accessibility size and AX5 with names of ordinary length, the layout is
    /// exactly the one the design specified: bottom-anchored, last row 24pt above
    /// the home indicator. Nothing is clamped, nothing is truncated, and no row
    /// becomes unreachable — which is what "the layout survives it" has to mean
    /// for a screen whose entire purpose is being tapped.
    public static func spareHeight(
        habitCount: Int,
        at size: DynamicTypeSize,
        captionLines: Int = 2,
        wrappedNames: Int = 0,
        frameHeight: CGFloat = TodayMetrics.frameHeight
    ) -> CGFloat {
        let wrapped = max(0, min(wrappedNames, habitCount))
        let rows = CGFloat(wrapped) * rowHeight(at: size, nameLines: 2)
            + CGFloat(habitCount - wrapped) * rowHeight(at: size)
            + CGFloat(max(0, habitCount - 1)) * rowSpacing
        let used = safeAreaTop
            + headerTopInset
            + headerHeight(at: size, captionLines: captionLines)
            + minimumSpacer
            + rows
            + bottomInset
            + homeIndicatorZone
        return frameHeight - used
    }
}
