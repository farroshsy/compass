import Foundation

/// An immutable, self-describing claim that a named rule became true on a named
/// civil day, carrying enough evidence for a stranger to check it without the
/// app. `docs/achievement-protocol.md` §3.
///
/// **Seven fields. No more.** It is not a badge, not a token, and not a row
/// pointing at a live rules table.
public struct Achievement: Codable, Sendable, Hashable, Identifiable {

    /// Deterministic — `"<rule.id>@<earnedOn>"`, never a UUID. §3.1.
    public let id: AchievementID

    /// **A frozen copy of the rule that fired**, not a foreign key. §3.2. An
    /// achievement earned in 2026 must still render and verify in 2029 after the
    /// rule has been reworded, retuned, or deleted entirely.
    public let rule: RuleSpec

    /// The civil day the claim became true. **In the digest** — it is the
    /// semantic claim.
    public let earnedOn: Day

    /// The instant the engine noticed. **Not in the digest**: it is bookkeeping.
    /// It orders the certificate list and gates the 72-hour provisional window
    /// (§7.1). It does **not** drive a "new" indicator — that was cut, because a
    /// "new" badge is a re-engagement affordance in an app whose non-goals ban
    /// badges.
    ///
    /// Two fields rather than one because with retroactive edits and an app that
    /// was not opened for a week, "when it became true" and "when we found out"
    /// genuinely differ, and a single field forces a lie about one of them.
    public let detectedAt: Date

    /// The numbers that mattered, as an open map. §3.4.
    ///
    /// **Carries `habitID`, never `habit`** — never a display name. `facts` is
    /// inside the canonical bytes, which are hashed, signed and anchored, and the
    /// resulting certificate is the artifact designed to be handed to a stranger.
    /// There is no redaction path and there can never be one, so a user who names
    /// a habit after a recovery programme, a medical routine or a therapy task
    /// and later regrets it would have no remedy at all. The human-readable name
    /// lives in a mutable local `habits.json`, resolved at render time.
    public let facts: [FactKey: JSONValue]

    /// The commitment to the underlying data. §4.
    public let witness: Witness

    /// Forward-compatibility bag, round-tripped losslessly. **Not in the
    /// digest**, and the consequence must be understood: anything that needs to
    /// be provable goes in ``facts`` or ``witness``, never here. §3.5.
    public let extra: [String: JSONValue]

    public init(
        id: AchievementID,
        rule: RuleSpec,
        earnedOn: Day,
        detectedAt: Date,
        facts: [FactKey: JSONValue],
        witness: Witness,
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.rule = rule
        self.earnedOn = earnedOn
        self.detectedAt = detectedAt
        self.facts = facts
        self.witness = witness
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey {
        case id, rule, earnedOn, detectedAt, facts, witness, extra
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AchievementID.self, forKey: .id)
        rule = try container.decode(RuleSpec.self, forKey: .rule)
        earnedOn = try container.decode(Day.self, forKey: .earnedOn)
        detectedAt = try container.decode(Date.self, forKey: .detectedAt)
        facts = try container.decode([FactKey: JSONValue].self, forKey: .facts)
        witness = try container.decode(Witness.self, forKey: .witness)
        extra = try container.decodeIfPresent([String: JSONValue].self, forKey: .extra) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(rule, forKey: .rule)
        try container.encode(earnedOn, forKey: .earnedOn)
        try container.encode(detectedAt, forKey: .detectedAt)
        try container.encode(facts, forKey: .facts)
        try container.encode(witness, forKey: .witness)
        if !extra.isEmpty { try container.encode(extra, forKey: .extra) }
    }
}

/// The commitment to the underlying data. `docs/achievement-protocol.md` §4.
///
/// ``evidenceRoot`` and ``logHeads`` are not redundant and do different jobs:
///
/// - `evidenceRoot` pins **exactly which events were counted**. It is what makes
///   a post-hoc revocation honest — the claim can still be checked against the
///   set it was actually made over.
/// - `logHeads` commits to the **whole history** as of detection. It is what
///   links the achievement to a weekly log-head anchor, which is the only thing
///   that makes a backfilled achievement provable about the past rather than
///   about the day it was detected.
///
/// **Explicitly not stored:** the list of qualifying days. A 1000-day streak
/// would carry 1000 `Day` values, all recomputable from a log head that already
/// commits to them.
public struct Witness: Codable, Sendable, Hashable {

    public let firstDay: Day
    /// `== earnedOn` for streak rules.
    public let lastDay: Day
    public let dayCount: Int

    /// 32 bytes: the Merkle root over the events that were actually counted.
    /// Construction frozen in §4.1 — see ``EvidenceRoot``.
    public let evidenceRoot: Data

