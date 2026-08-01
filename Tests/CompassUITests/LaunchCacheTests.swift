import CompassDomain
import Foundation
import Synchronization
import Testing

@testable import CompassUI

/// The launch path when a snapshot stands in for the log, and tap-path line 4.
/// `docs/technical.md` §4.
///
/// The cache is allowed to be deleted, ignored and overwritten. It is not
/// allowed to put a wrong number on the screen — and the number is the one thing
/// on this screen a person checks.
@MainActor
@Suite("The launch cache, on screen")
struct LaunchCacheTests {

    /// Four habits, twelve days of history, and today already half done.
    private func history() -> [Event] {
        var events = seededFour()
        var lamport = events.count
        func next() -> Int { lamport += 1; return lamport }

        // Twelve consecutive complete days, ending the day before "today".
        for offset in 0..<12 {
            let d = day("2026-07-19").adding(offset)
            for index in 0..<4 {
                events.append(
                    checkedIn(HabitID(rawValue: "habit-\(index)"), on: d.iso, lamport: next())
                )
            }
        }
        return events
    }

    private func snapshot(of events: [Event], on today: Day) -> TodaySnapshot {
        TodaySnapshot(
            projection: project(events), subject: declaredSubject(events),
            today: today, spineLength: TodaySnapshot.spineLength
        )
    }

    private func model(
        snapshot: TodaySnapshot?,
        events: [Event] = [],
        source: FakeSource = FakeSource(),
        recorder: FakeRecorder = FakeRecorder(),
        absorber: (any EventAbsorber)? = nil,
        at instant: String = "2026-07-31T09:00:00+07:00"
    ) -> TodayModel {
        TodayModel(
            events: events,
            clock: ScriptedClock(instant),
            recorder: recorder,
            source: source,
            snapshot: snapshot,
            absorber: absorber
        )
    }

    // MARK: The first frame

    @Test("The first frame comes from the cache, with no events read at all")
    func firstFrameFromTheCache() {
        let events = history()
        let subject = model(snapshot: snapshot(of: events, on: day("2026-07-31")))

        // Nothing was handed to it but the cache — `events` is empty, exactly as
        // the composition root leaves it when it does not decode the log.
        #expect(subject.habits.map(\.name) == ["Move", "Read", "Build", "Reflect"])
        #expect(subject.totalDays == 12)
        #expect(subject.firstRecordedDay == day("2026-07-19"))
        #expect(subject.spine.suffix(13) == Array(repeating: true, count: 12) + [false])
        #expect(subject.habits.allSatisfy { !subject.isChecked($0) })
    }

    @Test("A cache written yesterday still renders today, moved forward")
    func staleCacheIsMovedForward() {
        let events = history()
        // Written on the 30th; the app is opened on the 31st.
        let subject = model(snapshot: snapshot(of: events, on: day("2026-07-30")))

        #expect(subject.today == day("2026-07-31"))
        #expect(subject.totalDays == 12)
        #expect(subject.habits.allSatisfy { !subject.isChecked($0) })
        // Yesterday's dot is still filled, today's is a gap.
        #expect(subject.spine.suffix(2) == [true, false])
    }

    @Test("A cache from the future is refused, and the log renders the frame")
    func futureCacheIsRefused() {
        // A clock that moved backwards. `docs/technical.md` §3 refuses to sort
        // by wall-clock for the same reason, and the honest answer is the same:
        // trust the log.
        let events = history()
        let subject = model(snapshot: snapshot(of: events, on: day("2026-08-05")), events: events)

        #expect(subject.totalDays == 12)
        #expect(subject.habits.map(\.name) == ["Move", "Read", "Build", "Reflect"])
    }

    // MARK: A tap before the replay lands

    @Test("A tap in the window before the replay moves the number exactly")
    func tapBeforeTheReplayIsExact() {
        let events = history()
        let recorder = FakeRecorder(continuing: events)
        let subject = model(
            snapshot: snapshot(of: events, on: day("2026-07-31")), recorder: recorder
        )
        #expect(subject.totalDays == 12)

        // Today was not recorded, so the first check-in on it is a thirteenth
        // day — not a fourteenth, and not still twelve.
        subject.toggle(subject.habits[0])
        #expect(subject.totalDays == 13)
        #expect(subject.firstRecordedDay == day("2026-07-19"))

        // Un-tapping the only habit done today takes it back off.
        subject.toggle(subject.habits[0])
        #expect(subject.totalDays == 12)

        // Two habits on one day is still one day.
        subject.toggle(subject.habits[0])
        subject.toggle(subject.habits[1])
        #expect(subject.totalDays == 13)
    }

    @Test("The dot the finger is pointing at fills, and the ones behind it do not move")
    func todaysDotIsLive() {
        let events = history()
        let subject = model(
            snapshot: snapshot(of: events, on: day("2026-07-31")),
            recorder: FakeRecorder(continuing: events)
        )
        #expect(subject.spine.last == false)

        for habit in subject.habits { subject.toggle(habit) }

        #expect(subject.spine.last == true)
        #expect(subject.spine.suffix(13) == Array(repeating: true, count: 13))
    }

