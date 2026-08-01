import CompassDomain
import Foundation

/// Week 4: the digest leaves the device. `docs/adr/0004`, `docs/technical.md`
/// §10a and §11, `docs/achievement-protocol.md` §7.1.
///
/// Three jobs, in one pass, and the pass is safe to run as often as anything
/// cares to run it:
///
/// 1. **Anchor the event-log head, weekly.** ADR 0004's corollary is why this is
///    first: without it, an award the engine backfilled onto a day in the past
///    has an anchor that proves only the day it was submitted. That trigger is
///    not hypothetical — it fired on the first run of the week-3 engine.
/// 2. **Submit sealed achievements whose 72 hours are up.** Sign immediately,
///    publish late: the local record is tamper-evident from the first moment,
///    and nothing irreversible is published that the user might want back.
/// 3. **Upgrade everything still pending**, aggressively and forever. A fresh
///    submission is a promise; only a Bitcoin attestation is a proof.
///
/// **Nothing here is on the launch path and nothing on screen waits for it.**
/// `.claude/skills/ios.md` forbids a network call on the launch path outright.
/// The drain runs from the `.task` that follows the first frame and from a
/// `BGProcessingTask`, and when nothing is due it **makes no request at all** —
/// which is what makes it safe to call on every foreground.
///
/// ### Two documented shapes it had to work around, reported not designed around
///
/// - **`Attestor.attest` is declared over `AchievementClaim`**, which carries an
///   achievement ID and a digest, while `Attestation` requires `publicKey`,
///   `signature` and `backing` — values the calendars know nothing about and
///   only the signer can produce. So the attestor **reads the sealed record it
///   is anchoring** and returns it with the anchor added. That is the honest
///   reading of the lifecycle in §7.1, where `sealed` strictly precedes
///   `submitted`; it is not a new field and not a new port.
/// - **`Attestation.calendar` is singular** while ADR 0004 requires submitting
///   to all three. It is left `nil` at submission — there is no single calendar
///   to name, and the proof itself carries every one of them — and it is filled
///   in on confirmation with the calendar whose branch actually delivered the
///   Bitcoin path, which is the only moment the question has one answer.
///   ``LogAnchor``, which no document freezes, has `calendars` plural.
public struct AnchorPipeline: Sendable {

    public let layout: StoreLayout
    private let store: AwardStore
    private let calendars: Calendars
    private let clock: SystemClock

    public init(
        layout: StoreLayout,
        calendars: Calendars = Calendars(),
        clock: SystemClock = SystemClock()
    ) {
        self.layout = layout
        self.store = AwardStore(layout: layout)
        self.calendars = calendars
        self.clock = clock
    }

    // MARK: The pass

    public func run() async throws -> AnchorDrain {
        let now = clock.now()
        var confirmed: [AchievementID] = []
        var submitted: [AchievementID] = []

        // **Upgrading comes first**, and the order is not arbitrary: a proof
        // submitted seconds ago cannot possibly be in a block, so asking about
        // it in the same pass that created it is a guaranteed-wasted round trip
        // to somebody else's server, three times over.
        try await upgradeAll(now: now, confirmed: &confirmed)
        let anchor = try await anchorLogHead(now: now)
        try await submitDue(now: now, submitted: &submitted)

        return AnchorDrain(
            attestations: try store.readAttestations(),
            submitted: submitted,
            confirmed: confirmed,
            logAnchor: try store.latestAnchor() ?? anchor
        )
    }

    // MARK: 1 — the weekly log-head anchor

    /// Commits where every writer's chain stands, if a week is up and anything
    /// has changed. ``LogAnchorSchedule`` holds both halves of that condition and
    /// says why re-anchoring unchanged heads is worse than doing nothing.
    private func anchorLogHead(now: Date) async throws -> LogAnchor? {
        var heads: [String: Data] = [:]
        for (device, head) in try JournalReader(url: layout.events).read().chain.heads {
            heads[device.rawValue] = head
        }

        // An anchor already exists for exactly these heads, so the cadence
        // question does not arise: either it went out and there is nothing to
        // add, or it failed and the backoff decides. ``LogAnchorSchedule``
        // governs the *other* case — heads that have moved since the last
        // successful anchor.
        if let existing = try store.readAnchors().last(where: { $0.heads == heads }) {
            guard existing.state == .failed else { return nil }
            guard AnchorRetry.mayRetry(
                firstAttemptAt: existing.submittedAt ?? existing.createdAt,
                failures: try store.failureCount(forAnchor: existing.digest),
                now: now
            ) else { return nil }
        } else {
            // **The cadence is measured from the last anchor that actually went
            // out**, never from a failed attempt. A first attempt that reached no
            // calendar has anchored nothing, and treating it as the week's anchor
            // would leave the log unanchored for seven more days because of an
            // afternoon when three servers were down. The failed record still
            // exists — nothing in these files is ever deleted — it simply does
            // not count as a week.
            let succeeded = try store.readAnchors()
                .filter { $0.state != .failed }
                .max { $0.createdAt < $1.createdAt }
            guard LogAnchorSchedule.isDue(heads: heads, since: succeeded, now: now)
            else { return nil }
        }

        let digest = try LogAnchor.digest(heads: heads)
        let responses = await calendars.submit(digest)
        let accepted = responses.filter(\.succeeded)

        guard !accepted.isEmpty else {
            // Every calendar refused. The heads are unchanged and still
            // un-anchored, so the next drain tries again — after the backoff,
            // which is measured from the first attempt and counted out of this
            // file's own failed lines.
            let previous = try store.readAnchors().last { $0.digest == digest }
            try store.append(
                LogAnchor(
                    heads: heads,
                    digest: digest,
                    createdAt: previous?.createdAt ?? now,
                    state: .failed,
                    otsProof: previous?.otsProof,
                    calendars: previous?.calendars ?? [],
                    submittedAt: previous?.submittedAt ?? now
                )
            )
            AnchorPipeline.warn(
                "log head not anchored: \(responses.compactMap(\.failure).joined(separator: "; "))"
            )
            return nil
        }

        var merged = OTSTimestamp()
        for response in accepted {
            if let timestamp = response.timestamp { merged.merge(timestamp) }
        }

        let anchor = LogAnchor(
            heads: heads,
            digest: digest,
            createdAt: now,
            state: .submitted,
            otsProof: try OpenTimestamps.writeDetached(digest: digest, timestamp: merged),
            calendars: accepted.map(\.calendar),
            submittedAt: now
        )
        try store.append(anchor)
        return anchor
    }

