import CompassApplication
import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// The widget's path into the store. `docs/technical.md` §4 and §11.
///
/// `TwoWritersTests` proves the file survives two processes. This suite proves
/// the *second writer* is the one the design asks for: its own identity, the
/// same append API as the app, and none of the three rewriting steps the app's
/// composition performs.
@Suite("The widget, as a second writer")
struct WidgetStoreTests {

    /// A store with the four habits already in it, the way the app leaves one.
    private func seeded(
        _ layout: StoreLayout, at clock: SystemClock = frozenClock()
    ) throws -> ComposedStore {
        AppComposition.compose(storeURL: layout.storeURL, clock: clock)
    }

    private func appIdentity(_ layout: StoreLayout) throws -> DeviceID {
        try WriterIdentity(layout: layout, writer: WriterIdentity.app).load()
    }

    private func firstHabit(_ store: ComposedStore) throws -> HabitID {
        try #require(project(store.events).activeHabits.first?.id)
    }

    // MARK: The identity

    @Test("A widget check-in is written by a different writer than the app's")
    func widgetIsASecondWriter() throws {
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)

            try WidgetStore(layout: layout, clock: frozenClock()).toggle(habit)

            let read = try JournalReader(url: layout.events).read()
            let written = try #require(read.events.last)

            #expect(written.kind == .checkedIn)
            #expect(written.device != (try appIdentity(layout)))
            #expect(read.chain.heads.count == 2, "the widget wrote on the app's chain")
            #expect(read.chain.isIntact)

            // Its own **chain**, from genesis: `prev` links per writer.
            #expect(written.prev == EventChain.genesis)

