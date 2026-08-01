import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// Week 4's pass: what leaves the device, when, and what happens when nobody
/// answers. `docs/adr/0004`, `docs/achievement-protocol.md` §7.1,
/// `docs/technical.md` §9.8.
///
/// Everything here runs against a scripted `URLSession` — see
/// ``StubCalendarProtocol`` for why the seam is there and not behind a fake
/// `Calendars`. The one live network test is `CalendarNetworkTests`.
///
/// **`.serialized` for the keychain, not for the script.** Each test owns its own
/// scripted session — that is what ``StubCalendars`` is for, and it is what makes
/// this suite safe to run beside `VerifierTests`. What still has to be serial is
/// the real keychain: these tests issue real achievements, which mint and delete
/// real `SecItem`s, and running that concurrently is how a headless run acquires
/// a dialog nobody is there to dismiss.
@Suite(.serialized)
struct AnchoringTests {

    private func keychain() -> KeychainStore {
        KeychainStore(
            service: "dev.farros.compass.tests.\(UUID().uuidString)", account: "achievement-key"
        )
    }

    /// A store with `days` of history for one habit, its awards issued and
    /// sealed, and a pipeline pointed at a scripted calendar.
    ///
    /// `detectedAt` is the lever every one of these tests pulls: the 72-hour
    /// window is measured from it, so a clock set three days later is a store
    /// whose achievements are submittable and a clock set an hour later is one
    /// whose achievements are not.
    private func sealedStore<T>(
        days: Int = 40,
        issuedAt: String = "2026-02-10T09:00:00+07:00",
        now: String = "2026-02-20T09:00:00+07:00",
        _ body: (StoreLayout, AnchorPipeline, AwardStore, StubCalendars) async throws -> T
    ) async throws -> T {
        try await withTemporaryStoreAsync { layout in
            let issuing = frozenClock(at: issuedAt)
            let journal = try EventJournal(layout: layout, writer: writerApp, clock: issuing)
            defer { journal.close() }

            try journal.record(
                kind: .habitCreated, day: day("2026-01-01"), source: nil,
                payload: .habit(habitA, name: "Meditate")
            )
            for offset in 0..<days {
                try journal.record(
                    kind: .checkedIn, day: day("2026-01-01").adding(offset), source: .tap,
                    payload: .habit(habitA)
                )
            }

            let store = keychain()
            defer { store.delete() }
            _ = try AchievementIssuer(
                layout: layout, recorder: journal, clock: issuing, keychain: store
            ).issue()

            let calendars = StubCalendars()
            let pipeline = AnchorPipeline(
                layout: layout, calendars: calendars.calendars, clock: frozenClock(at: now)
            )
            return try await body(layout, pipeline, AwardStore(layout: layout), calendars)
        }
    }

    // MARK: All three, never the first