    // MARK: 2 — submitting what the window has released

    /// Every sealed, unrevoked achievement whose 72 hours are up.
    ///
    /// The window is `AnchorSchedule`, in Domain, deliberately: a gate that lives
    /// only inside the code that wants to skip it is not a gate.
    private func submitDue(now: Date, submitted: inout [AchievementID]) async throws {
        let ledger = try store.readAwards()
        let attestations = try store.readAttestations()

        for achievement in ledger.achievements.sorted(by: { $0.id < $1.id }) {
            guard !ledger.isRevoked(achievement.id) else { continue }
            guard let attestation = attestations[achievement.id] else { continue }
            guard attestation.state == .sealed || attestation.state == .failed else { continue }
            guard AnchorSchedule.maySubmit(detectedAt: achievement.detectedAt, now: now) else {
                continue
            }
            if attestation.state == .failed {
                let failures = try store.failureCount(for: achievement.id)
                guard let first = attestation.submittedAt,
                      AnchorRetry.mayRetry(firstAttemptAt: first, failures: failures, now: now)
                else { continue }
            }

            let digest = try achievement.digest
            let responses = await calendars.submit(digest)
            let accepted = responses.filter(\.succeeded)

            guard !accepted.isEmpty else {
                // **The achievement stays earned.** Anchoring failing is not a
                // reason to un-award anything, and it is invisible on the main
                // screen by design — the certificate is the only surface that
                // ever says a word about it, and only after 30 days.
                var failed = attestation
                failed.state = .failed
                failed.submittedAt = attestation.submittedAt ?? now
                try store.append(failed)
                AnchorPipeline.warn(
                    "\(achievement.id.rawValue) not submitted: "
                        + responses.compactMap(\.failure).joined(separator: "; ")
                )
                continue
            }

            var merged = OTSTimestamp()
            if let existing = attestation.otsProof,
               let previous = try? OpenTimestamps.readDetached(existing),
               previous.digest == digest {
                merged.merge(previous.timestamp)
            }
            for response in accepted {
                if let timestamp = response.timestamp { merged.merge(timestamp) }
            }

            var anchored = attestation
            anchored.state = .submitted
            anchored.otsProof = try OpenTimestamps.writeDetached(digest: digest, timestamp: merged)
            anchored.submittedAt = now
            // Deliberately not set — see the type's documentation. Three
            // calendars have this digest and the proof names all three.
            anchored.calendar = nil
            try store.append(anchored)
            submitted.append(achievement.id)
        }
    }

    // MARK: 3 — upgrading

    /// Asks every calendar a pending branch is waiting on for the rest of the
    /// path, and records `confirmed` the moment a Bitcoin attestation lands.
    ///
    /// **Only a Bitcoin attestation confirms.** `submitted` means bytes were
    /// sent, and `.claude/skills/ui.md` forbids rendering anchoring language
    /// before `confirmed` for exactly that reason.
    ///
    /// One request per pending branch, so the cost of a pass is the number of
    /// *unconfirmed* proofs times the number of calendars holding each. That is
    /// bounded by roughly a dozen awards a year plus one weekly head, and each
    /// stays unconfirmed for hours rather than months — so the worst realistic
    /// pass is a few dozen requests, and the steady state is zero.
    private func upgradeAll(now: Date, confirmed: inout [AchievementID]) async throws {
        for anchor in try store.readAnchors() where anchor.state == .submitted {
            guard let proof = anchor.otsProof else { continue }
            guard let upgraded = try await upgrade(proof: proof, digest: anchor.digest) else {
                continue
            }
            var updated = anchor
            updated.otsProof = upgraded.proof
            if let bitcoin = upgraded.bitcoin {
                updated.state = .confirmed
                updated.confirmedAt = now
                updated.blockHeight = bitcoin.height
            }
            try store.append(updated)
        }

        for (id, attestation) in try store.readAttestations().sorted(by: { $0.key < $1.key })
        where attestation.state == .submitted {
            guard let proof = attestation.otsProof, !proof.isEmpty,
                  let digest = try? OpenTimestamps.readDetached(proof).digest,
                  let upgraded = try await upgrade(proof: proof, digest: digest)
            else { continue }
            var updated = attestation
            updated.otsProof = upgraded.proof
            if let bitcoin = upgraded.bitcoin {
                updated.state = .confirmed
                updated.confirmedAt = now
                updated.blockHeight = bitcoin.height
                updated.calendar = bitcoin.calendar
                confirmed.append(id)
            }
            try store.append(updated)
        }
    }

