import Foundation
import Testing

@testable import CompassDomain

/// The evaluation engine. `docs/technical.md` §5 and §9.5,
/// `docs/achievement-protocol.md` §9, `.claude/skills/testing.md`.
///
/// Every test here asserts a product meaning rather than restating the
/// implementation: that a hundred-day rule shipped late lands on the historical
/// day, that an un-checked day takes the claim with it, that a name never reaches
/// the record, that two runs produce the same bytes.
@Suite("The achievement engine — a pure function of the log")
struct AchievementEngineTests {

    // MARK: Fixtures

    static let detected = Date(timeIntervalSince1970: 1_800_000_000)

    static func streakRule(
        _ habit: HabitID = habitA, threshold: Int, id: String? = nil
    ) -> RuleSpec {
        RuleSpec(
            id: RuleID(rawValue: id ?? "streak.\(habit.rawValue).\(threshold)"),
            kind: .streak,
            scope: Scope(habit: habit),
            threshold: threshold
        )
    }

    static func totalRule(threshold: Int, requiresAll: Bool = false) -> RuleSpec {
        RuleSpec(
            id: RuleID(rawValue: "total.recorded.\(threshold)"),
            kind: .total,
            scope: Scope(habit: nil, requiresAll: requiresAll),
            threshold: threshold
        )
    }

    /// `count` consecutive daily check-ins for one habit, starting at `start`.
    static func run(
        _ habit: HabitID = habitA, from start: Day, count: Int, firstLamport: Int = 10
    ) throws -> [Event] {
        var events = [event(.habitCreated, habit: habit, on: start, lamport: 1, name: "Meditate")]
        for offset in 0..<count {
            events.append(
                event(
                    .checkedIn, habit: habit, on: start.adding(offset),
                    lamport: firstLamport + offset, source: .tap
                )
            )
        }
        return try chained(events)
    }

    static func evaluate(
        _ events: [Event], _ rules: [RuleSpec], recorded: Set<AchievementID> = []
    ) throws -> AchievementEngine.Evaluation {
        try AchievementEngine.evaluate(
            events: events, rules: rules, detectedAt: detected, alreadyRecorded: recorded
        )
    }

    // MARK: What a rule means

