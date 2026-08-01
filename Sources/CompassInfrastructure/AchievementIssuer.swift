import CompassDomain
import Foundation

/// The guarded step. `docs/technical.md` §5, `docs/achievement-protocol.md` §7.1.
///
/// > **An earned achievement is then recorded as a fact, not left as a
/// > derivation.** The engine computes eligibility; a separate guarded step
/// > appends `achievementAwarded` exactly once. This matters because the award
/// > gates an irreversible external side effect: if a rule is later reworded, a
/// > purely derived award would silently un-award something already anchored to
/// > Bitcoin.
///
/// That is what this type is. ``AchievementEngine`` is pure and lives in Domain;
/// everything here is the part that touches files, keys and clocks.
///
/// ### The order of the three writes, and what a crash between them costs
///
/// Per new achievement: **the record first, then the signature, then the event.**
///
/// - `awards.jsonl` is tier-1 irreplaceable (`docs/technical.md` §6) and is what
///   a certificate is rendered from. It is written first so that no crash can
///   leave an award that was announced in the log but has no record.
/// - The signature comes next, because §7.1 requires sealing to happen
///   "**immediately**, in the same pass, offline" — the signature costs nothing
///   and makes the local record tamper-evident from the first moment.
/// - The `achievementAwarded` event is last, and it is **reconciled rather than
///   guarded**: every pass appends the event for any recorded achievement that
///   does not have one yet. So a crash after the record leaves a missing event
///   that the next pass repairs, and no path can produce two events for one
///   award. "Exactly once" is then a property of the file rather than of the
///   sequencing.
///
/// Nothing here ever rewrites or deletes a line, in either file, in any state.
public struct AchievementIssuer: Sendable {

    public let layout: StoreLayout
    private let store: AwardStore
    private let rules: RuleStore
    private let keychain: KeychainStore
    private let clock: SystemClock

    /// Where `achievementAwarded` and `achievementRevoked` are appended. It is
    /// the app's journal — the widget never issues anything.
    private let recorder: any EventRecorder

    public init(
        layout: StoreLayout,
        recorder: any EventRecorder,
        clock: SystemClock = SystemClock(),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.layout = layout
        self.store = AwardStore(layout: layout)
        self.rules = RuleStore(layout: layout)
        self.keychain = keychain
        self.clock = clock
        self.recorder = recorder
    }

    // MARK: The pass

    /// Runs the engine over the whole log and records what it finds.
    public func issue() throws -> AwardBook {
        let events = try JournalReader(url: layout.events).read().events
        let ledger = try store.readAwards()
        let specs = try rules.load()
        let now = clock.now()

        let evaluation = try AchievementEngine.evaluate(
            events: events,
            rules: specs,
            detectedAt: now,
            alreadyRecorded: ledger.recordedIDs
        )

        // A rule this build has no evaluator for is skipped and its file is left
        // exactly where it is. Announced rather than swallowed: an older build
        // that quietly ignored a newer build's rules would look like a build in
        // which nothing is ever earned. `docs/achievement-protocol.md` §5.1.
        for skipped in evaluation.skipped {
            AchievementIssuer.warn("rule kind not implemented in this build: \(skipped)")
        }

        for achievement in evaluation.awarded {
            try store.append(.achievement(achievement))
            try seal(achievement)
        }

        // Every recorded achievement whose claim the log no longer supports. The
        // record is not touched; a reversal is posted beside it.
        let revocations = AchievementEngine.revocations(
            forRecorded: ledger.achievements.map(\.id),
            notIn: evaluation.earned,
            alreadyRevoked: ledger.revokedIDs,
            at: now,
            logHeads: evaluation.logHeads
        )
        for revocation in revocations {
            try store.append(.revocation(revocation))
        }

        try reconcileEvents(with: events)

        var book = try recordedBook()
        book = AwardBook(
            achievements: book.achievements,
            revoked: book.revoked,
            attestations: book.attestations,
            newlyIssued: evaluation.awarded
                .sorted { $0.earnedOn > $1.earnedOn }
                .map(\.id)
        )
        return book
    }

    /// What is already recorded, evaluating nothing.
    public func recordedBook() throws -> AwardBook {
        let ledger = try store.readAwards()
        return AwardBook(
            achievements: ledger.newestFirst,
            revoked: ledger.revokedIDs,
            attestations: try store.readAttestations()
        )
    }