    private struct Upgraded {
        let proof: Data
        let bitcoin: (height: Int, calendar: URL?)?
    }

    /// Returns the merged proof only when something actually arrived, so a drain
    /// that learns nothing appends nothing.
    private func upgrade(proof: Data, digest: Data) async throws -> Upgraded? {
        var timestamp = try OpenTimestamps.readDetached(proof).timestamp
        var changed = false
        var delivering: URL?

        for (uri, commitment) in timestamp.pending(from: digest) {
            guard let calendar = URL(string: uri) else { continue }
            let response = await calendars.upgrade(commitment: commitment, from: calendar)
            guard let fetched = response.timestamp else {
                // A 404 here reads "Pending confirmation in Bitcoin blockchain",
                // which is where every fresh submission sits for hours. It is
                // the ordinary case and never a failure state.
                continue
            }
            let before = timestamp.bitcoin(from: digest).count
            // `changed` follows the graft rather than the request. A calendar
            // that answered with something this proof has no place for has
            // taught us nothing, and appending an identical line to say so would
            // put a state change in an append-only file where no state changed.
            guard timestamp.graft(fetched, at: commitment, from: digest) else { continue }
            changed = true
            if timestamp.bitcoin(from: digest).count > before, delivering == nil {
                delivering = calendar
            }
        }

        guard changed else { return nil }
        let attestations = timestamp.bitcoin(from: digest)
        return Upgraded(
            proof: try OpenTimestamps.writeDetached(digest: digest, timestamp: timestamp),
            bitcoin: attestations.min { $0.height < $1.height }
                .map { (height: $0.height, calendar: delivering) }
        )
    }

    /// Where a calendar failure goes. Standard error, like the skipped-rule
    /// warning beside it: there is no logging subsystem in this project and
    /// `.claude/skills/ui.md` forbids anchoring failure from reaching the screen.
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("compass: \(message)\n".utf8))
    }
}

// MARK: - The port

extension AnchorPipeline: Anchoring {
    public func drain() async throws -> AnchorDrain {
        try await run()
    }
}

// MARK: - The `Attestor` port

/// `OpenTimestampsAttestor` behind the `Attestor` port — the anti-rewrite hinge
/// in `docs/technical.md` §2. `SoulboundAttestor` arrives later behind this
/// identical protocol, an achievement holds a list of attestations, and nothing
/// migrates.
///
/// It submits **one** claim, to all three calendars, and returns the sealed
/// record with the anchor added. `AnchorPipeline` is what decides *which* claims
/// are due and when; this is what a claim being attested means.
public struct OpenTimestampsAttestor: Attestor {

    public let layout: StoreLayout
    private let store: AwardStore
    private let calendars: Calendars
    private let clock: SystemClock

    public init(
        layout: StoreLayout,
        calendars: Calendars = Calendars(),
        clock: SystemClock = SystemClock()
    ) {
        self.layout = layout
        self.store = AwardStore(layout: layout)
        self.calendars = calendars
        self.clock = clock
    }

    public func attest(_ claim: AchievementClaim) async throws -> Attestation {
        guard let sealed = try store.readAttestations()[claim.achievement] else {
            // §7.1 makes `sealed` strictly precede `submitted`: signing happens
            // immediately, in the same pass as the award, offline. There is
            // nothing here to attest before that has happened.
            throw AttestationError.notSealed(claim.achievement)
        }

        let responses = await calendars.submit(claim.digest)
        let accepted = responses.filter(\.succeeded)
        guard !accepted.isEmpty else {
            throw AttestationError.allCalendarsFailed(
                responses.compactMap(\.failure).joined(separator: "; ")
            )
        }

        var merged = OTSTimestamp()
        for response in accepted {
            if let timestamp = response.timestamp { merged.merge(timestamp) }
        }

        var anchored = sealed
        anchored.state = .submitted
        anchored.otsProof = try OpenTimestamps.writeDetached(
            digest: claim.digest, timestamp: merged
        )
        anchored.submittedAt = clock.now()
        return anchored
    }
}

public enum AttestationError: Error, Hashable, Sendable {
    /// Nothing has signed this achievement yet, so there is nothing to anchor.
    case notSealed(AchievementID)
    /// All three refused. The achievement stays earned and pending, and the
    /// certificate says nothing about anchoring.
    case allCalendarsFailed(String)
}
