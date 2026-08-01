import CompassDomain
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The blind deboss. **A hallmark, never the thing you check.**
///
/// The thing you check is the full digest printed underneath and the export
/// bundle. That distinction is why 64 truncated bits in a die is not the mistake
/// the elided text hash was: a truncated hash written out in text invites a
/// verification it cannot support, and a pressed field does not invite anything.
///
/// ### What the cells encode
///
/// **The first 64 bits of `witness.evidenceRoot`** — the Merkle root over the
/// events that were actually counted (`docs/achievement-protocol.md` §4, frozen
/// in §4.1) — as an 8 x 8 field of pressed cells, MSB first, **one byte per
/// row**. So the impression is a property of *this* record and no other: two
/// certificates can never carry the same one, and forging it means colliding the
/// Merkle root.
///
/// A set bit is a struck cell. An unset bit is nothing drawn — flat paper. No
/// red, no cross, no apology.
///
/// ### How it is rendered, and what that costs
///
/// **The die frame ships with no matrix in it and the app strikes the cells over
/// it in SwiftUI**, per turn 5d, which withdrew the in-app height-field renderer
/// in the repository's own words: "it was an aesthetic preference wearing
/// infrastructure's clothes."
///
/// The alternative — shipping the full-size matrix PNGs, which one earlier line
/// of the same turn says to do — is the single most dangerous item in the design
/// bundle. A pre-baked matrix prints an **identical** 64-bit hallmark on every
/// certificate, destroying the exact property the impression exists for and
/// putting a false statement on a signed, anchored, shareable document. The later
/// line governs; the vendored assets are `die-*` only; `Assets/seal/README.md`
/// had already adjudicated it.
///
/// The cost of the two-layer strike is stated rather than hidden: it is flatter
/// than the reference render — the walls do not curve, there is no displaced lip
/// around each cell, and beside the stills it is visibly cheaper. That is the
/// accepted trade, and `Assets/seal/reference/` exists so it can be compared
/// against what it approximates.
///
/// ### The crop, which is load-bearing
///
/// The shipped frames are 400 x 400 (@2x) and 600 x 600 (@3x) — a **200pt nominal
/// frame at both scales**, so the asset-catalogue scale factors are correct as
/// named and must not be re-scaled relative to each other. The die impression
/// spans 68.4% of that frame, so drawing the asset at 168pt would give a die of
/// only ~115pt. It is drawn at 245.6pt and clipped to a centred 168pt square
/// instead. ``CertificateMetrics/dieSpanOfFrame``.
struct SealView: View {

    /// `witness.evidenceRoot`. Only the first 8 bytes are drawn.
    let evidenceRoot: Data