    // MARK: Sealing

    /// Signs the achievement **immediately, offline**, and records the
    /// attestation as ``AnchorState/sealed``.
    ///
    /// §7.1 step 2: this happens in the same pass as the award. The certificate
    /// therefore says "Sealed on this device" from the first moment it is shown,
    /// and it keeps saying exactly that until `AnchorState` is `confirmed` —
    /// which cannot happen before week 4, and cannot happen at all until a
    /// calendar has upgraded a proof with the Bitcoin path.
    ///
    /// **The signature is over `canonicalBytes`, never over `digest`.** §6.7 —
    /// the inherited `Signer.sign(_ text:)` double-hashes and is not on this path
    /// and cannot be: it is not copied into this repository.
    private func seal(_ achievement: Achievement) throws {
        let signer = try Signer(store: keychain)
        try store.append(
            Attestation(
                achievement: achievement.id,
                publicKey: signer.publicKey,
                signature: try signer.signature(over: try achievement.canonicalBytes),
                // Recorded honestly. A simulator-made proof must never look as
                // strong as a phone-made one.
                backing: signer.backing,
                state: .sealed
            )
        )
    }

    // MARK: The log's own record of what was awarded

    /// Appends the `achievementAwarded` and `achievementRevoked` events the log
    /// is missing, and no others.
    ///
    /// The set of events already present is read from the log rather than
    /// inferred from what this pass did, which is what makes the operation
    /// idempotent across a crash at any point above.
    private func reconcileEvents(with events: [Event]) throws {
        var announced: Set<AchievementID> = []
        var reversed: Set<AchievementID> = []
        for event in events {
            guard let id = event.payload.achievementID else { continue }
            if event.kind == .achievementAwarded { announced.insert(id) }
            if event.kind == .achievementRevoked { reversed.insert(id) }
        }

        let ledger = try store.readAwards()
        let day = clock.today(cutoffHour: DayBoundary.cutoffHour)

        for achievement in ledger.achievements where !announced.contains(achievement.id) {
            // `day` is today, not `earnedOn`: an event's `day` is the civil day
            // it is **about**, and what this event is about is the award being
            // recorded, which happened now. `earnedOn` — the day the claim became
            // true — is inside the achievement, in the digest, where it belongs.
            try recorder.record(
                kind: .achievementAwarded,
                day: day,
                source: nil,
                payload: .achievement(achievement.id)
            )
            announced.insert(achievement.id)
        }

        for revocation in ledger.revocations where !reversed.contains(revocation.achievement) {
            try recorder.record(
                kind: .achievementRevoked,
                day: day,
                source: nil,
                payload: .achievement(revocation.achievement, reason: revocation.reason)
            )
            reversed.insert(revocation.achievement)
        }
    }

    /// Where a skipped rule goes. `FileHandle.standardError` rather than a
    /// logging subsystem: there is no logging subsystem in this project, and
    /// adding one for two call sites is an abstraction with a single use site.
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("compass: \(message)\n".utf8))
    }
}

// MARK: - The port

extension AchievementIssuer: Awarding {

    /// The engine is a synchronous, pure function wrapped in file I/O, and the
    /// port is `async` so that nothing on the tap path can accidentally wait for
    /// it. `docs/technical.md` §4 line 5 dispatches it into a detached `Task`.
    ///
    /// **A failure is written to stderr before it is rethrown.** The caller —
    /// `TodayModel` — surfaces it in the settings sheet, which is the half a
    /// person sees; this is the half a *future session* sees, on a device console
    /// or in a test run, and it is written here because this is where the error
    /// still has its context. Both halves are new on 2026-08-01: until then both
    /// call sites did `try? await awarding.evaluate()` and a milestone that
    /// failed to issue was indistinguishable from one that was never earned.
    ///
    /// It rethrows rather than swallowing. Deciding what a failure means is the
    /// caller's job, and there is exactly one caller.
    public func evaluate() async throws -> AwardBook {
        do {
            return try issue()
        } catch {
            AchievementIssuer.warn("the achievement pass failed: \(error)")
            throw error
        }
    }

    public func recorded() async throws -> AwardBook {
        try recordedBook()
    }
}
