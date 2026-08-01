import Foundation

// The two types the ``Attestor`` port in `Ports.swift` is declared over.
//
// They live here now only because `docs/technical.md` §2 declares the port in
// terms of them, and a protocol cannot be declared over names that do not
// exist. The achievement engine that produces claims, and the attestor that
// consumes them, are week 3 and week 4 work per §11 build order — nothing here
// is implemented, wired, or read by Domain.
//
// `Attestation` is transcribed from `docs/achievement-protocol.md` §7, which
// specifies it field for field. `AchievementClaim` is named in
// `docs/technical.md` §2 and is defined nowhere in the corpus; per
// `PROJECT_CONSTITUTION.md` §9 that gap is reported rather than designed
// around. It carries the two quantities the corpus does pin down: which
// achievement (`Attestation.achievement`, §7) and the digest that is submitted
// to a calendar (§6.6, §7.1 step 3).

/// What is handed to an ``Attestor``.
public struct AchievementClaim: Hashable, Sendable {
    public let achievement: AchievementID
    /// `SHA-256(canonicalBytes)`. `docs/achievement-protocol.md` §6.6.
    public let digest: Data

    public init(achievement: AchievementID, digest: Data) {
        self.achievement = achievement
        self.digest = digest
    }
}

/// Mutable, and therefore stored in its own file — `attestations.jsonl`,
/// last-write-wins per achievement ID. Separating mutable from immutable is
/// what allows `awards.jsonl` to be strictly append-only.
/// `docs/achievement-protocol.md` §7.
public struct Attestation: Codable, Sendable, Hashable {
    public let achievement: AchievementID
    public let publicKey: Data
    /// P-256 over `canonicalBytes`, never over `digest`. §6.7.
    public let signature: Data
    /// What backed the key that signed, recorded honestly. §7.
    ///
    /// It is **not** a statement about what kind of machine ran the app: the iOS
    /// Simulator on a T2 or Apple Silicon Mac signs with a real enclave key and
    /// truthfully records `secureEnclave`. §7.0 bis, measured 2026-08-01.
    ///
    /// It is also **outside the digest**, so on a bundle from anyone else it is
    /// unsigned text. Nothing may render it as verified — §9 Invariant 8.
    public let backing: SignerBacking
    public var state: AnchorState
    public var otsProof: Data?
    public var calendar: URL?
    public var submittedAt: Date?
    public var confirmedAt: Date?
    public var blockHeight: Int?
    /// Reserved; `nil` until a token is ever minted.
    public var chain: ChainRecord?

    public init(
        achievement: AchievementID,
        publicKey: Data,
        signature: Data,
        backing: SignerBacking,
        state: AnchorState,
        otsProof: Data? = nil,
        calendar: URL? = nil,
        submittedAt: Date? = nil,
        confirmedAt: Date? = nil,
        blockHeight: Int? = nil,
        chain: ChainRecord? = nil
    ) {
        self.achievement = achievement
        self.publicKey = publicKey
        self.signature = signature
        self.backing = backing
        self.state = state
        self.otsProof = otsProof
        self.calendar = calendar
        self.submittedAt = submittedAt
        self.confirmedAt = confirmedAt
        self.blockHeight = blockHeight
        self.chain = chain
    }
}

/// Frozen closed set, and therefore permitted to be an enum. §2.2, §7.1.
///
/// A fresh OpenTimestamps submission is an *incomplete* proof. Until a calendar
/// upgrades it with the Bitcoin path the achievement is sealed but not
/// anchored, and MUST NOT be described as anchored.
public enum AnchorState: String, Codable, Hashable, Sendable, CaseIterable {

    /// Computed, recorded and shown. **Never persisted by this build:** §7.1
    /// says sealing "happens **immediately**, in the same pass, offline", so
    /// every attestation this application writes is already ``sealed``. The case
    /// stays because it names the state an achievement is in between being
    /// computed and being signed, and because the enum is frozen.
    case provisional

    /// Signed with the P-256 key. The local record is tamper-evident from the
    /// first moment, and the certificate says exactly this and nothing more
    /// until ``confirmed``.
    case sealed

    /// The digest has been sent to an OpenTimestamps calendar. **This MUST NOT
    /// happen until 72 hours after `detectedAt`** — see ``AnchorSchedule``. It
    /// only ever means bytes were sent.
    case submitted

