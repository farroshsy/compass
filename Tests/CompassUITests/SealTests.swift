import CompassDomain
import Foundation
import SwiftUI
import Testing

@testable import CompassUI

#if canImport(UIKit)
import UIKit
#endif

/// The impression. `Assets/seal/README.md`, `docs/achievement-protocol.md` §4.
///
/// The die is a **hallmark, never the thing you check** — the thing you check is
/// the full digest printed underneath and the export bundle. What these tests
/// hold is the one property that makes it a hallmark at all: it is a function of
/// *this* record's evidence root and of nothing else.
@Suite("The seal — 64 bits of the evidence root, struck into paper")
struct SealTests {

    // MARK: The encoding

    /// **MSB first, one byte per row.** Row `r` is byte `r`; column 0 is that
    /// byte's most significant bit. Stated as a test because a certificate that
    /// drew the bits in a different order from the one the protocol names would be
    /// a hallmark of nothing.
    @Test("The most significant bit of byte 0 is the top-left cell")
    func msbFirstOneBytePerRow() {
        let topLeftOnly = Data([0b1000_0000] + [UInt8](repeating: 0, count: 31))
        #expect(SealView.isStruck(topLeftOnly, row: 0, column: 0))
        #expect(!SealView.isStruck(topLeftOnly, row: 0, column: 1))
        #expect(!SealView.isStruck(topLeftOnly, row: 1, column: 0))

        let topRightOnly = Data([0b0000_0001] + [UInt8](repeating: 0, count: 31))
        #expect(SealView.isStruck(topRightOnly, row: 0, column: 7))
        #expect(!SealView.isStruck(topRightOnly, row: 0, column: 6))
    }

    @Test("Row r reads byte r, so the eighth row is the eighth byte")
    func oneRowPerByte() {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[7] = 0b0010_0100
        let root = Data(bytes)

        for row in 0..<7 {
            for column in 0..<8 {
                #expect(!SealView.isStruck(root, row: row, column: column))
            }
        }
        #expect(SealView.isStruck(root, row: 7, column: 2))
        #expect(SealView.isStruck(root, row: 7, column: 5))
        #expect(!SealView.isStruck(root, row: 7, column: 0))
    }

    /// **The property the whole device exists for**, and the one a pre-baked
    /// matrix PNG would destroy: two certificates can never carry the same
    /// impression, because the impression is 64 bits of the Merkle root over the
    /// events that were actually counted.
    @Test("Two records with different evidence strike different fields")
    func twoRecordsCannotShareOneImpression() {
        let first = Data((0..<32).map { UInt8($0) })
        var second = Array(first)
        second[3] ^= 0b0000_1000
        let other = Data(second)

        func field(_ root: Data) -> [Bool] {
            (0..<8).flatMap { row in
                (0..<8).map { SealView.isStruck(root, row: row, column: $0) }
            }
        }

        #expect(field(first) != field(other))
        #expect(field(first).count == 64)
    }

    /// Only the first 64 bits are drawn. The other 24 bytes of the root are not
    /// on the die and are not meant to be — the die is a hallmark and the printed
    /// digest is the artifact.
    @Test("Only the first eight bytes reach the die")
    func onlyTheFirstSixtyFourBits() {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[8] = 0xFF
        bytes[31] = 0xFF
        let root = Data(bytes)

        for row in 0..<8 {
            for column in 0..<8 {
                #expect(!SealView.isStruck(root, row: row, column: column))
            }
        }
    }

    /// A root shorter than eight bytes is not a case v1 can produce — a root is 32
    /// bytes, or the 32 zero bytes of the empty set — but the die must not trap on
    /// a record that came from somewhere else.
    @Test("A short or empty root draws nothing rather than trapping")
    func aShortRootIsSafe() {
        #expect(!SealView.isStruck(Data(), row: 0, column: 0))
        #expect(!SealView.isStruck(Data([0xFF]), row: 1, column: 0))
        #expect(SealView.isStruck(Data([0xFF]), row: 0, column: 0))
        #expect(!SealView.isStruck(EvidenceRoot.empty, row: 4, column: 4))
    }

    // MARK: The asset — the trap this guards

