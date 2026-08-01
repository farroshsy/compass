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
        confirming: Bool = false, softwareKey: Bool = false, _ body: (URL) throws -> T
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
            // A software key, forced. It is **not** "a simulator's key": on any
            // host with a Secure Enclave — every T2 and Apple Silicon Mac — the
            // simulator mints a real enclave key and the record says
            // `secureEnclave`, measured on 2026-08-01. The fallback happens only
            // on a host with no enclave at all. Forcing it is what lets this
            // fixture say the same thing on every machine.
            //
            // Minted before the pass, because the issuer restores whatever is
            // already in the keychain — which is what a build that has ever run
            // without an enclave does forever.
            if softwareKey {
                _ = try Signer(store: keys, preferEnclave: false)
            }
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

    // MARK: §8 — what the record says backed the key, read out loud

    /// **The verifier says what the record claims, and says it twice.**
    ///
    /// "The record says so" is only half of it. A record nothing reads out loud
    /// is a record a reader does not have, and the run this file exists to
    /// produce ends in a one-line conclusion — so the distinction has to survive
    /// a reader who reads only that line. Before 2026-08-01 the summary of a
    /// bundle every one of whose signatures came from a software key was "Every
    /// check that could run, passed." and nothing else.
    ///
    /// It is **unchecked, not failed**: a software signature is perfectly valid
    /// and nothing about the bundle is wrong. What it cannot support is the claim
    /// that one particular phone made it, and that is what gets said.
    @Test("A software-backed bundle says so, per record and in the summary")
    func aSoftwareKeyIsReportedAsSoftware() async throws {
        try await exportedBundle(softwareKey: true) { bundle in
            // The record itself, first: this is what travels.
            let raw = try String(
                contentsOf: bundle.appendingPathComponent("attestations.jsonl"), encoding: .utf8
            )
            #expect(raw.contains("\"backing\":\"software\""))

            let result = try runVerifier(on: bundle)
            // Not a failure. The signatures verify; the provenance is weaker.
            #expect(result.status == 0, Comment(rawValue: result.output))
            #expect(result.output.contains("P-256 signature verifies"))
            #expect(result.output.contains("the key is SOFTWARE-backed"))
            #expect(result.output.contains("attests to no particular device"))
            // And in the conclusion, where a skimming reader stops.
            #expect(result.output.contains("were NOT made by a Secure Enclave key"))
            #expect(!result.output.contains("CLAIMS a Secure Enclave key"))
        }
    }

    /// The other half, so the test above cannot pass by saying "software"
    /// unconditionally: a bundle whose record *does* say `secureEnclave` is read
    /// differently, and read as a **claim** rather than as a stronger case.
    ///
    /// It forges nothing — `aForgedEnclaveClaimIsNotReportedAsVerified` covers
    /// the adversarial half — and asserts only that the two words produce two
    /// different readings, neither of them an `ok`.
    ///
    /// **The record is written here rather than taken from the host.** This test
    /// used to export an ordinary bundle and hope the machine had an enclave,
    /// with a `withKnownIssue` for machines that do not. That got the world
    /// backwards: `SecureEnclave.isAvailable` is true inside the iOS Simulator on
    /// every T2 and Apple Silicon Mac, and the case the escape hatch was written
    /// for is the rare one. Writing the field makes the test say the same thing
    /// on every host, which is what a fixture about *reporting* should do.
    @Test("A record claiming an enclave key is read as a claim, not as a stronger case")
    func anEnclaveClaimIsReadAsAClaim() async throws {
        try await exportedBundle(softwareKey: true) { bundle in
            let url = bundle.appendingPathComponent("attestations.jsonl")
            try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(
                    of: "\"backing\":\"software\"", with: "\"backing\":\"secureEnclave\""
                )
                .write(to: url, atomically: true, encoding: .utf8)

            let result = try runVerifier(on: bundle)
            #expect(result.output.contains("CLAIMS a Secure Enclave key"))
            #expect(result.output.contains("this run verified none of those claims"))
            #expect(!result.output.contains("SOFTWARE-backed"))
            #expect(!result.output.contains("were NOT made by a Secure Enclave key"))
        }
    }

    /// **The forgery the `ok` marker invited.** `docs/achievement-protocol.md`
    /// §9 Invariant 8, and the reason it exists.
    ///
    /// `backing` is deliberately **outside the digest** — §7, because no
    /// signature can prove what hardware held the key that made it — so on a
    /// bundle received from someone else it is attacker-controlled text. This
    /// test takes a genuinely software-signed bundle, changes the one word, and
    /// recomputes every manifest digest exactly as an honest exporter would. The
    /// signature still verifies, the chain is untouched, the log still supports
    /// the claim: **nothing is left to catch it but how the field is reported.**
    ///
    /// Until 2026-08-01 the answer was "nothing". That bundle printed
    ///
    /// ```text
    ///   ok         the key is Secure Enclave-backed, per the record
    ///   ok       every signature here came from a Secure Enclave key
    /// ```
    ///
    /// under the same `ok` marker as the P-256 signature, the manifest digests
    /// and the chain — the three things this file actually recomputes. The
    /// `software` and `missing` branches hedged correctly the whole time; only
    /// the strongest claim, the one a forger would choose, was rendered as a
    /// check that passed.
    ///
    /// It is **not** promoted to a failure. A bundle that claims an enclave key
    /// is not thereby a forgery, and this file cannot tell the two apart — which
    /// is the entire point. It is reported as unchecked, in the end-of-run list
    /// of things this run could not do.
    @Test("A forged secureEnclave claim is never reported as a check that passed")
    func aForgedEnclaveClaimIsNotReportedAsVerified() async throws {
        try await exportedBundle(softwareKey: true) { bundle in
            let url = bundle.appendingPathComponent("attestations.jsonl")
            let genuine = try String(contentsOf: url, encoding: .utf8)
            #expect(genuine.contains("\"backing\":\"software\""))
            try genuine.replacingOccurrences(
                of: "\"backing\":\"software\"", with: "\"backing\":\"secureEnclave\""
            ).write(to: url, atomically: true, encoding: .utf8)

            // Every digest recomputed, not just the edited file's: a forger has
            // the whole manifest and no reason to leave one stale.
            let manifestURL = bundle.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(
                ExportManifest.self, from: try Data(contentsOf: manifestURL)
            )
            var files = manifest.files
            for name in files.keys {
                files[name] = Exporter.sha256Hex(
                    try Data(contentsOf: bundle.appendingPathComponent(name))
                )
            }
            try Exporter.canonicalJSON(
                ExportManifest(exportedAt: manifest.exportedAt, files: files)
            ).write(to: manifestURL)

            let result = try runVerifier(on: bundle)

            // The forgery is invisible to everything that actually verifies, and
            // that is what makes the reporting load-bearing rather than cosmetic.
            #expect(result.status == 0, Comment(rawValue: result.output))
            #expect(result.output.contains("P-256 signature verifies"))
            #expect(!result.output.contains("digest does not match the manifest"))
            #expect(!result.output.contains("CHECK(S) FAILED"))

            // **The assertion this test exists for.** `ok` is reserved for a
            // check that recomputed something, and reading a field is not that.
            for line in result.output.split(separator: "\n") where line.contains("Secure Enclave") {
                #expect(
                    !line.contains("ok "),
                    Comment(rawValue: "an undigested claim rendered as a passed check: \(line)")
                )
            }
            #expect(!result.output.contains("the key is Secure Enclave-backed"))
            #expect(!result.output.contains("every signature here came from a Secure Enclave key"))

            // And it is said out loud, twice, in the words that mark it unverified.
            #expect(result.output.contains("CLAIMS a Secure Enclave key"))
            #expect(result.output.contains("`backing` is outside the digest"))
            #expect(result.output.contains("this run verified none of those claims"))
            // In the end-of-run list, which is where a reader looks for what was
            // not established.
            #expect(result.output.contains("could not be checked here"))
        }
    }

    /// A record that does not say is reported as not saying, and never assumed to
    /// be the stronger of the two.
    ///
    /// This is not hypothetical bookkeeping: `attestations.jsonl` is read
    /// last-write-wins from an append-only file that a newer or older build may
    /// have written, and `docs/technical.md` §6's damage policy is "never
    /// silently drop lines and never refuse". A verifier that raised a `KeyError`
    /// on a missing field would refuse the whole bundle over one absent word, and
    /// one that defaulted to `secureEnclave` would invent the strongest claim the
    /// format can make.
    @Test("An attestation with no backing field is reported as not saying")
    func aMissingBackingIsReportedRatherThanAssumed() async throws {
        try await exportedBundle { bundle in
            let url = bundle.appendingPathComponent("attestations.jsonl")
            let stripped = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\"backing\":\"secureEnclave\",", with: "")
                .replacingOccurrences(of: "\"backing\":\"software\",", with: "")
            try stripped.write(to: url, atomically: true, encoding: .utf8)

            let result = try runVerifier(on: bundle)
            #expect(result.output.contains("does not say what backed its key"))
            #expect(!result.output.contains("CLAIMS a Secure Enclave key"))
            // The manifest no longer matches, which is a real failure and the
            // one that should be reported — but the run reaches the end and says
            // what it saw rather than dying on a missing key.
            #expect(result.output.contains("what this run concluded"))
        }
    }

    // MARK: §4.1 — the leaf order, on a log that can tell the two apart

    /// **A log whose day order is not its `(lamport, device)` order**, which is
    /// the only kind of log that can distinguish a correct evidence root from a
    /// plausible one.
    ///
    /// Two writers, two habits, five check-ins appended out of day sequence: the
    /// two days that are checked in last are the two *earliest* days, and one day
    /// holds two events written by different writers at different times. That is
    /// not a contrived shape — it is what the widget and the app produce whenever
    /// a day is filled in after a later one, and `docs/technical.md` §4 has them
    /// interleaving by design.
    ///
    /// Every earlier bundle in this suite is tidy: one writer's check-ins,
    /// appended one day after another, so day order and `(lamport, device)` order
    /// coincide and a reader sorting by either reaches the same root. A verifier
    /// that agrees only on tidy data is worse than none, because it is trusted.
    /// This fixture is the one that fails it.
    ///
    /// It builds the store with a **fresh journal per write** — the cold path
    /// `WidgetStore.toggle` is on — so the two writers really do interleave
    /// through the tail rather than through one process's cached resume.
    private func interleavedBundle<T>(_ body: (URL, StoreLayout) throws -> T) throws -> T {
        try withTemporaryStore { layout in
            let issuing = frozenClock(at: "2026-02-10T09:00:00+07:00")

            func write(
                _ writer: DeviceID, _ kind: EventKind, on iso: String,
                _ payload: EventPayload, source: CheckInSource?
            ) throws {
                let journal = try EventJournal(layout: layout, writer: writer, clock: issuing)
                defer { journal.close() }
                try journal.record(kind: kind, day: day(iso), source: source, payload: payload)
            }

            try write(writerApp, .habitCreated, on: "2026-01-01", .habit(habitA, name: "Move"), source: nil)
            try write(writerWidget, .habitCreated, on: "2026-01-01", .habit(habitB, name: "Read"), source: nil)

            // The five check-ins, in an order no day-sorted reader can reproduce:
            // the last day first, then the first, then the middle one twice.
            try write(writerApp, .checkedIn, on: "2026-01-03", .habit(habitA), source: .tap)
            try write(writerWidget, .checkedIn, on: "2026-01-03", .habit(habitB), source: .widget)
            try write(writerApp, .checkedIn, on: "2026-01-01", .habit(habitA), source: .tap)
            try write(writerWidget, .checkedIn, on: "2026-01-02", .habit(habitB), source: .widget)
            try write(writerApp, .checkedIn, on: "2026-01-02", .habit(habitA), source: .tap)

            // An "any habit" total at three days, so the counted set spans all
            // three days and one day contributes two leaves. The shipped rows
            // start at 100 and cannot fire over a three-day log; this one is
            // written into the store's own `rules/`, which `RuleStore` reads and
            // never overwrites.
            _ = try RuleStore(layout: layout).load()
            try Data(
                #"[{"id":"total.recorded.3","kind":"total","threshold":3,"scope":{"requiresAll":false}}]"#
                    .utf8
            ).write(to: layout.rules.appendingPathComponent("interleaved.json"))

            let keys = KeychainStore(
                service: "dev.farros.compass.tests.\(UUID().uuidString)",
                account: "achievement-key"
            )
            defer { keys.delete() }
            let journal = try EventJournal(layout: layout, writer: writerApp, clock: issuing)
            defer { journal.close() }
            _ = try AchievementIssuer(
                layout: layout, recorder: journal, clock: issuing, keychain: keys
            ).issue()

            let bundle = layout.storeURL.appendingPathComponent("bundle", isDirectory: true)
            try Exporter(layout: layout).export(
                to: bundle, at: instant("2026-02-14T09:00:00Z")
            )
            return try body(bundle, layout)
        }
    }

    /// **`docs/achievement-protocol.md` §4.1 is the arbiter, and both readers now
    /// obey it.**
    ///
    /// The leaves are "the qualifying events' `content_hash` values, in
    /// `(lamport, device)` order" — the document says nothing about days, and on
    /// this log the two orders give two different roots. The test computes both
    /// from §4.1's own primitives rather than from either implementation's
    /// gathering code, then asserts which one the app recorded and that the
    /// standalone verifier reaches the same one.
    ///
    /// Found by reading `evidence_for` in `verifier/compass-verify.py`, which
    /// iterated `days` and handed the result straight to `evidence_root`. It
    /// passed every bundle this suite had because every one of them was appended
    /// in day order.
    @Test("§4.1: the evidence leaves are in (lamport, device) order, never day order")
    func evidenceLeavesAreInTotalOrderNotDayOrder() throws {
        try interleavedBundle { bundle, layout in
            let events = try JournalReader(url: layout.events).read().events
            let checkIns = events.filter { $0.kind == .checkedIn }
            #expect(checkIns.count == 5)

            // The two candidate leaf sequences, spelled out here rather than
            // borrowed: day-major (what a reader that iterates days produces) and
            // §4.1's `(lamport, device)`.
            let days = Set(checkIns.map(\.day)).sorted()
            let dayMajor = days.flatMap { day in
                checkIns.filter { $0.day == day }.sorted { $0.order < $1.order }
            }
            let totalOrder = checkIns.sorted { $0.order < $1.order }

            // **The fixture is load-bearing.** If this ever holds, the log has
            // become tidy again and the test below has stopped proving anything.
            #expect(
                dayMajor.map(\.lamport) != totalOrder.map(\.lamport),
                "the fixture no longer distinguishes day order from (lamport, device) order"
            )

            let dayRoot = EvidenceRoot.root(
                ofLeaves: try dayMajor.map { EvidenceRoot.leaf(try $0.contentHash) }
            )
            let specRoot = EvidenceRoot.root(
                ofLeaves: try totalOrder.map { EvidenceRoot.leaf(try $0.contentHash) }
            )
            #expect(dayRoot != specRoot)

            // The app sorts, so it recorded §4.1's root and not the other one.
            let awards = try AwardStore(layout: layout).readAwards()
            #expect(awards.achievements.count == 1)
            let witness = try #require(awards.achievements.first).witness
            #expect(hex(witness.evidenceRoot) == hex(specRoot))
            #expect(hex(witness.evidenceRoot) != hex(dayRoot))

            // And the second reader, sharing none of that code, agrees.
            let result = try runVerifier(on: bundle)
            #expect(result.status == 0, Comment(rawValue: result.output))
            #expect(result.output.contains("evidence root recomputed"))
            #expect(!result.output.contains("the evidence root does not cover"))
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