    /// 168pt shipping, 120pt at the accessibility sizes. **It does not scale with
    /// the text** — it is a graphic, not type.
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            frame
            matrix
        }
        .frame(width: size, height: size)
        // The flat paper in the asset is exactly the certificate background, so
        // the image has no edge and the impression belongs to the page. Clipping
        // to a square rather than to a rounded shape is part of that: a rounded
        // corner would announce an image.
        .clipped()
        .accessibilityHidden(true)
    }

    /// The die frame, drawn oversize and cropped to its impression.
    @ViewBuilder
    private var frame: some View {
        if let image = SealAsset.image(for: colorScheme, displayScale: displayScale) {
            image
                .resizable()
                .interpolation(.high)
                .frame(
                    width: CertificateMetrics.frameDrawSize(forSeal: size),
                    height: CertificateMetrics.frameDrawSize(forSeal: size)
                )
        } else {
            // The frame is missing from the bundle, which is a build failure
            // rather than a runtime condition. Drawing nothing leaves the struck
            // cells on flat paper: the certificate still says everything it needs
            // to, and the digest underneath is still the thing that is checked.
            Color.clear
        }
    }

    /// The 64 struck cells.
    ///
    /// Per set bit: a rounded rect filled in the **paper** colour, with a 1pt
    /// inner top-left shadow at 22% and a 1pt bottom-right highlight at 55% —
    /// one light source at 22 degrees above the sheet, from the upper left,
    /// everywhere on this screen.
    private var matrix: some View {
        let cell = CertificateMetrics.cellSide(atSealSize: size)
        let span = cell * CGFloat(CertificateMetrics.matrixSide)
        return VStack(spacing: 0) {
            ForEach(0..<CertificateMetrics.matrixSide, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<CertificateMetrics.matrixSide, id: \.self) { column in
                        Group {
                            if SealView.isStruck(evidenceRoot, row: row, column: column) {
                                struckCell(side: cell)
                            } else {
                                // Flat paper. Nothing is drawn at all.
                                Color.clear
                            }
                        }
                        .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: span, height: span)
    }

    private func struckCell(side: CGFloat) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: side * CertificateMetrics.cellCornerRatio, style: .continuous
        )
        let edge = CertificateMetrics.cellEdgeWidth
        return shape
            .fill(CertificatePalette.paper(for: colorScheme))
            .overlay {
                shape
                    .strokeBorder(
                        .black.opacity(CertificateMetrics.cellShadowOpacity), lineWidth: edge
                    )
                    // The upper-left wall catches the shadow.
                    .mask(alignment: .topLeading) {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: side))
                            path.addLine(to: CGPoint(x: 0, y: 0))
                            path.addLine(to: CGPoint(x: side, y: 0))
                            path.addLine(to: CGPoint(x: side, y: side))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [.black, .black, .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
            }
            .overlay {
                shape
                    .strokeBorder(
                        .white.opacity(CertificateMetrics.cellHighlightOpacity), lineWidth: edge
                    )
                    // And the lower-right one catches the light.
                    .mask {
                        LinearGradient(
                            colors: [.clear, .white, .white],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
            }
            .frame(width: side, height: side)
    }

    // MARK: The bits

    /// Whether the cell at `(row, column)` is struck.
    ///
    /// **MSB first, one byte per row.** Row `r` is byte `r` of the evidence root;
    /// column 0 is that byte's most significant bit. Stated as one function
    /// because it is the whole encoding, and because a certificate that drew the
    /// bits in a different order from the one the protocol names would be a
    /// hallmark of nothing.
    ///
    /// A root shorter than 8 bytes — which no rule in v1 can produce, since a
    /// root is 32 bytes or the 32 zero bytes of the empty set — draws nothing for
    /// the missing rows rather than trapping.
    static func isStruck(_ evidenceRoot: Data, row: Int, column: Int) -> Bool {
        let bytes = Array(evidenceRoot)
        guard row < bytes.count else { return false }
        return bytes[row] & (0x80 >> UInt8(column)) != 0
    }
}

// MARK: - The four files week 3 ships

/// The die frames, and nothing else. `Assets/seal/README.md`.
///
/// **Four files: light and dark, at @2x and @3x.** Both scales encode the same
/// **200pt nominal frame**, so the scale factors are correct as named and must
/// never be re-scaled relative to each other — that is the second way to get the
/// crop wrong, after drawing the asset at the seal size.
///
/// The appearance is chosen here rather than by an asset catalogue because
/// ``SealView`` already knows it, and because a catalogue is not compiled by
/// `swift build` — see `Package.swift` for why that mattered enough to decide it.
enum SealAsset {

    /// What the shipped frames are a frame *of*: a 200pt square at both scales.
    static let nominalSize: CGFloat = 200

    /// `die-light-3x`, `die-dark-2x`, and so on.
    ///
    /// `@3x` at a scale of 3 or more, `@2x` below it. There is no `@1x` frame and
    /// there is no device that would want one.
    static func name(for scheme: ColorScheme, displayScale: CGFloat) -> String {
        "die-\(scheme == .dark ? "dark" : "light")-\(displayScale >= 3 ? "3x" : "2x")"
    }

    static func url(for scheme: ColorScheme, displayScale: CGFloat) -> URL? {
        Bundle.module.url(
            forResource: name(for: scheme, displayScale: displayScale),
            withExtension: "png",
            subdirectory: "SealFrames"
        )
    }

    /// The frame, loaded **at its own scale** so its 400 or 600 pixels are 200
    /// points. Loading it at scale 1 would make the nominal frame 400pt and put
    /// the crop out by a factor of two.
    static func image(for scheme: ColorScheme, displayScale: CGFloat) -> Image? {
        guard let url = url(for: scheme, displayScale: displayScale),
              let data = try? Data(contentsOf: url)
        else { return nil }

        let scale = displayScale >= 3 ? CGFloat(3) : CGFloat(2)
        #if canImport(UIKit)
        guard let image = UIImage(data: data, scale: scale) else { return nil }
        return Image(uiImage: image)
        #else
        guard let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: nominalSize, height: nominalSize)
        return Image(nsImage: image)
        #endif
    }
}
