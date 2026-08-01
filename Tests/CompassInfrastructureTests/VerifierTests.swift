import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// The standalone verifier, run against a bundle this suite produced.
/// `docs/product.md`, `docs/adr/0004`, `docs/technical.md` §10a.
///
/// **This is the test that makes the mission sentence true rather than stated.**
/// The sentence promises a record a stranger can check "without trusting you or
/// the app", and `verifier/compass-verify.py` is the thing that makes that
/// runnable. A verifier that has never verified a real bundle is not a verifier,
/// and a verifier that shares code with the app has checked nothing.
///
/// It shares none. It is Python, it imports only the standard library, it
/// reimplements both canonical forms from `docs/technical.md` §3 and
/// `docs/achievement-protocol.md` §6, and it verifies P-256 by doing the
/// elliptic-curve arithmetic itself. So when it agrees with `CanonicalBytes.swift`
/// and `Signer.swift`, that agreement is **evidence** rather than a tautology —
/// which is exactly what week 1b's Python event verifier established as the
/// pattern, now extended to the achievement form, the signature and the proof.
///
/// It throws rather than skipping when Python is missing, for the same reason
/// `TwoWritersTests` throws when its helper binary is missing: a skipped test is
/// a green suite nobody reads.
@Suite(.serialized)
struct VerifierTests {

    /// A store with awards, signatures and a submitted log-head anchor, exported
    /// to a bundle.
    private func exportedBundle<T>(
        confirming: Bool = false, _ body: (URL) throws -> T
    ) async throws -> T {
        try await withTemporaryStoreAsync { layout in
            let issuing = frozenClock(at: "2026-02-10T09:00:00+07:00")
            let journal = try EventJournal(layout: layout, writer: writerApp, clock: issuing)
            defer { journal.close() }

            try journal.record(
                kind: .habitCreated, day: day("2026-01-01"), source: nil,
                payload: .habit(habitA, name: "Meditate")
            )
            for offset in 0..<40 {
                try journal.record(
                    kind: .checkedIn, day: day("2026-01-01").adding(offset), source: .tap,
                    payload: .habit(habitA)
                )
            }

            let keys = KeychainStore(
                service: "dev.farros.compass.tests.\(UUID().uuidString)",
                account: "achievement-key"
            )
            defer { keys.delete() }
            _ = try AchievementIssuer(
                layout: layout, recorder: journal, clock: issuing, keychain: keys
            ).issue()

            let calendars = StubCalendars()
            calendars.acceptEverySubmission()
            let pipeline = AnchorPipeline(
                layout: layout, calendars: calendars.calendars,
                clock: frozenClock(at: "2026-02-14T09:00:00+07:00")
            )
            _ = try await pipeline.drain()

            if confirming {
                // A second pass, with the calendars now holding the Bitcoin
                // path. Both files gain a **second line** for records they
                // already have — that is what append-only means — and reading
                // them unfolded is what a naive verifier does.
                calendars.answerEveryUpgrade(with: bitcoinResponse(height: 912_345))
                _ = try await pipeline.drain()
            }

            let bundle = layout.storeURL.appendingPathComponent("bundle", isDirectory: true)
            try Exporter(layout: layout).export(
                to: bundle, at: instant("2026-02-14T09:00:00Z")
            )
            return try body(bundle)
        }
    }

