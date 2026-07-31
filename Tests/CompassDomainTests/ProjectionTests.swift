import Foundation
import Testing

@testable import CompassDomain

@Suite("Projection — the fold")
struct ProjectionFoldTests {

    @Test("A check-in marks the day done")
    func checkIn() {
        let projection = project([
            event(.checkedIn, habit: habitA, on: day("2026-07-31"), lamport: 1, source: .tap)
        ])
        #expect(projection.isChecked(habitA, on: day("2026-07-31")))
        #expect(projection.status(habitA, on: day("2026-07-31")) == .done)
        #expect(projection.status(habitA, on: day("2026-07-30")) == .missed)
    }

    @Test("Un-checking appends a compensating event, and the fold resolves to unchecked")
    func checkInThenRevoke() {
        let target = day("2026-07-31")
        let events = [
            event(.checkedIn, habit: habitA, on: target, lamport: 1, source: .tap),
            event(.checkInRevoked, habit: habitA, on: target, lamport: 2),
        ]
        let projection = project(events)

        #expect(!projection.isChecked(habitA, on: target))
        #expect(projection.status(habitA, on: target) == .missed)
        // Nothing was deleted: both events are still in the log.
        #expect(events.count == 2)
        #expect(projection.totalCheckedDays == 0)
    }

    @Test("Re-checking after a revoke wins, because it is the later writer")
    func revokeThenCheckIn() {
        let target = day("2026-07-31")
        let projection = project([
            event(.checkedIn, habit: habitA, on: target, lamport: 1, source: .tap),
            event(.checkInRevoked, habit: habitA, on: target, lamport: 2),
            event(.checkedIn, habit: habitA, on: target, lamport: 3, source: .tap),
        ])
        #expect(projection.isChecked(habitA, on: target))
    }

    @Test("A revoke only touches its own (habit, day) cell")
    func revokeIsScopedToOneCell() {
        let projection = project([
            event(.checkedIn, habit: habitA, on: day("2026-07-30"), lamport: 1),
            event(.checkedIn, habit: habitA, on: day("2026-07-31"), lamport: 2),
            event(.checkedIn, habit: habitB, on: day("2026-07-31"), lamport: 3),
            event(.checkInRevoked, habit: habitA, on: day("2026-07-31"), lamport: 4),
        ])
        #expect(projection.isChecked(habitA, on: day("2026-07-30")))
        #expect(!projection.isChecked(habitA, on: day("2026-07-31")))
        #expect(projection.isChecked(habitB, on: day("2026-07-31")))
    }

    @Test("Toggling twice in one day leaves the day unchecked")
    func doubleToggle() {
        let target = day("2026-07-31")
        var projection = Projection()
        projection.apply(event(.checkedIn, habit: habitA, on: target, lamport: 1, source: .tap))
        #expect(projection.isChecked(habitA, on: target))
        projection.apply(event(.checkInRevoked, habit: habitA, on: target, lamport: 2))
        #expect(!projection.isChecked(habitA, on: target))
    }

    @Test("Renaming is cosmetic: it changes the name and nothing else")
    func renameIsCosmetic() {
        let base = [
            event(.habitCreated, habit: habitA, lamport: 1, name: "Meditate"),
            event(.checkedIn, habit: habitA, on: day("2026-07-30"), lamport: 2),
            event(.checkedIn, habit: habitA, on: day("2026-07-31"), lamport: 3),
        ]
        let renamed = base + [event(.habitRenamed, habit: habitA, lamport: 4, name: "Sit still")]

        let before = project(base)
        let after = project(renamed)

        #expect(before.habit(habitA)?.name == "Meditate")
        #expect(after.habit(habitA)?.name == "Sit still")
        #expect(before.habit(habitA)?.checkedDays == after.habit(habitA)?.checkedDays)
        #expect(before.totalCheckedDays == after.totalCheckedDays)
    }

    @Test("Archiving and un-archiving are last-writer-wins too")
    func archival() {
        let archived = project([
            event(.habitCreated, habit: habitB, lamport: 1, name: "Read"),
            event(.habitArchived, habit: habitB, on: day("2026-07-20"), lamport: 2),
        ])
        #expect(archived.habit(habitB)?.isArchived == true)
        #expect(archived.activeHabits.isEmpty)

        let unarchived = project([
            event(.habitCreated, habit: habitB, lamport: 1, name: "Read"),
            event(.habitArchived, habit: habitB, on: day("2026-07-20"), lamport: 2),
            event(.habitUnarchived, habit: habitB, on: day("2026-07-21"), lamport: 3),
        ])
        #expect(unarchived.habit(habitB)?.isArchived == false)
        #expect(unarchived.activeHabits.map(\.id) == [habitB])
    }

