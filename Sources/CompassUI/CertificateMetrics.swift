import SwiftUI

/// Every number and every colour on the certificate, in one place, so that the
/// screen and the test that pins it read from the same source.
///
/// Same reason ``TodayMetrics`` exists: `.claude/skills/testing.md` and
/// `docs/technical.md` §9 both refuse SwiftUI snapshot tests, so the honest
/// alternative is not a rendering of the screen but the layout budget the screen
/// is built from. Two of the findings here are load-bearing and easy to lose —
/// the seal's crop, which is what makes the die the right size at all, and the
/// AX5 structural variant, which is the only reason a 42pt identifier block is
/// readable in full.
public enum CertificateMetrics {

    // MARK: The canvas — iPhone 16 Pro, 402 x 874 logical points

    public static let frameWidth: CGFloat = 402
    public static let frameHeight: CGFloat = 874
    public static let safeAreaTop: CGFloat = 62

    // MARK: Insets

    public static let horizontalMargin: CGFloat = 20

    /// **Not Today's 24.** This screen is a document, not a daily interaction,
    /// and it deliberately breaks the bottom-anchored rule.
    public static let bottomInset: CGFloat = 40

    /// The masthead's top edge sits 90pt from the frame top: 62pt of safe area
    /// plus this.
    public static let topInset: CGFloat = 28

    /// 90pt from the frame top. Derived rather than restated, so the two numbers
    /// cannot drift apart.
    public static let mastheadTop = safeAreaTop + topInset

    // MARK: The vertical rhythm, top to bottom

    public static let mastheadToRule: CGFloat = 12
    public static let ruleToClaim: CGFloat = 30
    public static let claimToDate: CGFloat = 18
    public static let dateToSealRow: CGFloat = 32
    public static let sealRowToRule: CGFloat = 36
    public static let ruleToIdentifier: CGFloat = 12

    /// The flexible gap above the controls. Everything above it is fixed.
    public static let minimumSpacer: CGFloat = 20

    /// One device pixel, not one point. Both rules are hairlines.
    public static let ruleHeight: CGFloat = 1 / 3

    // MARK: Type

    /// "Record" — one word. `caption2` 11pt semibold, uppercase, tracked open.
    ///
    /// "Attested record" was cut: **"attested" claims a third party that does not
    /// exist.** There is no second party in this product and `docs/product.md`
    /// makes that permanent, so the masthead may not imply one.
    public static let mastheadPointSize: CGFloat = 11
    public static let mastheadTracking: CGFloat = 1.6

    /// Clamped at `xxLarge`. The design's reason, kept because it is the argument
    /// rather than the number: "At 42pt, tracked and uppercase, it stopped being
    /// a letterhead and started shouting the one word on the screen that carries
    /// no information."
    public static let mastheadClamp: DynamicTypeSize = .xxLarge

    /// The claim, and **the one thing on this screen that scales all the way.**
    ///
    /// It is `.system(.largeTitle, design: .serif)` — a *relative* metric, per
    /// `.claude/skills/ui.md` line 62. Turn 4d's "Build spec" table specifies
    /// `.system(size: 34, design: .serif)` instead, and that is a stale row from a
    /// superseded turn: a fixed point size does not respond to Dynamic Type and
    /// would silently void the whole accessibility pass — which scales this from
    /// 34 to 60 on the `largeTitle` ramp, i.e. the newest turn already agrees with
    /// `ui.md`. The number below is the *base* the relative metric starts from.
    public static let claimPointSize: CGFloat = 34
    public static let claimLineHeight: CGFloat = 42
    public static let claimTracking: CGFloat = -0.2

    public static let datePointSize: CGFloat = 17
    public static let dateLineHeight: CGFloat = 24

    public static let attestationPointSize: CGFloat = 13
    public static let attestationLineHeight: CGFloat = 19

