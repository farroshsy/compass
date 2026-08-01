import Foundation
import Testing

@testable import CompassDomain

/// The disposable launch cache. `docs/technical.md` §4 and §6.
///
/// Everything here is about one property: the cache may be **wrong in no way
/// that survives a moment**, and it may be **stale in no way that shows a wrong
/// screen**. It is allowed to be deleted, ignored and overwritten; it is not
/// allowed to lie.
@Suite("TodaySnapshot — the cache that is never the source of anything")
struct TodaySnapshotTests {

    private func log() -> [Event] {
        var events: [Event] = []
        var lamport = 0
        func next() -> Int { lamport += 1; return lamport }

        events.append(event(.habitCreated, habit: habitA, on: day("2026-07-01"),
                            lamport: next(), name: "Move"))
        events.append(event(.habitCreated, habit: habitB, on: day("2026-07-01"),
                            lamport: next(), name: "Read"))
        // Three days where both were done, then one where only Move was.
        for offset in 0..<3 {
            let d = day("2026-07-01").adding(offset)
            events.append(event(.checkedIn, habit: habitA, on: d, lamport: next(), source: .tap))
            events.append(event(.checkedIn, habit: habitB, on: d, lamport: next(), source: .tap))
        }
        events.append(event(.checkedIn, habit: habitA, on: day("2026-07-04"),
                            lamport: next(), source: .tap))
        events.append(event(.subjectNamed, lamport: next(), payload: .subject(named: "Farros")))
        return events
    }

    @Test("It folds the screen, and the strip ends on the day it describes")
    func foldsTheScreen() {
        let events = log()
        let snapshot = TodaySnapshot(
            projection: project(events), subject: declaredSubject(events),
            today: day("2026-07-04"), spineLength: 28
        )

        #expect(snapshot.day == day("2026-07-04"))
        #expect(snapshot.habits.map(\.name) == ["Move", "Read"])
        #expect(snapshot.habits.map(\.isChecked) == [true, false])
        #expect(snapshot.daysRecorded == 4)
        #expect(snapshot.dayIsRecorded)
        #expect(snapshot.firstRecordedDay == day("2026-07-01"))
        #expect(snapshot.declaredName == "Farros")

        // Three complete days, then a day only one habit was done on.
        #expect(snapshot.spine.count == 28)
        #expect(snapshot.spine.suffix(4) == [true, true, true, false])
        #expect(snapshot.spine.prefix(24).allSatisfy { !$0 })
    }

    @Test("It carries no lamport and no chain head, and must not acquire one")
    func carriesNothingAWriterNeeds() throws {
        // A disposable file that could hand a writer a `lamport` would be a
        // disposable file that can fork a chain. `docs/technical.md` §6 puts
        // this in the tier that may be deleted at any moment; nothing in that
        // tier may be load-bearing for the tier that cannot.
        let events = log()
        let snapshot = TodaySnapshot(
            projection: project(events), subject: declaredSubject(events),
            today: day("2026-07-04"), spineLength: 28
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains("lamport"))
        #expect(!text.contains("prev"))
        #expect(!text.contains("device"))
    }

    // MARK: Staleness

    @Test("Opening the app the next morning slides the strip and clears the row")
    func rollsForwardOneDay() throws {
        // The ordinary daily-driver case. A cache that were only valid on the
        // day it was written would be a cache that almost never hits.
        let events = log()
        let written = TodaySnapshot(
            projection: project(events), subject: declaredSubject(events),
            today: day("2026-07-04"), spineLength: 28
        )
        let rolled = try #require(written.rolledForward(to: day("2026-07-05")))

        #expect(rolled.day == day("2026-07-05"))
        #expect(rolled.habits.allSatisfy { !$0.isChecked })
        #expect(rolled.spine.suffix(5) == [true, true, true, false, false])

        // The totals do not move, because no day in between was recorded — if
        // one had been, a write would have happened and the cache would have
        // been rewritten.
        #expect(rolled.daysRecorded == written.daysRecorded)
        #expect(rolled.dayIsRecorded == false)
        #expect(rolled.firstRecordedDay == written.firstRecordedDay)
        #expect(rolled.declaredName == written.declaredName)
    }

    @Test("A gap longer than the strip leaves nothing but gaps")
    func rollsForwardPastTheWholeStrip() throws {
        let events = log()
        let written = TodaySnapshot(
            projection: project(events), subject: declaredSubject(events),
            today: day("2026-07-04"), spineLength: 28
        )
        let rolled = try #require(written.rolledForward(to: day("2026-09-04")))

        #expect(rolled.spine.allSatisfy { !$0 })
        #expect(rolled.daysRecorded == 4)
    }

    @Test("A clock that moved backwards is refused, not guessed at")
    func refusesToRollBackwards() {
        // `docs/technical.md` §3 refuses to sort by wall-clock precisely because
        // clocks move backwards — NTP corrections, manual changes. The honest
        // answer here is the same: fall back to the log rather than invent a
        // past.
        let events = log()
        let written = TodaySnapshot(
            projection: project(events), subject: declaredSubject(events),
            today: day("2026-07-04"), spineLength: 28
        )
        #expect(written.rolledForward(to: day("2026-07-03")) == nil)
        #expect(written.rolledForward(to: day("2026-07-04")) == written)
    }

    // MARK: Rehydration

    @Test("A rehydrated projection describes today, and says nothing about the past")
    func restoresTodayOnly() {
        let events = log()
        let today = day("2026-07-04")
        let snapshot = TodaySnapshot(
            projection: project(events), subject: declaredSubject(events),
            today: today, spineLength: 28
        )
        let restored = Projection.restored(from: snapshot)

        // What it does describe.
        #expect(restored.activeHabits.map(\.name) == ["Move", "Read"])
        #expect(restored.isChecked(habitA, on: today))
        #expect(!restored.isChecked(habitB, on: today))
        #expect(restored.mayCreateHabit)

        // What it does not, and must not be asked. `TodayModel` reads these
        // from the snapshot's own fields until the replay lands.
        #expect(restored.daysRecorded == 1)
        #expect(project(events).daysRecorded == 4)
    }

    @Test("A real event beats a rehydrated one, whatever its lamport")
    func aRealEventAlwaysWins() {
        // Every last-writer-wins register is left unset on rehydration, so the
        // first real event of any kind wins. An `EventOrder` invented for a
        // cache would be a claim about a write that never happened — and it
        // could beat a real one.
        let events = log()
        let today = day("2026-07-04")
        var restored = Projection.restored(
            from: TodaySnapshot(
                projection: project(events), subject: declaredSubject(events),
                today: today, spineLength: 28
            )
        )

        restored.apply(event(.checkInRevoked, habit: habitA, on: today, lamport: 1))
        #expect(!restored.isChecked(habitA, on: today))

        restored.apply(event(.habitRenamed, habit: habitA, lamport: 1, name: "Walk"))
        #expect(restored.habit(habitA)?.name == "Walk")
    }

    @Test("The declared name rehydrates, and the first real declaration overrides it")
    func restoresTheDeclaredName() {
        var subject = SubjectName(restoring: "Farros")
        #expect(subject.value == "Farros")

        subject.apply(event(.subjectNamed, lamport: 1, payload: .subject(named: "Someone else")))
        #expect(subject.value == "Someone else")
    }

    @Test("It round-trips through JSON")
    func roundTrips() throws {
        let events = log()
        let snapshot = TodaySnapshot(
            projection: project(events), subject: declaredSubject(events),
            today: day("2026-07-04"), spineLength: 28
        )
        let decoded = try JSONDecoder().decode(
            TodaySnapshot.self, from: try JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
    }
}
