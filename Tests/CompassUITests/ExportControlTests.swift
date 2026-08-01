import CompassDomain
import Foundation
import Testing

@testable import CompassUI

/// The settings sheet's export control — everything about it that is not the
/// system's file picker.
///
/// **Why this suite exists.** `docs/product.md` has budgeted export to the
/// settings sheet since its first draft — "Rename, archive, export" — and
/// `Exporter` was written and tested in week 1. Neither fact made export
/// reachable: until 2026-08-01 `grep` found no `fileExporter` and no `Exporter(`
/// outside `Export.swift` and its own tests, so every bundle this project ever
/// verified was produced by a helper process written beside the app. A mission
/// sentence promising a record "you can hand to a stranger" was, from inside the
/// product, false.
///
/// **What is not asserted here, said plainly.** The picker is a system sheet and
/// `.claude/skills/testing.md` refuses snapshot tests and a broad XCUITest suite
/// out loud, so nothing here can prove that a folder landed on disk. What is
/// asserted is every decision the control makes before and after it:
///
/// - that pressing it produces the bundle the port supplies, unchanged;
/// - that a failure becomes a sentence rather than a silence;
/// - that the document reproduces the bundle byte for byte, including nesting;
/// - that the filename is a civil date and carries nothing else.
///
/// `ExportTests` holds the other end — that the port's bundle is the bundle
/// `Exporter` writes to disk, file for file. Together they are the chain.
@MainActor
@Suite("The export control — the bundle, the document, and the failure")
struct ExportControlTests {

    private func model(exporting: (any Exporting)?) -> TodayModel {
        let seeded = seededFour()
        return TodayModel(
            events: seeded,
            clock: ScriptedClock("2026-08-01T09:00:00+07:00"),
            recorder: FakeRecorder(continuing: seeded),
            source: FakeSource(),
            exporting: exporting
        )
    }

    // MARK: The model

    /// The control hands over what the port produced and does not touch it. A
    /// surface that edited the bundle would be a surface producing a record the
    /// manifest does not describe.
    @Test("Exporting returns the port's bundle, unchanged")
    func exportReturnsThePortsBundle() async throws {
        let bundle = sampleBundle()
        let port = FakeExporting(bundle: bundle)

        let outcome = await model(exporting: port).export()

        guard case .ready(let produced) = outcome else {
            Issue.record("expected a bundle, got \(outcome)")
            return
        }
        #expect(produced == bundle)
        #expect(port.calls == 1)
    }

    /// **The one place in this app where a failure must speak.**
    ///
    /// Everywhere else — a failed tap, a failed anchor, a failed award — silence
    /// is correct and `.claude/skills/ui.md` requires it: those are background
    /// passes nobody asked for, and the next one repairs whatever the last one
    /// missed. Export is a button somebody just pressed, and a button that
    /// quietly does nothing is the "did that work?" doubt the whole synchronous
    /// design exists to remove.
    @Test("A failed export is a sentence, not a silence")
    func aFailedExportSaysSo() async {
        let outcome = await model(exporting: FakeExporting(fails: true)).export()

        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        // The reason travels verbatim: there is nobody to file a report with —
        // one person, one phone — so a message that said only "something went
        // wrong" would cost a future session the entire diagnosis.
        #expect(message.contains("the store went away"))
    }

    /// A launch that could not open the store has nothing to export, and says
    /// that rather than presenting an empty picker. It is the same condition
    /// ``TodayModel/isStoreAvailable`` reports on Today, said where a file was
    /// asked for.
    @Test("With no store there is nothing to export, and it says so")
    func noPortIsAnHonestRefusal() async {
        let outcome = await model(exporting: nil).export()

        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message == SettingsCopy.exportUnavailable)
    }

    // MARK: The document

    /// **The document is the bundle.** Every member, byte for byte, under the
    /// directories its path names.
    ///
    /// A member silently dropped here is a file the stranger never receives, and
    /// `manifest.json` digests all of them — so the bundle would fail its own
    /// check on the far side, with nothing on this side having noticed.
    @Test("The exported document reproduces every member, byte for byte")
    func theDocumentIsTheBundle() throws {
        let bundle = sampleBundle()
        let wrapper = BundleDocument(bundle: bundle).directoryWrapper()

        #expect(wrapper.isDirectory)
        var flattened: [String: Data] = [:]
        for (name, member) in wrapper.fileWrappers ?? [String: FileWrapper]() {
            if member.isDirectory {
                for (leaf, file) in member.fileWrappers ?? [String: FileWrapper]() {
                    flattened["\(name)/\(leaf)"] = file.regularFileContents
                }
            } else {
                flattened[name] = member.regularFileContents
            }
        }

        #expect(flattened.keys.sorted() == bundle.files.keys.sorted())
        for (path, bytes) in bundle.files {
            #expect(flattened[path] == bytes, "\(path) differs")
        }
    }

    /// Nesting is real nesting. `rules/` and `proofs/` are directories in the
    /// bundle `Exporter` writes and in the one the verifier reads, and a
    /// flattened `rules-totals.json` beside them would be a bundle no reader in
    /// this project accepts.
    @Test("rules/ and proofs/ come out as directories, not as flattened names")
    func nestedMembersStayNested() throws {
        let wrapper = BundleDocument(bundle: sampleBundle()).directoryWrapper()
        let children = try #require(wrapper.fileWrappers)

        let rules = try #require(children["rules"])
        #expect(rules.isDirectory)
        #expect(rules.fileWrappers?.keys.sorted() == ["totals.json"])

        let proofs = try #require(children["proofs"])
        #expect(proofs.isDirectory)
        #expect(proofs.fileWrappers?.count == 1)
    }

    /// An empty store still produces a bundle, and the document still produces a
    /// directory rather than nothing. `ExportTests` pins the same case one target
    /// down: a bundle whose shape depended on whether anything had been tapped
    /// yet would be a bundle whose restore path is untested on day one.
    @Test("A bundle with no members is an empty directory, not a missing one")
    func anEmptyBundleIsStillADirectory() {
        let wrapper = BundleDocument(
            bundle: ExportBundle(files: [:], exportedAt: .distantPast)
        ).directoryWrapper()

        #expect(wrapper.isDirectory)
        #expect(wrapper.fileWrappers?.isEmpty == true)
    }

    // MARK: The filename

    /// A civil date and nothing else.
    ///
    /// No time, because two exports on one day are the same day's record. **No
    /// declared name**, for the reason `docs/achievement-protocol.md` §3.4 gives
    /// about `rule.id`: the name is optional and unverified, there is no
    /// redaction path, and a filename travels further than most fields do.
    @Test("The default filename is the export's civil date, and carries nothing else")
    func theFilenameIsADate() {
        let zone = TimeZone(secondsFromGMT: 7 * 3_600)!
        #expect(
            SettingsCopy.exportFilename(at: instant("2026-08-01T09:00:00+07:00"), in: zone)
                == "Compass-2026-08-01"
        )
        // Zero-padded, so the names sort as dates in a file listing.
        #expect(
            SettingsCopy.exportFilename(at: instant("2026-01-05T09:00:00+07:00"), in: zone)
                == "Compass-2026-01-05"
        )
        // It is the export's own instant that names it, in the user's zone — an
        // export made at 00:30 in Surabaya is that day's, not the previous day's
        // in UTC.
        #expect(
            SettingsCopy.exportFilename(at: instant("2026-08-02T00:30:00+07:00"), in: zone)
                == "Compass-2026-08-02"
        )
    }
}
