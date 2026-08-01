import CompassDomain
import Foundation
import Testing

// `@testable` for ``SettingsEdits``, which is internal to `CompassUI` on
// purpose: it has exactly one use site, ``SettingsView``, and widening the
// module's public surface for a test would be the wrong trade. The two bugs it
// was extracted to expose are driven below.
@testable import CompassUI

/// What the settings sheet does to the log.
///
/// The sheet's *layout* is SwiftUI and is not tested here —
/// `.claude/skills/testing.md` refuses snapshot tests and a broad XCUITest suite
/// out loud. Its *behaviour* is ``SettingsEdits``, which is ordinary code and is
/// driven directly: what each control does, and what Done commits.
///
/// That split is new, and it is new because behaviour living in `@State` inside
/// a `View` is behaviour no test can reach. Two data bugs sat there — Done
/// silently discarding the declared name, and Done writing a rename the user had
/// cancelled by removing the habit — and both were invisible to a suite of 206
/// tests. ``SettingsEdits`` records the reasoning.
///
/// Three rules must not bend, and each is asserted rather than trusted:
///
/// - **removal never deletes.** It appends `habitArchived`, the habit stays in
///   the projection, and every day it recorded stays with it.
/// - **the cap is four active habits.** Archived ones do not hold a slot.
/// - **nothing is written that the user did not confirm, and nothing they did
///   confirm is dropped.**
@MainActor
@Suite("The settings sheet — add, remove, rename, and the declared name")
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

    /// ``TodayModel/rename(_:to:)`` reads the current name out of the projection
    /// rather than out of the ``HabitState`` it is handed, and the comment on
    /// that line says the snapshot is exactly what must not be trusted — "a view
    /// can hand back a row it rendered before the last write landed". Nothing
    /// asserted it: trusting the caller left the whole suite green.
    ///
    /// The sheet hands back stale rows **by construction.** `ForEach` over
    /// `model.habits` captures each `HabitState` by value into that row's
    /// closures, so the row's own `onSubmit` and the Done sweep can both fire
    /// against a value rendered before the other one wrote.
    ///
    /// What it costs is not cosmetic. The log is append-only and has no tidying
    /// pass, so a redundant `habitRenamed` is on disk forever, inside
    /// `witness.logHeads` for every achievement sealed afterwards.
    @Test("A rename is judged against the log, not against the row that asked for it")
    func renamingTrustsTheProjectionAndNotTheCaller() throws {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        // The row as the sheet rendered it, while the log still said "Read".
        let asRendered = try #require(model.habits.first { $0.name == "Read" })
        #expect(model.rename(asRendered, to: "Read a book"))
        #expect(recorder.recorded.count == 1)

        // The same stale row, submitted again with the name the log now has.
        // Its snapshot still reads "Read", so a caller-trusting guard sees a
        // change and writes a second, meaningless rename.
        #expect(!model.rename(asRendered, to: "Read a book"))
        #expect(recorder.recorded.count == 1)
        #expect(model.habits.map(\.name) == ["Move", "Read a book", "Build", "Reflect"])
    }

    @Test("Renaming a habit the log has never heard of writes nothing")
    func renamingAnUnknownHabitWritesNothing() throws {
        let seeded = Array(seededFour().prefix(2))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        // A row folded out of a different log entirely. The projection lookup is
        // what refuses it; trusting the caller would mint a `habitRenamed` for a
        // habit that has no `habitCreated` anywhere on this chain.
        let stranger = try #require(
            project([created(HabitID(rawValue: "habit-z"), name: "Stretch", lamport: 1)])
                .activeHabits.first
        )

        #expect(!model.rename(stranger, to: "Walk"))
        #expect(recorder.recorded.isEmpty)
        #expect(model.habits.map(\.name) == ["Move", "Read"])
    }

    // MARK: Done — the sheet closing, and what it takes with it

    /// **The declared name was the one field Done did not commit.**
    ///
    /// The Done handler's own comment says it commits first because "a name
    /// typed and not submitted is an edit the user believes they made, and
    /// dismissing over it would discard it in silence". It swept habit renames
    /// and returned. The declared name — the field the sheet was added for — was
    /// dropped, so typing a name and tapping Done left no `subjectNamed` in the
    /// log and an empty field on reopen.
    ///
    /// Reopening is asserted through a fresh ``SettingsEdits``, which is what
    /// ``SettingsView/init(model:)`` builds, so "the name is there when I come
    /// back" is a statement about the log rather than about a cache.
    @Test("Done commits a name typed and never submitted, and it is there on reopen")
    func doneCommitsTheDeclaredName() throws {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        // The sheet opens; the user types into "Name on the record" and taps
        // Done without ever leaving the field.
        var edits = SettingsEdits(model)
        edits.typedName = "Farros Hilmi Syafei"
        edits.commitAll(into: model)

        let event = try #require(recorder.last)
        #expect(event.kind == .subjectNamed)
        #expect(event.payload.name == "Farros Hilmi Syafei")
        #expect(model.declaredName == "Farros Hilmi Syafei")

        // Reopened.
        #expect(SettingsEdits(model).typedName == "Farros Hilmi Syafei")
    }

    @Test("Done also commits a habit name typed and never submitted")
    func doneCommitsHabitRenames() throws {
        let seeded = Array(seededFour().prefix(2))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)
        var edits = SettingsEdits(model)

        edits.setName("Walk", of: try #require(model.habits.first))
        edits.commitAll(into: model)

        #expect(model.habits.map(\.name) == ["Walk", "Read"])
        #expect(recorder.recorded.map(\.kind) == [.habitRenamed])
    }

    /// Opening the sheet and closing it is not an edit. Without this, a Done
    /// that declared unconditionally would append a `subjectNamed` carrying `""`
    /// on every visit, onto a log that is append-only and cannot be tidied.
    @Test("Done writes nothing when nothing was typed")
    func doneOnAnUntouchedSheetIsSilent() {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        var edits = SettingsEdits(model)
        edits.commitAll(into: model)

        #expect(recorder.recorded.isEmpty)
        #expect(model.habits.map(\.name) == ["Move", "Read", "Build", "Reflect"])
    }

    /// **Done commits every edit and no creation, and this pins the second
    /// half.** The other three fields on the sheet revise something that already
    /// exists: a rename is undone by another rename, a declared name by declaring
    /// an empty one. Creation is not revisable. It mints a `HabitID` and appends
    /// a `habitCreated` to a log with no tidying pass, so a habit minted from
    /// abandoned typing is on disk forever, inside `witness.logHeads` for every
    /// achievement sealed afterwards — and Remove archives rather than deletes,
    /// so there is no way back.
    ///
    /// Asserted with a **free slot**, which is the case where the sweep would
    /// actually succeed: at the cap `mayAddHabit` refuses it anyway, and a test
    /// that could not tell the two apart would pass for the wrong reason.
    ///
    /// ``SettingsEdits/commitAll(into:)`` states the rule. This is what stops a
    /// future session "fixing" the asymmetry by sweeping the add field, which
    /// looks like consistency and is a permanent write nobody confirmed.
    @Test("Done does not mint a habit out of the add field")
    func doneRefusesToCreateFromAHalfTypedName() {
        let seeded = Array(seededFour().prefix(3))
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)

        // Three habits, so there is a slot free and the cap is not what refuses.
        #expect(model.mayAddHabit)

        var edits = SettingsEdits(model)
        edits.newHabitName = "Walk"
        #expect(edits.canAdd(in: model))
        edits.commitAll(into: model)

        #expect(recorder.recorded.isEmpty)
        #expect(model.habits.map(\.name) == ["Move", "Read", "Build"])

        // And the text was not silently binned either: it is still in the field,
        // and Add still does what the user can see it does.
        #expect(edits.newHabitName == "Walk")
        edits.add(into: model)
        #expect(model.habits.map(\.name) == ["Move", "Read", "Build", "Walk"])
        #expect(recorder.recorded.map(\.kind) == [.habitCreated])
    }

    /// **The sequence reproduced on the device.** Type into a row, tap Remove,
    /// tap Restore: the row came back rendering the abandoned text, and Done
    /// wrote it to the log.
    ///
    /// The edit survived because it was cleared only by committing it, and the
    /// Done sweep runs over active habits — so an entry for a habit archived
    /// mid-edit had nothing to clear it and nothing to commit it, until the
    /// habit came back. That contradicts what the field is documented to
    /// guarantee: it can never show a name the log does not have.
    ///
    /// Removing a row is the user abandoning it, not confirming it.
    @Test("Removing a habit discards the name half-typed into it, through Restore and Done")
    func removingDiscardsTheInFlightRename() throws {
        let seeded = seededFour()
        let recorder = FakeRecorder(continuing: seeded)
        let model = model(events: seeded, recorder: recorder)
        var edits = SettingsEdits(model)

        let move = try #require(model.habits.first)
        #expect(move.name == "Move")

        edits.setName("Move outside every ZZZmorning", of: move)
        edits.remove(move, from: model)
        #expect(model.habits.map(\.name) == ["Read", "Build", "Reflect"])

        #expect(model.restoreHabit(try #require(model.removedHabits.first)))

        // The restored row shows the name the log has, not the abandoned text.
        let restored = try #require(model.habits.first { $0.id == move.id })
        #expect(edits.name(of: restored) == "Move")

        // And Done takes nothing with it.
        edits.commitAll(into: model)
        #expect(model.habits.map(\.name) == ["Move", "Read", "Build", "Reflect"])
        #expect(!recorder.recorded.contains { $0.kind == .habitRenamed })
        #expect(recorder.recorded.map(\.kind) == [.habitArchived, .habitUnarchived])
    }

    /// The other direction of the same rule. A write that fails changes nothing
    /// on screen everywhere else in this app, so a Remove that never archived
    /// anything must not quietly bin what the user was typing either.
    @Test("A Remove that fails to write keeps what the user was typing")
    func aFailedRemoveKeepsTheEdit() throws {
        let seeded = Array(seededFour().prefix(2))
        let model = model(
            events: seeded, recorder: FakeRecorder(continuing: seeded, fails: true)
        )
        var edits = SettingsEdits(model)

        let move = try #require(model.habits.first)
        edits.setName("Walk", of: move)
        edits.remove(move, from: model)

        #expect(model.removedHabits.isEmpty)
        #expect(model.habits.map(\.name) == ["Move", "Read"])
        #expect(edits.name(of: move) == "Walk")
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
            // The export section, added 2026-08-01. The bundle it writes
            // contains signatures, proofs and digests; the sheet still describes
            // what the file *is* and leaves the claims about what it proves to
            // the certificate and to the verifier, which are the two things that
            // have earned them.
            SettingsCopy.exportButton,
            SettingsCopy.exportFooter,
            // The achievement-pass failure notice, added 2026-08-01. It replaces
            // the Records footer when a pass has failed, so it is subject to the
            // same rule: it describes what did not happen, and claims nothing
            // about what the record proves.
            //
            // **With a reason present.** This read `reason: ""` until later the
            // same day, which checked the fixed half of the sentence and left the
            // only part that varies — the part composed from an error at runtime
            // — never checked at all. Every reason the app can produce is an
            // `AwardFailure.reason`, so the three below are what that type emits.
            //
            // A Foundation read failure, the ordinary case:
            SettingsCopy.awardFailed(reason: AwardFailure(cocoaReadFailure()).reason),
            // An error this project defines, whose bridged domain is its own
            // qualified type name:
            SettingsCopy.awardFailed(
                reason: AwardFailure(
                    CanonicalEncodingError.controlCharacter(scalar: 0x07, field: "facts")
                ).reason
            ),
            // **And the one that makes this list load-bearing.**
            // `CanonicalEncodingError.field` is composed as `"\(field).\(key)"`
            // over a map's own keys — `CanonicalBytes.map(_:field:)` — and that
            // encoder is also how a bundle received *from someone else* is
            // re-encoded to check its digest. So the field name in a real error
            // can be text this app never chose, including the exact vocabulary
            // `unearnedClaims` bans. That is the same hazard the type's own
            // comment names: "an error message is somewhere they can travel".
            SettingsCopy.awardFailed(
                reason: AwardFailure(
                    CanonicalEncodingError.controlCharacter(
                        scalar: 0x07, field: "facts.content_hash"
                    )
                ).reason
            ),
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
