import CompassApplication
import CompassDomain
import Foundation

/// **The second writer's whole path into the store.** `docs/technical.md` §4 and
/// §11.
///
/// The widget process reads the log to know what to draw and appends one event
/// when a button is pressed. That is all it does, and this type is all of it —
/// which is the point: the interactive widget takes the daily loop from ~3 s to
/// ~0.7 s, and every line of that has to be somewhere `swift test` compiles. The
/// `Widget/` folder is a shell holding an `AppIntent` conformance and a view, in
/// exactly the sense `App/` is a shell, and for exactly the same reason —
/// neither is compiled by `swift test` and neither has a test target, and a
/// mutation pass has already proved twice over what that costs.
///
/// ### It is a second writer, not a second phone
///
/// `device` means writer. The app process and the widget process on one phone
/// are two writers with two `device` UUIDs, two `lamport` sequences and two
/// `prev` chains, and `witness.logHeads` carries two heads for one phone. That is
/// not a workaround for the widget: ADR 0002 rejected a single global hash chain
/// because concurrent appenders fork it, and two processes on one phone are
/// simply the first instance of the case it was rejected for.
///
/// Concretely, ``WriterIdentity/widget`` names a second identity file, so
/// ``EventJournal`` here stamps a different `device`, counts a different
/// `lamport` sequence, and chains `prev` onto a head that no app-process event
/// has ever been on.
///
/// ### Three things it deliberately does not do
///
/// `docs/technical.md` §4: "The widget never rewrites, compacts, or truncates.
/// Only the app process does, and only under the same lock." So this path runs
/// **no** App Group migration, **no** `reproject` hatch and **no** habit seed,
/// all three of which ``AppComposition/compose(storeURL:clock:writer:)`` does and
/// all three of which rewrite or invent. A widget that reprojected would rewrite
/// the only truth from a background process while the app held it open; a widget
/// that seeded would mint four habits because it was drawn before the app was
/// ever opened.
///
/// ### Why it reads the log and not the cache
///
/// `snapshot.json` is the disposable tier and is written by whichever process
/// last recorded something — including this one. It is nonetheless not read here,
/// because a cache is a claim and the log is the fact, and the cost of being
/// wrong is different in the two processes: the app renders a stale first frame
/// and reconciles a moment later from a `.task`, whereas this type's read decides
/// **which event gets written**. A stale "unchecked" here appends a second
/// `checkedIn` for a day that already has one. `docs/technical.md` §6 measures a
/// full decode at 193 ms at five years, which is a frame budget the app does not
/// have and a timeline budget this process does.
public struct WidgetStore: Sendable {

    /// The single injected base URL, exactly as everywhere else.
    /// `.claude/skills/architecture.md`: no file path is constructed anywhere but
    /// ``StoreLayout``.
    public let layout: StoreLayout

    private let clock: SystemClock

    /// The writer *name*, resolved to a UUID on first write. Injectable so the
    /// two-writer test can run two of these against one file without either
    /// pretending to be the other.
    private let writer: String

    public init(
        layout: StoreLayout,
        clock: SystemClock = SystemClock(),
        writer: String = WriterIdentity.widget
    ) {
        self.layout = layout
        self.clock = clock
        self.writer = writer
    }

    /// What the widget draws: the same value the app's launch cache carries, so
    /// the two surfaces cannot describe one log in two shapes.
    ///
    /// It is computed rather than read from `snapshot.json` — see the type
    /// documentation. On an empty store it returns an honest empty screen rather
    /// than throwing: a widget on a phone where the app has never been opened
    /// draws no rows, which is true.
    public func read() throws -> TodaySnapshot {
        let events = try JournalReader(url: layout.events).read().events
        return screen(from: events)
    }