    /// So the attestation's last line sits just above the seal's bottom edge.
    public static let attestationBottomPadding: CGFloat = 3

    public static let identifierPointSize: CGFloat = 11
    public static let identifierLineHeight: CGFloat = 17

    public static let controlPointSize: CGFloat = 17
    public static let controlTarget: CGFloat = 44

    // MARK: The seal row

    /// Between the die and the attestation beside it.
    public static let sealRowGap: CGFloat = 20

    /// Shipping size. Fixed — it is a graphic, not text.
    public static let sealSize: CGFloat = 168

    /// The AX5 size. **It does not scale**, it steps once.
    ///
    /// See `memory/known-bugs.md`: the "holds to 160pt, merges at 120pt" finding
    /// was measured on the **superseded** 4 x 7 twenty-eight-cell device, and the
    /// shipped device is an 8 x 8 sixty-four-cell matrix — more than twice as
    /// dense, with a cell that falls to ``cellSide(atSealSize:)`` = 6.14pt here.
    /// Nobody has measured the shipped die at this size. The number is the
    /// design's; the gap is recorded rather than papered over.
    public static let sealSizeAccessibility: CGFloat = 120

    // MARK: The crop — load-bearing, and easy to get wrong

    /// **The die impression spans 68.4% of the shipped frame.**
    ///
    /// The assets are 400 x 400 (@2x) and 600 x 600 (@3x): a 200pt *nominal*
    /// frame at both scales. Drawing that asset at 168pt therefore gives a die of
    /// only ~115pt — which is the mistake this constant exists to prevent. The
    /// frame is drawn larger and clipped to a centred square instead.
    public static let dieSpanOfFrame: CGFloat = 0.684

    /// How large to draw the frame asset so that its die comes out at `size`.
    ///
    /// 168 / 0.684 = 245.6, and 120 / 0.684 = 175.4 — the two numbers every
    /// turn-5 drawing uses (it draws 246 and 176 and insets by 39 and 28). One
    /// ratio and two derived sizes rather than three constants, because three
    /// constants are three things that can disagree.
    public static func frameDrawSize(forSeal size: CGFloat) -> CGFloat {
        size / dieSpanOfFrame
    }

    /// How far to inset the drawn frame on each edge to leave the die.
    public static func frameInset(forSeal size: CGFloat) -> CGFloat {
        (frameDrawSize(forSeal: size) - size) / 2
    }

    // MARK: The matrix struck over it

    /// The field is 8 x 8 — **the first 64 bits of `witness.evidenceRoot`**, MSB
    /// first, one byte per row. `docs/achievement-protocol.md` §4 and §4.1.
    public static let matrixSide = 8

    /// 8.6pt per cell at a 168pt die: 8 x 8.6 = 68.8pt of matrix inside the die.
    public static let matrixSpanOfDie: CGFloat = 68.8 / 168

    /// The cell pitch at a given die size. 8.6 at 168; 6.14 at 120.
    public static func cellSide(atSealSize size: CGFloat) -> CGFloat {
        size * matrixSpanOfDie / CGFloat(matrixSide)
    }

    /// A rounded square, **not a dot.** "A matrix reads as struck data; a field
    /// of circles reads as a keypad." It is deliberately the same shape as the
    /// checked-row mark on Today, so the daily gesture and the sealed record are
    /// one form at two scales — which is why the ratio is read from
    /// ``TodayMetrics`` rather than restated.
    public static let cellCornerRatio = TodayMetrics.markCornerRatio

    /// The 1pt inner top-left shadow and 1pt bottom-right highlight that make a
    /// cell read as pressed rather than painted. One light source at 22 degrees
    /// above the sheet, from the upper left, everywhere.
    public static let cellShadowOpacity: Double = 0.22
    public static let cellHighlightOpacity: Double = 0.55
    public static let cellEdgeWidth: CGFloat = 1

    // MARK: Dynamic Type — "this screen would rather be long than crowded"

