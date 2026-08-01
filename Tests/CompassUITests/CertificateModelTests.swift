import CompassDomain
import Foundation
import Testing

@testable import CompassUI

/// When the certificate appears, when it does not, and what it is built from.
/// `.claude/skills/ui.md`, `docs/technical.md` §4 line 5.
@MainActor
@Suite("The certificate, and when it is raised")
struct CertificateModelTests {

    private func model(
        events: [Event] = seededFour(),
        awarding: FakeAwarding
    ) -> TodayModel {
        TodayModel(
            events: events,
            clock: ScriptedClock("2026-03-14T09:00:00+07:00"),
            recorder: FakeRecorder(continuing: events),
            source: FakeSource(events: events),
            awarding: awarding
        )
    }

    private func book(_ achievements: [Achievement], newlyIssued: [AchievementID] = []) -> AwardBook
    {
        AwardBook(achievements: achievements, newlyIssued: newlyIssued)
    }

    // MARK: Raising it

    /// Line 5. A milestone falls out of the log while the app is open, and the
    /// card comes up on its own — the one time it ever does.
    @Test("A pass that issues something raises the certificate")
    func aMilestoneRaisesTheCard() async throws {
        let issued = award()
        let engine = FakeAwarding(book: book([issued], newlyIssued: [issued.id]))
        let model = model(awarding: engine)

        await model.reconcile()

        #expect(model.presented == issued.id)
        #expect(model.certificates.map(\.id) == [issued.id])
    }

    /// **"The card is not re-shown unprompted."** A pass that issues nothing —
    /// which is every pass but the one — leaves the screen alone.
    @Test("A pass that issues nothing leaves the screen alone")
    func anEmptyPassRaisesNothing() async throws {
        let recorded = award()
        let engine = FakeAwarding(book: book([recorded]))
        let model = model(awarding: engine)

        await model.reconcile()

        #expect(model.presented == nil)
        // And the record is still in the list, which is where it stays reachable.
        #expect(model.certificates.map(\.id) == [recorded.id])
    }

    /// Dismissing clears it, and the next pass does not bring it back — the
    /// engine issues nothing the second time, because the award is already
    /// recorded.
    @Test("A dismissed certificate is not raised again by the next pass")
    func dismissalSticks() async throws {
        let issued = award()
        let engine = FakeAwarding(book: book([issued], newlyIssued: [issued.id]))
        let model = model(awarding: engine)

        await model.reconcile()
        #expect(model.presented == issued.id)

        model.presented = nil
        engine.issue(book([issued]))
        await model.reconcile()

        #expect(model.presented == nil)
    }

    /// **A first run over accumulated history issues several at once** — the
    /// 7-day and the 30-day land in the same pass — and three stacked full-screen
    /// covers would be a takeover celebration, which is banned. The newest comes
    /// up; the rest are in the list.
    @Test("A backfilling first run raises one card, not a stack of them")
    func onlyTheNewestIsRaised() async throws {
        let older = award("streak.habit-a.7", threshold: 7, earnedOn: "2026-01-07")
        let newer = award("streak.habit-a.30", threshold: 30, earnedOn: "2026-01-30")
        let engine = FakeAwarding(
            book: book([newer, older], newlyIssued: [newer.id, older.id])
        )
        let model = model(awarding: engine)

        await model.reconcile()

        #expect(model.presented == newer.id)
        #expect(model.certificates.count == 2)
    }

    /// Nothing on the launch path waits for the engine, and a failed pass raises
    /// nothing: no card, no alert, nothing on Today.
    ///
    /// **This comment used to end "there is no achievement-failure surface in
    /// this product and there must not be one", and the second half was wrong.**
    /// `.claude/skills/ui.md` bans it *on Today*, which is right — the engine is
    /// invisible and a status area on that screen would break the one thing the
    /// product is. It does not ban saying so anywhere, and it draws exactly that
    /// distinction for anchoring: "invisible on the main screen does not mean
    /// unsayable anywhere". A milestone that failed to issue and left no trace is
    /// indistinguishable from one that was never earned, and the second is a fact
    /// about the user's life while the first is a bug.
    /// See ``CompassUI/TodayModel/awardFailure``.
    @Test("A failing engine leaves the screen usable and raises nothing")
    func aFailedPassRaisesNothing() async throws {
        let engine = FakeAwarding(fails: true)
        let model = model(awarding: engine)

        await model.reconcile()

        #expect(model.presented == nil)
        #expect(model.certificates.isEmpty)
        // The screen still works, and nothing it renders moved.
        #expect(model.habits.count == 4)
        #expect(model.caption == TodayCaption.text(totalDays: 0, firstDay: nil))
    }

    // MARK: A failed pass is remembered — not on Today, and not nowhere

