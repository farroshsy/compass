import CompassDomain
import CompassInfrastructure
import CompassUI
import SwiftUI

/// The composition root — **the only place infrastructure is constructed.**
/// `docs/technical.md` §2, `.claude/skills/architecture.md`.
///
/// Everything below this line is ports. `CompassUI` cannot import
/// `CompassInfrastructure` at all, so this file is the seam, and it is the only
/// file that has to change when the store moves to the App Group container
/// before the widget ships in week 2.
@main
struct CompassApp: App {

    @State private var model = CompassApp.compose()

    var body: some Scene {
        WindowGroup {
            TodayView(model: model)
        }
    }
}

extension CompassApp {

    /// The two habits, **seeded with their names already set**, so first launch
    /// opens directly on Today with the rows there. No naming screen, no
    /// keyboard, no permission prompt, nothing between install and the first
    /// tap. `docs/product.md`, `.claude/skills/ui.md`.
    ///
    /// They are compiled in rather than read from a resource file: a seed that
    /// can fail to load is a first launch that can fail, and renaming is a
    /// cosmetic event by construction (`habitRenamed` never affects the fold),
    /// so the names are the cheapest thing in the project to change.
    /// `memory/next-tasks.md` names them until they are named for real.
    static let seededHabits: [(id: HabitID, name: String)] = [
        (HabitID(rawValue: "habit-a"), "habit-a"),
        (HabitID(rawValue: "habit-b"), "habit-b"),
    ]

    /// Builds the store, the writer identity, the journal and the clock, seeds
    /// the habits on a first launch, and hands the model its ports plus the
    /// events the first frame renders from.
    ///
    /// The log is read **synchronously** here. `docs/technical.md` §4 is
    /// explicit: the first frame must render correct data with zero awaits, and
    /// `await log.replay()` must not happen before anything is shown.
    @MainActor
    static func compose() -> TodayModel {
        // The single injected `storeURL`. No file path is constructed anywhere
        // else in the codebase, which is what makes switching this one line to
        // `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
        // a one-line change plus a file move. It MUST move before the widget
        // ships in week 2. `docs/technical.md` §6.
        let layout = StoreLayout(storeURL: documentsStoreURL())
        let clock = SystemClock()

        do {
            let writer = try WriterIdentity(layout: layout).load()

            // One read, two results. The first frame renders from `read.events`,
            // and `read.highWaterMarks` is this writer's `lamport` mark — so the
            // journal starts already knowing where its sequence resumes and the
            // first tap of the process does not decode the whole log on the main
            // actor. `docs/technical.md` §4 requires those synchronous steps to
            // be microseconds; §6 measures a full decode at 193 ms at five years
            // and 865 ms at ten.
            let read = try JournalReader(url: layout.events).read()
            let journal = try EventJournal(
                layout: layout,
                writer: writer,
                clock: clock,
                highWaterMark: read.highWaterMarks[writer] ?? 0
            )

            var events = read.events
            events.append(contentsOf: try seedIfEmpty(events, into: journal, clock: clock))

            return TodayModel(
                events: events, clock: clock, recorder: journal, source: journal
            )
        } catch {
            // `docs/technical.md` §6: **never refuse to launch.** A
            // `preconditionFailure` here crashed on every launch — the app was
            // unopenable for as long as the condition lasted, and the condition
            // is usually transient and the log usually intact.
            //
            // A silent in-memory fallback is not the alternative: it would take
            // taps the user believes are recorded and drop them. So the store is
            // ``UnavailableStore``, every write throws, `toggle` takes the tap
            // nowhere, and `isStoreAvailable` is what lets the screen say so
            // rather than look like an app that forgot everything.
            let store = UnavailableStore(reason: "\(error)")
            return TodayModel(
                events: [],
                clock: clock,
                recorder: store,
                source: store,
                isStoreAvailable: false
            )
        }
    }

    /// Appends one `habitCreated` per seeded habit, but only when no habit has
    /// ever existed. Habits are created the same way everything else in this
    /// system happens — as events in the log — so the seed survives relaunch
    /// because the events do, and re-seeding cannot happen.
    ///
    /// Archived habits still count as existing, so archiving both does not
    /// resurrect the seed.
    private static func seedIfEmpty(
        _ events: [Event], into journal: EventJournal, clock: SystemClock
    ) throws -> [Event] {
        guard project(events).habits.isEmpty else { return [] }

        let day = clock.today(cutoffHour: DayBoundary.cutoffHour)
        return try seededHabits.map { habit in
            try journal.record(
                kind: .habitCreated,
                day: day,
                source: nil,
                payload: .habit(habit.id, name: habit.name)
            )
        }
    }

    /// Week 1a's base URL: the app's own Documents directory.
    ///
    /// iCloud device backup is **deliberately left enabled** —
    /// `isExcludedFromBackup` is not set — because until CloudKit sync exists
    /// it is the only thing between a dropped phone and total loss. The honest
    /// consequence is that the plaintext diary is uploaded to Apple.
    /// `docs/technical.md` §6 and §8.
    private static func documentsStoreURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Compass", isDirectory: true)
    }
}
