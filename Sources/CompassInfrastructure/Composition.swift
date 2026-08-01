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

    /// The App Group the store lives in from week 1b. `docs/technical.md` §6.
    ///
    /// It must move before the widget ships in week 2, because a widget cannot
    /// read a container it has no access to — and §6 is equally clear that the
    /// entitlement this needs must not be a gate on storage code, since an
    /// entitlement needs a provisioning profile which needs the paid developer
    /// account, and "day one is where projects die". Hence the fallback in
    /// ``storeURL``.
    public static let appGroupIdentifier = "group.dev.farros.compass"

    /// Week 1a's base URL: the app's own Documents directory, and now the
    /// fallback when the App Group container is not reachable.
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

    /// The App Group container's store, or `nil` when the container is not
    /// reachable — no entitlement, or a build signed without one.
    public static var appGroupStoreURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Compass", isDirectory: true)
    }

    /// **The single injected base URL.** `docs/technical.md` §6,
    /// `.claude/skills/architecture.md`: every path in the codebase obtains its
    /// base from here, and no file path is constructed anywhere else. That rule
    /// is what made this one line the whole of the move.
    ///
    /// It prefers the App Group container and falls back to Documents. The
    /// fallback is not a hedge, it is §6's stated requirement: "one overstated
    /// sentence turned a purchase into a hard gate on all storage code, for a
    /// project whose documented failure mode is that day one is where projects
    /// die." A build with no entitlement still runs, still records, and still
    /// keeps every event — it simply cannot be read by a widget, which does not
    /// exist until week 2.
    public static var storeURL: URL {
        appGroupStoreURL ?? documentsStoreURL
    }

    /// Moves a Documents-era store into the App Group container, once.
    ///
    /// **Existing data survives every change** — `PROJECT_CONSTITUTION.md` §5 —
    /// so nothing is deleted here. The files are copied across and the old
    /// directory is then renamed rather than removed: if anything about this is
    /// wrong, the week-1a log is still sitting on disk under a name that says
    /// what happened to it.
    ///
    /// It is a no-op in every case but the one it is for: no container, no old
    /// store, or a container that already holds a log.
    @discardableResult
    static func moveToAppGroupIfNeeded(
        from source: URL = AppComposition.documentsStoreURL,
        to destination: URL? = AppComposition.appGroupStoreURL
    ) -> Bool {
        let manager = FileManager.default
        guard let destination, destination != source else { return false }
        guard manager.fileExists(atPath: source.path) else { return false }

        // A container that already holds a log is the normal case from the
        // second launch onwards. Deciding on the log rather than on the
        // directory matters: `StoreLayout.prepare()` creates the directory, so
        // its existence proves nothing about whether anything is in it.
        let events = StoreLayout(storeURL: destination).events
        guard !manager.fileExists(atPath: events.path) else { return false }

        do {
            try StoreLayout(storeURL: destination).prepare()
            for name in try manager.contentsOfDirectory(atPath: source.path) {
                let target = destination.appendingPathComponent(name)
                guard !manager.fileExists(atPath: target.path) else { continue }
                try manager.copyItem(at: source.appendingPathComponent(name), to: target)
            }
            // Renamed, never removed. The copy above is the migration; this is
            // only what stops it happening twice.
            //
            // A name already in use is not a reason to overwrite it: whatever is
            // sitting there is a previous store that somebody kept, and this
            // method exists to not lose one.
            let parent = source.deletingLastPathComponent()
            var kept = parent.appendingPathComponent("Compass.moved-to-group", isDirectory: true)
            if manager.fileExists(atPath: kept.path) {
                kept = parent.appendingPathComponent(
                    "Compass.moved-to-group-\(UUID().uuidString)", isDirectory: true
                )
            }
            try manager.moveItem(at: source, to: kept)
            return true
        } catch {
            // A half-copied container is not a loss: the source is untouched,
            // the next launch tries again, and every file it did copy is skipped
            // because it is already there. Failing loudly here would refuse to
            // launch, which §6 forbids.
            return false
        }
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
        storeURL: URL = AppComposition.storeURL,
        clock: SystemClock = SystemClock(),
        writer: String = WriterIdentity.app
    ) -> ComposedStore {
        // The file move that goes with the one-line URL change above.
        // `docs/technical.md` §6: "Switching that URL from `.documentDirectory`
        // to `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
        // is then one line plus a file move, and it MUST happen before the
        // widget ships in week 2."
        //
        // It runs only when the default is in play. A caller that named its own
        // `storeURL` — every test, and any future second store — is not
        // migrating anything, and moving a directory out from under it would be
        // this function reaching outside what it was asked to compose.
        if storeURL == AppComposition.storeURL {
            moveToAppGroupIfNeeded()
        }

        // The single injected `storeURL`. No file path is constructed anywhere
        // else in the codebase, which is what made that move one line here and
        // nothing anywhere else. `docs/technical.md` §6.
        let layout = StoreLayout(storeURL: storeURL)

        do {
            let identity = try WriterIdentity(layout: layout, writer: writer).load()

            // **Before anything opens the log for appending.** The one-time
            // hatch in `docs/technical.md` §11 replays a week-1a log — every
            // event carrying `prev = genesis`, because the canonical encoding
            // did not exist when they were written — into a freshly chained one,
            // keeping the original as `events.jsonl.pre-chain`. It is idempotent
            // by construction: once it has run the chain verifies, and a log
            // whose chain verifies needs nothing. It closes permanently the
            // moment anything is signed.
            //
            // Its outcome is deliberately not branched on here. Every value it
            // can return leaves a log this composition can open and this app can
            // use: a refusal leaves the week-1a log exactly as it was, and the
            // journal then chains forward from the last event it can read, which
            // `JournalRead.chain` reports as one break at the boundary rather
            // than hiding. What is genuinely missing is a *surface* saying so —
            // recorded in `memory/known-bugs.md` beside the damaged-log notice
            // §6 owes, which is the same missing surface.
            try Reprojector(layout: layout).reprojectIfNeeded()

            // The launch cache, read synchronously and moved to today. It is a
            // hit on every launch after the first, including the ordinary
            // daily-driver case of opening the app the morning after — the strip
            // slides and today's booleans clear.
            let today = clock.today(cutoffHour: DayBoundary.cutoffHour)
            let cached = SnapshotStore(layout: layout).read()?.rolledForward(to: today)

            // A cache with no habits in it cannot be the first frame: a fresh
            // install must fall through to the seed below, and a launch that
            // rendered four empty rows would look exactly like one that lost
            // them.
            if let cached, !cached.habits.isEmpty {
                // **Nothing decodes the log here.** The journal starts unprimed
                // and `EventLog.replay()` — the `.task` immediately after the
                // first frame — hands it the resume it read anyway. If a tap
                // beats that replay, the journal recovers under the advisory
                // `flock` instead, which is the cold-start path §4 describes.
                let journal = try EventJournal(layout: layout, writer: identity, clock: clock)
                let log = EventLog(layout: layout, clock: clock, priming: journal)
                return ComposedStore(
                    events: [], clock: clock, recorder: journal, source: log,
                    snapshot: cached, absorber: log,
                    awarding: AchievementIssuer(
                        layout: layout, recorder: journal, clock: clock
                    ),
                    // Week 4. It is constructed on every launch and makes no
                    // request until something is actually due, which is what
                    // lets `TodayModel` call it on every foreground.
                    anchoring: AnchorPipeline(layout: layout, clock: clock)
                )
            }

            // No usable cache: first launch, or it was deleted. One read, two
            // results — the first frame renders from `read.events`, and
            // `read.resume(for:)` is this writer's `lamport` mark **and its
            // chain head**, so the journal starts already knowing where its
            // sequence resumes and what its next `prev` is.
            let read = try JournalReader(url: layout.events).read()
            let journal = try EventJournal(
                layout: layout,
                writer: identity,
                clock: clock,
                resume: read.resume(for: identity)
            )
            let log = EventLog(layout: layout, clock: clock, priming: journal)

            var events = read.events
            events.append(contentsOf: try seedIfEmpty(events, into: journal, clock: clock))

            return ComposedStore(
                events: events, clock: clock, recorder: journal, source: log, absorber: log,
                // Week 3's line 5. It reads the log itself rather than taking a
                // projection, because `witness.evidenceRoot` is built from the
                // qualifying events' `content_hash` and a projection has no
                // events in it. `docs/achievement-protocol.md` §4.1.
                awarding: AchievementIssuer(layout: layout, recorder: journal, clock: clock),
                anchoring: AnchorPipeline(layout: layout, clock: clock)
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
