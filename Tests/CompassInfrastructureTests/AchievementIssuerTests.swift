import CompassApplication
import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// The guarded step, the two award files, and the rules on disk.
/// `docs/technical.md` §5 and §6, `docs/achievement-protocol.md` §7 and §8.
@Suite(.serialized)
struct AchievementIssuerTests {

    private func keychain() -> KeychainStore {
        KeychainStore(
            service: "dev.farros.compass.tests.\(UUID().uuidString)", account: "achievement-key"
        )
    }

    /// A store holding `count` consecutive daily check-ins for one habit,
    /// written through the real journal so the chain and the `lamport` sequence
    /// are the ones the app would have produced.
    private func seededStore<T>(
        days count: Int,
        from start: String = "2026-01-01",
        habit: HabitID = habitA,
        _ body: (StoreLayout, EventJournal, AchievementIssuer, KeychainStore) throws -> T
    ) throws -> T {
        try withTemporaryStore { layout in
            let clock = frozenClock(at: "2026-07-31T09:00:00+07:00")
            let journal = try EventJournal(layout: layout, writer: writerApp, clock: clock)
            defer { journal.close() }

            try journal.record(
                kind: .habitCreated, day: day(start), source: nil,
                payload: .habit(habit, name: "Meditate")
            )
            for offset in 0..<count {
                try journal.record(
                    kind: .checkedIn, day: day(start).adding(offset), source: .tap,
                    payload: .habit(habit)
                )
            }

            let store = keychain()
            defer { store.delete() }
            let issuer = AchievementIssuer(
                layout: layout, recorder: journal, clock: clock, keychain: store
            )
            return try body(layout, journal, issuer, store)
        }
    }

    // MARK: The pass, end to end

