import Foundation

/// The evaluation engine. **A pure function of the log.**
/// `docs/technical.md` §5, `docs/achievement-protocol.md` §9.
///
/// The four invariants it exists to satisfy, restated because every design
/// choice below follows from one of them:
///
/// 1. **Pure.** Same inputs, bit-identical outputs. No clock, no I/O, no
///    `Calendar.current`. `detectedAt` is passed in.
/// 2. **Idempotent.** Deterministic IDs (`"<ruleID>@<earnedOn>"`) filtered
///    against the set already recorded.
/// 3. **Re-runnable over all history at any time.** Shipping a hundred-day rule
///    to someone already at day 150 awards it immediately, with `earnedOn` set to
///    the historical day.
/// 4. An award, once recorded, is **never mutated and never deleted** — a rule
///    that changes later cannot un-award it, because the achievement carries a
///    frozen copy of the rule that fired.
///
/// ### It takes events, not a projection
///
/// `docs/technical.md` §4's tap-path sketch reads
/// `Task { await achievements.evaluate(projection) }`, and that signature cannot
/// be implemented: `docs/achievement-protocol.md` §4.1 builds `evidenceRoot` out
/// of the **`content_hash` of the qualifying events**, and a `Projection` carries
/// no events — it folds them into booleans and drops them. `witness.logHeads`
/// needs the chain heads, which are likewise a property of the events.
///
/// So the engine takes the log. This is the same class of gap as §4's
/// `Event(kind:habit:day:at:)`, which cannot produce the `device`, `lamport`,
/// `recordedAt` and `zoneOffset` §3 requires — reported rather than designed
/// around, per `PROJECT_CONSTITUTION.md` §9.
public enum AchievementEngine {

    /// Everything one pass over the log concluded.
    public struct Evaluation: Sendable, Hashable {

        /// Newly earned, deterministic order, excluding everything already
        /// recorded.
        public let awarded: [Achievement]

        /// **Every achievement the log currently supports**, recorded or not.
        ///
        /// This is what makes revocation computable without a second pass: an
        /// achievement in `awards.jsonl` that is *not* in this set is one whose
        /// claim has stopped being true, which happens when the user un-checks a
        /// day it depended on. See ``revocations(forRecorded:notIn:at:logHeads:)``.
        public let earned: Set<AchievementID>

        /// Rules skipped because their ``RuleKind`` has no evaluator in this
        /// build. **The rule file is left on disk untouched** — an older build
        /// never destroys rules it does not understand.
        /// `docs/achievement-protocol.md` §5.1.
        public let skipped: [RuleID]

        /// Each writer's chain head as of this evaluation, the value every
        /// witness in ``awarded`` committed to.
        public let logHeads: [String: Data]

        public init(
            awarded: [Achievement],
            earned: Set<AchievementID>,
            skipped: [RuleID],
            logHeads: [String: Data]
        ) {
            self.awarded = awarded
            self.earned = earned
            self.skipped = skipped
            self.logHeads = logHeads
        }
    }