    /// Invariant 3: "Shipping a hundred-day rule to someone already at day 150
    /// awards it immediately with `earnedOn` set to the **historical** day."
    ///
    /// This is the whole reason the engine scans for the earliest qualifying
    /// window rather than looking at the tail of the log. An award dated today
    /// for a run that finished seven weeks ago is a false claim on a document
    /// designed to be handed to a stranger.
    @Test("A rule shipped late lands on the day the claim actually became true")
    func backfillsToTheHistoricalDay() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 150)
        let result = try AchievementEngineTests.evaluate(
            events, [AchievementEngineTests.streakRule(threshold: 100)]
        )

        #expect(result.awarded.count == 1)
        let award = try #require(result.awarded.first)
        // 2026-01-01 is day 1, so day 100 is 2026-04-10.
        #expect(award.earnedOn == day("2026-01-01").adding(99))
        #expect(award.witness.firstDay == day("2026-01-01"))
        #expect(award.witness.lastDay == award.earnedOn)
        #expect(award.witness.dayCount == 100)
    }

    /// §3.1: `id = "<rule.id>@<earnedOn>"`, never a UUID. A random ID means
    /// replaying the log twice produces two awards for one fact.
    @Test("The identifier is the rule and the day it became true, and nothing else")
    func identifierIsDeterministic() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 7)
        let result = try AchievementEngineTests.evaluate(
            events, [AchievementEngineTests.streakRule(threshold: 7)]
        )
        #expect(result.awarded.first?.id.rawValue == "streak.habit-a.7@2026-01-07")
    }

    @Test("A run one day short of the threshold awards nothing")
    func shortOfTheThresholdAwardsNothing() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 6)
        let result = try AchievementEngineTests.evaluate(
            events, [AchievementEngineTests.streakRule(threshold: 7)]
        )
        #expect(result.awarded.isEmpty)
        #expect(result.earned.isEmpty)
    }

    /// A gap is a gap. `.claude/skills/ui.md`: "A missed day is a plain gap." The
    /// engine has to agree with the spine about that, or the certificate claims
    /// something the screen never showed.
    @Test("A missed day breaks the run, and the count restarts")
    func aGapBreaksTheStreak() throws {
        var events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 10)
        // Remove day 5 entirely — a day the user never opened the app.
        events = events.filter { $0.day != day("2026-01-05") || $0.kind != .checkedIn }
        events = try chained(events)

        let result = try AchievementEngineTests.evaluate(
            events, [AchievementEngineTests.streakRule(threshold: 7)]
        )
        // Days 6..10 is five, days 1..4 is four. Neither reaches seven.
        #expect(result.awarded.isEmpty)
    }

    /// `total` counts the first `threshold` qualifying days and stops. The claim
    /// is "N days recorded", made on the day the Nth was — not on the latest day
    /// in the log.
    @Test("A total is earned on the day the count reached the threshold")
    func totalEarnsOnTheDayTheCountLanded() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 20)
        let result = try AchievementEngineTests.evaluate(
            events, [AchievementEngineTests.totalRule(threshold: 10)]
        )
        let award = try #require(result.awarded.first)
        #expect(award.earnedOn == day("2026-01-10"))
        #expect(award.witness.dayCount == 10)
        #expect(award.facts[.total] == .int(10))
    }

    /// Unlike a streak, a total does not care about gaps.
    @Test("A total counts days that are not consecutive")
    func totalIgnoresGaps() throws {
        var events = [event(.habitCreated, habit: habitA, on: day("2026-01-01"), lamport: 1)]
        for (index, offset) in [0, 2, 4, 6, 8].enumerated() {
            events.append(
                event(
                    .checkedIn, habit: habitA, on: day("2026-01-01").adding(offset),
                    lamport: 10 + index, source: .tap
                )
            )
        }
        let result = try AchievementEngineTests.evaluate(
            try chained(events), [AchievementEngineTests.totalRule(threshold: 5)]
        )
        #expect(result.awarded.first?.earnedOn == day("2026-01-09"))
    }

    /// `Scope(habit: nil, requiresAll: true)` is the question the 28-dot spine
    /// asks, and it must be judged against the habits active **on that day** —
    /// never against today's set. A day before any habit existed is a gap, not a
    /// day on which everything was done: `allSatisfy` over an empty set is `true`,
    /// and that is the trap.
    @Test("An all-habits rule needs every habit that was tracked that day")
    func allHabitsScopeJudgesEachDayAgainstThatDay() throws {
        var events = [
            event(.habitCreated, habit: habitA, on: day("2026-01-01"), lamport: 1),
            event(.habitCreated, habit: habitB, on: day("2026-01-03"), lamport: 2),
        ]
        // Days 1 and 2: only habit A exists, and it is done — those days qualify.
        // Days 3 and 4: both exist; only day 4 has both done.
        events.append(
            event(.checkedIn, habit: habitA, on: day("2026-01-01"), lamport: 10, source: .tap))
        events.append(
            event(.checkedIn, habit: habitA, on: day("2026-01-02"), lamport: 11, source: .tap))
        events.append(
            event(.checkedIn, habit: habitA, on: day("2026-01-03"), lamport: 12, source: .tap))
        events.append(
            event(.checkedIn, habit: habitA, on: day("2026-01-04"), lamport: 13, source: .tap))
        events.append(
            event(.checkedIn, habit: habitB, on: day("2026-01-04"), lamport: 14, source: .tap))

        let rule = RuleSpec(
            id: RuleID(rawValue: "total.complete.3"), kind: .total,
            scope: .allHabits, threshold: 3
        )
        let result = try AchievementEngineTests.evaluate(try chained(events), [rule])

        // Qualifying: 01-01, 01-02 (A only exists), 01-04 (both done). 01-03 has
        // B tracked and not done. Three days, so the award lands on 01-04.
        let award = try #require(result.awarded.first)
        #expect(award.earnedOn == day("2026-01-04"))
        #expect(award.witness.dayCount == 3)
    }

    // MARK: Purity, idempotence, re-runnability — §9.1 to §9.3

    /// §9.2. The precondition for retroactive edits and rule backfill: the engine
    /// is safely re-runnable an unlimited number of times.
    @Test("Re-running over the same log awards nothing a second time")
    func firesExactlyOnceEver() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 40)
        let rules = [
            AchievementEngineTests.streakRule(threshold: 7),
            AchievementEngineTests.streakRule(threshold: 30),
        ]

        let first = try AchievementEngineTests.evaluate(events, rules)
        #expect(first.awarded.count == 2)

        let second = try AchievementEngineTests.evaluate(
            events, rules, recorded: Set(first.awarded.map(\.id))
        )
        #expect(second.awarded.isEmpty)
        // Still earned — what changed is only that it is already recorded. That
        // distinction is what revocation is computed from.
        #expect(second.earned == first.earned)
    }

    /// §9.1: "Same inputs, bit-identical outputs." Asserted on the **digest**,
    /// because that is the quantity the whole apparatus rests on — an engine
    /// whose two runs agreed about the day and disagreed about the evidence root
    /// would pass a weaker test and produce two different signatures.
    @Test("Two runs over one log produce byte-identical records")
    func isBitIdenticalAcrossRuns() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 30)
        let rules = [AchievementEngineTests.streakRule(threshold: 30)]

        let first = try AchievementEngineTests.evaluate(events, rules)
        let second = try AchievementEngineTests.evaluate(events, rules)

        #expect(
            try first.awarded.map { hex(try $0.digest) }
                == second.awarded.map { hex(try $0.digest) }
        )
    }

    /// The engine is handed a log, and the order a log arrives in is not a
    /// promise — `docs/technical.md` §7 requires permuted arrival to produce an
    /// identical result, and the total order is `(lamport, device)`, never
    /// wall-clock. The fixture's `recordedAt` descends as `lamport` ascends, so
    /// anything reaching for the clock fails here rather than passing by luck.
    @Test("A shuffled log produces the identical award, digest and all")
    func isInvariantUnderArrivalOrder() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 30)
        let rules = [AchievementEngineTests.streakRule(threshold: 30)]

        var generator = SeededGenerator(seed: 20_260_801)
        let shuffled = events.shuffled(using: &generator)

        #expect(
            try AchievementEngineTests.evaluate(events, rules).awarded.map {
                hex(try $0.digest)
            }
                == AchievementEngineTests.evaluate(shuffled, rules).awarded.map {
                    hex(try $0.digest)
                }
        )
    }

    /// The rules arrive from a directory listing, which is not an order.
    @Test("Rule order does not change what is awarded")
    func isInvariantUnderRuleOrder() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 40)
        let rules = [
            AchievementEngineTests.streakRule(threshold: 30),
            AchievementEngineTests.streakRule(threshold: 7),
            AchievementEngineTests.totalRule(threshold: 10),
        ]
        let forwards = try AchievementEngineTests.evaluate(events, rules)
        let backwards = try AchievementEngineTests.evaluate(events, rules.reversed())
        #expect(forwards.awarded.map(\.id) == backwards.awarded.map(\.id))
    }

    // MARK: Unknown kinds — §5.1

    /// "An evaluator MUST skip an unknown `RuleKind` with a warning and MUST
    /// leave the rule file on disk untouched. An older build never destroys rules
    /// it does not understand."
    @Test("An unimplemented rule kind is skipped, reported, and awards nothing")
    func skipsUnknownKinds() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 40)
        let reserved = RuleSpec(
            id: RuleID(rawValue: "rate.habit-a.5of7"), kind: .rateInWindow,
            scope: Scope(habit: habitA), threshold: 5, window: 7, requires: 5
        )
        let fromTheFuture = RuleSpec(
            id: RuleID(rawValue: "phase.of.the.moon"),
            kind: RuleKind(rawValue: "lunar"), scope: Scope(), threshold: 1
        )

        let result = try AchievementEngineTests.evaluate(
            events, [reserved, fromTheFuture, AchievementEngineTests.streakRule(threshold: 7)]
        )

        #expect(result.awarded.count == 1)
        #expect(Set(result.skipped) == [reserved.id, fromTheFuture.id])
    }

    // MARK: What is inside the record — §3.4

    /// **The single most consequential assertion in this suite.** §3.4: a habit's
    /// display name written into `facts` can never be taken back — the record is
    /// immutable, the digest is signed, and the anchor is Bitcoin. This checks the
    /// whole byte string rather than one field, because the failure it guards is
    /// a name reaching *any* digested position.
    @Test("No habit display name appears anywhere in the sealed bytes")
    func theRecordNeverCarriesADisplayName() throws {
        var events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 10)
        events.append(
            event(.habitRenamed, habit: habitA, lamport: 500, name: "Narcotics Anonymous")
        )
        events = try chained(events)

        let result = try AchievementEngineTests.evaluate(
            events, [AchievementEngineTests.streakRule(threshold: 7)]
        )
        let award = try #require(result.awarded.first)
        let bytes = String(decoding: try award.canonicalBytes, as: UTF8.self)

        #expect(!bytes.contains("Narcotics"))
        #expect(!bytes.contains("Meditate"))
        #expect(award.facts[.habitID] == .string("habit-a"))
        // `facts["habit"]` is the deleted field. §10 lists it so it is not
        // reinvented; this is the assertion that it has not been.
        #expect(award.facts[FactKey(rawValue: "habit")] == nil)
    }

    /// §3.4: `source_live` and `source_backfill` are REQUIRED on every
    /// achievement derived from check-ins and **MUST sum to `witness.dayCount`**.
    /// Without the partition, a certificate over mostly backfilled days would be
    /// indistinguishable from one over live taps.
    @Test("source_live and source_backfill are present and sum to dayCount")
    func factsPartitionTheDayCount() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 30)
        let result = try AchievementEngineTests.evaluate(
            events,
            [
                AchievementEngineTests.streakRule(threshold: 30),
                AchievementEngineTests.totalRule(threshold: 10),
            ]
        )
        #expect(result.awarded.count == 2)

        for award in result.awarded {
            guard case .int(let live)? = award.facts[.sourceLive],
                  case .int(let backfill)? = award.facts[.sourceBackfill]
            else {
                Issue.record("a v1 award is missing the source partition")
                return
            }
            #expect(live + backfill == award.witness.dayCount)
            // v1 ships no backfill surface, so every day is live — and the `0` is
            // sealed rather than omitted, because "no day was backfilled" and "we
            // did not record whether any day was backfilled" are different claims.
            #expect(backfill == 0)
        }
    }

    // MARK: The witness — §4

    /// `evidenceRoot` pins exactly which events were counted. Two claims made
    /// over different evidence must not carry the same root, or a post-hoc
    /// revocation could not be honest about what it reversed.
    @Test("Two records over different evidence carry different roots")
    func evidenceRootIsSpecificToTheRecord() throws {
        let first = try AchievementEngineTests.evaluate(
            try AchievementEngineTests.run(from: day("2026-01-01"), count: 7),
            [AchievementEngineTests.streakRule(threshold: 7)]
        )
        let second = try AchievementEngineTests.evaluate(
            try AchievementEngineTests.run(from: day("2026-02-01"), count: 7),
            [AchievementEngineTests.streakRule(threshold: 7)]
        )
        #expect(first.awarded[0].witness.evidenceRoot != second.awarded[0].witness.evidenceRoot)
        #expect(first.awarded[0].witness.evidenceRoot.count == 32)
    }

    /// §4: `logHeads` commits to the whole history as of detection, and it is
    /// per **writer**, not per phone — the app process and the widget process are
    /// two writers with two chains.
    @Test("logHeads carries one head per writer")
    func witnessCommitsToEveryWritersChain() throws {
        var events = [event(.habitCreated, habit: habitA, on: day("2026-01-01"), lamport: 1)]
        for offset in 0..<7 {
            events.append(
                event(
                    .checkedIn, habit: habitA, on: day("2026-01-01").adding(offset),
                    lamport: 10 + offset,
                    device: offset.isMultiple(of: 2) ? deviceApp : deviceWidget,
                    source: offset.isMultiple(of: 2) ? .tap : .widget
                )
            )
        }
        let result = try AchievementEngineTests.evaluate(
            try chained(events), [AchievementEngineTests.streakRule(threshold: 7)]
        )
        let heads = try #require(result.awarded.first).witness.logHeads
        #expect(Set(heads.keys) == [deviceApp.rawValue, deviceWidget.rawValue])
        #expect(heads.values.allSatisfy { $0.count == 32 })
    }

    // MARK: Revocation — §8

    /// The whole reason revocation exists: the user un-checks a day the claim
    /// depended on, and the claim stops being true.
    @Test("Un-checking a counted day removes the claim from what the log supports")
    func anUncheckedDayEndsTheClaim() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 7)
        let rules = [AchievementEngineTests.streakRule(threshold: 7)]

        let awarded = try AchievementEngineTests.evaluate(events, rules)
        let id = try #require(awarded.awarded.first).id

        var edited = events
        edited.append(
            event(.checkInRevoked, habit: habitA, on: day("2026-01-04"), lamport: 900)
        )
        let after = try AchievementEngineTests.evaluate(
            try chained(edited), rules, recorded: [id]
        )

        #expect(!after.earned.contains(id))

        let revocations = AchievementEngine.revocations(
            forRecorded: [id], notIn: after.earned, alreadyRevoked: [],
            at: AchievementEngineTests.detected, logHeads: after.logHeads
        )
        #expect(revocations.count == 1)
        #expect(revocations.first?.achievement == id)
        #expect(revocations.first?.reason == Revocation.dependedOnDayEdited)
    }

    /// A claim that stopped being true does not produce a fresh reversal on every
    /// launch thereafter. `awards.jsonl` is append-only and never compacted, so a
    /// reversal per launch is a file that grows forever.
    @Test("A claim already reversed is not reversed again")
    func revocationHappensOnce() throws {
        let id = AchievementID(rawValue: "streak.habit-a.7@2026-01-07")
        let repeated = AchievementEngine.revocations(
            forRecorded: [id], notIn: [], alreadyRevoked: [id],
            at: AchievementEngineTests.detected, logHeads: [:]
        )
        #expect(repeated.isEmpty)
    }

    /// §9.4 and §8: "An achievement is **never** silently recomputed away because
    /// a rule changed. The frozen `rule` copy is what guarantees this."
    @Test("The record carries the whole rule, so deleting the rule cannot un-award it")
    func theRuleIsFrozenOntoTheRecord() throws {
        let events = try AchievementEngineTests.run(from: day("2026-01-01"), count: 7)
        let rule = AchievementEngineTests.streakRule(threshold: 7)
        let award = try #require(
            try AchievementEngineTests.evaluate(events, [rule]).awarded.first
        )
        #expect(award.rule == rule)

        // The rule is gone from the shipped set. The record still renders and
        // still verifies, because it is not a foreign key.
        #expect(try award.digest.count == 32)
        #expect(award.rule.threshold == 7)
        #expect(award.rule.kind == .streak)
    }

    // MARK: The fold and the engine must agree about what "checked" means

    /// ``QualifyingLog`` resolves the `(habit, day)` cell in `(lamport, device)`
    /// order, which is the same last-writer-wins rule ``Projection`` applies. That
    /// is one rule written twice, and this is what holds the two together: if they
    /// ever diverge, a certificate would commit to evidence the screen never
    /// showed.
    @Test("The engine's cells are exactly the projection's checked days")
    func theEngineAndTheFoldAgree() throws {
        let events = corpus()
        let log = QualifyingLog(events: events)
        let folded = project(events)

        #expect(!folded.habits.isEmpty)
        for (id, habit) in folded.habits {
            #expect(log.checkedDays(of: id) == habit.checkedDays, "\(id) disagrees")
        }
    }

    // MARK: The 72-hour hold — §7.1

    /// "This MUST NOT happen until **72 hours after `detectedAt`**." Signing
    /// immediately and publishing late is what gives both properties: the local
    /// record cannot be silently altered, and nothing irreversible has been
    /// published that the user might want to take back.
    @Test("Nothing may be submitted for anchoring inside 72 hours of detection")
    func theProvisionalWindowHolds() {
        let detected = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!AnchorSchedule.maySubmit(detectedAt: detected, now: detected))
        #expect(
            !AnchorSchedule.maySubmit(
                detectedAt: detected, now: detected.addingTimeInterval(71 * 3600)
            )
        )
        #expect(
            !AnchorSchedule.maySubmit(
                detectedAt: detected, now: detected.addingTimeInterval(72 * 3600 - 1)
            )
        )
        #expect(
            AnchorSchedule.maySubmit(
                detectedAt: detected, now: detected.addingTimeInterval(72 * 3600)
            )
        )
    }
}