    /// The shipped rule rows are read from the package bundle, seeded into the
    /// store, and fire over history the first time the engine runs — which is
    /// exactly the trigger `docs/technical.md` §10a names for weekly log-head
    /// anchoring in week 4.
    @Test("A 40-day history awards the shipped 7-day and 30-day rules, and nothing else")
    func theShippedRulesFireOverHistory() throws {
        try seededStore(days: 40) { _, _, issuer, _ in
            let book = try issuer.issue()
            #expect(
                book.newlyIssued.map(\.rawValue).sorted() == [
                    "streak.habit-a.30@2026-01-30", "streak.habit-a.7@2026-01-07",
                ]
            )
            #expect(book.achievements.count == 2)
        }
    }

    /// §7.1 step 2: sealing happens **immediately, in the same pass, offline**.
    /// The certificate therefore has something true to say the moment it is shown.
    @Test("Every award is signed in the same pass, and the signature verifies")
    func everyAwardIsSealedImmediately() throws {
        try seededStore(days: 10) { _, _, issuer, _ in
            let book = try issuer.issue()
            let award = try #require(book.achievements.first)
            let attestation = try #require(book.attestations[award.id])

            #expect(attestation.state == .sealed)
            #expect(
                Signer.isValid(
                    attestation.signature,
                    over: try award.canonicalBytes,
                    publicKey: attestation.publicKey
                )
            )
            // Nothing about anchoring has happened, and nothing may say it has.
            #expect(attestation.otsProof == nil)
            #expect(attestation.submittedAt == nil)
            #expect(attestation.confirmedAt == nil)
        }
    }

    /// **`backing` on the record is the signer's own, not a constant.**
    /// `docs/technical.md` §8, `docs/achievement-protocol.md` §7 — "`backing`
    /// MUST be recorded honestly".
    ///
    /// This is the *writer* half of that rule, and §7.0 bis is why it is the half
    /// that can actually be delivered: `backing` says what backed the key, and no
    /// field in the format says what kind of machine ran the app.
    ///
    /// Nothing asserted the rule until 2026-08-01, and the cost was measured:
    /// replacing `backing: signer.backing` in `AchievementIssuer.seal` with a
    /// hardcoded `.secureEnclave` left **all 493 tests passing**. The value was
    /// reaching `attestations.jsonl` and the standalone verifier the whole time,
    /// and every bundle would have claimed the strongest provenance the format
    /// can express.
    ///
    /// It is driven through the whole issuer rather than through `Signer` alone —
    /// `SignerTests` already pins `Signer.backing` itself — because the defect is
    /// not in the signer. It is in whether what the signer knows survives the
    /// trip onto disk.
    ///
    /// The software key is forced through `Signer(store:preferEnclave:)`, and the
    /// issuer then *restores* it. That restore is the real path: a build that has
    /// ever run on a host with no enclave keeps the software key in its keychain
    /// forever. It is **not** how a simulator behaves — on a T2 or Apple Silicon
    /// Mac the simulator has an enclave and takes the other branch.
    @Test("A software-backed key is recorded as software, on disk, by the issuer")
    func theRecordedBackingIsTheSignersOwn() throws {
        try seededStore(days: 10) { layout, _, issuer, keys in
            // The key exists before the pass, exactly as it does on every launch
            // after the first, and it is a software one.
            let minted = try Signer(store: keys, preferEnclave: false)
            #expect(minted.backing == .software)

            let book = try issuer.issue()
            let award = try #require(book.achievements.first)

            #expect(book.attestations[award.id]?.backing == .software)
            #expect(book.attestations[award.id]?.publicKey == minted.publicKey)

            // And it is on disk, in the file that travels, rather than only in
            // the value this pass returned.
            let onDisk = try AwardStore(layout: layout).readAttestations()
            #expect(onDisk[award.id]?.backing == .software)
            let raw = try String(contentsOf: layout.attestations, encoding: .utf8)
            #expect(raw.contains("\"backing\":\"software\""))
            #expect(!raw.contains("secureEnclave"))
        }
    }

    /// The other half, so the test above cannot pass by always reading
    /// `software`. On a machine with an enclave the ordinary path records
    /// `secureEnclave`, and on one without it there is nothing to distinguish —
    /// so the assertion is that the record agrees with the signer, whichever the
    /// machine has.
    @Test("The recorded backing always agrees with the key that actually signed")
    func theRecordAgreesWithTheSigner() throws {
        try seededStore(days: 10) { _, _, issuer, keys in
            let book = try issuer.issue()
            let award = try #require(book.achievements.first)
            // Constructed after the pass, so it restores the key the pass
            // persisted rather than minting a second one.
            let signer = try Signer(store: keys)

            #expect(book.attestations[award.id]?.backing == signer.backing)
            #expect(book.attestations[award.id]?.publicKey == signer.publicKey)
        }
    }

    /// §9.2 and §9.5. The certificate must not be raised twice for one fact, and
    /// `awards.jsonl` must not grow a duplicate line per launch.
    @Test("Running the pass again awards nothing and writes nothing")
    func theSecondPassIsAnEmptyPass() throws {
        try seededStore(days: 10) { layout, _, issuer, _ in
            _ = try issuer.issue()
            let afterFirst = try Data(contentsOf: layout.awards)

            let second = try issuer.issue()
            #expect(second.newlyIssued.isEmpty)
            #expect(try Data(contentsOf: layout.awards) == afterFirst)

            // And the log's own record of the award is written once, not once per
            // pass.
            _ = try issuer.issue()
            let events = try JournalReader(url: layout.events).read().events
            #expect(events.filter { $0.kind == .achievementAwarded }.count == 1)
        }
    }

    /// `docs/technical.md` §5: "The engine computes eligibility; a separate
    /// guarded step appends `achievementAwarded` exactly once."
    @Test("The log carries one achievementAwarded per award, naming the achievement")
    func theLogRecordsTheAward() throws {
        try seededStore(days: 40) { layout, _, issuer, _ in
            let book = try issuer.issue()
            let events = try JournalReader(url: layout.events).read().events
            let announced = events
                .filter { $0.kind == .achievementAwarded }
                .compactMap(\.payload.achievementID)

            #expect(Set(announced) == Set(book.achievements.map(\.id)))
        }
    }

    /// A crash between the record and the event is repaired on the next pass
    /// rather than leaving the log permanently silent about an award that exists.
    @Test("A missing achievementAwarded event is repaired on the next pass")
    func aMissingAwardEventIsRepaired() throws {
        try seededStore(days: 10) { layout, journal, issuer, store in
            _ = try issuer.issue()

            // A fresh store with the same awards file but a log that never got
            // the event — which is what a crash between the two writes leaves.
            try withTemporaryStore { second in
                try FileManager.default.copyItem(at: layout.awards, to: second.awards)
                let clock = frozenClock()
                let journalTwo = try EventJournal(
                    layout: second, writer: writerApp, clock: clock
                )
                defer { journalTwo.close() }
                let issuerTwo = AchievementIssuer(
                    layout: second, recorder: journalTwo, clock: clock, keychain: store
                )
                _ = try issuerTwo.issue()

                let events = try JournalReader(url: second.events).read().events
                #expect(events.filter { $0.kind == .achievementAwarded }.count == 1)
            }
            _ = journal
        }
    }

    // MARK: Revocation — §8

    /// The rule this file exists to keep: **you never erase a published entry;
    /// you post a reversal.** The achievement stays on disk, keeps its place in
    /// the list, and gains a revocation beside it.
    @Test("Un-checking a counted day posts a reversal and deletes nothing")
    func revocationAppendsAndNeverDeletes() throws {
        try seededStore(days: 10) { layout, journal, issuer, _ in
            let first = try issuer.issue()
            let id = try #require(first.achievements.first).id
            let awardsAfterIssue = try Data(contentsOf: layout.awards)

            try journal.record(
                kind: .checkInRevoked, day: day("2026-01-04"), source: nil,
                payload: .habit(habitA)
            )

            let after = try issuer.issue()
            #expect(after.isRevoked(id))
            // The record survives, in its place.
            #expect(after.achievements.contains { $0.id == id })

            // Append-only: everything that was there is still there, byte for
            // byte, with the reversal added after it.
            let awardsAfterRevocation = try Data(contentsOf: layout.awards)
            #expect(awardsAfterRevocation.count > awardsAfterIssue.count)
            #expect(awardsAfterRevocation.prefix(awardsAfterIssue.count) == awardsAfterIssue)

            // And the log says so once.
            let events = try JournalReader(url: layout.events).read().events
            #expect(events.filter { $0.kind == .achievementRevoked }.count == 1)
        }
    }

    @Test("A reversal is posted once, not once per launch")
    func revocationIsPostedOnce() throws {
        try seededStore(days: 10) { layout, journal, issuer, _ in
            _ = try issuer.issue()
            try journal.record(
                kind: .checkInRevoked, day: day("2026-01-04"), source: nil,
                payload: .habit(habitA)
            )
            _ = try issuer.issue()
            let afterFirst = try Data(contentsOf: layout.awards)

            _ = try issuer.issue()
            #expect(try Data(contentsOf: layout.awards) == afterFirst)
        }
    }

    /// A revoked achievement must not be re-awarded when the user re-checks the
    /// day: the ID already carries a posted reversal, and awarding it again would
    /// put two contradictory records in an append-only file.
    @Test("A revoked achievement is not awarded again when the day comes back")
    func aRevokedAwardIsNotReissued() throws {
        try seededStore(days: 10) { layout, journal, issuer, _ in
            let id = try #require(try issuer.issue().achievements.first).id

            try journal.record(
                kind: .checkInRevoked, day: day("2026-01-04"), source: nil,
                payload: .habit(habitA)
            )
            _ = try issuer.issue()

            try journal.record(
                kind: .checkedIn, day: day("2026-01-04"), source: .tap, payload: .habit(habitA)
            )
            let after = try issuer.issue()

            #expect(after.newlyIssued.isEmpty)
            #expect(after.achievements.filter { $0.id == id }.count == 1)
            _ = layout
        }
    }

    // MARK: The two files

    /// §7: attestations live apart from awards **because they mutate while the
    /// achievement does not**, and the mutable file is append-only with
    /// last-write-wins on read.
    @Test("An attestation state change appends a line and wins on read")
    func attestationsAreAppendOnlyAndLastWriteWins() throws {
        try withTemporaryStore { layout in
            let store = AwardStore(layout: layout)
            let id = AchievementID(rawValue: "streak.habit-a.7@2026-01-07")
            let base = Attestation(
                achievement: id, publicKey: Data([1]), signature: Data([2]),
                backing: .software, state: .sealed
            )
            try store.append(base)

            var upgraded = base
            upgraded.state = .confirmed
            upgraded.confirmedAt = instant("2026-03-17T00:00:00+00:00")
            try store.append(upgraded)

            #expect(try store.readAttestations()[id]?.state == .confirmed)
            // Both lines are on disk. Nothing was rewritten.
            #expect(lineCount(try Data(contentsOf: layout.attestations)) == 2)
        }
    }

    /// The two record types share one file with no discriminator, and the reader
    /// tells them apart by shape. A line that is neither is **counted, kept and
    /// never rewritten** — the same contract the event log has for a line it
    /// cannot decode.
    @Test("awards.jsonl holds both record types, and keeps a line it cannot read")
    func awardsFileKeepsWhatItCannotRead() throws {
        try withTemporaryStore { layout in
            let store = AwardStore(layout: layout)
            let achievement = AchievementIssuerTests.sampleAchievement
            try store.append(.achievement(achievement))
            try store.append(
                .revocation(
                    Revocation(
                        achievement: achievement.id, reason: Revocation.dependedOnDayEdited,
                        at: instant("2026-03-17T00:00:00+00:00"), newLogHeads: [:]
                    )
                )
            )
            try appendRawLine(Data(#"{"record":"somethingFromANewerBuild"}"#.utf8), to: layout.awards)

            let ledger = try store.readAwards()
            #expect(ledger.achievements.count == 1)
            #expect(ledger.revocations.count == 1)
            #expect(ledger.unreadableLines == [3])

            // Kept, not dropped: reading and re-reading does not shorten the file.
            #expect(lineCount(try Data(contentsOf: layout.awards)) == 3)
        }
    }

    /// §3.3 gives `detectedAt` exactly two jobs, and this is one: it orders the
    /// certificate list.
    ///
    /// **The tiebreak is the whole test.** A first pass over history detects
    /// every backfilled award at the *same instant*, so on the run that produces
    /// the longest list `detectedAt` orders nothing — and a list that put the
    /// 7-day record above the 30-day one would be reverse-chronological in name
    /// only. Falling back to `earnedOn` is what makes the word true. This is what
    /// the simulator actually showed on 2026-08-01 before the fallback existed.
    @Test("A list detected in one pass is still ordered by the day the claim landed")
    func theListIsReverseChronological() throws {
        try seededStore(days: 40) { _, _, issuer, _ in
            let book = try issuer.issue()
            #expect(book.achievements.count == 2)
            #expect(
                book.achievements.map(\.id.rawValue) == [
                    "streak.habit-a.30@2026-01-30", "streak.habit-a.7@2026-01-07",
                ]
            )
            // And they really were detected together, so `earnedOn` is the field
            // doing the work rather than a coincidence of timing.
            #expect(book.achievements[0].detectedAt == book.achievements[1].detectedAt)
        }
    }

    // MARK: Rules on disk — §5.1, §6

    @Test("The bundled rules are seeded into the store and never overwritten")
    func rulesAreSeededOnceAndLeftAlone() throws {
        try withTemporaryStore { layout in
            let store = RuleStore(layout: layout)
            let rules = try store.load()
            #expect(rules.count == 23, "20 per-habit streaks plus 3 all-habit totals")
            #expect(rules.allSatisfy { $0.kind.isImplemented })

            // A rule file edited by hand is the "hot-reloadable" half of §6 and is
            // never clobbered by a later launch.
            let edited = layout.rules.appendingPathComponent("totals.json")
            try Data("[]".utf8).write(to: edited)
            #expect(try store.load().count == 20)
        }
    }

    /// A rule ID never carries a habit's display name — the identifier block on
    /// the certificate prints it verbatim, and that certificate is designed to be
    /// handed to a stranger. `memory/decisions.md`, 2026-08-01.
    @Test("No shipped rule ID contains a habit display name")
    func ruleIdentifiersAreOpaque() throws {
        try withTemporaryStore { layout in
            let names = ["move", "read", "build", "reflect", "meditate", "walk", "write"]
            for rule in try RuleStore(layout: layout).load() {
                let id = rule.id.rawValue.lowercased()
                #expect(!names.contains { id.contains($0) }, "\(rule.id) names a habit")
            }
        }
    }

    /// §5.1: an unknown kind is skipped and **the rule file is left on disk
    /// untouched.** An older build never destroys rules it does not understand.
    @Test("A rule from a newer build is skipped and left exactly where it is")
    func anUnknownRuleKindSurvivesThePass() throws {
        try seededStore(days: 10) { layout, _, issuer, _ in
            let future = layout.rules.appendingPathComponent("lunar.json")
            let json = #"""
                [{"id":"lunar.habit-a.13","kind":"lunar","threshold":13,
                  "scope":{"habit":"habit-a","requiresAll":false}}]
                """#
            _ = try RuleStore(layout: layout).load()
            try Data(json.utf8).write(to: future)
            let before = try Data(contentsOf: future)

            let book = try issuer.issue()
            #expect(!book.achievements.contains { $0.rule.id.rawValue == "lunar.habit-a.13" })
            #expect(try Data(contentsOf: future) == before)
        }
    }

    // MARK: The export bundle — §8, §9.13

    /// **The assertion §9.13 asks for, which could not be made until week 3
    /// because there were no achievements to reproduce.**
    ///
    /// > A test asserts that a fresh install fed only the exported bundle
    /// > reproduces every achievement **bit-identically** and verifies every
    /// > proof. An unexercised escape hatch is not an escape hatch.
    ///
    /// Bit-identically means the **digest**, not the fields: two records that
    /// agreed field by field and disagreed by one byte in the canonical form
    /// would carry two different signatures and fail every verification a
    /// stranger could run. The proof half is week 4's; the signature half is
    /// here, and it is checked against the restored `attestations.jsonl`.
    ///
    /// The earlier form of the bundle contained neither file. Someone who
    /// followed the documents exactly, exported weekly, and then dropped their
    /// phone in a river lost every signature and every proof.
    @Test("A fresh install fed only the bundle reproduces every award, digest for digest")
    func theBundleCarriesTheAwardsAndTheirSignatures() throws {
        try seededStore(days: 40) { layout, _, issuer, _ in
            let issued = try issuer.issue()
            #expect(issued.achievements.count == 2)

            try withTemporaryStore { workspace in
                let bundle = workspace.storeURL.appendingPathComponent("b", isDirectory: true)
                try Exporter(layout: layout).export(to: bundle, at: instant("2026-08-01T00:00:00+00:00"))

                // The three artifacts that did not exist before week 3.
                let manifest = try Exporter(layout: layout).verify(bundleAt: bundle)
                #expect(manifest.files[BundleFile.awards] != nil)
                #expect(manifest.files[BundleFile.attestations] != nil)
                #expect(manifest.files.keys.contains { $0.hasPrefix("rules/") })

                try withTemporaryStore { restored in
                    try Exporter(layout: restored).restore(from: bundle)
                    let book = try AwardStore(layout: restored).readAwards()

                    #expect(
                        try book.achievements.map { hex(try $0.digest) }
                            == issued.achievements.map { hex(try $0.digest) }
                    )

                    // And every signature still verifies against the restored
                    // record, on a device that has none of the keys.
                    let attestations = try AwardStore(layout: restored).readAttestations()
                    for achievement in book.achievements {
                        let attestation = try #require(attestations[achievement.id])
                        #expect(
                            Signer.isValid(
                                attestation.signature,
                                over: try achievement.canonicalBytes,
                                publicKey: attestation.publicKey
                            )
                        )
                    }
                }
            }
        }
    }

    // MARK: A fixture

    static let sampleAchievement = Achievement(
        id: AchievementID(rawValue: "streak.habit-a.7@2026-01-07"),
        rule: RuleSpec(
            id: RuleID(rawValue: "streak.habit-a.7"), kind: .streak,
            scope: Scope(habit: habitA), threshold: 7
        ),
        earnedOn: day("2026-01-07"),
        detectedAt: instant("2026-01-07T12:00:00+00:00"),
        facts: [
            .streak: .int(7), .habitID: .string("habit-a"), .from: .string("2026-01-01"),
            .sourceLive: .int(7), .sourceBackfill: .int(0),
        ],
        witness: Witness(
            firstDay: day("2026-01-01"), lastDay: day("2026-01-07"), dayCount: 7,
            evidenceRoot: Data(repeating: 0x11, count: 32), logHeads: [:]
        )
    )
}