    /// Records one check-in **as the second writer**, and returns the screen as
    /// it stands afterwards.
    ///
    /// The whole of the decision is ``CheckIn/toggle(_:on:in:from:using:)`` —
    /// the same call `TodayModel.toggle` makes, with `.widget` in place of
    /// `.tap`. Nothing about which event to append is decided here, because two
    /// writers deciding that separately is a fork with no lock to catch it.
    ///
    /// ### The journal is handed no resume, deliberately
    ///
    /// `AppComposition.compose` hands its journal the resume that fell out of the
    /// read it did anyway, which keeps a full decode off the app's tap path. This
    /// does the opposite, and pays for a second decode to do it.
    ///
    /// The reason is that a widget extension is not one process. iOS may run
    /// several instances, and unlike the app they all share **one** writer
    /// identity — so two of them recovering `lamport` from two unsynchronised
    /// reads would stamp the same `(lamport, device)` pair onto two events and
    /// fork one chain into two. `docs/technical.md` §4 answers exactly that:
    /// "Any operation that must read the tail and then append … takes an advisory
    /// `flock` on the file for the duration of the read-then-write." Passing a
    /// resume is what makes ``EventJournal/record(kind:day:source:payload:)``
    /// skip that lock, so this does not pass one.
    ///
    /// The read below is therefore for the *decision* only, and being one event
    /// stale there is harmless — it is the same staleness the app tolerates
    /// between its first frame and its replay. Being stale about `lamport` is not
    /// harmless, so that half happens under the lock.
    @discardableResult
    public func toggle(_ habit: HabitID) throws -> TodaySnapshot {
        let identity = try WriterIdentity(layout: layout, writer: writer).load()
        let read = try JournalReader(url: layout.events).read()

        var projection = project(read.events)
        let day = clock.today(cutoffHour: DayBoundary.cutoffHour)

        // **A widget timeline goes stale; the log does not.** A rendered button
        // outlives the row it was drawn from, so a tap can arrive for a habit the
        // user removed in the app minutes ago — and `CheckIn.kind` would happily
        // check in a habit that has no row, or one that never existed at all,
        // creating a habit-shaped hole in the projection with no `habitCreated`
        // anywhere in the log. The app cannot reach this state: its rows come
        // from the live projection it is holding. Refusing is the honest answer —
        // nothing is written, and the timeline the caller reloads afterwards
        // shows the habit is gone.
        guard projection.habit(habit)?.isArchived == false else {
            throw WidgetStoreError.noSuchHabit(habit)
        }

        let journal = try EventJournal(layout: layout, writer: identity, clock: clock)
        defer { journal.close() }

        let event = try CheckIn.toggle(
            habit, on: day, in: projection, from: .widget, using: journal
        )
        projection.apply(event)
        let screen = screen(from: read.events, projection: projection, on: day)

        // The disposable tier, rewritten by whichever process last recorded
        // something. It carries no `lamport`, no head and no `device` — a file
        // that may be deleted at any moment must never be able to fork a chain —
        // so a second process writing it cannot hurt anything, and not writing it
        // would leave the app's next launch rendering a first frame that
        // contradicts a tap the user just made and watched land.
        SnapshotStore(layout: layout).write(screen)

        return screen
    }

    private func screen(from events: [Event]) -> TodaySnapshot {
        screen(
            from: events,
            projection: project(events),
            on: clock.today(cutoffHour: DayBoundary.cutoffHour)
        )
    }

    private func screen(
        from events: [Event], projection: Projection, on day: Day
    ) -> TodaySnapshot {
        TodaySnapshot(
            projection: projection,
            subject: declaredSubject(events),
            today: day,
            spineLength: TodaySnapshot.spineLength
        )
    }
}

// MARK: - Errors

public enum WidgetStoreError: Error, Hashable, Sendable {
    /// A button that outlived its row. The habit is archived, or was never in
    /// this log at all.
    case noSuchHabit(HabitID)
}

// MARK: - The composition root's widget half

extension AppComposition {

    /// The widget process's store, wired the same way the app's is and with the
    /// **second** writer identity. `docs/technical.md` §4.
    ///
    /// It is here because infrastructure is constructed in exactly one file, and
    /// the widget process is still this codebase constructing infrastructure —
    /// it just happens to be a different process doing it. The `Widget/` folder
    /// calls this and holds no wiring of its own, for the same reason `App/`
    /// holds none.
    ///
    /// The store URL is ``storeURL``, which prefers the App Group container. In
    /// the widget that preference is not a preference: a widget cannot read the
    /// app's Documents directory at all, so a build whose profile does not carry
    /// `group.dev.farros.compass` gives the app a working store and the widget an
    /// empty one. That is the documented consequence of §6's fallback, and it is
    /// why `docs/technical.md` §6 requires the container move to land before this
    /// ships — it did, in week 1b.
    public static func composeWidget(
        storeURL: URL = AppComposition.storeURL,
        clock: SystemClock = SystemClock()
    ) -> WidgetStore {
        WidgetStore(layout: StoreLayout(storeURL: storeURL), clock: clock)
    }

