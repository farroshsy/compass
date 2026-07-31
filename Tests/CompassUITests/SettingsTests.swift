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

    // MARK: Renaming

    /// The rule this test exists for is the one `docs/technical.md` §3 states
    /// about `habitRenamed`: **cosmetic, never affects the fold.** What that means
    /// to a person is that changing the label on a row does not cost them the row.
    ///
    /// Before rename existed, the only way to change a name at the four-habit cap
    /// was Remove then Add, which mints a new `HabitID` — so the sixty days behind
    /// the old name went behind an archived row and the new row started at zero.
    /// Every assertion below is about the history surviving, not about the event.
    @Test("Renaming a habit keeps its identity, its days and its place")
    func renamingKeepsEverythingButTheLabel() throws {
        let seeded = seededFour()
        let log = seeded + [
            checkIn(HabitID(rawValue: "habit-1"), on: "2026-07-30", lamport: 5),
            checkIn(HabitID(rawValue: "habit-1"), on: "2026-07-31", lamport: 6),
        ]
        let recorder = FakeRecorder(continuing: log)
        let model = model(events: log, recorder: recorder)

        let read = try #require(model.habits.first { $0.name == "Read" })
        #expect(model.rename(read, to: "Read a book"))

        // The label changed.
        #expect(model.habits.map(\.name) == ["Move", "Read a book", "Build", "Reflect"])
        // Nothing else did: same habit, same days, same position, same total.
        let renamed = try #require(model.habits.first { $0.id == read.id })
        #expect(renamed.checkedDays == read.checkedDays)
        #expect(model.habits.map(\.id)[1] == read.id)
        #expect(model.totalDays == 2)
        #expect(model.removedHabits.isEmpty)
        #expect(model.projection.habits.count == Projection.habitCap)
    }

    @Test("Renaming at the cap is possible at all")
    func renamingIsNotBlockedByTheCap() throws {
        // The case that forced this feature: four names seeded at the limit, so
        // Remove-then-Add is not even available without first losing a habit.
        let seeded = seededFour()
        let model = model(events: seeded, recorder: FakeRecorder(continuing: seeded))

        #expect(!model.mayAddHabit)
        #expect(model.rename(try #require(model.habits.first), to: "Walk"))
        #expect(model.habits.map(\.name) == ["Walk", "Read", "Build", "Reflect"])
    }

    @Test("A rename writes a habitRenamed carrying the habit's own identifier")
    func renamingAppendsARename() throws {
        let seeded = Array(seededFour().prefix(2))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        let read = try #require(model.habits.last)
        #expect(model.rename(read, to: "  Read a book  "))

        let event = try #require(recorder.last)
        #expect(event.kind == .habitRenamed)
        #expect(event.payload.habitID == read.id)
        #expect(event.payload.name == "Read a book")
        #expect(event.source == nil)
    }

    @Test("A blank or unchanged name writes nothing")
    func renamesThatChangeNothingWriteNothing() throws {
        let seeded = Array(seededFour().prefix(2))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)
        let move = try #require(model.habits.first)

        #expect(!model.rename(move, to: ""))
        #expect(!model.rename(move, to: "   \n "))
        #expect(!model.rename(move, to: "Move"))
        #expect(!model.rename(move, to: "  Move  "))

        #expect(recorder.recorded.isEmpty)
        #expect(model.habits.map(\.name) == ["Move", "Read"])
    }

    @Test("A rename that fails to write changes nothing on screen")
    func aFailedRenameChangesNothing() throws {
        let seeded = Array(seededFour().prefix(2))
        let model = model(
            events: seeded, recorder: FakeRecorder(continuing: seeded, fails: true)
        )

        #expect(!model.rename(try #require(model.habits.first), to: "Walk"))
        #expect(model.habits.map(\.name) == ["Move", "Read"])
    }

    // MARK: Restoring — the way back from a one-tap Remove

    /// Remove is one tap and `.claude/skills/ui.md` forbids a confirmation
    /// dialog, so the interface has to hold the undo somewhere. Before this
    /// existed the only way back was Add, which mints a new identifier — so the
    /// user's sixty days stayed behind the removed row and the new one started at
    /// zero. This asserts the days come back with the habit.
    @Test("A removed habit can be put back, with every day it recorded")
    func restoringBringsTheHistoryBack() throws {
        let seeded = seededFour()
        let log = seeded + [
            checkIn(HabitID(rawValue: "habit-1"), on: "2026-07-30", lamport: 5),
            checkIn(HabitID(rawValue: "habit-1"), on: "2026-07-31", lamport: 6),
        ]
        let recorder = FakeRecorder(continuing: log)
        let model = model(events: log, recorder: recorder)

        let read = try #require(model.habits.first { $0.name == "Read" })
        model.removeHabit(read)
        #expect(model.habits.map(\.name) == ["Move", "Build", "Reflect"])

        #expect(model.restoreHabit(try #require(model.removedHabits.first)))

        // Back in its own place, not appended to the end, and still holding the
        // two days it recorded before the mis-tap.
        #expect(model.habits.map(\.name) == ["Move", "Read", "Build", "Reflect"])
        #expect(model.removedHabits.isEmpty)
        #expect(try #require(model.habits.first { $0.id == read.id }).checkedDays.count == 2)
        #expect(model.totalDays == 2)

        let event = try #require(recorder.last)
        #expect(event.kind == .habitUnarchived)
        #expect(event.payload.habitID == read.id)
        #expect(event.source == nil)
    }

    @Test("Restoring a fifth habit is refused, and nothing is written")
    func restoringRespectsTheCap() throws {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        // Remove one, add a replacement — now four are active and one is removed.
        model.removeHabit(try #require(model.habits.first))
        model.addHabit(named: "Stretch")
        #expect(model.habits.count == Projection.habitCap)

        let written = recorder.recorded.count
        #expect(!model.restoreHabit(try #require(model.removedHabits.first)))
        #expect(recorder.recorded.count == written)
        #expect(model.habits.count == Projection.habitCap)
        #expect(model.removedHabits.count == 1)
    }

    @Test("Restoring something that is not removed does nothing")
    func restoringAnActiveHabitIsANoOp() throws {
        let seeded = Array(seededFour().prefix(2))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        #expect(!model.restoreHabit(try #require(model.habits.first)))
        #expect(recorder.recorded.isEmpty)
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

    // MARK: What the sheet claims

    /// The footer under the name field used to say that anything sealed
    /// afterwards "cannot be changed without breaking the seal". There is no
    /// seal: in week 1a there is no `content_hash`, no chain and no signature,
    /// and every event's `prev` is 32 zero bytes. The log is a text file, and a
    /// name in it can be edited with nothing left over to notice.
    ///
    /// Both halves are asserted together on purpose. The first pins the state of
    /// the world that makes the claim false; the second pins the claim. When the
    /// chain lands in week 1b the first assertion fails — which is the point:
    /// that is the moment this copy is allowed to say more, and the test is what
    /// will say so rather than nobody noticing for a month.
    @Test("The sheet does not claim a seal this build does not have")
    func theFooterClaimsOnlyWhatIsTrue() throws {
        let seeded = Array(seededFour().prefix(2))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        model.declare(name: "Farros Hilmi Syafei")
        model.addHabit(named: "Stretch")

        // Nothing chains anything to anything.
        #expect(recorder.recorded.count == 2)
        #expect(recorder.recorded.allSatisfy { $0.prev == Event.genesisPrev })

        // So no sentence in the sheet may imply otherwise.
        let copy = [
            SettingsCopy.nameFooter,
            SettingsCopy.habitsFooter,
            SettingsCopy.removedFooter,
            SettingsCopy.removedFooterAtCap,
            SettingsCopy.addFooter,
            SettingsCopy.addFooterAtCap,
        ]
        for sentence in copy {
            for claim in SettingsCopy.unearnedClaims {
                #expect(
                    !sentence.lowercased().contains(claim),
                    "\"\(claim)\" is a claim about cryptography this build does not ship"
                )
            }
        }
    }

    /// The half of the old footer the verification pass judged correct, kept: the
    /// app has no account, no server and no second party, and can never acquire
    /// one, so it must never imply the name was checked by anybody.
    @Test("The sheet still says nobody checks the name")
    func theDisclaimerSurvives() {
        let footer = SettingsCopy.nameFooter.lowercased()
        #expect(footer.contains("nobody checks it"))
        #expect(footer.contains("not"))
        #expect(footer.contains("true"))
        // And it says what saving actually does: it writes the name into the log.
        #expect(footer.contains("log"))
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
