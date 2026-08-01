import CompassApplication
import CompassDomain
import CompassUI
import Foundation
import Testing

/// The one screen's state. `docs/technical.md` §4 calls the tap path "the whole
/// design", and until this suite existed nothing tested it: the model was the
/// one piece of the loop with no test at all, which is exactly why an
/// out-of-spec field reached the disk from here.
@MainActor
@Suite("TodayModel — the tap path")
struct TodayModelTests {

    private func model(
        events: [Event] = [],
        clock: ScriptedClock,
        recorder: FakeRecorder = FakeRecorder(),
        source: FakeSource = FakeSource(),
        isStoreAvailable: Bool = true
    ) -> TodayModel {
        TodayModel(
            events: events,
            clock: clock,
            recorder: recorder,
            source: source,
            isStoreAvailable: isStoreAvailable
        )
    }

    private var seeded: [Event] {
        [created(habitA, name: "habit-a", lamport: 1)]
    }

    // MARK: What a tap writes

    @Test("a tap writes a checkedIn carrying the writer's source")
    func tapWritesCheckedIn() throws {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let recorder = FakeRecorder()
        let model = model(events: seeded, clock: clock, recorder: recorder)

        model.toggle(try #require(model.habits.first))

        let event = try #require(recorder.last)
        #expect(event.kind == .checkedIn)
        #expect(event.source == .tap)
        #expect(event.day == day("2026-07-31"))
        #expect(event.payload.habitID == habitA)
    }

    @Test("un-tapping writes a revocation with no source at all")
    func revocationCarriesNoSource() throws {
        // `docs/technical.md` §3: `checkedIn(habitID, day, source)` and
        // `checkInRevoked(habitID, day)`. `source` is inside the canonical form,
        // so a source on a revocation is an out-of-spec digested field on disk —
        // written on every un-tap, and unfixable once anything is signed.
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let recorder = FakeRecorder()
        let model = model(events: seeded, clock: clock, recorder: recorder)

        model.toggle(try #require(model.habits.first))
        model.toggle(try #require(model.habits.first))

        #expect(recorder.recorded.map(\.kind) == [.checkedIn, .checkInRevoked])
        #expect(recorder.recorded.map(\.source) == [.tap, nil])

        // Absent, not null: the encoded line has no `source` key on it.
        let line = try JSONEncoder().encode(try #require(recorder.last))
        let object = try #require(
            try JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        #expect(object["source"] == nil)
        #expect(object["kind"] as? String == "checkInRevoked")
    }

    @Test("a third tap checks in again, and carries a source again")
    func thirdTapIsACheckIn() throws {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let recorder = FakeRecorder()
        let model = model(events: seeded, clock: clock, recorder: recorder)

        for _ in 0..<3 { model.toggle(try #require(model.habits.first)) }

        #expect(recorder.recorded.map(\.kind) == [.checkedIn, .checkInRevoked, .checkedIn])
        #expect(recorder.recorded.map(\.source) == [.tap, nil, .tap])
        #expect(model.isChecked(try #require(model.habits.first)))
    }

    // MARK: One interaction, one day

    @Test("a tap that crosses 04:00 writes and renders the same day")
    func oneInteractionUsesOneDay() throws {
        // 03:59 is still yesterday; 04:01 is today. The app is in the foreground
        // across the boundary, so nothing refreshes the day but the tap itself.
        // `docs/technical.md` §3: the 04:00 boundary exists to remove the
        // "I did it but the app says I didn't" moment — a day read twice, once
        // for the write and once for the render, is how it comes back.
        let clock = ScriptedClock(
            "2026-07-31T03:59:00+07:00",
            "2026-07-31T04:01:00+07:00"
        )
        let recorder = FakeRecorder()
        let model = model(events: seeded, clock: clock, recorder: recorder)

        #expect(model.today == day("2026-07-30"))

        model.toggle(try #require(model.habits.first))

        let event = try #require(recorder.last)
        #expect(event.day == day("2026-07-31"), "the write must land on the new day")
        #expect(model.today == event.day, "the screen must be about the day it just wrote")

        // The finger felt it, the event is on disk, and the checkbox fills.
        #expect(model.isChecked(try #require(model.habits.first)))
        #expect(model.spine.last == true)
    }

    @Test("the day is read exactly once per tap")
    func theDayIsReadOncePerTap() throws {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let model = model(events: seeded, clock: clock)

        #expect(clock.reads == 1, "init renders the first frame from one read")

        model.toggle(try #require(model.habits.first))
        #expect(clock.reads == 2, "a tap reads the day once, and renders from that read")

        model.toggle(try #require(model.habits.first))
        #expect(clock.reads == 3)
    }

    @Test("a tap after the boundary un-checks the day it just checked")
    func toggleOffUsesTheRefreshedDay() throws {
        // Two taps, both after the app has been open across 04:00. The second
        // must revoke the first rather than check in again on a stale day.
        let clock = ScriptedClock(
            "2026-07-31T03:59:00+07:00",
            "2026-07-31T04:01:00+07:00"
        )
        let recorder = FakeRecorder()
        let model = model(events: seeded, clock: clock, recorder: recorder)

        model.toggle(try #require(model.habits.first))
        model.toggle(try #require(model.habits.first))

        #expect(recorder.recorded.map(\.kind) == [.checkedIn, .checkInRevoked])
        #expect(recorder.recorded.map(\.day) == [day("2026-07-31"), day("2026-07-31")])
        #expect(model.isChecked(try #require(model.habits.first)) == false)
    }

    // MARK: When the write fails

    @Test("a write that fails leaves the screen telling the truth")
    func failedWriteChangesNothing() throws {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let recorder = FakeRecorder(fails: true)
        let model = model(events: seeded, clock: clock, recorder: recorder)

        model.toggle(try #require(model.habits.first))

        // No check on screen that is not on disk. That doubt — "did my tap
        // actually save?" — is what the synchronous write exists to remove.
        #expect(recorder.recorded.isEmpty)
        #expect(model.isChecked(try #require(model.habits.first)) == false)
        #expect(model.totalDays == 0)
    }

    @Test("an unopenable store is a screen, not a crash")
    func unavailableStoreIsSurvivable() async throws {
        // `docs/technical.md` §6: never refuse to launch. The composition root
        // hands the model a store where every call throws, and the model has to
        // survive both halves of it — the tap path and the launch path.
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let recorder = FakeRecorder(fails: true)
        let model = model(
            events: [],
            clock: clock,
            recorder: recorder,
            source: FakeSource(fails: true),
            isStoreAvailable: false
        )

        #expect(model.isStoreAvailable == false)
        #expect(model.habits.isEmpty)
        #expect(model.totalDays == 0)

        await model.reconcile()
        #expect(model.totalDays == 0)

        model.refreshDay()
        #expect(model.today == day("2026-07-31"))
    }

    @Test("an available store says nothing")
    func availableStoreIsTheDefault() {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        #expect(model(events: seeded, clock: clock).isStoreAvailable)
    }

    // MARK: What the other writer did while the app was away

    @Test("a press made in the widget shows up when the app reconciles")
    func aSecondWritersPressLands() async throws {
        // Week 2's new fact: this process is no longer the only writer. The app
        // can sit in the background holding a projection while the widget appends
        // to the same file, so the screen is only true if it re-reads.
        //
        // `TodayView` re-runs this from `.task(id: scenePhase)` every time the app
        // becomes active. That wiring lives in a view and no test can drive it —
        // `.claude/skills/testing.md` refuses snapshot tests and XCUITest out
        // loud — so what is pinned here is the behaviour the wiring depends on:
        // a replay carrying another writer's event wins over what this process
        // believes.
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, clock: clock, recorder: recorder)

        model.toggle(try #require(model.habits.first))
        #expect(model.isChecked(try #require(model.habits.first)))

        // The widget, in the other process, un-checks it. Its `lamport` is higher
        // because a Lamport clock resumes past everything already in the log —
        // which is the only reason the fold prefers it.
        let fromTheWidget = Event(
            id: UUID(),
            device: DeviceID(rawValue: "22222222-2222-4222-8222-222222222222"),
            lamport: 9,
            kind: .checkInRevoked,
            day: day("2026-07-31"),
            recordedAt: 1_784_000_000_000,
            zoneOffset: surabayaOffsetSeconds / 60,
            payload: .habit(habitA)
        )

        let source = FakeSource(events: seeded + recorder.recorded + [fromTheWidget])
        let reopened = TodayModel(
            events: seeded, clock: clock, recorder: recorder, source: source
        )
        reopened.toggle(try #require(reopened.habits.first))
        await reopened.reconcile()

        #expect(reopened.isChecked(try #require(reopened.habits.first)) == false)
    }

    // MARK: What the degraded launch says out loud

    /// **The notice was written on the screen and unsayable.**
    ///
    /// `TodayView`'s header is one accessibility element — its children are
    /// merged with `.accessibilityElement(children: .combine)` and the merged
    /// label is then replaced — so anything rendered inside it and absent from
    /// that label is invisible to a screen reader. The store notice was one of
    /// those children. The element announced "0 days recorded" and never said
    /// why, which is precisely the "this app forgot everything" reading the
    /// notice exists to prevent, and worse for the one person who cannot see the
    /// sentence sitting two points below it.
    ///
    /// **What this proves, and the one line it does not.** SwiftUI's resolved
    /// accessibility tree cannot be read from a unit test, and
    /// `.claude/skills/testing.md` refuses out loud the two things that could
    /// read it — snapshot tests and a broad XCUITest suite. So this asserts the
    /// string the view hands to `.accessibilityLabel`, not the label VoiceOver
    /// finally resolves. The unproven step is exactly one line,
    /// `.accessibilityLabel(model.spokenCaption)`, and it is named here rather
    /// than papered over. What makes it hard to get wrong is the naming: the
    /// property that is only ever *shown* is `caption`, the one that is *said*
    /// is ``TodayModel/spokenCaption``, and the header renders both.
    @Test("the header speaks the store notice, not only the number")
    func theStoreNoticeIsSpoken() {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let degraded = model(
            events: [],
            clock: clock,
            recorder: FakeRecorder(fails: true),
            source: FakeSource(fails: true),
            isStoreAvailable: false
        )

        // The number is still said. The notice qualifies it rather than
        // replacing it: a reader that announced only the failure would be as
        // partial as one that announced only the zero.
        #expect(degraded.spokenCaption.contains(degraded.caption))
        #expect(degraded.spokenCaption.contains(TodayCaption.storeNotice))

        // One string, shown and spoken, so the two cannot drift apart.
        #expect(TodayCaption.storeNotice.contains("cannot reach its store"))
    }

    @Test("a store that opened adds nothing to what the header says")
    func anAvailableStoreSpeaksTheCaptionAlone() {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let working = model(events: seeded, clock: clock)
        #expect(working.spokenCaption == working.caption)
    }

    @Test("a composed store hands the model every port it resolved")
    func composedStoreInitialisesTheModel() throws {
        // The launch initialiser. It exists so `App/` — which `swift test` does
        // not compile and no test target covers — has no argument list to get
        // wrong; forwarding five arguments there is how a fix can be deleted in
        // silence. So the forwarding is asserted here, argument by argument.
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let recorder = FakeRecorder()
        let model = TodayModel(
            ComposedStore(
                events: seeded,
                clock: clock,
                recorder: recorder,
                source: FakeSource(events: seeded),
                isStoreAvailable: true
            )
        )

        #expect(model.habits.count == 1)
        #expect(model.today == day("2026-07-31"))
        #expect(model.isStoreAvailable)

        // The recorder is the one that was composed, not a default.
        model.toggle(try #require(model.habits.first))
        #expect(recorder.recorded.count == 1)
    }

    @Test("a composed store that could not be opened stays unavailable")
    func composedStoreCarriesUnavailability() {
        // The line a future session could drop without breaking a build: without
        // it the degraded launch renders as an app that simply forgot
        // everything. `docs/technical.md` §6.
        let model = TodayModel(
            ComposedStore(
                events: [],
                clock: ScriptedClock("2026-07-31T09:00:00+07:00"),
                recorder: FakeRecorder(fails: true),
                source: FakeSource(fails: true),
                isStoreAvailable: false
            )
        )

        #expect(!model.isStoreAvailable)
        #expect(model.habits.isEmpty)
    }

    // MARK: The 28-day spine

    /// `docs/product.md` calls the spine "a 28-day dot strip showing gaps
    /// honestly". These two tests are written against that word rather than
    /// against the arithmetic: a strip that rewrites what a past day meant
    /// because of something the user changed today is not honest, whichever
    /// direction it rewrites it in.
    ///
    /// A day that was complete when it happened is complete forever; a day that
    /// was missed when it happened is missed forever. Both are the same rule seen
    /// from the two sides, and the fold used to get both of them wrong.
    private func fullFortnight(_ habit: HabitID, endingOn last: String) -> [Event] {
        let end = day(last)
        let start = end.adding(-(TodayModel.spineLength - 1))
        var events = [created(habit, name: "Move", lamport: 1, on: start)]
        for offset in 0..<TodayModel.spineLength {
            events.append(
                checkedIn(habit, on: start.adding(offset).iso, lamport: 10 + offset)
            )
        }
        return events
    }

    @Test("Adding a habit today does not turn off the days before it existed")
    func addingAHabitLeavesThePastAlone() {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let log = fullFortnight(habitA, endingOn: "2026-07-31")
        let model = model(events: log, clock: clock, recorder: FakeRecorder(continuing: log))

        // Twenty-eight days, every one of them done.
        #expect(model.spine == Array(repeating: true, count: 28))

        model.addHabit(named: "Read")

        // The twenty-seven days before the new habit existed are unchanged. The
        // user did not un-do them by opening the settings sheet.
        #expect(model.spine.dropLast() == ArraySlice(Array(repeating: true, count: 27)))
        // Today is no longer complete, and that is not a rewrite: there is a
        // habit on the screen today that has not been done today.
        #expect(model.spine.last == false)
    }

    @Test("Removing a habit does not fill a day it was missed on")
    func removingAHabitLeavesThePastAlone() throws {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let start = day("2026-07-31").adding(-(TodayModel.spineLength - 1))
        // Offset 16 is the missed day, and it is written as an index throughout
        // because that is what indexes the spine the assertions read.
        var log = fullFortnight(habitA, endingOn: "2026-07-31")
        log.append(created(habitB, name: "Read", lamport: 2, on: start))
        for offset in 0..<TodayModel.spineLength where offset != 16 {
            log.append(checkedIn(habitB, on: start.adding(offset).iso, lamport: 100 + offset))
        }

        let model = model(events: log, clock: clock, recorder: FakeRecorder(continuing: log))

        // One gap, on the day "Read" was missed.
        #expect(model.spine.filter { !$0 }.count == 1)
        #expect(model.spine[16] == false)

        let read = try #require(model.habits.first { $0.name == "Read" })
        model.removeHabit(read)

        // Still one gap, in the same place. Removing the habit did not hand the
        // user a day they did not do — the dot is a record, not a setting.
        #expect(model.spine[16] == false, "a missed day must not be filled by removing a habit")
        #expect(model.spine.filter { !$0 }.count == 1)
        // And the days it was done on stay done.
        #expect(model.spine.last == true)
    }

    /// Before the first habit existed nothing was tracked, and a day with nothing
    /// tracked is a gap rather than a completion — `allSatisfy` over an empty set
    /// is `true`, which would fill the whole strip on the morning of install.
    @Test("The days before the first habit are gaps, not completions")
    func anEmptyPastIsNotAFullPast() throws {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let log = [created(habitA, name: "Move", lamport: 1, on: day("2026-07-31"))]
        let model = model(events: log, clock: clock, recorder: FakeRecorder(continuing: log))

        #expect(model.spine == Array(repeating: false, count: 28))

        model.toggle(try #require(model.habits.first))

        #expect(model.spine.last == true)
        #expect(model.spine.dropLast().allSatisfy { $0 == false })
    }

    // MARK: The launch path

    @Test("the replay wins over whatever the first frame rendered")
    func replayWins() async throws {
        let clock = ScriptedClock("2026-07-31T09:00:00+07:00")
        let onDisk = seeded + [
            Event(
                id: UUID(),
                device: writerApp,
                lamport: 2,
                kind: .checkedIn,
                day: day("2026-07-31"),
                recordedAt: 1_784_000_000_000,
                zoneOffset: 420,
                source: .tap,
                payload: .habit(habitA)
            )
        ]

        // The first frame rendered from a stale, disposable cache: the habit
        // exists but the check-in is missing.
        let model = model(events: seeded, clock: clock, source: FakeSource(events: onDisk))
        #expect(model.totalDays == 0)

        await model.reconcile()

        #expect(model.totalDays == 1)
        #expect(model.isChecked(try #require(model.habits.first)))
    }
}