    /// Runs every rule over the whole log.
    ///
    /// `alreadyRecorded` is the set of achievement IDs already in `awards.jsonl`,
    /// including revoked ones — a revoked achievement is **not** re-awarded, and
    /// that is the point of filtering on the recorded set rather than on the live
    /// one. Re-awarding it would be a second `achievementAwarded` for an ID that
    /// already has a posted reversal against it.
    public static func evaluate(
        events: [Event],
        rules: [RuleSpec],
        detectedAt: Date,
        alreadyRecorded: Set<AchievementID> = []
    ) throws -> Evaluation {
        let log = QualifyingLog(events: events)
        let logHeads = log.logHeads

        var awarded: [Achievement] = []
        var earned: Set<AchievementID> = []
        var skipped: [RuleID] = []

        // Sorted, so two runs over one log produce one order. `Array` order from
        // a directory listing is not a promise, and the awards file is
        // append-only — a different order would be a different file.
        for rule in rules.sorted(by: { $0.id < $1.id }) {
            guard rule.kind.isImplemented else {
                skipped.append(rule.id)
                continue
            }
            guard let counted = countedDays(for: rule, in: log) else { continue }

            let id = AchievementID(rule: rule.id, earnedOn: counted.earnedOn)
            earned.insert(id)
            guard !alreadyRecorded.contains(id) else { continue }

            let evidence = counted.days.flatMap { log.qualifyingEvents(on: $0, for: rule.scope) }
            let live = counted.days.filter { day in
                log.qualifyingEvents(on: day, for: rule.scope).contains { $0.source?.isLive == true }
            }.count

            var facts: [FactKey: JSONValue] = [
                rule.kind == .streak ? .streak : .total: .int(rule.threshold),
                .from: .string(counted.days[0].iso),
                // **REQUIRED on every achievement derived from check-ins**, and
                // they partition `witness.dayCount`. Without the partition a
                // certificate over mostly backfilled days would be
                // indistinguishable from one over live taps, and the sealed claim
                // would quietly overstate what happened. §3.4.
                .sourceLive: .int(live),
                .sourceBackfill: .int(counted.days.count - live),
            ]
            // The opaque identifier, never the display name. §3.4.
            if let habit = rule.scope.habit {
                facts[.habitID] = .string(habit.rawValue)
            }

            awarded.append(
                Achievement(
                    id: id,
                    rule: rule,
                    earnedOn: counted.earnedOn,
                    detectedAt: detectedAt,
                    facts: facts,
                    witness: Witness(
                        firstDay: counted.days[0],
                        lastDay: counted.earnedOn,
                        dayCount: counted.days.count,
                        evidenceRoot: try EvidenceRoot.root(over: evidence),
                        logHeads: logHeads
                    )
                )
            )
        }

        return Evaluation(
            awarded: awarded.sorted { $0.id < $1.id },
            earned: earned,
            skipped: skipped,
            logHeads: logHeads
        )
    }

    /// The reversals a pass concluded: every recorded achievement whose claim the
    /// log no longer supports.
    ///
    /// **It appends; it never deletes.** `docs/achievement-protocol.md` §8 has no
    /// deletion path in `awards.jsonl`, in any state, for any reason — including
    /// while the achievement is still `provisional`. What differs between
    /// revoking before and after submission is what the outside world saw, and
    /// therefore what the certificate list says. It is never whether the record
    /// survives.
    ///
    /// `alreadyRevoked` is passed so a claim that stopped being true does not
    /// produce a fresh `Revocation` on every launch thereafter.
    public static func revocations(
        forRecorded recorded: [AchievementID],
        notIn earned: Set<AchievementID>,
        alreadyRevoked: Set<AchievementID>,
        at instant: Date,
        logHeads: [String: Data],
        reason: String = Revocation.dependedOnDayEdited
    ) -> [Revocation] {
        recorded
            .filter { !earned.contains($0) && !alreadyRevoked.contains($0) }
            .sorted()
            .map {
                Revocation(achievement: $0, reason: reason, at: instant, newLogHeads: logHeads)
            }
    }

    // MARK: The two evaluators

    /// The days a rule counted, and the day it became true.
    private struct CountedDays {
        let days: [Day]
        let earnedOn: Day
    }

    private static func countedDays(for rule: RuleSpec, in log: QualifyingLog) -> CountedDays? {
        guard rule.threshold > 0 else { return nil }
        let days = log.qualifyingDays(for: rule.scope)

        switch rule.kind {
        case .streak:
            // **The earliest window of `threshold` consecutive days**, so the
            // answer is a fact about the log rather than about when the rule
            // shipped. That is what makes invariant 3 true: a hundred-day rule
            // shipped to someone at day 150 lands on day 100's date, not today's.
            var runStart = 0
            for index in days.indices {
                if index > 0, days[index].ordinal != days[index - 1].ordinal + 1 {
                    runStart = index
                }
                if index - runStart + 1 == rule.threshold {
                    return CountedDays(
                        days: Array(days[runStart...index]), earnedOn: days[index]
                    )
                }
            }
            return nil

        case .total:
            // The first `threshold` qualifying days, so `earnedOn` is the day the
            // count reached the threshold and never a later one. Days after it are
            // not counted and are not in the witness: the claim is "1,000 days
            // recorded", made on the day the thousandth was.
            guard days.count >= rule.threshold else { return nil }
            let counted = Array(days.prefix(rule.threshold))
            return CountedDays(days: counted, earnedOn: counted[counted.count - 1])

        default:
            // Unreachable: the caller has already filtered on `isImplemented`.
            // Present so that adding a kind to `RuleKind.implemented` without
            // writing its evaluator is a `nil`, never a wrong award.
            return nil
        }
    }
}

extension CheckInSource {

