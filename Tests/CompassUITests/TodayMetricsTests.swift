import CompassDomain
import CompassUI
import Foundation
import SwiftUI
import Testing

/// The Today screen's layout budget, as arithmetic.
///
/// `docs/technical.md` §9 and `.claude/skills/testing.md` both refuse SwiftUI
/// snapshot tests out loud — they break on every point release and catch
/// nothing a daily user would not notice within a day. This is the thing they
/// are refused *instead of*: not a rendering of the screen, but the numbers the
/// screen is built from, asserted against the design's load-bearing findings.
///
/// The one that matters is the four-habit cap. `docs/product.md` makes four a
/// hard cap; the design drew the screen at AX5 with four habits and found it
/// still fits, and called that "worth knowing, because it was the least certain
/// of the product's hard numbers". A number changed six months from now could
/// quietly falsify it, and nothing on screen would say so until someone with
/// four habits turned Dynamic Type up.
@Suite("TodayMetrics — the layout budget")
struct TodayMetricsTests {

    // MARK: The finding this suite exists for

    @Test("Four habits fit at AX5 — the hard cap survives the worst case")
    func fourHabitsFitAtAX5() {
        let spare = TodayMetrics.spareHeight(habitCount: TodayMetrics.habitCap, at: .accessibility5)
        #expect(spare > 0)
    }

    /// The cap is a product rule about how many habits may exist, enforced in
    /// Domain where habits are created. This target only has to fit them on the
    /// screen, so it reads the number rather than restating it — and the finding
    /// above is about *the cap*, not about the number four in particular.
    ///
    /// Both halves are asserted. A test written only against the constant would
    /// follow the constant wherever it was moved and assert nothing; a test
    /// written only against the literal would not notice the layout budget and
    /// the enforcement drifting apart.
    @Test("The layout budget and the enforced cap are the same number")
    func theCapIsOneNumber() {
        #expect(TodayMetrics.habitCap == Projection.habitCap)
        #expect(TodayMetrics.habitCap == 4)
    }

    /// The exact number, so that changing *any* constant on the screen forces
    /// this finding to be re-derived rather than silently re-scoped.
    ///
    /// It is not the design's 165. The design's own AX5 metric table gives
    /// `title3 20 -> 49`, one row off Apple's published table, which gives 53 —
    /// see ``TodayMetrics``. Correcting that makes every row 3.6pt taller, and
    /// the caption is counted at the two lines that "128 days recorded since 5
    /// December 2025" actually takes at 30pt in 362 points. The finding
    /// survives the correction with 137pt to spare, which is the point: the
    /// conclusion was right even though one of its inputs was not.
    ///
    /// 874 − (62 safe + 28 inset + 153 header + 32 spacer + 404 rows + 24
    /// inset + 34 indicator) = 137.
    @Test("The AX5 spare height is pinned")
    func spareHeightIsPinned() {
        let spare = TodayMetrics.spareHeight(habitCount: 4, at: .accessibility5)
        #expect(abs(spare - 137) < 0.05)
    }

    @Test("Four habits fit at every size")
    func fourHabitsFitEverywhere() {
        for size in DynamicTypeSize.allCases {
            #expect(TodayMetrics.spareHeight(habitCount: 4, at: size) > 0)
        }
    }

    @Test("A fifth habit is what the cap is protecting against")
    func theCapIsLoadBearing() {
        // Five fits; six does not. The cap is four, so the screen is never
        // asked either question — but if the cap is ever raised, this is the
        // assertion that says how far it can go.
        #expect(TodayMetrics.spareHeight(habitCount: 5, at: .accessibility5) > 0)
        #expect(TodayMetrics.spareHeight(habitCount: 6, at: .accessibility5) < 0)
    }

    // MARK: The budget re-derived for names that wrap

    /// The single-line budget above was measured against four short names
    /// compiled into the bundle. Names are typed by the user now, and Dynamic
    /// Type rule 3 gives a name a second line above `accessibility1` — so the
    /// worst case the cap has to survive is not the one that was measured, and
    /// these are the numbers for the one that is.
    @Test("A wrapped name costs one line, and at AX5 that is 64 points")
    func aWrappedNameCostsALine() {
        let single = TodayMetrics.rowHeight(at: .accessibility5)
        let wrapped = TodayMetrics.rowHeight(at: .accessibility5, nameLines: 2)

        #expect(single == 92)
        #expect(wrapped == 156)
        #expect(wrapped - single == 64)
    }