    /// **ADR 0004's first required mitigation, asserted.** "Submit to all three
    /// calendars, not first-success-wins. Three independent chances to upgrade,
    /// for the same zero marginal cost."
    ///
    /// The inherited `Calendars.anchor(_:)` returned the first proof and dropped
    /// the other two, which is the shape this test exists to make impossible to
    /// reintroduce quietly.
    @Test("The log head goes to all three calendars, and all three answers are kept")
    func theLogHeadGoesToEveryCalendar() async throws {
        // Inside the 72-hour window, so the only thing this pass can submit is
        // the log head — which is what makes the request list readable.
        try await sealedStore(now: "2026-02-11T09:00:00+07:00") { layout, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            _ = try await pipeline.drain()

            #expect(calendars.requests.sorted() == calendarHosts.map { "\($0)/digest" })

            let anchor = try #require(try store.latestAnchor())
            #expect(anchor.state == .submitted)
            #expect(anchor.calendars.count == 3)

            // Three promises in one artifact, which is what "three independent
            // chances" has to mean on disk.
            let proof = try OpenTimestamps.readDetached(try #require(anchor.otsProof))
            #expect(proof.digest == anchor.digest)
            #expect(proof.timestamp.pending(from: anchor.digest).count == 3)
            #expect(proof.timestamp.bitcoin(from: anchor.digest).isEmpty)

            // And what was posted is the digest itself, not a description of it.
            #expect(calendars.bodies.allSatisfy { $0 == anchor.digest })
        }
    }

    /// A calendar that is down costs one of the three chances and nothing else.
    @Test("One calendar refusing does not stop the other two")
    func oneRefusalIsNotAFailure() async throws {
        try await sealedStore(now: "2026-02-11T09:00:00+07:00") { _, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            calendars.answer(
                "\(calendarHosts[0])/digest", with: .init(status: 500, body: Data())
            )
            _ = try await pipeline.drain()

            let anchor = try #require(try store.latestAnchor())
            #expect(anchor.state == .submitted)
            #expect(anchor.calendars.count == 2)
        }
    }

    /// The digest is a commitment to where every writer's chain stands, and it is
    /// **the same value the standalone verifier recomputes** from `events.jsonl`
    /// alone. If these two ever disagreed, the bundle would carry a proof about a
    /// number nothing else in the world produces.
    @Test("The anchored digest is the digest of this log's own heads")
    func theAnchorCommitsToTheRealHeads() async throws {
        try await sealedStore(now: "2026-02-11T09:00:00+07:00") { layout, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            _ = try await pipeline.drain()

            let anchor = try #require(try store.latestAnchor())
            var heads: [String: Data] = [:]
            for (device, head) in try JournalReader(url: layout.events).read().chain.heads {
                heads[device.rawValue] = head
            }
            #expect(anchor.heads == heads)
            #expect(anchor.digest == (try LogAnchor.digest(heads: heads)))
        }
    }

    // MARK: The 72-hour window

    /// Sign immediately, publish late. An achievement detected an hour ago is
    /// sealed, shown, and **not** submitted — nothing irreversible has been
    /// published that the user might want back.
    @Test("An achievement inside the 72-hour window is not submitted")
    func theWindowHoldsSubmission() async throws {
        try await sealedStore(
            issuedAt: "2026-02-10T09:00:00+07:00", now: "2026-02-11T09:00:00+07:00"
        ) { _, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            let drained = try await pipeline.drain()

            #expect(drained.submitted.isEmpty)
            #expect(try store.readAttestations().values.allSatisfy { $0.state == .sealed })
            // Only the log head went out — and the log head has no provisional
            // window, deliberately: it is not a claim anybody would retract.
            #expect(calendars.requests.count == 3)
        }
    }

    @Test("An achievement past the window is submitted to all three")
    func theWindowReleasesSubmission() async throws {
        try await sealedStore(
            issuedAt: "2026-02-10T09:00:00+07:00", now: "2026-02-14T09:00:00+07:00"
        ) { _, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            let drained = try await pipeline.drain()

            #expect(drained.submitted.count == 2)  // the 7-day and the 30-day
            let attestations = try store.readAttestations()
            #expect(attestations.values.allSatisfy { $0.state == .submitted })
            #expect(attestations.values.allSatisfy { $0.otsProof != nil })
            // `calendar` is left unset on purpose: three calendars hold this
            // digest and the field is singular. The proof names all three.
            #expect(attestations.values.allSatisfy { $0.calendar == nil })
        }
    }

    // MARK: Nothing due

    /// **The property that makes it safe to drain on every foreground.** The
    /// launch drain runs whenever the app becomes active, so a pass with nothing
    /// to do has to cost nothing — otherwise `.claude/skills/ios.md`'s "no
    /// network call on the launch path" would be true only in the letter.
    @Test("A drain with nothing due makes no request at all")
    func nothingDueCostsNothing() async throws {
        try await sealedStore(
            issuedAt: "2026-02-10T09:00:00+07:00", now: "2026-02-11T09:00:00+07:00"
        ) { layout, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            // One pass to anchor the head, then mark it confirmed so nothing is
            // left pending. The achievements are still inside their window.
            _ = try await pipeline.drain()
            var anchor = try #require(try store.latestAnchor())
            anchor.state = .confirmed
            anchor.blockHeight = 900_000
            try store.append(anchor)

            let before = calendars.requests.count
            let drained = try await pipeline.drain()

            #expect(calendars.requests.count == before)
            #expect(drained.submitted.isEmpty)
            #expect(drained.confirmed.isEmpty)
        }
    }

    // MARK: When nobody answers

    /// **The achievement stays earned.** `docs/technical.md` §9.8: attestation
    /// failure leaves the achievement earned and pending. Anchoring is not what
    /// makes a milestone true; it is what makes its date checkable.
    @Test("Every calendar failing leaves the achievement earned, sealed and pending")
    func failureLeavesTheAchievementEarned() async throws {
        try await sealedStore(now: "2026-02-14T09:00:00+07:00") { _, pipeline, store, calendars in
            for host in calendarHosts {
                calendars.answer(
                    "\(host)/digest", with: .init(status: 503, body: Data("down".utf8))
                )
            }
            let drained = try await pipeline.drain()

            #expect(drained.submitted.isEmpty)
            // Still awarded, still signed, still renderable.
            let ledger = try store.readAwards()
            #expect(ledger.achievements.count == 2)
            #expect(ledger.revocations.isEmpty)
            for attestation in try store.readAttestations().values {
                #expect(attestation.state == .failed)
                #expect(attestation.signature.isEmpty == false)
                #expect(attestation.submittedAt != nil)
                // Nothing that could be rendered as anchoring language.
                #expect(attestation.otsProof == nil)
                #expect(attestation.confirmedAt == nil)
            }
        }
    }

    /// The append-only file **is** the retry counter — the protocol has no field
    /// for one and this build does not add fields the protocol lacks.
    @Test("A failure is counted from the file's own failed lines")
    func failuresAreCountedFromTheFile() async throws {
        try await sealedStore(now: "2026-02-14T09:00:00+07:00") { _, pipeline, store, calendars in
            for host in calendarHosts {
                calendars.answer("\(host)/digest", with: .init(status: 503))
            }
            _ = try await pipeline.drain()

            let id = try #require(try store.readAwards().achievements.first?.id)
            #expect(try store.failureCount(for: id) == 1)
        }
    }

    /// The backoff is honoured across passes: a drain a minute after a failure
    /// does not hammer a calendar that is down.
    @Test("A failed submission is not retried before its backoff has elapsed")
    func theBackoffHoldsTheRetry() async throws {
        try await withTemporaryStoreAsync { layout in
            let issuing = frozenClock(at: "2026-02-10T09:00:00+07:00")
            let journal = try EventJournal(layout: layout, writer: writerApp, clock: issuing)
            defer { journal.close() }
            try journal.record(
                kind: .habitCreated, day: day("2026-01-01"), source: nil,
                payload: .habit(habitA, name: "Meditate")
            )
            for offset in 0..<10 {
                try journal.record(
                    kind: .checkedIn, day: day("2026-01-01").adding(offset), source: .tap,
                    payload: .habit(habitA)
                )
            }
            let keys = keychain()
            defer { keys.delete() }
            _ = try AchievementIssuer(
                layout: layout, recorder: journal, clock: issuing, keychain: keys
            ).issue()

            let calendars = StubCalendars()
            for host in calendarHosts {
                calendars.answer("\(host)/digest", with: .init(status: 503))
            }

            func pipeline(at moment: String) -> AnchorPipeline {
                AnchorPipeline(
                    layout: layout, calendars: calendars.calendars, clock: frozenClock(at: moment)
                )
            }

            // First attempt, three days after detection: it fails.
            _ = try await pipeline(at: "2026-02-14T09:00:00+07:00").drain()
            let afterFirst = calendars.requests.count

            // A minute later: the backoff is one hour, so nothing is retried.
            // The log head is unchanged, so it is not re-anchored either.
            _ = try await pipeline(at: "2026-02-14T09:01:00+07:00").drain()
            #expect(calendars.requests.count == afterFirst)

            // Two hours later: it tries again.
            _ = try await pipeline(at: "2026-02-14T11:00:00+07:00").drain()
            #expect(calendars.requests.count > afterFirst)
        }
    }

    /// **A failed attempt is not a week.** The cadence is measured from the last
    /// anchor that actually reached a calendar, so an afternoon when three
    /// servers are down does not leave the log unanchored for seven more days.
    ///
    /// The failed record still exists — nothing in these files is ever deleted —
    /// it simply does not count as an anchor.
    @Test("A failed anchor does not start the weekly clock")
    func aFailedAnchorIsNotAWeek() async throws {
        try await withTemporaryStoreAsync { layout in
            let clock = frozenClock(at: "2026-02-10T09:00:00+07:00")
            let journal = try EventJournal(layout: layout, writer: writerApp, clock: clock)
            defer { journal.close() }
            try journal.record(
                kind: .habitCreated, day: day("2026-01-01"), source: nil,
                payload: .habit(habitA, name: "Meditate")
            )

            let calendars = StubCalendars()
            for host in calendarHosts {
                calendars.answer("\(host)/digest", with: .init(status: 503))
            }
            let store = AwardStore(layout: layout)

            func pipeline(at moment: String) -> AnchorPipeline {
                AnchorPipeline(
                    layout: layout, calendars: calendars.calendars, clock: frozenClock(at: moment)
                )
            }

            // The first attempt reaches nobody.
            _ = try await pipeline(at: "2026-02-10T09:00:00+07:00").drain()
            #expect(try store.readAnchors().allSatisfy { $0.state == .failed })

            // The head moves, and the calendars come back the next day. Nothing
            // has ever been anchored, so the next anchor must not wait a week.
            try journal.record(
                kind: .checkedIn, day: day("2026-01-02"), source: .tap, payload: .habit(habitA)
            )
            calendars.acceptEverySubmission()
            _ = try await pipeline(at: "2026-02-11T09:00:00+07:00").drain()

            let anchors = try store.readAnchors()
            #expect(anchors.count == 2)
            #expect(anchors.contains { $0.state == .submitted })
        }
    }

    // MARK: Confirmation

    /// **The only transition that earns the word "anchored".** A calendar
    /// answering the upgrade with a Bitcoin attestation is what moves a record
    /// from `submitted` to `confirmed`, and only `confirmed` puts a second line
    /// on the certificate.
    @Test("An upgrade that reaches a Bitcoin block confirms the record")
    func anUpgradeConfirms() async throws {
        try await sealedStore(now: "2026-02-14T09:00:00+07:00") { _, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            _ = try await pipeline.drain()
            #expect(try store.readAttestations().values.allSatisfy { $0.state == .submitted })

            // Now every calendar has the Bitcoin path. The commitment named in
            // the upgrade URL is a value derived from the proof itself, which is
            // why the script answers any `/timestamp/…` rather than one URL.
            calendars.answerEveryUpgrade(with: bitcoinResponse(height: 912_345))

            let drained = try await pipeline.drain()
            #expect(drained.confirmed.count == 2)

            for attestation in try store.readAttestations().values {
                #expect(attestation.state == .confirmed)
                #expect(attestation.blockHeight == 912_345)
                #expect(attestation.confirmedAt != nil)
                // Filled in now, and only now: this is the one moment the
                // singular field has a single answer.
                #expect(attestation.calendar != nil)
            }
        }
    }

    /// A 404 reading "Pending confirmation in Bitcoin blockchain" is where every
    /// fresh submission sits for hours. It is the ordinary case and must never
    /// become a failure state or a reason to stop asking.
    @Test("A not-yet-upgraded proof stays submitted and is asked about again")
    func pendingIsNotFailure() async throws {
        try await sealedStore(now: "2026-02-14T09:00:00+07:00") { _, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            _ = try await pipeline.drain()

            // The stub's default answer is the calendar's real 404 body.
            let drained = try await pipeline.drain()
            #expect(drained.confirmed.isEmpty)
            #expect(try store.readAttestations().values.allSatisfy { $0.state == .submitted })
            #expect(try store.latestAnchor()?.state == .submitted)
        }
    }

    /// A revoked achievement is never published. §8: revoking while provisional
    /// means nothing was ever published, so nothing needs reversing outside.
    @Test("A revoked achievement is not submitted")
    func revokedRecordsStayHome() async throws {
        try await sealedStore(now: "2026-02-14T09:00:00+07:00") { layout, pipeline, store, calendars in
            calendars.acceptEverySubmission()
            let id = try #require(try store.readAwards().achievements.map(\.id).sorted().first)
            try store.append(
                .revocation(
                    Revocation(
                        achievement: id, reason: Revocation.dependedOnDayEdited,
                        at: instant("2026-02-13T09:00:00Z"), newLogHeads: [:]
                    )
                )
            )

            let drained = try await pipeline.drain()
            #expect(!drained.submitted.contains(id))
            #expect(try store.readAttestations()[id]?.state == .sealed)
        }
    }
}