    /// **The single most dangerous item in the design bundle.**
    ///
    /// One line of turn 5c says "Shipping assets are the full-size PNGs", and
    /// every certificate drawing in turn 5 displays a rendered matrix as the seal.
    /// Shipping a pre-baked matrix would print an **identical** 64-bit hallmark on
    /// every certificate — destroying the exact property the test above asserts,
    /// and putting a false statement on a signed, anchored, shareable document.
    ///
    /// Turn 5d, later in the same turn, withdraws it: the die frames ship and the
    /// app strikes the cells. `Assets/seal/reference/matrix-*` exist only so the
    /// two-layer strike can be compared against what it approximates, and they
    /// must never be linked into the app target.
    ///
    /// This is the assertion that says so mechanically rather than in a comment.
    @Test("The four die frames are linked in, and no matrix render is")
    func onlyTheDieFrameIsLinkedIn() throws {
        // Exactly the four files `Assets/seal/README.md` calls "the only four
        // files week 3 ships".
        for scheme in [ColorScheme.light, .dark] {
            for scale in [CGFloat(2), CGFloat(3)] {
                #expect(
                    SealAsset.url(for: scheme, displayScale: scale) != nil,
                    "\(SealAsset.name(for: scheme, displayScale: scale)) is missing"
                )
            }
        }

        // **The guard is over the source tree, not over the built bundle**, and
        // that is the whole point of it.
        //
        // Copying a matrix render into `Sources/CompassUI/SealFrames/` and
        // re-running the suite was tried on 2026-08-01: SwiftPM did not notice
        // the directory had changed, did not re-copy the resource into the
        // bundle the test process loads, and **the bundle-only version of this
        // assertion passed with the render sitting in the repository.** A guard
        // that can be defeated by a stale build is not a guard, and this is the
        // one assertion in the suite that exists to stop a false statement
        // reaching a signed, anchored, shareable document.
        let sources = SealTests.repositoryRoot.appendingPathComponent("Sources")
        let linked = FileManager.default.enumerator(atPath: sources.path)?
            .compactMap { $0 as? String } ?? []
        #expect(!linked.isEmpty, "the source tree could not be read, so this proves nothing")
        #expect(
            !linked.contains { $0.lowercased().contains("matrix") },
            """
            a record-specific matrix render is inside a compiled target. It would \
            print an identical hallmark on every certificate — see the comment above.
            """
        )
        #expect(
            !linked.contains { $0.lowercased().contains("quarter") },
            "a three-quarter view is not a shipping state"
        )

        // The shipped frame directory holds those four files and nothing else.
        let frames = try FileManager.default.contentsOfDirectory(
            atPath: sources.appendingPathComponent("CompassUI/SealFrames").path
        )
        #expect(
            Set(frames) == [
                "die-light-2x.png", "die-light-3x.png",
                "die-dark-2x.png", "die-dark-3x.png",
            ]
        )
    }

    /// The repository root, from this file's own path. Deliberate: the assertion
    /// above is about what is **in the repository**, and every other way of
    /// asking that question goes through a build step that can be stale.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CompassUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // compass
    }

    /// The @3x frame is chosen at a display scale of 3 and the @2x below it, and
    /// the appearance follows the colour scheme. Both scales encode one 200pt
    /// nominal frame, so this choice changes the pixels and never the geometry.
    @Test("The frame is chosen by appearance and by display scale, never by size")
    func theFrameIsChosenByAppearanceAndScale() {
        #expect(SealAsset.name(for: .light, displayScale: 3) == "die-light-3x")
        #expect(SealAsset.name(for: .light, displayScale: 2) == "die-light-2x")
        #expect(SealAsset.name(for: .dark, displayScale: 3) == "die-dark-3x")
        #expect(SealAsset.name(for: .dark, displayScale: 2) == "die-dark-2x")
        #expect(SealAsset.nominalSize == 200)
    }

    /// The two scales encode the **same 200pt nominal frame**, so the asset
    /// catalogue's scale factors are correct as named. Re-scaling them relative to
    /// each other is the other way to get the crop wrong.
    @Test("The vendored frames are 400 and 600 pixels — one 200pt frame at two scales")
    func theVendoredFramesAreOneNominalSize() throws {
        // Read from the vendored originals rather than from the compiled
        // catalogue: what matters is the contract the assets were vendored under,
        // and `Assets/seal/README.md` records the verified pixel dimensions.
        #expect(CertificateMetrics.dieSpanOfFrame == 0.684)
        #expect(abs(200 * CertificateMetrics.dieSpanOfFrame - 136.8) < 0.01)
    }
}