    /// Above this, the sheet becomes a `ScrollView` with the controls pinned
    /// below it in their own block, the seal row unstacks, and the attestation
    /// moves under the die. It is a **structural** variant, not a scale factor.
    public static let structuralVariantFrom: DynamicTypeSize = .accessibility1

    public static func isStructural(_ size: DynamicTypeSize) -> Bool {
        size >= structuralVariantFrom
    }

    public static func sealSize(at size: DynamicTypeSize) -> CGFloat {
        isStructural(size) ? sealSizeAccessibility : sealSize
    }

    /// The gap above the seal: 32 normally, 28 once it is stacked.
    public static func spaceAboveSeal(at size: DynamicTypeSize) -> CGFloat {
        isStructural(size) ? 28 : dateToSealRow
    }

    /// The gap above the date: 18 normally, 16 at the structural sizes.
    public static func spaceAboveDate(at size: DynamicTypeSize) -> CGFloat {
        isStructural(size) ? 16 : claimToDate
    }

    /// The gap above the attestation once it has stacked below the die.
    public static let spaceAboveStackedAttestation: CGFloat = 14

    /// The bottom scroll-edge gradient, transparent to paper.
    public static let scrollEdgeHeight: CGFloat = 80

    /// The control row's height: 44 normally, 53 at the structural sizes.
    public static func controlTarget(at size: DynamicTypeSize) -> CGFloat {
        isStructural(size) ? 53 : controlTarget
    }

    /// **The claim's hard line break is dropped above the structural threshold.**
    /// At 60pt in 362 points the claim already reflows to three lines, and an
    /// explicit break inside a run that is wrapping anyway produces a ragged
    /// orphan. The claim is the content; it is allowed to be long.
    public static func claimBreaksLines(at size: DynamicTypeSize) -> Bool {
        !isStructural(size)
    }

    /// The same 1.2 factor ``TodayMetrics/lineHeightFactor`` derives from the
    /// design's own pairs, and the certificate corroborates it: at the
    /// accessibility sizes the design's claim (60/72), date (53/64) and
    /// attestation (44/53) all land within half a point of it.
    public static let lineHeightFactor = TodayMetrics.lineHeightFactor

    /// Extra leading beyond the font's natural line height, so the drawn line
    /// heights are what the design measured.
    ///
    /// Computed at the base size and applied as a constant rather than scaled:
    /// the deltas are between 1 and 4 points here, and at the accessibility sizes
    /// the natural leading has already caught up with the target — so a scaling
    /// version would add up to four points to a fifty-point line to fix a
    /// discrepancy that no longer exists.
    public static func lineSpacing(pointSize: CGFloat, lineHeight: CGFloat) -> CGFloat {
        max(0, lineHeight - pointSize * lineHeightFactor)
    }

    // MARK: The layout budget

    /// The height of the whole document at the **default** type size, from the
    /// masthead's cap line to the last line of the identifier block.
    ///
    /// It is deliberately not parameterised by ``DynamicTypeSize``. Above
    /// `accessibility1` the sheet scrolls and the controls are pinned in their own
    /// block, so there is no budget to keep — that is the entire point of the
    /// structural variant, and computing a budget for a case that cannot overflow
    /// would be arithmetic that proves nothing.
    ///
    /// At the default size there **is** a budget, and it is what
    /// `CertificateMetricsTests` asserts: the document, the minimum spacer, the
    /// controls and the 40pt bottom inset all fit the 874pt frame with the design's
    /// two-line claim and four-line identifier block.
    public static func documentHeight(claimLines: Int, identifierLines: Int) -> CGFloat {
        let masthead = (mastheadPointSize * lineHeightFactor).rounded()
        return masthead
            + mastheadToRule + ruleHeight + ruleToClaim
            + CGFloat(claimLines) * claimLineHeight
            + claimToDate + dateLineHeight
            + dateToSealRow + sealSize
            + sealRowToRule + ruleHeight + ruleToIdentifier
            + CGFloat(identifierLines) * identifierLineHeight
    }