    /// A name cannot wrap where the line limit is 1, so asking for two lines
    /// below `accessibility2` must not inflate the budget. Otherwise the metric
    /// would predict an overflow the screen cannot have.
    @Test("Below accessibility2 a second line costs nothing, because there is none")
    func aRowThatCannotWrapDoesNotGrow() {
        for size in DynamicTypeSize.allCases where TodayMetrics.nameLineLimit(at: size) == 1 {
            #expect(
                TodayMetrics.rowHeight(at: size, nameLines: 2) == TodayMetrics.rowHeight(at: size),
                "\(size)"
            )
        }
        #expect(TodayMetrics.rowHeight(at: .large, nameLines: 2) == 76)
    }

    /// The whole table, pinned, so the conclusion cannot be re-scoped by changing
    /// a constant somewhere else on the screen.
    @Test("The AX5 spare height, name by name")
    func theWrappedBudgetIsPinned() {
        let expected: [Int: CGFloat] = [0: 137, 1: 73, 2: 9, 3: -55, 4: -119]
        for (wrapped, spare) in expected {
            #expect(
                abs(
                    TodayMetrics.spareHeight(
                        habitCount: 4, at: .accessibility5, wrappedNames: wrapped
                    ) - spare
                ) < 0.05,
                "\(wrapped) wrapped names"
            )
        }
    }

    /// **The finding that forced the layout to change.** Two wrapped names fit
    /// with 9 points to spare; three do not fit at all. At AX3 — two sizes below
    /// the worst case — four wrapped names already overflow.
    ///
    /// There is no arrangement of the other numbers that recovers it: even
    /// collapsing the 32pt spacer to nothing leaves the worst case 87 points
    /// short. So the screen scrolls when it does not fit rather than the settings
    /// sheet refusing names, and ``TodayMetrics/spareHeight(habitCount:at:captionLines:wrappedNames:frameHeight:)``
    /// records why that way round.
    @Test("Three wrapped names overflow the frame, and no spacing change saves them")
    func theWrappedWorstCaseDoesNotFit() {
        #expect(TodayMetrics.spareHeight(habitCount: 4, at: .accessibility5, wrappedNames: 2) > 0)
        #expect(TodayMetrics.spareHeight(habitCount: 4, at: .accessibility5, wrappedNames: 3) < 0)

        // AX3, all four wrapped: short by 23 points.
        let ax3 = TodayMetrics.spareHeight(habitCount: 4, at: .accessibility3, wrappedNames: 4)
        #expect(abs(ax3 + 23) < 0.05)

        // The spacer is a minimum, so the most it could give back is its own
        // height. It is not enough.
        let worst = TodayMetrics.spareHeight(habitCount: 4, at: .accessibility5, wrappedNames: 4)
        #expect(worst + TodayMetrics.minimumSpacer < 0)
    }

    /// The case that is not the worst case is still the common one, and it must
    /// be untouched: with names of ordinary length nothing about the screen
    /// changes, at any size, which is what lets the scroll view stay inert.
    @Test("Unwrapped names still fit at every size, with the cap unchanged")
    func theOrdinaryCaseIsUnchanged() {
        for size in DynamicTypeSize.allCases {
            #expect(TodayMetrics.spareHeight(habitCount: 4, at: size) > 0, "\(size)")
        }
        #expect(TodayMetrics.habitCap == Projection.habitCap)
    }

    // MARK: Dynamic Type rule 1 — clamp the display, never the controls

    @Test("The header clamps at accessibility2 and the rows do not clamp at all")
    func theHeaderClampsAndTheRowsDoNot() {
        // The caption stops growing.
        #expect(
            TodayMetrics.captionPointSize(at: .accessibility5)
                == TodayMetrics.captionPointSize(at: .accessibility2)
        )
        // The name does not.
        #expect(
            TodayMetrics.namePointSize(at: .accessibility5)
                > TodayMetrics.namePointSize(at: .accessibility2)
        )
    }

    /// Rule 2, and the reason it exists: unclamped, the caption reaches 49pt
    /// against a 44pt number and "stands almost as tall as the number,
    /// destroying the one hierarchy on the screen".
    ///
    /// This is the assertion that fails if the clamp is ever removed.
    @Test("The number stays the largest thing in the header at every size")
    func theHierarchySurvivesAX5() {
        for size in DynamicTypeSize.allCases {
            #expect(TodayMetrics.captionPointSize(at: size) < TodayMetrics.numberPointSize)
        }
        // Specifically: 30 against 44, not 49 against 44.
        #expect(TodayMetrics.captionPointSize(at: .accessibility5) == 30)
    }

    // MARK: Dynamic Type rule 3 — two lines above accessibility1

    @Test("Habit names get a second line above accessibility1")
    func namesGetTwoLinesAtAccessibilitySizes() {
        #expect(TodayMetrics.nameLineLimit(at: .large) == 1)
        #expect(TodayMetrics.nameLineLimit(at: .accessibility1) == 1)
        #expect(TodayMetrics.nameLineLimit(at: .accessibility2) == 2)
        #expect(TodayMetrics.nameLineLimit(at: .accessibility5) == 2)
    }

    // MARK: Dynamic Type rule 4 — the spine does not scale, and it must fit

    @Test("28 dots fit the content width")
    func theSpineFits() {
        // 28 * 9 + 27 * 2 = 306 of the 362 available points.
        #expect(TodayMetrics.spineWidth() == 306)
        #expect(TodayMetrics.spineWidth() <= TodayMetrics.contentWidth)
        #expect(TodayMetrics.contentWidth == 362)
    }

    // MARK: The settings glyph

    /// The design specifies it exactly: SF Symbols `gearshape`, 17pt, 30% ink,
    /// a 44 x 44 target centred at (371, 128) in the 402 x 874 frame,
    /// overhanging the margin by 11pt so the glyph's trailing edge lands on the
    /// margin line and the target still reaches 44.
    ///
    /// It was held back while the settings sheet did not exist — a glyph that
    /// opens nothing is a control that lies — and `docs/open-questions.md`
    /// records the geometry with the falsifier "the settings sheet exists. Then
    /// the glyph ships with it, at that position, unchanged." This is that
    /// position, asserted, so "unchanged" is checkable rather than remembered.
    @Test("The settings glyph sits where the design measured it")
    func theSettingsGlyphGeometry() {
        #expect(TodayMetrics.settingsGlyphPointSize == 17)
        #expect(TodayMetrics.settingsGlyphInk == 0.30)
        #expect(TodayMetrics.settingsTarget == 44)
        #expect(TodayMetrics.settingsOverhang == 11)

        #expect(TodayMetrics.settingsCentreX == 371)
        #expect(TodayMetrics.settingsCentreY == 128)
    }

    /// The target is the point of the overhang, and it is the thing a 17pt glyph
    /// cannot supply on its own. Apple's minimum is 44 x 44 and this is the
    /// smallest, furthest-away control in the app, so it has the least room to
    /// be wrong.
    @Test("The glyph is small, the target is not, and the target stays on screen")
    func theTargetIsBiggerThanTheGlyph() {
        #expect(TodayMetrics.settingsTarget >= 44)
        #expect(TodayMetrics.settingsGlyphPointSize < TodayMetrics.settingsTarget)

        // The glyph's trailing edge lands on the margin line: 371 + 22 − 11 = 382,
        // which is 402 − 20.
        let glyphTrailingEdge =
            TodayMetrics.settingsCentreX + TodayMetrics.settingsTarget / 2
            - TodayMetrics.settingsOverhang
        #expect(glyphTrailingEdge == TodayMetrics.frameWidth - TodayMetrics.horizontalMargin)

        // And the target itself, overhang included, is still inside the frame.
        #expect(
            TodayMetrics.settingsCentreX + TodayMetrics.settingsTarget / 2
                <= TodayMetrics.frameWidth
        )
    }

    /// It sits on the number's cap line — beside the number, never below the
    /// spine, and never far enough down to be in the thumb arc the rows own.
    @Test("The glyph is inside the header, not over the rows")
    func theGlyphStaysInTheHeader() {
        let headerTop = TodayMetrics.safeAreaTop + TodayMetrics.headerTopInset
        let targetBottom = TodayMetrics.settingsCentreY + TodayMetrics.settingsTarget / 2

        #expect(TodayMetrics.settingsCentreY > headerTop)
        #expect(
            targetBottom
                <= headerTop + TodayMetrics.headerHeight(at: .large, captionLines: 1)
        )
    }

    // MARK: The row

    @Test("The row is fixed below the accessibility sizes and grows above them")
    func rowHeightIsFixedThenGrows() {
        for size in DynamicTypeSize.allCases where !size.isAccessibilitySize {
            #expect(TodayMetrics.rowHeight(at: size) == 76)
        }
        #expect(TodayMetrics.rowHeight(at: .accessibility1) >= 88)
        #expect(
            TodayMetrics.rowHeight(at: .accessibility5)
                > TodayMetrics.rowHeight(at: .accessibility1)
        )
    }
}