    @Test("Achievement events carry no habit state and are ignored by the v1 fold")
    func achievementEventsAreInert() {
        let withoutAwards = project(corpus().filter {
            $0.kind != .achievementAwarded && $0.kind != .achievementRevoked
        })
        #expect(serialise(project(corpus())) == serialise(withoutAwards))
    }

    @Test("Total days is computed from the per-habit shards, not accumulated")
    func totalDays() {
        let projection = project(corpus())
        let byHand = projection.habits.values.reduce(0) { $0 + $1.checkedDays.count }
        #expect(projection.totalCheckedDays == byHand)
        #expect(projection.totalCheckedDays > 0)
    }

    /// The additive claim, as a test. A kind added later must leave the habit
    /// fold exactly as it was — which is also what an older build does with it,
    /// since both reach the same `default:` branch.
    @Test("A subjectNamed declaration is inert in the habit fold")
    func declarationsAreInertHere() {
        let withoutDeclarations = project(corpus().filter { $0.kind != .subjectNamed })
        #expect(serialise(project(corpus())) == serialise(withoutDeclarations))
        #expect(project(corpus()) == withoutDeclarations)
    }
}

/// Habit rows appear in the order the habits were created.
///
/// Until habits could be added this was the byte order of the `HabitID`, which
/// was invisible while every ID was a seed constant and became wrong the moment
/// the settings sheet could mint one: an ID is opaque on purpose, so sorting by
/// it put a habit added this afternoon wherever random hex landed.
@Suite("Projection — habits are ordered by creation")
struct ProjectionOrderTests {

    private let late = HabitID(rawValue: "a-created-second")
    private let early = HabitID(rawValue: "z-created-first")

    @Test("Creation order beats identifier order")
    func creationOrderWins() {
        let projection = project([
            event(.habitCreated, habit: early, lamport: 1, name: "First"),
            event(.habitCreated, habit: late, lamport: 2, name: "Second"),
        ])

        // The identifiers sort the other way round, so this cannot pass by
        // coincidence.
        #expect(late < early)
        #expect(projection.activeHabits.map(\.name) == ["First", "Second"])
    }

    @Test("The order does not depend on the order the events arrive in")
    func orderIsPermutationInvariant() {
        let events = [
            event(.habitCreated, habit: early, lamport: 1, name: "First"),
            event(.habitCreated, habit: late, lamport: 2, name: "Second"),
        ]
        #expect(project(events.reversed()).activeHabits.map(\.name) == ["First", "Second"])
    }

    @Test("Renaming a habit does not move it")
    func renamingDoesNotReorder() {
        let projection = project([
            event(.habitCreated, habit: early, lamport: 1, name: "First"),
            event(.habitCreated, habit: late, lamport: 2, name: "Second"),
            event(.habitRenamed, habit: early, lamport: 3, name: "Still first"),
        ])
        #expect(projection.activeHabits.map(\.name) == ["Still first", "Second"])
    }