    /// Points left over on the 874pt frame after the safe area, the document, the
    /// minimum spacer, the controls and the bottom inset. Negative means the
    /// document is taller than the screen.
    public static func spareHeight(
        claimLines: Int = 2,
        identifierLines: Int = 4,
        frameHeight: CGFloat = CertificateMetrics.frameHeight
    ) -> CGFloat {
        frameHeight - (
            mastheadTop
                + documentHeight(claimLines: claimLines, identifierLines: identifierLines)
                + minimumSpacer + controlTarget + bottomInset
        )
    }

    // MARK: The share export — 5g

    /// 402 x 654 at 1x, rendered at @3x to 1206 x 1962.
    public static let exportWidth: CGFloat = 402
    public static let exportHeight: CGFloat = 654
    public static let exportScale: CGFloat = 3
    public static let exportPadding: CGFloat = 40
}

/// The certificate's colour, which is **no colour at all.**
///
/// No gold, no accent, no tint, no hue anywhere. The certificate reads as a
/// document rather than a payout, and `docs/product.md` bans every token
/// vocabulary that a colour would import. It is entirely type and paper, and it
/// has no image assets except the die frame.
public enum CertificatePalette {

    /// Full bleed. The screen **is** the sheet, which is why the seal has nothing
    /// to float above.
    public static let paper = HabitTint.rgb(242, 239, 232)  // #F2EFE8
    public static let paperDark = HabitTint.rgb(28, 28, 32)  // #1C1C20

    public static let ink = HabitTint.rgb(25, 25, 23)  // #191917
    public static let inkDark = HabitTint.rgb(237, 234, 226)  // #EDEAE2

    /// The date and the attestation.
    public static let secondaryInkOpacity: Double = 0.55
    public static let secondaryInkOpacityDark: Double = 0.58

    /// The masthead. **Distinct from secondary — do not collapse them.**
    public static let mastheadInkOpacity: Double = 0.50

    /// The identifier block.
    public static let identifierInkOpacity: Double = 0.42
    public static let identifierInkOpacityDark: Double = 0.44

    /// The rule under the masthead.
    public static let mastheadRuleOpacity: Double = 0.16
    public static let mastheadRuleOpacityDark: Double = 0.18

    /// The rule above the identifier block. **Lighter than the masthead rule** —
    /// turn 4d collapsed the two to one value, and the drawings differ. The drawn
    /// values are the ones here.
    public static let lowerRuleOpacity: Double = 0.14
    public static let lowerRuleOpacityDark: Double = 0.16

    public static func paper(for scheme: ColorScheme) -> Color {
        scheme == .dark ? paperDark : paper
    }

    public static func ink(for scheme: ColorScheme) -> Color {
        scheme == .dark ? inkDark : ink
    }

    public static func secondaryInk(for scheme: ColorScheme) -> Color {
        ink(for: scheme)
            .opacity(scheme == .dark ? secondaryInkOpacityDark : secondaryInkOpacity)
    }

    public static func mastheadInk(for scheme: ColorScheme) -> Color {
        ink(for: scheme).opacity(mastheadInkOpacity)
    }

    public static func identifierInk(for scheme: ColorScheme) -> Color {
        ink(for: scheme)
            .opacity(scheme == .dark ? identifierInkOpacityDark : identifierInkOpacity)
    }

    public static func mastheadRule(for scheme: ColorScheme) -> Color {
        ink(for: scheme)
            .opacity(scheme == .dark ? mastheadRuleOpacityDark : mastheadRuleOpacity)
    }

    public static func lowerRule(for scheme: ColorScheme) -> Color {
        ink(for: scheme).opacity(scheme == .dark ? lowerRuleOpacityDark : lowerRuleOpacity)
    }
}
