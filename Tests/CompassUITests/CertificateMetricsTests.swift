import CompassDomain
import Foundation
import SwiftUI
import Testing

@testable import CompassUI

/// The certificate's geometry, and the seal's crop.
///
/// Same contract as `TodayMetricsTests`: `.claude/skills/testing.md` and
/// `docs/technical.md` §9 both refuse SwiftUI snapshot tests, so what is asserted
/// is not a rendering but the arithmetic the rendering is built from. Two of the
/// findings here would be silently lost by a plausible edit — the crop, which is
/// what makes the die the right size at all, and the structural threshold, which
/// is the only thing that lets a 42pt identifier block be readable in full.
@Suite("The certificate's geometry, and the seal's crop")
struct CertificateMetricsTests {

    // MARK: The crop — the mistake this constant exists to prevent

    /// **Drawing the shipped asset at the seal size gives a die that is a third
    /// too small.** The frames are a 200pt nominal square and the impression
    /// occupies 68.4% of it, so this is the number the design warns about by name
    /// — "drawing the asset at 168pt gives a die of only ~115pt".
    @Test("Drawing the frame at the seal size would give a 115pt die, not a 168pt one")
    func theNaiveDrawIsWrong() {
        let naive = CertificateMetrics.sealSize * CertificateMetrics.dieSpanOfFrame
        #expect(abs(naive - 115) < 1)
    }

    /// The two draw sizes every turn-5 drawing uses: 246 into a 168 box with a
    /// −39 margin, and 176 into a 120 box with a −28 margin. Both fall out of one
    /// ratio, so there is one number to be wrong rather than three.
    @Test("The frame is drawn oversize and cropped, at both seal sizes")
    func theCropIsDerivedFromOneRatio() {
        #expect(
            abs(CertificateMetrics.frameDrawSize(forSeal: 168) - 245.6) < 0.1,
            "the design draws 246 and insets 39 on each side"
        )
        #expect(abs(CertificateMetrics.frameInset(forSeal: 168) - 38.8) < 0.2)

