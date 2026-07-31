import CompassDomain
import Foundation

/// The composition root — **the only place infrastructure is constructed.**
/// `docs/technical.md` §2 and §6, `.claude/skills/architecture.md`.
///
/// Everything it returns is ports. `CompassUI` cannot import
/// `CompassInfrastructure` at all, so this is the seam, and it is the only place
/// that has to change when the store moves to the App Group container before the
/// widget ships in week 2.
///
/// ### Why it is here and not in `App/`
///
/// It used to be `CompassApp.compose()`, inside `App/CompassApp.swift`. That
/// folder is not compiled by `swift test` and has no test target, and a
/// verification pass proved what that costs by mutation: restoring the
/// `preconditionFailure` on the store-open failure path, **and** deleting the
/// argument that hands the journal its already-known high-water mark, left all
/// 111 tests passing. Both of those lines were fixes for real bugs — one crashed
/// the app on every launch, the other put a full log decode on the tap path —
/// and a future session could have deleted either in silence.
///
/// So the wiring moved into a target the test suite compiles, and `App/` became
/// a shell with no logic in it: it constructs the composed value and hands it to
/// the SwiftUI scene. Nothing in `App/` branches, catches, or forwards an
/// argument any more, because an argument in `App/` is an argument no test can
/// see.
///
/// The two behaviours that mutation exposed are now ordinary unit tests, in
/// `CompassInfrastructureTests/CompositionTests.swift`.
///
/// It is not in `CompassApplication`, which `docs/technical.md` §2 would
/// otherwise suggest, for a mechanical reason: `CompassUI` imports
/// `CompassApplication`, so `CompassApplication` cannot import `CompassUI`, and
/// composing the app means producing something the UI can consume. It is here
/// because this is the target that already constructs adapters, and composing
/// is still done in exactly one file.
public enum AppComposition {

    /// The four habits, **seeded with their names already set**, so first launch
    /// opens directly on Today with the rows there. No naming screen, no
    /// keyboard, no permission prompt, nothing between install and the first
    /// tap. `docs/product.md`, `.claude/skills/ui.md`.
    ///
    /// They are compiled in rather than read from a resource file: a seed that
    /// can fail to load is a first launch that can fail, and renaming is a
    /// cosmetic event by construction (`habitRenamed` never affects the fold),
    /// so the names are the cheapest thing in the project to change.
    ///
    /// **Move, Read, Build, Reflect — chosen by the owner on 2026-07-31**, one
    /// per domain: health, learning, deep work, reflection. Relationship and
    /// character are folded into Reflect rather than becoming two more booleans,
    /// because `docs/product.md` caps this at four and a fifth row makes the
    /// three-second promise false. `memory/decisions.md` has the reasoning.
    ///
    /// **This seeds at the cap.** `TodayMetricsTests` is what makes that safe:
    /// four rows still fit at AX5, with 137 points to spare.
    ///
    /// The identifiers stay opaque and carry no part of the names.
    /// `docs/achievement-protocol.md` §3.4 keeps display names out of anything
    /// digested, and a `HabitID` is exactly what `facts` carries — so an ID of
    /// `"move"` would put the name inside a signed, anchored record with no
    /// redaction path, which is the failure that section exists to prevent.
    /// Their byte order is also their creation order here, which is the order
    /// they appear on screen.
    public static let seededHabits: [(id: HabitID, name: String)] = [
        (HabitID(rawValue: "habit-a"), "Move"),
        (HabitID(rawValue: "habit-b"), "Read"),
        (HabitID(rawValue: "habit-c"), "Build"),
        (HabitID(rawValue: "habit-d"), "Reflect"),
    ]

    /// Week 1a's base URL: the app's own Documents directory.
    ///
    /// iCloud device backup is **deliberately left enabled** —
    /// `isExcludedFromBackup` is not set — because until CloudKit sync exists it
    /// is the only thing between a dropped phone and total loss. The honest
    /// consequence is that the plaintext diary is uploaded to Apple.
    /// `docs/technical.md` §6 and §8.
    public static var documentsStoreURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Compass", isDirectory: true)
    }

    /// Builds the store, the writer identity, the journal and the clock, seeds
    /// the habits on a first launch, and returns the ports plus the events the
    /// first frame renders from.
    ///
    /// The log is read **synchronously**. `docs/technical.md` §4 is explicit:
    /// the first frame must render correct data with zero awaits, and
    /// `await log.replay()` must not happen before anything is shown.
    ///
    /// **It does not throw and it does not trap.** `docs/technical.md` §6 ends
    /// its damaged-log policy with "never silently drop lines and never refuse
    /// to launch", so a store that cannot be opened produces a degraded launch,
    /// never a crash.
    public static func compose(
        storeURL: URL = AppComposition.documentsStoreURL,
        clock: SystemClock = SystemClock(),
        writer: String = WriterIdentity.app
    ) -> ComposedStore {
        // The single injected `storeURL`. No file path is constructed anywhere
        // else in the codebase, which is what makes switching this one line to
        // `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` a
        // one-line change plus a file move. It MUST move before the widget ships
        // in week 2. `docs/technical.md` §6.
        let layout = StoreLayout(storeURL: storeURL)

        do {
            let identity = try WriterIdentity(layout: layout, writer: writer).load()

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
                writer: identity,
                clock: clock,
                highWaterMark: read.highWaterMarks[identity] ?? 0
            )

            var events = read.events
            events.append(contentsOf: try seedIfEmpty(events, into: journal, clock: clock))

            return ComposedStore(
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
            // ``UnavailableStore``, every write throws, the tap goes nowhere, and
            // ``ComposedStore/isStoreAvailable`` is what lets the screen say so
            // rather than look like an app that forgot everything.
            let store = UnavailableStore(reason: "\(error)")
            return ComposedStore(
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
}