    /// A habit that was only ever checked into or renamed — its creation is on a
    /// chain this build has not seen, or the log is damaged — has no honest
    /// position, so it goes last rather than to the top.
    ///
    /// **Only a creation establishes creation order.** The rename case is the one
    /// worth writing down: a rename is cosmetic and carries the same
    /// `{"habitID","name"}` payload as a creation, so the cheap way to write the
    /// fold is to treat both alike — and then a habit renamed before this build
    /// ever saw it created jumps the queue.
    @Test("A habit with no creation event sorts last, renamed or not")
    func uncreatedHabitsSortLast() {
        let checkedIntoOnly = HabitID(rawValue: "a-checked-into")
        let renamedOnly = HabitID(rawValue: "b-renamed")
        let projection = project([
            event(.habitRenamed, habit: renamedOnly, lamport: 1, name: "Renamed"),
            event(.habitCreated, habit: early, lamport: 2, name: "Created"),
            event(
                .checkedIn, habit: checkedIntoOnly, on: day("2026-07-31"),
                lamport: 3, source: .tap
            ),
        ])
        #expect(projection.activeHabits.first?.id == early)
        #expect(Set(projection.activeHabits.dropFirst().map(\.id))
            == [checkedIntoOnly, renamedOnly])
    }

    /// Two creations for one habit is what a merge produces, and the register
    /// keeps the **earliest** — first writer wins, the only register in the fold
    /// that does. "When was this habit created" has one honest answer and a later
    /// duplicate is not it.
    ///
    /// Every other test here gives each habit exactly one creation, where a
    /// minimum and a maximum are indistinguishable.
    @Test("A duplicate creation does not move a habit")
    func theEarliestCreationWins() {
        let events = [
            event(.habitCreated, habit: early, lamport: 1, name: "First"),
            event(.habitCreated, habit: late, lamport: 2, name: "Second"),
            // The same habit created again, later — a merge, or a log carrying
            // both writers' views of the same seed.
            event(.habitCreated, habit: early, lamport: 3, name: "First"),
        ]

        #expect(project(events).activeHabits.map(\.name) == ["First", "Second"])
        #expect(project(events.reversed()).activeHabits.map(\.name) == ["First", "Second"])

        // And through a merge of per-habit shards, which is the path that
        // actually produces it.
        let shardEarly = project(events.filter { $0.payload.habitID == early })
        let shardLate = project(events.filter { $0.payload.habitID == late })
        #expect(shardEarly.merging(shardLate).activeHabits.map(\.name) == ["First", "Second"])
        #expect(shardLate.merging(shardEarly).activeHabits.map(\.name) == ["First", "Second"])
    }
}

/// The four-habit cap, enforced on **active** habits.
@Suite("Projection — the four-habit cap")
struct ProjectionCapTests {

    private func creations(_ count: Int) -> [Event] {
        (1...count).map {
            event(
                .habitCreated,
                habit: HabitID(rawValue: "h-\($0)"),
                lamport: $0,
                name: "Habit \($0)"
            )
        }
    }

    @Test("Four is the cap")
    func fourIsTheCap() {
        #expect(Projection.habitCap == 4)
        #expect(project(creations(3)).mayCreateHabit)
        #expect(!project(creations(4)).mayCreateHabit)
    }

    /// The rule that makes removal non-destructive workable: a removed habit is
    /// still in the log and still in the projection, and it does not hold a slot.
    @Test("An archived habit does not count towards the cap and is not gone")
    func archivedHabitsDoNotCount() {
        let archived = creations(4) + [
            event(.habitArchived, habit: HabitID(rawValue: "h-2"), lamport: 5)
        ]
        let projection = project(archived)

        #expect(projection.mayCreateHabit)
        #expect(projection.activeHabits.count == 3)
        #expect(projection.archivedHabits.map(\.id) == [HabitID(rawValue: "h-2")])
        // Not deleted. Still there, still named, still holding its own days.
        #expect(projection.habits.count == 4)
        #expect(projection.habit(HabitID(rawValue: "h-2"))?.name == "Habit 2")
    }

    @Test("Archiving a habit keeps every day it recorded")
    func archivingKeepsTheDays() {
        let events = [
            event(.habitCreated, habit: habitA, lamport: 1, name: "Move"),
            event(.checkedIn, habit: habitA, on: day("2026-07-30"), lamport: 2, source: .tap),
            event(.checkedIn, habit: habitA, on: day("2026-07-31"), lamport: 3, source: .tap),
        ]
        let before = project(events)
        let after = project(events + [event(.habitArchived, habit: habitA, lamport: 4)])

        #expect(before.totalCheckedDays == 2)
        #expect(after.totalCheckedDays == 2)
        #expect(after.habit(habitA)?.checkedDays == before.habit(habitA)?.checkedDays)
        #expect(after.activeHabits.isEmpty)
    }
}

/// The optional, self-declared, unverified name for the record.
///
/// `docs/open-questions.md` option (b), chosen by the owner on 2026-07-31. It is
/// a second fold, deliberately outside `Projection`, over the same log.
@Suite("SubjectName — the declared subject")
struct SubjectNameTests {

    private func declaration(_ name: String, lamport: Int, device: DeviceID = deviceApp) -> Event {
        event(.subjectNamed, lamport: lamport, device: device, payload: .subject(named: name))
    }

