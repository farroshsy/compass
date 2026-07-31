import CompassDomain
import CompassUI
import Foundation
import Testing

/// What the settings sheet does to the log.
///
/// The sheet itself is SwiftUI and is not tested here — `.claude/skills/testing.md`
/// refuses snapshot tests and a broad XCUITest suite out loud. What is testable,
/// and is the entire risk, is the three things it can write: a habit created, a
/// habit removed, and a name declared. Two of those have a rule that must not
/// bend, and both rules are asserted rather than trusted:
///
/// - **removal never deletes.** It appends `habitArchived`, the habit stays in
///   the projection, and every day it recorded stays with it.
/// - **the cap is four active habits.** Archived ones do not hold a slot.
@MainActor
@Suite("The settings sheet — add, remove, and the declared name")
struct SettingsTests {

    private func model(
        events: [Event],
        recorder: FakeRecorder,
        source: FakeSource = FakeSource()
    ) -> TodayModel {
        TodayModel(
            events: events,
            clock: ScriptedClock("2026-07-31T09:00:00+07:00"),
            recorder: recorder,
            source: source
        )
    }

    private func checkIn(_ habit: HabitID, on iso: String, lamport: Int) -> Event {
        Event(
            id: UUID(),
            device: writerApp,
            lamport: lamport,
            kind: .checkedIn,
            day: day(iso),
            recordedAt: 1_784_000_000_000,
            zoneOffset: surabayaOffsetSeconds / 60,
            source: .tap,
            payload: .habit(habit)
        )
    }

    // MARK: Adding

    @Test("Adding a habit appends a habitCreated carrying the name")
    func addingAppendsACreation() throws {
        let seeded = Array(seededFour().prefix(2))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        #expect(model.addHabit(named: "Stretch"))

        let event = try #require(recorder.last)
        #expect(event.kind == .habitCreated)
        #expect(event.payload.name == "Stretch")
        // `source` belongs to a check-in and to nothing else. It is inside the
        // canonical form, so a stray one is an out-of-spec digested field on
        // disk. `docs/technical.md` §3.
        #expect(event.source == nil)
        #expect(model.habits.map(\.name) == ["Move", "Read", "Stretch"])
    }

    /// The habit the user just typed goes at the bottom, under the ones already
    /// there. It is the reason `HabitState.createdOrder` exists: identifiers are
    /// opaque, so ordering by them put a new habit wherever random hex landed.
    @Test("A habit added now appears below the ones already there")
    func aNewHabitGoesLast() {
        let seeded = Array(seededFour().prefix(3))
        let model = model(events: seeded, recorder: FakeRecorder(continuing: seeded))

        model.addHabit(named: "Stretch")

        #expect(model.habits.map(\.name) == ["Move", "Read", "Build", "Stretch"])
    }

    /// `docs/achievement-protocol.md` §3.4. A `HabitID` is what `facts` carries
    /// into a signed, anchored, shareable record; there is no redaction path and
    /// there can never be one. A habit named after a medical routine must not put
    /// that word inside a digest.
    @Test("The minted identifier carries no part of the typed name")
    func mintedIdentifiersAreOpaque() throws {
        let seeded = Array(seededFour().prefix(1))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        model.addHabit(named: "Antidepressant")
        model.addHabit(named: "Antidepressant")

        let ids = recorder.recorded.compactMap { $0.payload.habitID?.rawValue }
        #expect(ids.count == 2)
        for id in ids {
            #expect(!id.lowercased().contains("antidepressant"))
            #expect(!id.isEmpty)
        }
        // Two habits with the same name are two habits, not one.
        #expect(ids[0] != ids[1])
        #expect(model.habits.count == 3)
    }

    @Test("A blank name is not a habit")
    func blankNamesAreRefused() {
        let seeded = Array(seededFour().prefix(1))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        #expect(!model.addHabit(named: ""))
        #expect(!model.addHabit(named: "   \n "))

        #expect(recorder.recorded.isEmpty)
        #expect(model.habits.count == 1)
    }

    @Test("Surrounding whitespace is trimmed, not stored")
    func namesAreTrimmed() throws {
        let seeded = Array(seededFour().prefix(1))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        model.addHabit(named: "  Stretch  ")

        #expect(try #require(recorder.last).payload.name == "Stretch")
    }

    // MARK: The cap

    @Test("A fifth active habit is refused, and nothing is written")
    func theCapIsEnforcedWhereHabitsAreCreated() {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        #expect(!model.mayAddHabit)
        #expect(!model.addHabit(named: "Stretch"))

        // Refused at the write, never by hiding a row: a hidden row is a habit
        // whose taps are impossible while its data keeps accumulating.
        #expect(recorder.recorded.isEmpty)
        #expect(model.habits.count == Projection.habitCap)
    }

    @Test("Removing one frees the slot, and the removed habit still does not hold one")
    func removalFreesASlot() {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        model.removeHabit(model.habits[1])
        #expect(model.mayAddHabit)

        #expect(model.addHabit(named: "Stretch"))
        #expect(model.habits.map(\.name) == ["Move", "Build", "Reflect", "Stretch"])
        #expect(!model.mayAddHabit)
        #expect(model.removedHabits.map(\.name) == ["Read"])
    }

    // MARK: Removing — which is archiving, and never deleting