/// The sentence under the number.
@Suite("TodayCaption")
struct TodayCaptionTests {

    private let british = Locale(identifier: "en_GB")

    @Test("It reads as the design's sentence")
    func theDesignsSentence() {
        let caption = TodayCaption.text(
            totalDays: 128, firstDay: day("2025-12-05"), locale: british
        )
        #expect(caption == "128 days recorded since 5 December 2025")
    }

    @Test("One day is singular")
    func singular() {
        let caption = TodayCaption.text(
            totalDays: 1, firstDay: day("2025-12-05"), locale: british
        )
        #expect(caption == "1 day recorded since 5 December 2025")
    }

    /// Nothing recorded means there is no date to be *since*, and the screen
    /// must not invent a start.
    @Test("An empty log has no since clause")
    func emptyLog() {
        #expect(TodayCaption.text(totalDays: 0, firstDay: nil, locale: british) == "0 days recorded")
    }

    /// A `Day` has no timezone. Rendering it must not be able to move the label
    /// across a boundary, whatever the machine running this thinks the time is.
    @Test("The date does not shift under a timezone")
    func theLabelDoesNotMove() {
        let first = day("2026-01-01")
        #expect(
            TodayCaption.text(totalDays: 1, firstDay: first, locale: british)
                == "1 day recorded since 1 January 2026"
        )
    }
}