    @Test("Nothing is declared by default")
    func emptyByDefault() {
        #expect(declaredSubject([]).value == "")
        #expect(declaredSubject([]).value.isEmpty)
        #expect(SubjectName().value == "")
    }

    @Test("A declaration is what the fold reads")
    func aDeclaration() {
        let subject = declaredSubject([declaration("Farros Hilmi Syafei", lamport: 1)])
        #expect(subject.value == "Farros Hilmi Syafei")
        #expect(!subject.value.isEmpty)
    }

    @Test("Last writer wins under the total order, in either arrival order")
    func lastWriterWins() {
        let early = declaration("first", lamport: 1)
        let late = declaration("second", lamport: 2)

        // The fixture's `recordedAt` descends with `lamport`, so anything that
        // reaches for wall-clock time fails here rather than passing by luck.
        #expect(late.recordedAt < early.recordedAt)
        #expect(declaredSubject([early, late]).value == "second")
        #expect(declaredSubject([late, early]).value == "second")
    }

    @Test("At an equal lamport the device breaks the tie deterministically")
    func deviceBreaksTheTie() {
        let fromApp = declaration("app", lamport: 5, device: deviceApp)
        let fromWidget = declaration("widget", lamport: 5, device: deviceWidget)

        #expect(declaredSubject([fromApp, fromWidget]).value == "widget")
        #expect(declaredSubject([fromWidget, fromApp]).value == "widget")
    }

    /// Withdrawing is a declaration of nothing, appended. It is not an erasure:
    /// both events stay in the log, and anything sealed while the name stood
    /// keeps the name.
    @Test("An empty name withdraws the declaration without deleting anything")
    func withdrawal() {
        let events = [declaration("Farros", lamport: 1), declaration("", lamport: 2)]
        let subject = declaredSubject(events)

        #expect(subject.value == "")
        #expect(subject.value.isEmpty)
        #expect(events.count == 2)
        #expect(declaredSubject([events[0]]).value == "Farros")
    }

    @Test("Every other kind is ignored, including one this build has never seen")
    func otherKindsAreIgnored() {
        let noise = corpus().filter { $0.kind != .subjectNamed } + [
            event(EventKind(rawValue: "somethingFromTheFuture"), lamport: 999, name: "Imposter")
        ]
        #expect(declaredSubject(noise).value == "")
    }

    @Test("Applying the same declarations twice, or shuffled, changes nothing")
    func deterministic() {
        let events = corpus()
        let once = declaredSubject(events)

        #expect(declaredSubject(events + events) == once)
        for seed in UInt64(1)...UInt64(25) {
            var generator = SeededGenerator(seed: seed)
            #expect(declaredSubject(events.shuffled(using: &generator)) == once, "seed \(seed)")
        }
    }
}

@Suite("Projection — ordering is (lamport, device), never wall-clock")
struct ProjectionOrderingTests {

    @Test("A revoke with a higher lamport wins even though its clock reads earlier")
    func lamportBeatsAnEarlierClock() {
        let target = day("2026-07-31")
        let checkIn = event(
            .checkedIn, habit: habitA, on: target, lamport: 1,
            recordedAt: 2_000_000_000_000, source: .tap
        )
        let revoke = event(
            .checkInRevoked, habit: habitA, on: target, lamport: 2,
            recordedAt: 1_000  // NTP correction, or the user changed the clock
        )

        #expect(revoke.recordedAt < checkIn.recordedAt)
        #expect(!project([checkIn, revoke]).isChecked(habitA, on: target))
        #expect(!project([revoke, checkIn]).isChecked(habitA, on: target))
    }

    @Test("A check-in with a higher lamport wins even though its clock reads earlier")
    func theMirrorCase() {
        let target = day("2026-07-31")
        let revoke = event(
            .checkInRevoked, habit: habitA, on: target, lamport: 1,
            recordedAt: 2_000_000_000_000
        )
        let checkIn = event(
            .checkedIn, habit: habitA, on: target, lamport: 2,
            recordedAt: 1_000, source: .tap
        )

        #expect(checkIn.recordedAt < revoke.recordedAt)
        #expect(project([revoke, checkIn]).isChecked(habitA, on: target))
        #expect(project([checkIn, revoke]).isChecked(habitA, on: target))
    }

