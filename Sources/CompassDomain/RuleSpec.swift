import Foundation

/// What a rule counts. `docs/achievement-protocol.md` §5.1.
///
/// | kind | v1 | meaning |
/// |---|---|---|
/// | `streak` | yes | `threshold` consecutive qualifying days |
/// | `total` | yes | `threshold` qualifying days in total |
/// | `rate_in_window` | reserved | `requires` of `window` days |
/// | `first_ever` | reserved | the first qualifying day of all time |
/// | `distinct_weekdays` | reserved | `threshold` distinct weekdays covered |
/// | `all_of` | reserved | every rule in `members` earned |
///
/// **An evaluator MUST skip an unknown kind with a warning and MUST leave the
/// rule file on disk untouched.** An older build never destroys rules it does not
/// understand — which is the whole reason this is a `RawRepresentable` string and
/// not an enum.
///
/// **Tripwire:** if a seventh kind is wanted and it needs conditionals *inside*
/// itself, stop and write Swift. That is a DSL arriving by accident.
public struct RuleKind: StringBacked {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// `threshold` consecutive qualifying days. Implemented in v1.
    public static let streak = RuleKind(rawValue: "streak")
    /// `threshold` qualifying days in total, not necessarily consecutive.
    /// Implemented in v1.
    public static let total = RuleKind(rawValue: "total")

    // Named so the format does not change when they arrive. Not implemented.
    public static let rateInWindow = RuleKind(rawValue: "rate_in_window")
    public static let firstEver = RuleKind(rawValue: "first_ever")
    public static let distinctWeekdays = RuleKind(rawValue: "distinct_weekdays")
    public static let allOf = RuleKind(rawValue: "all_of")

    /// The two `docs/technical.md` §5 ships evaluators for.
    public static let implemented: Set<RuleKind> = [.streak, .total]

    public var isImplemented: Bool { RuleKind.implemented.contains(self) }
}

/// How often one rule may fire. `docs/achievement-protocol.md` §5.
///
/// A `RawRepresentable` string because §6.2 puts it in the digest as
/// `"repeatPolicy":<string>` — a single scalar — and because `cooldown(days)`
/// carries a payload that an enum case in a digested field could not spell
/// stably. The spelling is `once`, `everyOccurrence`, or `cooldown:<days>`.
///
/// **v1 ships `once` and nothing else, and for `streak` and `total` the
/// distinction is currently unobservable:** both fire on the single earliest day
/// their threshold is first met, so there is no second occurrence to repeat at.
/// The field exists because it is inside the digest and cannot be added later.
public struct RepeatPolicy: StringBacked {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let once = RepeatPolicy(rawValue: "once")
    public static let everyOccurrence = RepeatPolicy(rawValue: "everyOccurrence")

    public static func cooldown(days: Int) -> RepeatPolicy {
        RepeatPolicy(rawValue: "cooldown:\(days)")
    }
}

/// Which days a rule is allowed to count. `docs/achievement-protocol.md` §5.
///
/// **A struct, not an enum with payloads**, and `tag` was deliberately removed:
/// tags and categories are a named non-goal in `docs/product.md`, and reserving a
/// field for a banned feature is what keeps the feature alive.
///
/// The three shapes it can take, spelled out because §5's one-line comments leave
/// the combination implicit and the engine has to be total over it:
///
/// - `habit: X` — a day qualifies when habit `X` was checked in on it.
/// - `habit: nil, requiresAll: false` — a day qualifies when **any** habit was
///   checked in on it. This is the same question `Projection.daysRecorded`
///   answers, and therefore the same one the number on Today reports.
/// - `habit: nil, requiresAll: true` — a day qualifies when **every habit that
///   was being tracked on that day** was checked in on it. This is the question
///   the 28-dot spine answers.
public struct Scope: Codable, Sendable, Hashable {

    /// `nil` = not scoped to one habit. **Always the opaque identifier**, never a
    /// display name: `facts` and `rule.id` both travel inside a signed, anchored,
    /// shareable record with no redaction path. §3.4.
    public let habit: HabitID?

    /// All habits active on the day must be done.
    public let requiresAll: Bool

    public init(habit: HabitID? = nil, requiresAll: Bool = false) {
        self.habit = habit
        self.requiresAll = requiresAll
    }

    /// Every habit that was being tracked that day. The only scope with no habit
    /// and no "any" reading.
    public static let allHabits = Scope(habit: nil, requiresAll: true)

    /// Any habit at all — a day on which something was recorded.
    public static let anyHabit = Scope(habit: nil, requiresAll: false)
}

/// A milestone rule. **Data, never code.** `docs/technical.md` §5,
/// `docs/achievement-protocol.md` §5.
///
/// A rule ships as a JSON row and each ``RuleKind`` has a small Swift evaluator,
/// so adding an achievement is a JSON row rather than a code change and the
/// engine backfills it over existing history with `earnedOn` set to the
/// historical day. Hard-coded `if streak == 100` rules would require a
/// version-gated backfill migration per achievement, which is the migration pain
/// this project cannot afford.
///
/// **A copy of the whole spec is frozen onto every achievement it fires**
/// (§3.2). An achievement earned in 2026 must still render and verify in 2029
/// after the rule has been reworded, retuned, or deleted entirely. Storing a
/// reference is what forces achievement-system migrations; storing the definition
/// is what avoids them.
public struct RuleSpec: Codable, Sendable, Hashable, Identifiable {

