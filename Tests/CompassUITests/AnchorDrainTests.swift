import CompassDomain
import CompassUI
import Foundation
import Testing

/// The launch drain, and the one thing week 4 changes on screen.
/// `.claude/skills/ios.md`, `docs/achievement-protocol.md` §7.1,
/// `docs/technical.md` §9.8.
///
/// > Anchoring retries with exponential backoff via `BGProcessingTask` **and**
/// > drains the pending queue opportunistically on launch. Both.
///
/// Three files in this corpus once specified two incompatible behaviours here.
/// The resolution was both, for a reason this suite is the second half of:
/// `BGProcessingTask` carries no execution guarantee, `.claude/skills/ui.md`
/// forbids anchoring failure from reaching the main screen, and so a scheduler
/// path chosen alone could fail undetectably by design. **The launch drain is
/// also the only one of the two that is observable in a test**, which is why it
/// is awaited inside `reconcile()` rather than dispatched into a detached `Task`
/// nobody can wait for.
@MainActor
struct AnchorDrainTests {

    private func model(
        awarding: FakeAwarding?, anchoring: FakeAnchoring?
    ) -> TodayModel {
        TodayModel(
            events: [],
            clock: ScriptedClock("2026-03-14T12:00:00+07:00"),
            recorder: FakeRecorder(),
            source: FakeSource(),
            awarding: awarding,
            anchoring: anchoring
        )
    }

    // MARK: It runs

    @Test("The replay that follows the first frame also drains the anchoring queue")
    func reconcileDrains() async {
        let anchoring = FakeAnchoring()
        await model(awarding: nil, anchoring: anchoring).reconcile()
        #expect(anchoring.drains == 1)
    }

    /// It is safe on every foreground, which is what makes "drain on launch"
    /// implementable at all — `TodayView` reconciles whenever the app becomes
    /// active, not once per view lifetime. The cost of a pass with nothing due is
    /// zero requests; that half is asserted in `AnchoringTests`.
    @Test("Becoming active again drains again")
    func everyReconcileDrains() async {
        let anchoring = FakeAnchoring()
        let model = model(awarding: nil, anchoring: anchoring)
        await model.reconcile()
        await model.reconcile()
        #expect(anchoring.drains == 2)
    }

    /// A failed drain is silent. There is no anchoring-failure surface anywhere
    /// by design, and the pass is idempotent, so the next foreground picks up
    /// whatever this one missed.
    @Test("A drain that throws changes nothing on screen")
    func aFailedDrainIsSilent() async {
        let record = award()
        let awarding = FakeAwarding(
            book: AwardBook(
                achievements: [record],
                attestations: [record.id: attestation(for: record.id, state: .sealed)]
            )
        )
        let model = model(awarding: awarding, anchoring: FakeAnchoring(fails: true))
        await model.reconcile()

        #expect(model.certificates.count == 1)
        #expect(
            model.certificate(record.id)?.copy.attestationLines == ["Sealed on this device"]
        )
    }

    /// The tap path does **not** drain. `.claude/skills/ios.md`: no `await`
    /// between the tap and the pixel, and no network call anywhere near it. A
    /// milestone is evaluated on a tap; an anchor is not.
    @Test("A tap never touches the network")
    func theTapPathDoesNotDrain() throws {
        let anchoring = FakeAnchoring()
        let model = TodayModel(
            events: [created(habitA, name: "Move", lamport: 1)],
            clock: ScriptedClock("2026-03-14T12:00:00+07:00"),
            recorder: FakeRecorder(),
            source: FakeSource(),
            awarding: FakeAwarding(),
            anchoring: anchoring
        )
        model.toggle(try #require(model.habits.first))
        #expect(anchoring.drains == 0)
    }

    // MARK: The one line

    /// **The whole of week 4's visible change.** A record is sealed and says so;
    /// a calendar confirms it while the app is open; the certificate gains one
    /// line of text and nothing else moves.
    @Test("A confirmation reaching the drain gives the certificate its anchored line")
    func aConfirmationReachesTheCertificate() async {
        let record = award()
        let awarding = FakeAwarding(
            book: AwardBook(
                achievements: [record],
                attestations: [record.id: attestation(for: record.id, state: .submitted)]
            )
        )
        let anchoring = FakeAnchoring()
        let model = model(awarding: awarding, anchoring: anchoring)

        await model.reconcile()
        // `submitted` only means bytes were sent. It renders nothing.
        #expect(
            model.certificate(record.id)?.copy.attestationLines == ["Sealed on this device"]
        )

        anchoring.confirm([
            record.id: attestation(
                for: record.id, state: .confirmed, confirmedAt: "2026-03-17T04:00:00Z"
            )
        ])
        await model.reconcile()

        #expect(
            model.certificate(record.id)?.copy.attestationLines
                == ["Sealed on this device · Anchored 17 March 2026"]
        )
    }

    /// And nothing else does. The drain reports attestations; it never awards,
    /// revokes, or re-presents anything. A pass that could raise the card would
    /// be a certificate appearing because a third-party server answered a
    /// request, which is not a milestone.
    @Test("A drain never changes which achievements exist, and never raises the card")
    func theDrainOnlyEverChangesAnchorState() async {
        let record = award()
        let awarding = FakeAwarding(
            book: AwardBook(
                achievements: [record],
                revoked: [],
                attestations: [record.id: attestation(for: record.id, state: .submitted)]
            )
        )
        let anchoring = FakeAnchoring()
        let model = model(awarding: awarding, anchoring: anchoring)
        await model.reconcile()
        model.presented = nil

        anchoring.confirm([
            record.id: attestation(
                for: record.id, state: .confirmed, confirmedAt: "2026-03-17T04:00:00Z"
            ),
            AchievementID(rawValue: "streak.habit-z.7@2026-01-01"): attestation(
                for: AchievementID(rawValue: "streak.habit-z.7@2026-01-01"), state: .confirmed
            ),
        ])
        await model.reconcile()

        #expect(model.certificates.map(\.id) == [record.id])
        #expect(model.presented == nil)
    }
}
