import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// The composition root, tested as ordinary code.
///
/// These tests exist because the wiring used to live in `App/CompassApp.swift`,
/// which `swift test` does not compile and no test target covers. A verification
/// pass proved the cost by mutation: restoring the `preconditionFailure` on the
/// store-open failure path, and deleting the argument that hands the journal its
/// already-known high-water mark, each left the whole suite green. Both lines
/// were fixes for real bugs — the first crashed the app on every launch, the
/// second put a full log decode on the tap path.
@Suite("Composition — the launch path, where App/ used to hide")
struct CompositionTests {

    @Test("A first launch seeds the four habits and opens the store")
    func firstLaunchSeeds() throws {
        try withTemporaryStore { layout in
            let composed = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock()
            )

            #expect(composed.isStoreAvailable)
            #expect(composed.events.count == AppComposition.seededHabits.count)
            #expect(composed.events.allSatisfy { $0.kind == .habitCreated })

            let names = project(composed.events).habits.values.map(\.name).sorted()
            #expect(names == AppComposition.seededHabits.map(\.name).sorted())

            // Habits are created the same way everything else happens — as
            // events in the log — so the seed is on disk, not in memory.
            let onDisk = try JournalReader(url: layout.events).read()
            #expect(onDisk.events.count == AppComposition.seededHabits.count)
        }
    }

    /// The owner chose these on 2026-07-31, one per domain — health, learning,
    /// deep work, reflection — and the order is the order they appear on the
    /// screen. `memory/decisions.md`.
    ///
    /// Asserted literally, and against `activeHabits` rather than against the
    /// seed constant, because a test written against the constant follows the
    /// constant wherever it goes and therefore asserts nothing about what the
    /// user opens the app to.
    @Test("The seeded habits are Move, Read, Build, Reflect, in that order")
    func theSeededHabits() throws {
        try withTemporaryStore { layout in
            let composed = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock()
            )
            let habits = project(composed.events).activeHabits
            #expect(habits.map(\.name) == ["Move", "Read", "Build", "Reflect"])
        }
    }

    /// `docs/product.md` caps habits at four and this seeds at the cap, which is
    /// only safe because `TodayMetricsTests` proves four rows still fit at AX5.
    /// If the cap ever drops, first launch would open over-full and the settings
    /// sheet would refuse to add anything.
    @Test("The seed sits exactly at the cap, and does not exceed it")
    func theSeedFitsTheCap() throws {
        #expect(AppComposition.seededHabits.count == Projection.habitCap)

        try withTemporaryStore { layout in
            let composed = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock()
            )
            #expect(!project(composed.events).mayCreateHabit)
        }
    }

    /// `docs/achievement-protocol.md` §3.4: a `HabitID` is what `facts` carries
    /// into a signed, anchored, shareable record, and there is no redaction path
    /// and can never be one. The display name must not be recoverable from it.
    ///
    /// The cheap mistake this forbids is seeding `HabitID("move")` because it
    /// reads well in the log.
    @Test("The seeded identifiers carry no part of the seeded names")
    func theSeededIdentifiersAreOpaque() {
        for habit in AppComposition.seededHabits {
            #expect(
                !habit.id.rawValue.lowercased().contains(habit.name.lowercased()),
                "\(habit.id) leaks \(habit.name) into everything that is ever digested"
            )
        }
    }

    @Test("The seed happens once, ever")
    func seedIsNotRepeated() throws {
        try withTemporaryStore { layout in
            _ = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())
            let second = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())

            #expect(second.events.count == AppComposition.seededHabits.count)
            let onDisk = try JournalReader(url: layout.events).read()
            #expect(onDisk.events.count == AppComposition.seededHabits.count)
        }
    }

    /// The seed guard asks the **fold** whether a habit has ever existed, not
    /// whether the file has anything in it, and nothing asserted the difference:
    /// swapping it for `events.isEmpty` left all 206 tests green.
    ///
    /// The two are not the same question. A log can hold events and no habit —
    /// `subjectNamed` is one such event today, and week 1b's snapshot and
    /// achievement kinds are more — and on that log the app must still open with
    /// rows on it. Keyed on the raw file, first launch would produce a screen
    /// with no habits and no way to get any except the settings sheet, which is
    /// exactly the first-launch flow `docs/product.md` bans.
    @Test("A log with events but no habit still seeds")
    func seedingAsksTheFoldAndNotTheFile() throws {
        try withTemporaryStore { layout in
            // Something written, by this writer, that is not a habit.
            let identity = try WriterIdentity(layout: layout).load()
            let journal = try EventJournal(
                layout: layout, writer: identity, clock: frozenClock(), highWaterMark: 0
            )
            try journal.record(
                kind: .subjectNamed,
                day: day("2026-07-31"),
                source: nil,
                payload: .subject(named: "Farros Hilmi Syafei")
            )

            let composed = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock()
            )

            #expect(
                project(composed.events).activeHabits.map(\.name)
                    == AppComposition.seededHabits.map(\.name)
            )
            #expect(composed.events.count == AppComposition.seededHabits.count + 1)
        }
    }

    /// The other half of the same guard, and the claim its comment makes:
    /// **archived habits still count as existing.**
    ///
    /// Removing a habit archives it and never deletes it, so a user who removes
    /// all four has deliberately emptied their screen. A guard that counted only
    /// *active* habits would read that as a first launch and put all four back on
    /// the next cold start — silently undoing four decisions, and appending four
    /// more `habitCreated` events to a log that cannot be tidied. Mutating the
    /// guard to `activeHabits` was the second thing this suite could not see.
    @Test("Removing every habit does not resurrect the seed on the next launch")
    func archivedHabitsStillCountAsExisting() throws {
        try withTemporaryStore { layout in
            let first = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock()
            )
            for habit in AppComposition.seededHabits {
                try first.recorder.record(
                    kind: .habitArchived,
                    day: day("2026-07-31"),
                    source: nil,
                    payload: .habit(habit.id)
                )
            }

            let second = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock()
            )
            let projected = project(second.events)

            // An empty screen, and it stays empty.
            #expect(projected.activeHabits.isEmpty)
            // Nothing was deleted, and nothing was re-created: the same four
            // habits, each holding every day it recorded, all of them removed.
            #expect(projected.habits.count == AppComposition.seededHabits.count)
            #expect(second.events.count == AppComposition.seededHabits.count * 2)
            #expect(projected.archivedHabits.count == AppComposition.seededHabits.count)
        }
    }

    @Test("A store that cannot be opened launches degraded rather than crashing")
    func unopenableStoreLaunchesDegraded() async throws {
        // A plain file sitting where the container directory has to be:
        // `StoreLayout.prepare()` cannot create a directory over it, so the very
        // first touch of the store — minting this writer's identity — throws.
        //
        // `docs/technical.md` §6: "never silently drop lines and **never refuse
        // to launch**." The bug this pins is a `preconditionFailure` in the
        // catch, which crashed on every launch for a condition that is usually
        // transient, with the log sitting intact on disk the whole time.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("compass-tests-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let composed = AppComposition.compose(storeURL: root, clock: frozenClock())

        #expect(!composed.isStoreAvailable)
        #expect(composed.events.isEmpty)

        // Degraded, not silent. Every call throws rather than accepting a tap
        // the user believes is recorded and losing it at exit.
        #expect(throws: (any Error).self) {
            try composed.recorder.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitA)
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await composed.source.replay()
        }
    }

    @Test("The composed journal is primed, so the first tap does not read the log")
    func composedJournalIsPrimedWithItsHighWaterMark() throws {
        // `docs/technical.md` §4 requires the synchronous tap steps to be
        // microseconds; §6 measures a full decode at 193 ms at five years and
        // 865 ms at ten. The composition root already read the log to render the
        // first frame, so it must hand the journal the mark that fell out of
        // that read — otherwise the first tap of every launch decodes the whole
        // file again, on the main actor.
        //
        // `EventJournalTests` pins that a *primed* journal never reads the log.
        // What is pinned here is that the composition root primes it, which is
        // the line the mutation deleted.
        try withTemporaryStore { layout in
            let first = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())
            try first.recorder.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitA)
            )
            // Four seeded habits at lamport 1 to 4, one check-in at 5.
            let afterSeed = AppComposition.seededHabits.count
            let writer = try WriterIdentity(layout: layout).load()
            let onDisk = try JournalReader(url: layout.events).read()
            #expect(onDisk.highWaterMarks[writer] == afterSeed + 1)

            let second = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())
            #expect(second.events.count == afterSeed + 1)

            // Emptying the file *after* composing is the probe: from here, any
            // read of the log answers "this writer has never written", so only a
            // journal that was told its mark up front can continue the sequence.
            // An unprimed one recovers 0 and reissues lamport 1, which is the
            // `(lamport, device)` collision §3's total order cannot survive.
            let handle = try FileHandle(forWritingTo: layout.events)
            try handle.truncate(atOffset: 0)
            try handle.close()

            let event = try second.recorder.record(
                kind: .checkedIn, day: day("2026-08-01"), source: .tap, payload: .habit(habitA)
            )
            #expect(event.lamport == afterSeed + 2)
        }
    }

    @Test("Composing without naming a writer lands on the app's own chain")
    func defaultWriterIsTheApp() throws {
        // `compose()` takes no arguments at the one call site that matters —
        // `App/CompassApp.swift` — so the writer it picks is a default, and a
        // default nothing asserts is a default that can be changed in silence.
        //
        // Two things go wrong if it drifts, and neither is visible at the
        // keyboard. The app stops finding the identity it already persisted, so
        // an installed copy mints a fresh `DeviceID` on upgrade and starts a
        // second chain beside its own history — `PROJECT_CONSTITUTION.md` §5,
        // "existing data survives every change". And in week 2 the widget
        // arrives as a second writer, at which point the app's name has to be
        // distinct from the widget's for `docs/technical.md` §4 to hold at all.
        //
        // The store URL and the clock are passed because a genuinely
        // no-argument call writes into the real Documents directory. **The
        // writer is not passed. That is the whole point of this test.**
        try withTemporaryStore { layout in
            let composed = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock()
            )
            let event = try composed.recorder.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitA)
            )

            // The literal `"app"`, never `WriterIdentity.app`. A test written
            // against the constant follows the constant wherever it is moved and
            // therefore asserts nothing — which is exactly the hole this closes:
            // renaming that constant to any value that collides with nothing
            // left all 123 tests green while every installed copy's
            // `writer-app.id` was orphaned.
            let identityFile = layout.writerIdentity("app")
            let stored = (try? String(contentsOf: identityFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(stored != nil, "no writer-app.id: this launch wrote as some other writer")
            #expect(event.device == stored.map(DeviceID.init(rawValue:)))

            // And the seed went onto that same chain, so first launch and first
            // tap are one writer rather than two.
            #expect(composed.events.allSatisfy { $0.device == event.device })
        }
    }

    @Test("Each writer composes onto its own sequence")
    func writersAreSeparate() throws {
        // "Device means writer, not phone." `docs/technical.md` §4. The widget
        // process composes the same way in week 2 and must not land on the app's
        // chain, so the writer name is a parameter rather than a constant.
        try withTemporaryStore { layout in
            let app = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())
            let widget = AppComposition.compose(
                storeURL: layout.storeURL, clock: frozenClock(), writer: "widget"
            )

            let appEvent = try app.recorder.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitA)
            )
            let widgetEvent = try widget.recorder.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .widget, payload: .habit(habitB)
            )

            #expect(appEvent.device != widgetEvent.device)
            // The widget did not re-seed: the habits already exist in the log.
            #expect(widget.events.count == AppComposition.seededHabits.count)
        }
    }

    @Test("The default store URL is one directory under Documents")
    func defaultStoreURL() {
        // The one line that moves to
        // `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
        // before the widget ships in week 2. `docs/technical.md` §6.
        let url = AppComposition.documentsStoreURL
        #expect(url.lastPathComponent == "Compass")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Documents")
    }
}