    /// An upgraded proof has landed in a Bitcoin block. **The only state in
    /// which anchoring language may be rendered.**
    case confirmed

    /// Retried with exponential backoff via `BGProcessingTask` **and** drained
    /// opportunistically on next launch. Invisible on the main screen; sayable
    /// once, on the certificate, after 30 days.
    case failed
}

/// The 72-hour provisional window. `docs/achievement-protocol.md` §7.1,
/// `docs/technical.md` §5.
///
/// **Sign immediately, publish late.** That gives both properties that matter:
/// the local record cannot be silently altered from the first moment, and nothing
/// irreversible has been published that the user might immediately want to take
/// back. It costs one timestamp comparison in a background job and it removes an
/// entire reversal UI from v1 — if a day the achievement depended on is un-checked
/// inside the window, nothing was ever published, so nothing needs reversing on
/// the outside.
///
/// It lives in Domain, as arithmetic on two instants, because week 4's submission
/// path must not be the place the rule is first written down: a gate that exists
/// only inside the code that wants to skip it is not a gate.
public enum AnchorSchedule {

    /// 72 hours, in seconds.
    public static let provisionalWindow: TimeInterval = 72 * 60 * 60

    /// The earliest instant an achievement detected at `detectedAt` may be
    /// submitted to a calendar.
    public static func submittableFrom(detectedAt: Date) -> Date {
        detectedAt.addingTimeInterval(provisionalWindow)
    }

    /// Whether the window has elapsed. `>=`, so an achievement detected exactly
    /// 72 hours ago is submittable — the boundary is stated rather than left to
    /// whichever comparison someone types.
    public static func maySubmit(detectedAt: Date, now: Date) -> Bool {
        now >= submittableFrom(detectedAt: detectedAt)
    }
}

/// The exponential backoff behind ``AnchorState/failed``.
/// `docs/achievement-protocol.md` §7.1, `docs/adr/0004`.
///
/// **There is no attempt-count field, and one was not added.** §7 lists
/// `Attestation`'s fields and the protocol document's stated purpose is that
/// "future code must not invent fields". It is not needed: both anchor files are
/// append-only and every state change appends a line, so the number of failures
/// is already on disk and counting them *is* the counter. See
/// `AwardStore.failureCount(for:)`.
///
/// The schedule doubles from one hour and stops widening at one week, and it
/// **never gives up**. ADR 0004 asks for re-attempts "over a long horizon —
/// months, not the length of one backoff schedule", so there is no attempt limit
/// here and there must not be one: a proof that is never upgraded is worthless,
/// and the only cost of trying again is one request.
public enum AnchorRetry {

    public static let firstDelay: TimeInterval = 60 * 60
    public static let widest: TimeInterval = 7 * 24 * 60 * 60

    /// How long to wait after the `n`th failure.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // Bounded before the shift, not after: `1 << 63` is a trap, and this
        // value is derived from a count of lines in a file that grows for as
        // long as a calendar stays unreachable.
        let doublings = min(failures - 1, 16)
        return min(widest, firstDelay * TimeInterval(1 << doublings))
    }

    /// The earliest instant the `failures + 1`th attempt may be made.
    public static func nextAttempt(firstAttemptAt: Date, failures: Int) -> Date {
        var offset: TimeInterval = 0
        var attempt = 1
        while attempt <= failures {
            offset += delay(afterFailures: attempt)
            attempt += 1
        }
        return firstAttemptAt.addingTimeInterval(offset)
    }

    public static func mayRetry(firstAttemptAt: Date, failures: Int, now: Date) -> Bool {
        now >= nextAttempt(firstAttemptAt: firstAttemptAt, failures: failures)
    }
}

/// Frozen closed set, and therefore permitted to be an enum. §2.2.
public enum SignerBacking: String, Codable, Hashable, Sendable, CaseIterable {
    case secureEnclave
    case software
}

// MARK: - The weekly log-head anchor

