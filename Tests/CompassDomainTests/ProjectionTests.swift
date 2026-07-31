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