    /// **The bug this replaced.** Both call sites read
    /// `if let issued = try? await awarding.evaluate()`, so every failure was
    /// discarded at the point it happened — no state, no file, no log line. A
    /// milestone that could not be issued was, from every angle available to a
    /// person or to a future session, a milestone that was never earned.
    @Test("A failed pass is remembered, with the reason")
    func aFailedPassIsRemembered() async throws {
        let model = model(awarding: FakeAwarding(fails: true))

        await model.reconcile()

        let failure = try #require(model.awardFailure)
        // The reason travels: there is nobody to file a report with, and a
        // recorded failure with no cause in it costs a future session the
        // diagnosis. What travels is the error's *identity* — for an error this
        // project defines, the bridged domain is its qualified type name.
        #expect(failure.reason.contains("Failure"))
    }

    /// **No raw error text reaches the UI**, and the error that proves it is the
    /// one a real failure produces.
    ///
    /// `awardFailure` was `"\(error)"` until 2026-08-01. Driven on the simulator
    /// with an unreadable `awards.jsonl`, the Records footer rendered the whole
    /// `NSCocoaErrorDomain Code=257` sentence — the host's absolute path, the
    /// CoreSimulator device UUID and the App Group UUID — and it overflowed off
    /// the bottom of the sheet.
    ///
    /// `CanonicalEncodingError` is deliberately payload-minimal, and its comment
    /// says why: an error message is somewhere user data can travel. That
    /// discipline binds only the errors this project writes, and **every
    /// Foundation error that can reach this catch carries a path** — which is why
    /// the fixture here is a real `NSError` with a real `NSFilePathErrorKey` and
    /// not `FakeAwarding.Failure`, whose emptiness would let the old line pass.
    @Test("A failure never carries the error's own text into the UI")
    func aFailureNeverCarriesTheErrorsOwnText() async throws {
        let unreadable = cocoaReadFailure()
        // **The fixture is load-bearing.** If this ever stops holding, the error
        // has stopped carrying what this test exists to keep off screen, and
        // every assertion below would pass on the unfixed line too.
        #expect("\(unreadable)".contains(unreadableAwardsPath))

        let model = model(awarding: FakeAwarding(failingWith: unreadable))
        await model.reconcile()

        let failure = try #require(model.awardFailure)
        let onScreen = SettingsCopy.awardFailed(reason: failure.reason)

        // Nothing from the filesystem, and nothing from the message.
        #expect(!onScreen.contains(unreadableAwardsPath))
        #expect(!onScreen.contains("/Users/"))
        #expect(!onScreen.contains("4D361587"))
        #expect(!onScreen.contains("64541B32"))
        #expect(!onScreen.contains("permission to view"))
        #expect(!onScreen.contains("UserInfo"))

        // What does survive is the diagnosis, and it is bounded — this footer
        // sits under a list in a sheet, and the raw version ran off the bottom.
        #expect(failure.reason == "NSCocoaErrorDomain 257")
        #expect(failure.reason.count < 64)
    }

    /// The tap path carried the identical line and therefore the identical bug.
    /// It is asserted separately because they are two call sites, and because §4
    /// line 5 dispatches rather than awaits — a fix applied to the launch path
    /// alone would leave the more frequent one silent.
    @Test("A pass that fails on the tap path is remembered too")
    func aFailedTapPassIsRemembered() async throws {
        let engine = FakeAwarding(fails: true)
        let model = model(awarding: engine)

        model.toggle(model.habits[0])
        // Wait for the pass to have *run*, then give its continuation a bounded
        // number of turns to land. Spinning on `awardFailure` itself would be
        // spinning on the thing under test: the first version of this test did
        // exactly that and hung the whole suite when the fix was mutated out,
        // which is a worse failure than a red assertion.
        while engine.passes == 0 { await Task.yield() }
        for _ in 0..<100 where model.awardFailure == nil { await Task.yield() }

        #expect(model.awardFailure != nil)
        #expect(model.presented == nil)
    }

    /// **Cleared by the next pass that works**, which is what keeps it honest
    /// rather than alarming — and what makes not persisting it defensible. The
    /// engine is idempotent and re-runnable, so a transient failure resolves
    /// itself on the next tap or launch, and one whose cause is still there fails
    /// again and says so again.
    @Test("A later successful pass clears the failure")
    func aSuccessfulPassClearsIt() async throws {
        let issued = award()
        let engine = FakeAwarding(fails: true)
        let model = model(awarding: engine)

        await model.reconcile()
        #expect(model.awardFailure != nil)

        engine.succeed(with: book([issued], newlyIssued: [issued.id]))
        await model.reconcile()

        #expect(model.awardFailure == nil)
        #expect(model.certificates.map(\.id) == [issued.id])
    }

    /// Nothing failed, so nothing is said. A sheet carrying a standing sentence
    /// about the engine would be a status area with extra steps.
    @Test("A pass that works says nothing about failing")
    func aWorkingPassSaysNothing() async throws {
        let model = model(awarding: FakeAwarding(book: book([award()])))
        await model.reconcile()
        #expect(model.awardFailure == nil)
    }

    /// A model with no engine has nothing to report either. The unopenable-store
    /// launch already says what it has to say through
    /// ``CompassUI/TodayModel/isStoreAvailable``, and a second sentence about a
    /// pass that was never attempted would be noise.
    @Test("No engine is not a failed pass")
    func noEngineIsNotAFailure() async throws {
        let events = seededFour()
        let model = TodayModel(
            events: events,
            clock: ScriptedClock("2026-03-14T09:00:00+07:00"),
            recorder: FakeRecorder(continuing: events),
            source: FakeSource(events: events)
        )

        await model.reconcile()
        model.toggle(model.habits[0])

        #expect(model.awardFailure == nil)
    }