    @Test("Removing a habit appends a habitArchived and deletes nothing")
    func removingArchives() throws {
        let seeded = seededFour()
        let log = seeded + [
            checkIn(HabitID(rawValue: "habit-1"), on: "2026-07-30", lamport: 5),
            checkIn(HabitID(rawValue: "habit-1"), on: "2026-07-31", lamport: 6),
        ]
        let recorder = FakeRecorder(continuing: log)
        let model = model(events: log, recorder: recorder)

        #expect(model.totalDays == 2)
        let read = try #require(model.habits.first { $0.name == "Read" })
        #expect(model.removeHabit(read))

        let event = try #require(recorder.last)
        #expect(event.kind == .habitArchived)
        #expect(event.payload.habitID == read.id)
        #expect(event.source == nil)

        // Off Today. Still in the log, still in the projection, still holding
        // every day it recorded. This is the whole premise of an append-only
        // record and there is no code path in this app that breaks it.
        #expect(model.habits.map(\.name) == ["Move", "Build", "Reflect"])
        #expect(model.removedHabits.map(\.name) == ["Read"])
        #expect(model.totalDays == 2)
        #expect(model.projection.habit(read.id)?.checkedDays.count == 2)
        #expect(model.projection.habits.count == Projection.habitCap)
    }

    @Test("A write that fails changes nothing, for either control")
    func failedWritesChangeNothing() {
        let seeded = Array(seededFour().prefix(2))
        let recorder = FakeRecorder(continuing: seeded, fails: true)
        let model = model(events: seeded, recorder: recorder)

        #expect(!model.addHabit(named: "Stretch"))
        #expect(!model.removeHabit(model.habits[0]))
        #expect(!model.declare(name: "Farros"))

        #expect(recorder.recorded.isEmpty)
        #expect(model.habits.map(\.name) == ["Move", "Read"])
        #expect(model.removedHabits.isEmpty)
        #expect(model.declaredName == "")
    }

    // MARK: The declared name

    @Test("Nothing is declared until the user declares something")
    func emptyByDefault() {
        let seeded = seededFour()
        #expect(model(events: seeded, recorder: FakeRecorder(continuing: seeded)).declaredName == "")
    }

    @Test("Declaring a name appends a subjectNamed carrying only that name")
    func declaringAppendsASubjectNamed() throws {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        #expect(model.declare(name: "  Farros Hilmi Syafei "))

        let event = try #require(recorder.last)
        #expect(event.kind == .subjectNamed)
        #expect(event.payload.name == "Farros Hilmi Syafei")
        #expect(event.source == nil)
        #expect(model.declaredName == "Farros Hilmi Syafei")

        // `docs/technical.md` §3 freezes the per-kind payload keys, and
        // `subjectNamed` is `{"name":<string>}` — one key, and nothing else may
        // ride along inside a structure that is closed by design.
        let line = try JSONEncoder().encode(event)
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(Array(payload.keys) == ["name"])
        #expect(object["source"] == nil)
    }

    @Test("Declaring the same name again writes nothing")
    func redeclaringIsANoOp() {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        #expect(model.declare(name: "Farros"))
        #expect(!model.declare(name: "Farros"))
        #expect(!model.declare(name: "  Farros  "))

        #expect(recorder.recorded.count == 1)
    }

    /// Withdrawing is a declaration of nothing, appended. Nothing is erased —
    /// both events stay in the log, and a record sealed while the name stood
    /// keeps it.
    @Test("An empty name withdraws the declaration by appending, not by deleting")
    func withdrawingAppends() {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        model.declare(name: "Farros")
        #expect(model.declare(name: ""))

        #expect(model.declaredName == "")
        #expect(recorder.recorded.map(\.kind) == [.subjectNamed, .subjectNamed])
        #expect(recorder.recorded.map { $0.payload.name } == ["Farros", ""])
    }

    @Test("The declared name comes back from the log on the next launch")
    func theNameSurvivesAReplay() async {
        let seeded = seededFour()
        let declaration = Event(
            id: UUID(),
            device: writerApp,
            lamport: 9,
            kind: .subjectNamed,
            day: day("2026-07-31"),
            recordedAt: 1_784_000_000_000,
            zoneOffset: surabayaOffsetSeconds / 60,
            payload: .subject(named: "Farros Hilmi Syafei")
        )

        // The first frame rendered from a stale cache that has not seen it.
        let model = model(
            events: seeded,
            recorder: FakeRecorder(continuing: seeded),
            source: FakeSource(events: seeded + [declaration])
        )
        #expect(model.declaredName == "")

        await model.reconcile()
        #expect(model.declaredName == "Farros Hilmi Syafei")
    }

    /// The replay wins, but it cannot win over an event it never saw. Both folds
    /// have to survive that, and the one added later is the one that would be
    /// forgotten.
    @Test("A declaration made during a replay is not lost when the replay lands")
    func aDeclarationDuringAReplaySurvives() async {
        let seeded = Array(seededFour().prefix(3))
        let gate = ReplayGate()
        let model = model(
            events: seeded,
            recorder: FakeRecorder(continuing: seeded),
            source: FakeSource(events: seeded, gate: gate)
        )

        let replay = Task { await model.reconcile() }
        await gate.waitUntilEntered()

        model.declare(name: "Farros")
        model.addHabit(named: "Stretch")

        gate.open()
        await replay.value

        #expect(model.declaredName == "Farros")
        #expect(model.habits.map(\.name) == ["Move", "Read", "Build", "Stretch"])
    }
}