        #expect(
            abs(CertificateMetrics.frameDrawSize(forSeal: 120) - 175.4) < 0.1,
            "the design draws 176 and insets 28 on each side"
        )
        #expect(abs(CertificateMetrics.frameInset(forSeal: 120) - 27.7) < 0.2)

        // And the crop is scale-invariant, which is what makes the ratio the
        // right thing to keep rather than the two sizes.
        for size in [CertificateMetrics.sealSize, CertificateMetrics.sealSizeAccessibility] {
            let drawn = CertificateMetrics.frameDrawSize(forSeal: size)
            #expect(abs(drawn * CertificateMetrics.dieSpanOfFrame - size) < 0.001)
        }
    }

    // MARK: The matrix

    /// 8.6pt per cell at a 168pt die: 8 x 8.6 = 68.8pt of matrix inside the die.
    @Test("A cell is 8.6pt at the shipping size")
    func cellPitchAtShippingSize() {
        #expect(abs(CertificateMetrics.cellSide(atSealSize: 168) - 8.6) < 0.01)
        #expect(
            abs(
                CertificateMetrics.cellSide(atSealSize: 168)
                    * CGFloat(CertificateMetrics.matrixSide) - 68.8
            ) < 0.01
        )
    }

    /// **The unvalidated number, pinned so it is at least visible.**
    ///
    /// `memory/known-bugs.md`: the "holds to 160pt, merges at 120pt" finding was
    /// measured on the **superseded** 4 x 7 twenty-eight-cell device, and the
    /// shipped device is an 8 x 8 sixty-four-cell matrix — more than twice as
    /// dense. At the accessibility size a cell falls to 6.14pt with a 1pt shadow
    /// and a 1pt highlight on it, i.e. a third of the cell is edge treatment.
    /// Nobody has measured whether that still reads as struck data.
    ///
    /// The test does not claim it does. It claims the number is 6.14, so that a
    /// future change to the AX5 size or to the matrix ratio has to come here and
    /// read this paragraph.
    @Test("At the accessibility size a cell is 6.14pt, and that has never been measured")
    func cellPitchAtTheAccessibilitySize() {
        #expect(abs(CertificateMetrics.cellSide(atSealSize: 120) - 6.14) < 0.01)
        // Two thirds of the cell is face; one third is the 1pt shadow and the 1pt
        // highlight. Stated as arithmetic so the risk is legible.
        let face = CertificateMetrics.cellSide(atSealSize: 120) - 2 * CertificateMetrics.cellEdgeWidth
        #expect(face < CertificateMetrics.cellSide(atSealSize: 120) * 0.7)
    }

    /// The mark on Today and one cell in the die are the same form at two scales,
    /// which is a consequence the design recorded as worth keeping. It is read
    /// from `TodayMetrics` rather than restated, so it cannot drift.
    @Test("A struck cell is the same rounded square as the checked-row mark")
    func theCellIsTheDailyMark() {
        #expect(CertificateMetrics.cellCornerRatio == TodayMetrics.markCornerRatio)
    }

    // MARK: The vertical rhythm

    @Test("The masthead sits 90pt from the top of the frame")
    func mastheadPosition() {
        #expect(CertificateMetrics.mastheadTop == 90)
        #expect(CertificateMetrics.safeAreaTop == 62)
        #expect(CertificateMetrics.topInset == 28)
    }

    /// **It deliberately breaks the bottom-anchored rule.** Today's last row sits
    /// 24pt above the home indicator; this is 40, because the certificate is a
    /// document rather than a daily interaction.
    @Test("The bottom inset is 40, not Today's 24")
    func bottomInsetIsNotTodays() {
        #expect(CertificateMetrics.bottomInset == 40)
        #expect(CertificateMetrics.bottomInset != TodayMetrics.bottomInset)
    }

    /// The document, the minimum spacer, the controls and the bottom inset all fit
    /// the reference frame at the default size, with the spacer taking up the
    /// slack. This is the assertion behind "the layout is fixed above the spacer".
    @Test("The whole document fits the 874pt frame with room for the spacer")
    func theDocumentFits() {
        let spare = CertificateMetrics.spareHeight()
        #expect(spare > 0, "the certificate overflows its own reference frame")
        #expect(spare > 100, "there is no slack left for a longer claim")

        // A three-line claim and a six-line identifier block — the worst case the
        // default size can produce — still fits.
        #expect(CertificateMetrics.spareHeight(claimLines: 3, identifierLines: 6) > 0)
    }

    /// The two rules are different weights, and collapsing them to one value is
    /// exactly what turn 4d did. The drawings differ; the drawn values are kept.
    @Test("The masthead rule and the lower rule are not the same weight")
    func theTwoRulesDiffer() {
        #expect(CertificatePalette.mastheadRuleOpacity != CertificatePalette.lowerRuleOpacity)
        #expect(
            CertificatePalette.mastheadRuleOpacityDark != CertificatePalette.lowerRuleOpacityDark
        )
    }

    /// Masthead ink is 50% in both appearances and secondary ink is 55/58. They
    /// are close enough to look like a rounding error and are not one.
    @Test("Masthead ink and secondary ink are distinct, in both appearances")
    func mastheadInkIsNotSecondaryInk() {
        #expect(
            CertificatePalette.mastheadInkOpacity != CertificatePalette.secondaryInkOpacity
        )
        #expect(
            CertificatePalette.mastheadInkOpacity != CertificatePalette.secondaryInkOpacityDark
        )
    }

    // MARK: Dynamic Type — the structural variant

    /// Above `accessibility1` the sheet stops being a fixed layout and becomes a
    /// scroll view with the controls pinned below it. Everything else about the
    /// accessibility pass depends on that being true.
    @Test("The structural variant begins at accessibility1 and not before")
    func theStructuralThreshold() {
        for size in DynamicTypeSize.allCases {
            #expect(
                CertificateMetrics.isStructural(size) == (size >= .accessibility1),
                "\(size)"
            )
        }
    }

    /// **The seal is a graphic and does not scale with the text.** It steps once,
    /// and never shrinks below its accessibility size to make room for type —
    /// which is why the attestation stacks below it instead.
    @Test("The seal takes exactly two sizes, and steps at the structural threshold")
    func theSealStepsRatherThanScales() {
        let sizes = Set(DynamicTypeSize.allCases.map(CertificateMetrics.sealSize(at:)))
        #expect(sizes == [168, 120])

        // Two values is not enough on its own: it has to step in the same place
        // the layout does, or the die shrinks while the row it sits in is still
        // side-by-side — which is the arrangement that cannot hold 44pt text.
        for size in DynamicTypeSize.allCases {
            #expect(
                CertificateMetrics.sealSize(at: size)
                    == (CertificateMetrics.isStructural(size) ? 120 : 168),
                "\(size)"
            )
        }
    }

    /// At AX5 the claim reflows to three lines and the hard break is dropped: an
    /// explicit break inside a paragraph that is already wrapping produces a
    /// ragged orphan.
    @Test("The claim's hard line break is dropped at the structural sizes")
    func theClaimStopsBreakingItself() {
        #expect(CertificateMetrics.claimBreaksLines(at: .large))
        #expect(!CertificateMetrics.claimBreaksLines(at: .accessibility5))
    }

    @Test("The controls grow from 44 to 53 at the structural sizes")
    func controlTargets() {
        #expect(CertificateMetrics.controlTarget(at: .large) == 44)
        #expect(CertificateMetrics.controlTarget(at: .accessibility5) == 53)
    }

    // MARK: The share export

    /// 402 x 654 at 1x, rendered at @3x — 1206 x 1962.
    @Test("The export renders at the size the design specifies")
    func exportGeometry() {
        #expect(CertificateMetrics.exportWidth * CertificateMetrics.exportScale == 1206)
        #expect(CertificateMetrics.exportHeight * CertificateMetrics.exportScale == 1962)
        #expect(CertificateMetrics.exportPadding == 40)
    }

    /// The document is shorter than the export canvas, so nothing is cropped out
    /// of the artifact that leaves the phone.
    @Test("The document fits the export canvas with both controls removed")
    func theExportHoldsTheDocument() {
        let used = 2 * CertificateMetrics.exportPadding
            + CertificateMetrics.documentHeight(claimLines: 2, identifierLines: 4)
        #expect(used <= CertificateMetrics.exportHeight)
    }

    // MARK: Leading

    /// The design's own pairs corroborate the 1.2 factor `TodayMetrics` derives:
    /// at the accessibility sizes the claim (60/72), the date (53/64) and the
    /// attestation (44/53) all land within half a point of it.
    @Test("The line-height factor the design implies is the one already in use")
    func leadingFactorHolds() {
        #expect(CertificateMetrics.lineHeightFactor == TodayMetrics.lineHeightFactor)
        #expect(abs(60 * CertificateMetrics.lineHeightFactor - 72) < 0.5)
        #expect(abs(53 * CertificateMetrics.lineHeightFactor - 64) < 0.5)
        #expect(abs(44 * CertificateMetrics.lineHeightFactor - 53) < 0.5)
    }
}