    /// Whether a day carrying this source counts towards `facts["source_live"]`.
    ///
    /// **True for all three v1 values**, because v1 ships no backfill surface —
    /// `docs/technical.md` §3 and §10b. It is computed rather than hardcoded to
    /// `0` so that the day a `backfill` source is ever added, the partition is
    /// already correct: one line here, and no change to the digest, which cannot
    /// take one.
    var isLive: Bool {
        switch self {
        case .tap, .widget, .shortcut: true
        }
    }
}

// MARK: - The log, indexed for evaluation

/// The log, folded once into what every rule needs to ask of it.
///
/// It exists because the two things a witness commits to — which events were
/// counted, and where every writer's chain stood — are both properties of the
/// **events**, and a ``Projection`` has neither: it folds check-ins into
/// booleans and drops the events that produced them.
///
/// ### It re-derives last-writer-wins, and a test holds the two together
///
/// The `(habit, day)` cell here is resolved exactly as ``Projection`` resolves
/// it: iterate in `(lamport, device)` order and let the last write stand. That is
/// the same rule written twice, which is a thing this codebase avoids — so
/// `AchievementEngineTests` asserts that for every habit and every day, the cell
/// this holds an event for is precisely the cell `project(_:)` reports as
/// checked. If the two ever diverge, that test fails rather than a certificate
/// quietly committing to the wrong evidence.
///
/// The alternative — teaching `Projection` to carry the winning `Event` per cell
/// — was rejected because the projection is also rehydrated from the disposable
/// launch cache, which has no events in it, so half of every restored projection
/// would carry a field it structurally cannot fill.
struct QualifyingLog {

    /// The winning `checkedIn` event per `(habit, day)` cell. A revoked cell is
    /// **absent**, not marked — the same shape as ``HabitState/checkedDays``.
    private let cells: [HabitID: [Day: Event]]

    /// Which habits were being tracked on which day, from the same fold the spine
    /// uses. A day is judged against the habits active *on it*, never against
    /// today's set.
    private let projection: Projection

    /// Every writer's chain head, for `witness.logHeads`.
    let logHeads: [String: Data]

    init(events: [Event]) {
        let ordered = events.sorted { $0.order < $1.order }

        var cells: [HabitID: [Day: Event]] = [:]
        for event in ordered {
            guard event.kind == .checkedIn || event.kind == .checkInRevoked,
                  let habit = event.payload.habitID
            else { continue }
            if event.kind == .checkedIn {
                cells[habit, default: [:]][event.day] = event
            } else {
                cells[habit]?[event.day] = nil
            }
        }
        self.cells = cells
        self.projection = project(ordered)

        var heads: [String: Data] = [:]
        for (device, head) in EventChain.verify(ordered).heads {
            heads[device.rawValue] = head
        }
        self.logHeads = heads
    }

    /// Every day this scope counts, ascending. See ``Scope`` for the three shapes
    /// and what each one asks of a day.
    func qualifyingDays(for scope: Scope) -> [Day] {
        if let habit = scope.habit {
            return (cells[habit] ?? [:]).keys.sorted()
        }

        var candidates: Set<Day> = []
        for byDay in cells.values { candidates.formUnion(byDay.keys) }

        guard scope.requiresAll else { return candidates.sorted() }

        return candidates.filter { day in
            let active = projection.habitsActive(on: day)
            // `allSatisfy` over an empty set is `true`, and the days before any
            // habit existed are exactly that set — so a day nothing was tracked on
            // would otherwise count as a day everything was done. The spine already
            // guards this; the guard is here for the same reason.
            guard !active.isEmpty else { return false }
            return active.allSatisfy { cells[$0.id]?[day] != nil }
        }.sorted()
    }

    /// The events that made `day` qualify — the ones the evidence root commits
    /// to.
    ///
    /// For a habit-scoped rule that is one event: the write that currently owns
    /// that cell. For an unscoped rule it is every check-in standing on that day,
    /// because what made the day qualify is all of them together — "any habit"
    /// is answered by the set, and "every active habit" is only true of the set.
    func qualifyingEvents(on day: Day, for scope: Scope) -> [Event] {
        if let habit = scope.habit {
            return [cells[habit]?[day]].compactMap { $0 }
        }
        return cells.values.compactMap { $0[day] }.sorted { $0.order < $1.order }
    }

    /// The cell map, for the test that holds this type and ``Projection``
    /// together. See the type's own documentation.
    func checkedDays(of habit: HabitID) -> Set<Day> {
        Set((cells[habit] ?? [:]).keys)
    }
}