    /// `deviceID` -> that writer's chain head, as of detection. Serialised with
    /// device keys sorted byte-wise in the canonical form (§4).
    public let logHeads: [String: Data]

    public init(
        firstDay: Day, lastDay: Day, dayCount: Int, evidenceRoot: Data, logHeads: [String: Data]
    ) {
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.dayCount = dayCount
        self.evidenceRoot = evidenceRoot
        self.logHeads = logHeads
    }
}

/// A posted reversal. `docs/achievement-protocol.md` §8.
///
/// **Appended to `awards.jsonl`. Every revocation is an appended record; there is
/// no deletion path in that file, in any state, for any reason.** An earlier form
/// of §8 said a revocation while `provisional` removes the record quietly, which
/// contradicted Invariant 4 and the append-only property the mutable/immutable
/// file split exists to preserve — and a documented deletion path inside a
/// strictly append-only file gets implemented as a whole-file rewrite, the exact
/// operation ADR 0002 disqualifies on flash-write grounds.
///
/// The difference between revoking before and after submission is what the
/// outside world saw, and therefore what the UI says. It is never whether the
/// record is deleted. **You never erase a published entry; you post a reversal.**
public struct Revocation: Codable, Sendable, Hashable {
    public let achievement: AchievementID
    public let reason: String
    public let at: Date
    public let newLogHeads: [String: Data]

    public init(
        achievement: AchievementID, reason: String, at: Date, newLogHeads: [String: Data]
    ) {
        self.achievement = achievement
        self.reason = reason
        self.at = at
        self.newLogHeads = newLogHeads
    }

    /// The only reason v1 ever produces. The user edited a day the claim depended
    /// on, so the claim stopped being true — and the certificate list says exactly
    /// that, with no colour, no icon and no offer to fix it.
    public static let dependedOnDayEdited = "a day it depended on was edited"
}

/// Everything the certificate surfaces need, as one value.
///
/// It exists for the same reason ``ComposedStore`` does: `CompassUI` cannot
/// import `CompassInfrastructure`, so what the settings sheet and the
/// certificate read has to arrive as a Domain value across the ``Awarding``
/// port.
///
/// A **revoked achievement is still in ``achievements``**, keeping its place in
/// the list. `docs/achievement-protocol.md` §8: you never erase a published
/// entry; you post a reversal.
public struct AwardBook: Sendable, Hashable {

    /// Reverse-chronological by `detectedAt`. §3.3 gives that field exactly two
    /// jobs and this is one of them.
    public let achievements: [Achievement]

    public let revoked: Set<AchievementID>

    /// The current attestation per achievement, folded last-write-wins.
    public let attestations: [AchievementID: Attestation]

    /// What **this pass** awarded, newest first. Empty on every pass but the one
    /// that finds something, which is what stops the certificate being
    /// re-presented: `.claude/skills/ui.md` says "the card is not re-shown
    /// unprompted".
    public let newlyIssued: [AchievementID]

    public init(
        achievements: [Achievement],
        revoked: Set<AchievementID> = [],
        attestations: [AchievementID: Attestation] = [:],
        newlyIssued: [AchievementID] = []
    ) {
        self.achievements = achievements
        self.revoked = revoked
        self.attestations = attestations
        self.newlyIssued = newlyIssued
    }

    public static let empty = AwardBook(achievements: [])

    public func achievement(_ id: AchievementID) -> Achievement? {
        achievements.first { $0.id == id }
    }

    public func isRevoked(_ id: AchievementID) -> Bool { revoked.contains(id) }
}

/// One line of `awards.jsonl`. `docs/technical.md` §6.
///
/// Two record types share one append-only file, and the protocol specifies **no
/// discriminator field** for telling them apart. One is not invented here:
/// `docs/achievement-protocol.md` opens by stating that its purpose is that
/// "future code must not invent fields", and that a field not in the document is
/// added by amending the document first, in a commit of its own.
///
/// They do not need one. The two shapes are disjoint on their required keys — an
/// achievement has `rule`, `earnedOn`, `facts` and `witness`; a revocation has
/// `reason`, `at` and `newLogHeads`, and even their identifier keys differ (`id`
/// versus `achievement`). So a line is decoded as an achievement, then as a
/// revocation, and a line that is neither is **kept verbatim and re-emitted**
/// rather than dropped, exactly as an unknown event kind is.
public enum AwardRecord: Sendable, Hashable {
    case achievement(Achievement)
    case revocation(Revocation)

    public var achievementID: AchievementID {
        switch self {
        case .achievement(let value): value.id
        case .revocation(let value): value.achievement
        }
    }
}