    /// A model with no engine at all — the unopenable-store launch — behaves
    /// exactly as it did before week 3.
    @Test("A model with no engine still renders and still records")
    func noEngineIsNotAnError() async throws {
        let events = seededFour()
        let recorder = FakeRecorder(continuing: events)
        let model = TodayModel(
            events: events,
            clock: ScriptedClock("2026-03-14T09:00:00+07:00"),
            recorder: recorder,
            source: FakeSource(events: events)
        )

        await model.reconcile()
        model.toggle(model.habits[0])

        #expect(model.presented == nil)
        #expect(recorder.recorded.count == 1)
    }

    /// §4 line 5 runs on the tap path, dispatched and never awaited.
    @Test("A tap dispatches a pass")
    func aTapRunsTheEngine() async throws {
        let engine = FakeAwarding()
        let model = model(awarding: engine)

        model.toggle(model.habits[0])

        // The `Task` is dispatched, not awaited — so the assertion is that it
        // eventually runs, which is exactly the contract: the tap does not wait.
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.passes >= 1)
    }

    // MARK: What it is built from

    /// The habit's display name is resolved from the live fold at render time —
    /// the same mapping written into the export bundle as `habits.json`, and the
    /// reason no display name is ever inside the digest.
    @Test("The certificate resolves the habit's current name, not a frozen one")
    func nameIsResolvedAtRenderTime() async throws {
        let events = seededFour()
        let issued = award(habit: HabitID(rawValue: "habit-0"))
        let engine = FakeAwarding(book: book([issued], newlyIssued: [issued.id]))
        let model = model(events: events, awarding: engine)

        await model.reconcile()
        let before = try #require(model.certificate(issued.id))
        #expect(before.copy.claimLines[1] == "Move.")

        model.rename(model.habits[0], to: "Walk")
        let after = try #require(model.certificate(issued.id))
        #expect(after.copy.claimLines[1] == "Walk.")
        // And the identifier block is untouched, because it names no habit.
        #expect(before.copy.identifierLines == after.copy.identifierLines)
    }

    /// The seal is struck from this record's evidence root and no other's.
    @Test("The presentation carries this record's evidence root")
    func theSealIsPerRecord() async throws {
        let first = award("streak.habit-a.7", threshold: 7, evidenceRoot: 0x11)
        let second = award("streak.habit-a.30", threshold: 30, evidenceRoot: 0x22)
        let engine = FakeAwarding(book: book([second, first]))
        let model = model(awarding: engine)

        await model.reconcile()

        #expect(model.certificate(first.id)?.evidenceRoot == Data(repeating: 0x11, count: 32))
        #expect(model.certificate(second.id)?.evidenceRoot == Data(repeating: 0x22, count: 32))
    }

    /// The digest printed on the certificate is **the exact value the week-4
    /// verifier consumes** — `SHA-256(canonicalBytes)`, §6.6 — and not a
    /// recomputation of anything else.
    @Test("The printed digest is the digest of the record's canonical bytes")
    func thePrintedDigestIsTheRealOne() async throws {
        let issued = award()
        let engine = FakeAwarding(book: book([issued]))
        let model = model(awarding: engine)
        await model.reconcile()

        let presentation = try #require(model.certificate(issued.id))
        let expected = try issued.digest.map { String(format: "%02x", $0) }.joined()
        let printed = presentation.copy.identifierLines[1].dropFirst(8)
            + presentation.copy.identifierLines[2].trimmingCharacters(in: .whitespaces)
        #expect(String(printed) == expected)
    }

    @Test("Asking for a certificate that is not on record gives nothing")
    func anUnknownIdentifierHasNoCertificate() async throws {
        let model = model(awarding: FakeAwarding())
        await model.reconcile()
        #expect(model.certificate(AchievementID(rawValue: "nothing@2026-01-01")) == nil)
    }

    // MARK: The list

    /// A revoked entry **keeps its place** in the list. You never erase a
    /// published entry; you post a reversal.
    @Test("A revoked record stays in the list and is marked as revoked")
    func revokedRecordsKeepTheirPlace() async throws {
        let first = award("streak.habit-a.7", threshold: 7, earnedOn: "2026-01-07")
        let second = award("streak.habit-a.30", threshold: 30, earnedOn: "2026-01-30")
        let engine = FakeAwarding(
            book: AwardBook(achievements: [second, first], revoked: [first.id])
        )
        let model = model(awarding: engine)

        await model.reconcile()

        #expect(model.certificates.map(\.id) == [second.id, first.id])
        #expect(model.book.isRevoked(first.id))
        #expect(!model.book.isRevoked(second.id))
        // And it is still openable: the reversal is a fact about the record, not
        // a reason to hide it.
        #expect(model.certificate(first.id) != nil)
    }
}