/// A commitment to where every writer's chain stood, submitted to
/// OpenTimestamps once a week. `docs/adr/0004`, `docs/technical.md` §10a.
///
/// **Why it has to exist before a certificate can claim anything about the
/// past.** ADR 0004's corollary: a rule shipped in June that backfills a March
/// achievement produces a June anchor, which alone proves nothing about March.
/// Only if the log head was already anchored weekly does the March data have a
/// March anchor — and only then does the achievement's `witness.logHeads` point
/// at something meaningful. That trigger is not distant: it **fired on the first
/// run of the week-3 engine**, which backfilled four awards onto days already in
/// the past.
///
/// The unavoidable residue, stated rather than papered over: no achievement
/// covering days before the *first* anchor can ever be proven about the past.
/// Anchoring cannot start before the anchoring code exists. For that first
/// cohort the certificate says what is true and claims nothing more.
///
/// ### The format is chosen here because no document specifies one
///
/// `docs/achievement-protocol.md` fixes `Achievement`, `Witness`, `RuleSpec`,
/// `Attestation` and `Revocation` field for field, and says its purpose is that
/// "future code must not invent fields". It does not describe this record at
/// all, and ADR 0004 mandates the work without giving it a shape — so a shape is
/// chosen, kept outside the achievement namespace, and reported. This is the
/// same reporting `AchievementClaim` above carries for the same reason.
///
/// Two deliberate differences from ``Attestation``, both of which are things
/// that type cannot express and this one is not frozen against:
///
/// - ``calendars`` is plural. ADR 0004 requires submitting to all three, and
///   `Attestation.calendar` is singular.
/// - There is no 72-hour provisional window. That window exists so nothing
///   irreversible is published that the user might immediately want to take
///   back (`docs/achievement-protocol.md` §7.1); a log head is not a claim about
///   anything a user would retract, and delaying it by three days would delay
///   the very property it exists to provide.
public struct LogAnchor: Codable, Sendable, Hashable {

    /// `deviceID` -> that writer's chain head, exactly as `witness.logHeads`
    /// carries it.
    public let heads: [String: Data]

    /// `SHA-256` over ``canonicalBytes`` — what is submitted to the calendars.
    public let digest: Data

    /// When this build first submitted it. The record does not exist before
    /// then: there is nothing to say about a head nobody has anchored.
    public let createdAt: Date

    public var state: AnchorState
    /// The merged detached proof: every calendar's branch in one artifact.
    public var otsProof: Data?
    /// Every calendar that accepted the digest. Plural, per ADR 0004.
    public var calendars: [URL]
    public var submittedAt: Date?
    public var confirmedAt: Date?
    public var blockHeight: Int?

    public init(
        heads: [String: Data],
        digest: Data,
        createdAt: Date,
        state: AnchorState,
        otsProof: Data? = nil,
        calendars: [URL] = [],
        submittedAt: Date? = nil,
        confirmedAt: Date? = nil,
        blockHeight: Int? = nil
    ) {
        self.heads = heads
        self.digest = digest
        self.createdAt = createdAt
        self.state = state
        self.otsProof = otsProof
        self.calendars = calendars
        self.submittedAt = submittedAt
        self.confirmedAt = confirmedAt
        self.blockHeight = blockHeight
    }
}

/// When the next log-head anchor is due. ADR 0004: "the event-log head,
/// **weekly**, from week 4".
///
/// It lives in Domain as arithmetic on two instants, for the same reason
/// ``AnchorSchedule`` does: a cadence that exists only inside the code that
/// wants to skip it is not a cadence.
public enum LogAnchorSchedule {

    /// Seven days, in seconds. Roughly 52 free submissions a year — the
    /// calendars Merkle-aggregate, so the marginal cost of a digest is zero.
    public static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// Whether a fresh anchor is due.
    ///
    /// **Unchanged heads are never re-anchored**, however long it has been. The
    /// digest would be identical, so a second submission buys a strictly later
    /// Bitcoin timestamp for a value that already has an earlier one — which is
    /// worse than nothing, and ADR 0004 names exactly that as what makes a proof
    /// unrecoverable if it is discarded.
    public static func isDue(heads: [String: Data], since last: LogAnchor?, now: Date) -> Bool {
        guard !heads.isEmpty else { return false }
        guard let last else { return true }
        if last.heads != heads { return now >= last.createdAt.addingTimeInterval(interval) }
        return false
    }
}

/// Reserved so that adding it later is not a format change. §7.
public struct ChainRecord: Codable, Hashable, Sendable {
    public let chainId: Int
    public let contract: String
    public let tokenId: String
    public let txHash: String

    public init(chainId: Int, contract: String, tokenId: String, txHash: String) {
        self.chainId = chainId
        self.contract = contract
        self.tokenId = tokenId
        self.txHash = txHash
    }
}