    /// The bundle carries everything `docs/technical.md` §8 lists for a feature
    /// that exists. A file missing here is a file the verifier cannot check, and
    /// the one this project would notice last is a proof.
    @Test("An exported bundle carries the anchors, the proofs and the public key")
    func theBundleIsComplete() async throws {
        try await exportedBundle { bundle in
            let names = Set(
                try FileManager.default.subpathsOfDirectory(atPath: bundle.path)
            )
            #expect(names.contains("events.jsonl"))
            #expect(names.contains("awards.jsonl"))
            #expect(names.contains("attestations.jsonl"))
            #expect(names.contains("anchors.jsonl"))
            #expect(names.contains("habits.json"))
            #expect(names.contains("publickey.pem"))
            #expect(names.contains("manifest.json"))
            #expect(names.contains { $0.hasPrefix("proofs/") && $0.hasSuffix(".ots") })
            #expect(names.contains { $0.hasPrefix("rules/") })

            // The public key is the form the rest of the world reads, not this
            // project's X9.63 blob in a file with a `.pem` extension.
            let pem = try String(
                contentsOf: bundle.appendingPathComponent("publickey.pem"), encoding: .utf8
            )
            #expect(pem.hasPrefix("-----BEGIN PUBLIC KEY-----"))

            // And the manifest covers every one of them, or `verify` is checking
            // a subset while claiming to check the bundle.
            let manifest = try JSONDecoder().decode(
                ExportManifest.self,
                from: try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))
            )
            #expect(manifest.files.keys.contains("anchors.jsonl"))
            #expect(manifest.files.keys.contains("publickey.pem"))
            #expect(manifest.files.keys.contains { $0.hasSuffix(".ots") })
            try Exporter(layout: StoreLayout(storeURL: bundle)).verify(bundleAt: bundle)
        }
    }

    /// **The whole point.** An independent implementation, written from the
    /// documents, agrees about every byte string this project signs.
    @Test("The standalone verifier passes every check on a bundle it did not produce")
    func theVerifierAgreesWithTheApp() async throws {
        try await exportedBundle { bundle in
            let result = try runVerifier(on: bundle)
            #expect(result.status == 0, Comment(rawValue: result.output))

            // Each of these lines is a claim the app makes and the verifier
            // independently re-derived, and no other test in this suite can
            // assert them: nothing else here recomputes the canonical bytes with
            // different code.
            #expect(result.output.contains("chain unbroken from genesis"))
            #expect(result.output.contains("the log supports it"))
            #expect(result.output.contains("evidence root recomputed"))
            #expect(result.output.contains("P-256 signature verifies"))
            #expect(result.output.contains("the anchored digest is the digest of these heads"))
            #expect(result.output.contains("the anchored head IS this log's head"))
            // `publickey.pem` is what other tools read. If it disagreed with the
            // keys that actually signed, one of the two would be lying about the
            // bundle, and only a second reader can notice.
            #expect(
                result.output.contains(
                    "publickey.pem holds exactly the keys that signed these records"
                )
            )
            #expect(result.output.contains("every record here was signed by one key"))
            #expect(result.output.contains("Every check that could run, passed."))

            // And it says out loud what it could not do, rather than implying a
            // pending proof is a proof.
            #expect(result.output.contains("no Bitcoin attestation yet"))
        }
    }

    /// A verifier that passes everything is not a verifier. One byte changed in
    /// the middle of the log has to be caught, and caught **as what it is** —
    /// the chain, not the signature, is what a tampered event breaks.
    @Test("Editing one event in an exported bundle is caught")
    func tamperingWithTheLogIsCaught() async throws {
        try await exportedBundle { bundle in
            let events = bundle.appendingPathComponent("events.jsonl")
            let text = try String(contentsOf: events, encoding: .utf8)
            // A meditation streak rewritten into a reading streak — the exact
            // forgery `payload` was pulled into the digest to prevent.
            try text.replacingOccurrences(of: "\"habit-a\"", with: "\"habit-z\"")
                .write(to: events, atomically: true, encoding: .utf8)

            let result = try runVerifier(on: bundle)
            #expect(result.status == 1)
            #expect(result.output.contains("digest does not match the manifest"))
            #expect(result.output.contains("CHECK(S) FAILED"))
        }
    }

    /// The manifest is not the defence — the chain is. A bundle whose manifest
    /// was rewritten to match the tampered log still fails, and it fails on the
    /// two things a forger cannot recompute without the key.
    @Test("A tampered log with a rewritten manifest still fails on the chain and the claim")
    func aRewrittenManifestDoesNotSaveAForgery() async throws {
        try await exportedBundle { bundle in
            let events = bundle.appendingPathComponent("events.jsonl")
            let text = try String(contentsOf: events, encoding: .utf8)
            try text.replacingOccurrences(of: "\"habit-a\"", with: "\"habit-z\"")
                .write(to: events, atomically: true, encoding: .utf8)

            // Recompute the manifest exactly as an honest exporter would, so the
            // only thing left to catch the change is the cryptography.
            let manifestURL = bundle.appendingPathComponent("manifest.json")
            var manifest = try JSONDecoder().decode(
                ExportManifest.self, from: try Data(contentsOf: manifestURL)
            )
            var files = manifest.files
            files["events.jsonl"] = Exporter.sha256Hex(try Data(contentsOf: events))
            manifest = ExportManifest(exportedAt: manifest.exportedAt, files: files)
            try Exporter.canonicalJSON(manifest).write(to: manifestURL)

            let result = try runVerifier(on: bundle)
            #expect(result.status == 1, Comment(rawValue: result.output))
            // The chain breaks at the edited line, because `payload` is inside
            // the digest that `prev` points at.
            #expect(result.output.contains("does not match its predecessor"))
            // And the achievement no longer follows from the log it names.
            #expect(result.output.contains("the log does not support this claim"))
        }
    }

    /// The other half of forgery, and the one the signature is actually for:
    /// leaving the log alone and inflating the **claim**.
    ///
    /// A 30-day streak rewritten to read 1,000 is a record whose chain still
    /// verifies, whose manifest can be rewritten, and whose every byte is
    /// plausible — and it fails on the two checks a forger cannot pass without
    /// the private key and without the days: the signature, and the log.
    @Test("Inflating the claim on an award is caught by the signature and by the log")
    func tamperingWithTheClaimIsCaught() async throws {
        try await exportedBundle { bundle in
            let awards = bundle.appendingPathComponent("awards.jsonl")
            let text = try String(contentsOf: awards, encoding: .utf8)
            try text.replacingOccurrences(of: "\"threshold\":30", with: "\"threshold\":1000")
                .write(to: awards, atomically: true, encoding: .utf8)

            let manifestURL = bundle.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(
                ExportManifest.self, from: try Data(contentsOf: manifestURL)
            )
            var files = manifest.files
            files["awards.jsonl"] = Exporter.sha256Hex(try Data(contentsOf: awards))
            try Exporter.canonicalJSON(
                ExportManifest(exportedAt: manifest.exportedAt, files: files)
            ).write(to: manifestURL)

            let result = try runVerifier(on: bundle)
            #expect(result.status == 1, Comment(rawValue: result.output))
            #expect(result.output.contains("the P-256 signature does NOT verify"))
            // 40 days of history cannot support a 1,000-day streak, and the
            // verifier says that in its own words rather than only reporting a
            // bad signature.
            #expect(result.output.contains("the log does not support this claim"))
        }
    }

    /// **The confirmed path, end to end, through both implementations.**
    ///
    /// It is a separate test from the pending one because the *shape on disk*
    /// differs: `anchors.jsonl` and `attestations.jsonl` are append-only, so a
    /// record that has been upgraded has two lines — the older still saying
    /// `submitted`. Folding them last-write-wins is a rule the app keeps and the
    /// verifier has to keep independently, and it is the kind of agreement that
    /// only a second reader can check.
    ///
    /// Running this for the first time is what found the verifier reporting one
    /// anchor as two: the stale line beside the fresh one, and a "no Bitcoin
    /// attestation yet" in the summary of a bundle that had one.
    @Test("A confirmed bundle verifies, and one anchor is reported once")
    func aConfirmedBundleVerifies() async throws {
        try await exportedBundle(confirming: true) { bundle in
            // Two lines on disk, one anchor.
            let raw = try String(
                contentsOf: bundle.appendingPathComponent("anchors.jsonl"), encoding: .utf8
            )
            #expect(raw.split(separator: "\n").count == 2)

            let result = try runVerifier(on: bundle)
            #expect(result.status == 0, Comment(rawValue: result.output))

            // The folding assertion: two lines on disk, **one** anchor in the
            // report. Reading them unfolded printed the stale `submitted` line
            // beside the fresh `confirmed` one, which reads as two anchors.
            let anchorReports = result.output.components(
                separatedBy: "the anchored digest is the digest of these heads"
            ).count - 1
            #expect(anchorReports == 1)

            // One Bitcoin block per proof: the log head and the two awards. Each
            // is a separate record with a separate digest, so three is right and
            // one would mean two of them went unreported.
            let confirmations = result.output.components(
                separatedBy: "Bitcoin block 912345 commits merkle root"
            ).count - 1
            #expect(confirmations == 3)
            #expect(!result.output.contains("no Bitcoin attestation yet"))
            // What it verified, and what it refuses to pretend it verified.
            #expect(
                result.output.contains(
                    "whether block 912345 really has that merkle root"
                )
            )
            #expect(result.output.contains("Every check that could run, passed."))
        }
    }

    // MARK: Running it

    private struct VerifierRun {
        let status: Int32
        let output: String
    }

    private func runVerifier(on bundle: URL) throws -> VerifierRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", VerifierTests.script().path, bundle.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return VerifierRun(
            status: process.terminationStatus, output: String(decoding: output, as: UTF8.self)
        )
    }

    /// Found from this source file, like `TwoWritersTests` finds its helper: it
    /// is a file in the repository, not a build product.
    private static func script() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CompassInfrastructureTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package
            .appendingPathComponent("verifier/compass-verify.py")
    }
}