    /// Everything one render of the widget needs, and it cannot fail.
    ///
    /// `Widget/` is a shell in exactly the sense `App/` is: not compiled by
    /// `swift test`, covered by no test target. So the `catch` lives here rather
    /// than there, and so does the answer — an empty screen. A widget whose store
    /// is unreachable draws no rows, which on a phone where the app has never been
    /// opened, or a build whose profile carries no App Group, is the truth.
    ///
    /// It is deliberately **not** ``ComposedStore/isStoreAvailable``'s equivalent:
    /// Today says out loud that it is not recording, because the user is looking
    /// at it and about to tap. A widget has no room to say anything and no way to
    /// be asked a follow-up question, and the app is one tap away.
    public static func widgetScreen(
        storeURL: URL = AppComposition.storeURL,
        clock: SystemClock = SystemClock()
    ) -> WidgetScreen {
        let store = composeWidget(storeURL: storeURL, clock: clock)
        let today = clock.today(cutoffHour: DayBoundary.cutoffHour)
        return WidgetScreen(
            snapshot: (try? store.read())
                ?? TodaySnapshot(
                    projection: Projection(), subject: SubjectName(),
                    today: today, spineLength: TodaySnapshot.spineLength
                ),
            staleAfter: clock.nextDayStart(after: clock.now())
        )
    }

    /// One press of one habit's button, and the screen to draw next.
    ///
    /// **It swallows the throw, on purpose.** The two things
    /// ``WidgetStore/toggle(_:)`` refuses are a habit that is archived and a habit
    /// that was never in this log — both of which mean the button outlived the row
    /// it was drawn from. There is nothing to tell the user: the honest response
    /// is to write nothing and redraw, and the redraw is the message, because the
    /// row the finger is on will not be there. Surfacing an error dialog over the
    /// Home Screen for a button that is merely out of date would be worse than
    /// the stale button was.
    ///
    /// A real write failure — a full disk — takes the same path for the same
    /// reason `TodayModel.toggle` does: the tap does nothing and the screen keeps
    /// telling the truth.
    public static func widgetPress(
        _ habit: HabitID,
        storeURL: URL = AppComposition.storeURL,
        clock: SystemClock = SystemClock()
    ) -> WidgetScreen {
        let store = composeWidget(storeURL: storeURL, clock: clock)
        guard let snapshot = try? store.toggle(habit) else {
            return widgetScreen(storeURL: storeURL, clock: clock)
        }
        return WidgetScreen(snapshot: snapshot, staleAfter: clock.nextDayStart(after: clock.now()))
    }
}

/// One render of the widget: what to draw, and when it stops being true.
///
/// The second half is the whole refresh policy. Everything the widget shows is a
/// fact about **today**, so the only scheduled moment it goes stale is the 04:00
/// boundary — no guessed interval, no periodic wake-up, and no reason to ask the
/// system for more budget than one redraw a day plus one per press.
public struct WidgetScreen: Sendable {

    /// The same value the app's launch cache carries, so the two surfaces cannot
    /// describe one log in two shapes.
    public let snapshot: TodaySnapshot

    /// The next 04:00 local. See ``SystemClock/nextDayStart(after:cutoffHour:)``.
    public let staleAfter: Date

    public init(snapshot: TodaySnapshot, staleAfter: Date) {
        self.snapshot = snapshot
        self.staleAfter = staleAfter
    }

    /// The rows, oldest first — active habits only. An archived habit has no row
    /// on Today and must not have one here either: a button for a habit the user
    /// removed is a button whose press ``WidgetStore/toggle(_:)`` refuses.
    public var habits: [TodaySnapshot.Habit] {
        snapshot.habits.filter { !$0.isArchived }
    }

    /// The number under the rows, and the same one Today makes the largest thing
    /// on its screen: distinct days anything was recorded. **Never the streak** —
    /// a number that resets to zero teaches starting over.
    public var daysRecorded: Int { snapshot.daysRecorded }
}