            // Its own **clock**, resumed past everything already in the log —
            // four seeded habits, so 5. Starting at 1 would put the widget's
            // every event before the app's, and the fold would discard them.
            #expect(written.lamport == 5)
        }
    }

    @Test("The widget's identity survives across widget processes")
    func widgetIdentityIsStable() throws {
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)

            // Three separate `WidgetStore` values, as three separate invocations
            // of the extension would be. A name that minted a fresh UUID each
            // time would restart a `lamport` sequence at 1 while the old chain's
            // head is still under every `logHeads` ever written.
            for _ in 0..<3 {
                try WidgetStore(layout: layout, clock: frozenClock()).toggle(habit)
            }

            let read = try JournalReader(url: layout.events).read()
            #expect(read.chain.heads.count == 2)
            #expect(read.chain.isIntact)

            let theirs = read.events.filter { $0.device != (try? appIdentity(layout)) }
            #expect(theirs.map(\.lamport) == [5, 6, 7])
            #expect(Set(theirs.map(\.device)).count == 1, "the widget minted a second identity")
        }
    }

    // MARK: The same append API

    @Test("A widget check-in records source widget, and a revocation records none")
    func sourceIsTheWidgetsOwn() throws {
        // `source` is inside the canonical form, so this is a digested field and
        // not a display detail. It is also the field that makes
        // `docs/achievement-protocol.md` §3.4's `source_live` partition mean
        // anything — a widget tap that claimed to be a screen tap would be a
        // small permanent lie in every digest downstream of it.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)
            let widget = WidgetStore(layout: layout, clock: frozenClock())

            try widget.toggle(habit)
            try widget.toggle(habit)

            let events = try JournalReader(url: layout.events).read().events.suffix(2)
            let checkedIn = try #require(events.first)
            let revoked = try #require(events.last)

            #expect(checkedIn.kind == .checkedIn)
            #expect(checkedIn.source == .widget)
            #expect(revoked.kind == .checkInRevoked)
            #expect(revoked.source == nil, "a revocation carried a source")
        }
    }

    @Test("Tap toggles and tap again untoggles, from the widget exactly as from the app")
    func widgetTogglesTheSameWay() throws {
        // Two writers disagreeing about what a tap means is a fork with no lock
        // to catch it, so both go through `CheckIn.toggle`. This asserts the
        // product meaning rather than the call: three widget taps leave the habit
        // checked, and the log holds a revocation rather than a deletion.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)
            let widget = WidgetStore(layout: layout, clock: frozenClock())

            #expect(try widget.toggle(habit).habits.first { $0.id == habit }?.isChecked == true)
            #expect(try widget.toggle(habit).habits.first { $0.id == habit }?.isChecked == false)
            #expect(try widget.toggle(habit).habits.first { $0.id == habit }?.isChecked == true)

            let kinds = try JournalReader(url: layout.events).read()
                .events.filter { $0.payload.habitID == habit }.map(\.kind)
            #expect(kinds.filter { $0 == .checkedIn }.count == 2)
            #expect(kinds.filter { $0 == .checkInRevoked }.count == 1)
        }
    }

    @Test("The widget sees what the app wrote, and the app sees what the widget wrote")
    func thetwoWritersShareOneTruth() throws {
        // The two processes never talk. The only thing that makes them agree is
        // that each reads the same log before deciding — so a check-in made in
        // the app must make the *next* widget press a revocation, and the other
        // way round.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)
            let widget = WidgetStore(layout: layout, clock: frozenClock())

            // The app checks in.
            try CheckIn.toggle(
                habit, on: frozenClock().today(cutoffHour: DayBoundary.cutoffHour),
                in: project(store.events), from: .tap, using: store.recorder
            )

            // The widget, invoked cold, must see it and revoke.
            let afterWidget = try widget.toggle(habit)
            #expect(afterWidget.habits.first { $0.id == habit }?.isChecked == false)
            #expect(try JournalReader(url: layout.events).read().events.last?.kind
                == .checkInRevoked)

            // And the app, replaying, agrees.
            let replayed = project(try JournalReader(url: layout.events).read().events)
            #expect(replayed.isChecked(habit, on: frozenClock().today(cutoffHour: 4)) == false)
            #expect(try JournalReader(url: layout.events).read().chain.isIntact)
        }
    }

    @Test("A widget press at 01:30 counts for the day the user was awake for")
    func widgetAppliesTheDayBoundary() throws {
        // The 04:00 boundary is applied once, when the event is created, and
        // never in the fold. A second entry point is a second place it can be
        // got wrong, which is exactly why `.claude/skills/ios.md` refuses every
        // entry point that is not the widget.
        try withTemporaryStore { layout in
            let store = try seeded(layout, at: frozenClock(at: "2026-07-31T09:00:00+07:00"))
            let habit = try firstHabit(store)

            let lateNight = frozenClock(at: "2026-08-01T01:30:00+07:00")
            try WidgetStore(layout: layout, clock: lateNight).toggle(habit)

            let written = try #require(JournalReader(url: layout.events).read().events.last)
            #expect(written.day == day("2026-07-31"), "the widget crossed the day at midnight")
        }
    }

    // MARK: What it must never do

    @Test("The widget never seeds habits")
    func widgetNeverSeeds() throws {
        // A widget can be drawn on a phone where the app has never been opened.
        // Seeding there would mint four `habitCreated` events on the widget's
        // chain, and the app would then launch onto habits it never created.
        try withTemporaryStore { layout in
            let screen = try WidgetStore(layout: layout, clock: frozenClock()).read()

            #expect(screen.habits.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: layout.events.path))
        }
    }

    @Test("The widget never rewrites the log")
    func widgetNeverRewrites() throws {
        // `docs/technical.md` §4: "The widget never rewrites, compacts, or
        // truncates. Only the app process does, and only under the same lock."
        // The one rewriting operation in this codebase is the `reproject` hatch,
        // and it is spent — a widget that ran it would rewrite the only truth
        // from a background process, on a log the app may have open.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)
            let before = try rawLog(layout)

            try WidgetStore(layout: layout, clock: frozenClock()).toggle(habit)

            let after = try rawLog(layout)
            #expect(after.starts(with: before), "the widget rewrote lines it did not append")
            #expect(!FileManager.default.fileExists(atPath: layout.preChainEvents.path))
        }
    }

    @Test("A button that outlived its row writes nothing")
    func staleButtonIsRefused() throws {
        // A rendered widget outlives the row it was drawn from. Without this
        // guard a press arriving after the habit was removed in the app would
        // record a check-in against an archived habit — or, for an ID that was
        // never in this log at all, conjure a habit with no `habitCreated`
        // anywhere behind it.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)

            // The user removes it in the app.
            let day = frozenClock().today(cutoffHour: DayBoundary.cutoffHour)
            try store.recorder.record(
                kind: .habitArchived, day: day, source: nil, payload: .habit(habit)
            )
            let before = try rawLog(layout)

            let widget = WidgetStore(layout: layout, clock: frozenClock())
            #expect(throws: WidgetStoreError.self) { try widget.toggle(habit) }
            #expect(throws: WidgetStoreError.self) {
                try widget.toggle(HabitID(rawValue: "never-existed"))
            }
            #expect(try rawLog(layout) == before, "a refused press reached the file")
        }
    }

    // MARK: The two entry points the shell calls

    @Test("A render never fails, whatever the store is doing")
    func renderNeverFails() throws {
        // `Widget/` is a shell in the sense `App/` is — not compiled by
        // `swift test`, covered by no test target — so the `catch` has to live in
        // the package or live nowhere. A store that cannot be opened draws no
        // rows, which on a phone where the app has never been opened, or a build
        // whose profile carries no App Group, is the truth.
        let unreachable = URL(fileURLWithPath: "/dev/null/not-a-directory", isDirectory: true)
        let screen = AppComposition.widgetScreen(storeURL: unreachable, clock: frozenClock())

        #expect(screen.habits.isEmpty)
        #expect(screen.daysRecorded == 0)
    }

    @Test("A press draws the row it just changed")
    func pressReturnsTheNewScreen() throws {
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)

            let after = AppComposition.widgetPress(
                habit, storeURL: layout.storeURL, clock: frozenClock()
            )
            #expect(after.habits.first { $0.id == habit }?.isChecked == true)
            #expect(after.daysRecorded == 1)

            let again = AppComposition.widgetPress(
                habit, storeURL: layout.storeURL, clock: frozenClock()
            )
            #expect(again.habits.first { $0.id == habit }?.isChecked == false)
            #expect(again.daysRecorded == 0)
        }
    }

    @Test("A press on a stale button redraws rather than failing")
    func stalePressRedraws() throws {
        // The refusal in ``WidgetStore/toggle(_:)`` is a throw, and the shell has
        // nowhere to put one: an error dialog over the Home Screen for a button
        // that is merely out of date would be worse than the stale button was.
        // The redraw *is* the message — the row is not in it.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)
            let day = frozenClock().today(cutoffHour: DayBoundary.cutoffHour)
            try store.recorder.record(
                kind: .habitArchived, day: day, source: nil, payload: .habit(habit)
            )
            let before = try rawLog(layout)

            let screen = AppComposition.widgetPress(
                habit, storeURL: layout.storeURL, clock: frozenClock()
            )

            #expect(screen.habits.contains { $0.id == habit } == false)
            #expect(screen.habits.count == 3)
            #expect(try rawLog(layout) == before, "a refused press reached the file")
        }
    }

    @Test("An archived habit gets no button")
    func archivedHabitsHaveNoRow() throws {
        // The rows the widget draws are what a press can arrive for, so a row for
        // a habit whose press would be refused is a button that does nothing. It
        // matches Today, where a removed habit has no row either.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)
            try store.recorder.record(
                kind: .habitArchived,
                day: frozenClock().today(cutoffHour: DayBoundary.cutoffHour),
                source: nil, payload: .habit(habit)
            )

            let screen = AppComposition.widgetScreen(
                storeURL: layout.storeURL, clock: frozenClock()
            )
            #expect(screen.habits.count == 3)
            #expect(screen.habits.contains { $0.id == habit } == false)
            // Still in the log, still in the snapshot — archived is not deleted.
            #expect(screen.snapshot.habits.count == 4)
        }
    }

    @Test("The screen says it goes stale at the next 04:00, and not before")
    func screenGoesStaleAtTheBoundary() throws {
        // The widget's whole refresh policy. Everything it draws is a fact about
        // today, so the one scheduled moment it stops being true is the boundary.
        try withTemporaryStore { layout in
            try seeded(layout)
            let clock = frozenClock(at: "2026-07-31T09:00:00+07:00")
            let screen = AppComposition.widgetScreen(storeURL: layout.storeURL, clock: clock)

            #expect(screen.staleAfter == instant("2026-08-01T04:00:00+07:00"))
            #expect(screen.snapshot.day == day("2026-07-31"))
        }
    }

    // MARK: The disposable cache

    @Test("A widget press leaves a cache the app's first frame can believe")
    func widgetRewritesTheCache() throws {
        // The cache is the disposable tier and the replay always wins, so this
        // can never corrupt anything. What it prevents is a first frame that
        // contradicts a tap the user just made and watched land: without it the
        // app opens showing the habit unchecked and fills it a moment later, on
        // the one screen the whole project is about.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)

            try WidgetStore(layout: layout, clock: frozenClock()).toggle(habit)

            let cached = try #require(SnapshotStore(layout: layout).read())
            #expect(cached.habits.first { $0.id == habit }?.isChecked == true)
            #expect(cached.daysRecorded == 1)

            // And the app's next launch renders from it without reading the log.
            let relaunched = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock()
            )
            #expect(relaunched.snapshot?.habits.first { $0.id == habit }?.isChecked == true)
        }
    }

    @Test("The widget reads the log, never the cache it just wrote")
    func widgetReadsTheLog() throws {
        // A cache is a claim; the log is the fact. In the app a stale cache costs
        // one wrong frame and the replay fixes it — here it decides *which event
        // gets written*, and a stale "unchecked" appends a second `checkedIn` for
        // a day that already has one.
        try withTemporaryStore { layout in
            let store = try seeded(layout)
            let habit = try firstHabit(store)
            let widget = WidgetStore(layout: layout, clock: frozenClock())

            try widget.toggle(habit)
            // Someone deletes the cache — permitted at any moment, by definition.
            SnapshotStore(layout: layout).delete()

            let screen = try widget.read()
            #expect(screen.habits.first { $0.id == habit }?.isChecked == true)

            // And the next press still revokes, because the decision came from
            // the log rather than from the file that is no longer there.
            #expect(try JournalReader(url: layout.events).read().events.count
                == store.events.count + 1)
            try widget.toggle(habit)
            #expect(try JournalReader(url: layout.events).read().events.last?.kind
                == .checkInRevoked)
        }
    }
}