    /// e.g. `"streak.habit-a.100"`. Never changes meaning — see ``RuleID``.
    public let id: RuleID

    /// **Presentation only. Not in the digest and not in the ID.** For wording
    /// and threshold-*presentation* changes that do not alter what is counted.
    public let version: Int

    public let kind: RuleKind
    public let scope: Scope
    public let threshold: Int

    /// `rate_in_window`: the window length in days. Reserved.
    public let window: Int?
    /// `rate_in_window`: how many of `window` must be satisfied. Reserved.
    public let requires: Int?

    /// `nil` = backfills always count. No backfill surface ships in v1.
    public let maxBackfillLagDays: Int?

    /// Reserved; `false` until neutral days ship. `docs/technical.md` §10b.
    public let neutralDaysBridge: Bool

    public let repeatPolicy: RepeatPolicy

    /// `all_of`: the rules that must all be earned. Reserved.
    public let members: [RuleID]?

    /// **Display only; NOT in the digest.** See ``fallbackTitle`` — nothing in
    /// this application renders either of them.
    public let titleKey: String

    /// **Display only; NOT in the digest**, and therefore never rendered as part
    /// of a verified claim.
    ///
    /// `docs/achievement-protocol.md` §5.2 derives titles from
    /// `titleKey` + `fallbackTitle` + `facts`, and Invariant 8 then closes the
    /// forgery path that opens: on a bundle received from someone else every
    /// undigested field is attacker-controllable while the signature still
    /// verifies, so a forged bundle could render an arbitrary title under a valid
    /// signature and a genuine Bitcoin anchor. "A title is rendered *from the
    /// rule*, not from `titleKey`."
    ///
    /// So these two fields are carried, round-tripped and frozen onto the award —
    /// the format is fixed by §5 and this build must not invent a different one —
    /// and **`CertificateCopy` renders from `kind`, `threshold`, `scope`,
    /// `earnedOn` and `facts` alone.**
    public let fallbackTitle: String

    /// Forward-compatibility bag, round-tripped losslessly, never digested.
    public let extra: [String: JSONValue]

    public init(
        id: RuleID,
        version: Int = 1,
        kind: RuleKind,
        scope: Scope,
        threshold: Int,
        window: Int? = nil,
        requires: Int? = nil,
        maxBackfillLagDays: Int? = nil,
        neutralDaysBridge: Bool = false,
        repeatPolicy: RepeatPolicy = .once,
        members: [RuleID]? = nil,
        titleKey: String = "",
        fallbackTitle: String = "",
        extra: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.version = version
        self.kind = kind
        self.scope = scope
        self.threshold = threshold
        self.window = window
        self.requires = requires
        self.maxBackfillLagDays = maxBackfillLagDays
        self.neutralDaysBridge = neutralDaysBridge
        self.repeatPolicy = repeatPolicy
        self.members = members
        self.titleKey = titleKey
        self.fallbackTitle = fallbackTitle
        self.extra = extra
    }

    // MARK: Codable — every field optional on read but `id`, `kind` and `threshold`

    private enum CodingKeys: String, CodingKey {
        case id, version, kind, scope, threshold, window, requires
        case maxBackfillLagDays, neutralDaysBridge, repeatPolicy, members
        case titleKey, fallbackTitle, extra
    }

    /// Defaults are supplied for every field a rule row may omit, so a hand-written
    /// JSON row stays short. `id`, `kind` and `threshold` have no honest default
    /// and a row missing one of them is refused rather than guessed at.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(RuleID.self, forKey: .id)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        kind = try container.decode(RuleKind.self, forKey: .kind)
        scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? Scope()
        threshold = try container.decode(Int.self, forKey: .threshold)
        window = try container.decodeIfPresent(Int.self, forKey: .window)
        requires = try container.decodeIfPresent(Int.self, forKey: .requires)
        maxBackfillLagDays = try container.decodeIfPresent(
            Int.self, forKey: .maxBackfillLagDays
        )
        neutralDaysBridge =
            try container.decodeIfPresent(Bool.self, forKey: .neutralDaysBridge) ?? false
        repeatPolicy =
            try container.decodeIfPresent(RepeatPolicy.self, forKey: .repeatPolicy) ?? .once
        members = try container.decodeIfPresent([RuleID].self, forKey: .members)
        titleKey = try container.decodeIfPresent(String.self, forKey: .titleKey) ?? ""
        fallbackTitle = try container.decodeIfPresent(String.self, forKey: .fallbackTitle) ?? ""
        extra = try container.decodeIfPresent([String: JSONValue].self, forKey: .extra) ?? [:]
    }
}