    @Test("The first recorded day appears when there was none")
    func firstDayAppearsFromNothing() {
        let events = seededFour()
        let subject = model(
            snapshot: snapshot(of: events, on: day("2026-07-31")),
            recorder: FakeRecorder(continuing: events)
        )
        #expect(subject.totalDays == 0)
        #expect(subject.firstRecordedDay == nil)

        subject.toggle(subject.habits[0])
        #expect(subject.totalDays == 1)
        #expect(subject.firstRecordedDay == day("2026-07-31"))
    }

    // MARK: The replay wins

    @Test("The replay wins, and the cache stops standing in for the log")
    func replayWinsAndDropsTheCache() async {
        let events = history()
        // A cache that disagrees with the log in every field that matters. The
        // log is the truth and the cache is disposable, so this is the direction
        // the disagreement must resolve in.
        let lying = TodaySnapshot(
            day: day("2026-07-31"),
            habits: [
                TodaySnapshot.Habit(
                    id: HabitID(rawValue: "habit-0"), name: "Wrong", isArchived: false,
                    isChecked: true, createdOn: day("2026-07-01")
                )
            ],
            daysRecorded: 999,
            dayIsRecorded: true,
            firstRecordedDay: day("2000-01-01"),
            spine: Array(repeating: true, count: TodaySnapshot.spineLength),
            declaredName: "Not the declared name"
        )

        let subject = model(snapshot: lying, source: FakeSource(events: events))
        #expect(subject.totalDays == 999)

        await subject.reconcile()

        #expect(subject.totalDays == 12)
        #expect(subject.firstRecordedDay == day("2026-07-19"))
        #expect(subject.habits.map(\.name) == ["Move", "Read", "Build", "Reflect"])
        #expect(subject.declaredName == "")
        #expect(subject.spine.last == false)
    }

    @Test("A failed replay leaves the cache standing rather than blanking the screen")
    func failedReplayKeepsTheCache() async {
        let events = history()
        let subject = model(
            snapshot: snapshot(of: events, on: day("2026-07-31")),
            source: FakeSource(fails: true)
        )

        await subject.reconcile()

        // The store is unreadable; the screen keeps showing the last thing it
        // knew rather than twelve days of history vanishing.
        #expect(subject.totalDays == 12)
        #expect(subject.habits.count == 4)
    }

    // MARK: Line 4

    @Test("Every recorded event is handed to the absorber, and none is invented")
    func everyWriteIsAbsorbed() async throws {
        let events = seededFour()
        let recorder = FakeRecorder(continuing: events)
        let absorber = RecordingAbsorber()
        let subject = model(
            snapshot: snapshot(of: events, on: day("2026-07-31")),
            recorder: recorder, absorber: absorber
        )

        subject.toggle(subject.habits[0])          // checkedIn
        subject.toggle(subject.habits[0])          // checkInRevoked
        subject.rename(subject.habits[1], to: "Study")
        subject.declare(name: "Farros")
        subject.removeHabit(subject.habits[2])

        // The `Task` in the tap path is what keeps the `await` off the finger,
        // so the assertion has to wait for it rather than assume it ran.
        try await absorber.waitForCount(recorder.recorded.count)

        // **A set, not a sequence, and that is not a weakened assertion.** The
        // `Task`s that carry these are unordered by construction, and nothing
        // downstream needs them ordered: `project` is commutative and idempotent
        // under `(lamport, device)` — the shard-, shuffle- and replay-invariance
        // tests in `CompassDomainTests` are what make that a fact rather than a
        // hope. Demanding an order here would be demanding a guarantee the tap
        // path deliberately does not buy.
        #expect(Set(absorber.absorbed.map(\.id)) == Set(recorder.recorded.map(\.id)))
        #expect(absorber.absorbed.count == recorder.recorded.count)
    }

    @Test("A write that fails is never absorbed")
    func failedWritesAreNotAbsorbed() async throws {
        let events = seededFour()
        let absorber = RecordingAbsorber()
        let subject = model(
            snapshot: snapshot(of: events, on: day("2026-07-31")),
            recorder: FakeRecorder(fails: true), absorber: absorber
        )

        subject.toggle(subject.habits[0])
        subject.declare(name: "Farros")

        // Nothing reached the disk, so there is nothing to catch up with. An
        // absorber that heard about it would put a check on screen that the log
        // does not have — the exact doubt the synchronous write removes.
        try await Task.sleep(for: .milliseconds(50))
        #expect(absorber.absorbed.isEmpty)
    }
}

/// Remembers what it was handed. `docs/technical.md` §4 line 4.
final class RecordingAbsorber: EventAbsorber {

    private let state = Mutex<[Event]>([])

    var absorbed: [Event] { state.withLock { $0 } }

    func absorb(_ event: Event) async {
        state.withLock { $0.append(event) }
    }

    /// Waits for `count` events, or gives up. The absorb is dispatched from a
    /// `Task`, so a test that read the array immediately would be racing the
    /// thing it is asserting.
    func waitForCount(_ count: Int, within: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now.advanced(by: within)
        while absorbed.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
