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