    @Test("At an equal lamport the device breaks the tie deterministically")
    func deviceBreaksTheTie() {
        let target = day("2026-07-31")
        // The widget's UUID sorts after the app's, so the widget's write wins.
        let revokeFromApp = event(
            .checkInRevoked, habit: habitA, on: target, lamport: 5, device: deviceApp
        )
        let checkInFromWidget = event(
            .checkedIn, habit: habitA, on: target, lamport: 5,
            device: deviceWidget, source: .widget
        )

        #expect(project([revokeFromApp, checkInFromWidget]).isChecked(habitA, on: target))
        #expect(project([checkInFromWidget, revokeFromApp]).isChecked(habitA, on: target))
    }

    @Test("The tie is broken the other way when the loser is the widget")
    func deviceTieTheOtherWay() {
        let target = day("2026-07-31")
        let checkInFromApp = event(
            .checkedIn, habit: habitA, on: target, lamport: 5, device: deviceApp, source: .tap
        )
        let revokeFromWidget = event(
            .checkInRevoked, habit: habitA, on: target, lamport: 5, device: deviceWidget
        )

        #expect(!project([checkInFromApp, revokeFromWidget]).isChecked(habitA, on: target))
        #expect(!project([revokeFromWidget, checkInFromApp]).isChecked(habitA, on: target))
    }

    @Test("The name register is last-writer-wins under the same total order")
    func nameIsLastWriterWins() {
        let early = event(.habitRenamed, habit: habitA, lamport: 1, name: "first")
        let late = event(.habitRenamed, habit: habitA, lamport: 2, name: "second")

        #expect(project([early, late]).habit(habitA)?.name == "second")
        #expect(project([late, early]).habit(habitA)?.name == "second")
    }
}

@Suite("Projection — determinism")
struct ProjectionDeterminismTests {

    @Test("Replay parity: replaying twice yields byte-identical serialised state")
    func replayParity() {
        let events = corpus()
        #expect(serialise(project(events)) == serialise(project(events)))
        #expect(project(events) == project(events))
    }

    @Test("Shard invariance: fold by habit, merge, and the result equals the whole")
    func shardInvariance() {
        let events = corpus()
        let whole = project(events)

        var shardIDs: [HabitID] = []
        for candidate in events.compactMap({ $0.payload.habitID }) where !shardIDs.contains(candidate) {
            shardIDs.append(candidate)
        }
        #expect(shardIDs.count >= 2, "the corpus must exercise more than one shard")

        var merged = Projection()
        for id in shardIDs {
            merged.merge(project(events.filter { $0.payload.habitID == id }))
        }
        // Events with no habit at all — the achievement records — are their own shard.
        merged.merge(project(events.filter { $0.payload.habitID == nil }))

        #expect(serialise(merged) == serialise(whole))
        #expect(merged == whole)
    }

    @Test("Merging shards in the reverse order gives the same answer")
    func shardMergeIsCommutative() {
        let events = corpus()
        let shardA = project(events.filter { $0.payload.habitID == habitA })
        let shardB = project(events.filter { $0.payload.habitID == habitB })

        #expect(serialise(shardA.merging(shardB)) == serialise(shardB.merging(shardA)))
    }

    @Test("Shuffle invariance: a permuted arrival order projects identically")
    func shuffleInvariance() {
        let events = corpus()
        let expected = serialise(project(events))

        for seed in UInt64(1)...UInt64(25) {
            var generator = SeededGenerator(seed: seed)
            let shuffled = events.shuffled(using: &generator)
            #expect(serialise(project(shuffled)) == expected, "seed \(seed) diverged")
        }
    }

    @Test("Incremental apply equals a from-zero rebuild")
    func incrementalEqualsFullReplay() {
        let events = corpus()
        var incremental = Projection()
        for (index, event) in events.enumerated() {
            incremental.apply(event)
            let rebuilt = project(Array(events.prefix(index + 1)))
            #expect(serialise(incremental) == serialise(rebuilt), "diverged at event \(index)")
        }
        #expect(incremental == project(events))
    }

    @Test("Applying the same event twice changes nothing")
    func idempotent() {
        let events = corpus()
        let once = project(events)
        let twice = project(events + events)
        #expect(serialise(once) == serialise(twice))
        #expect(once == twice)
    }
}
