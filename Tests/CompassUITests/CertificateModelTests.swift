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

    /// Nothing on the launch path waits for the engine, and a failed pass says
    /// nothing anywhere: it is idempotent and re-runnable, so the next launch
    /// finds whatever this one missed. There is no achievement-failure surface
    /// in this product and there must not be one.
    @Test("A failing engine leaves the screen usable and says nothing")
    func aFailedPassIsSilent() async throws {
        let engine = FakeAwarding(fails: true)
        let model = model(awarding: engine)

        await model.reconcile()

        #expect(model.presented == nil)
        #expect(model.certificates.isEmpty)
        // The screen still works.
        #expect(model.habits.count == 4)
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
