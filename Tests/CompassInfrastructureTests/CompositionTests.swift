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

    @Test("A first launch seeds the two habits and opens the store")
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
            #expect(onDisk.events.count == 2)
        }
    }

    @Test("The seed happens once, ever")
    func seedIsNotRepeated() throws {
        try withTemporaryStore { layout in
            _ = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())
            let second = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())

            #expect(second.events.count == AppComposition.seededHabits.count)
            let onDisk = try JournalReader(url: layout.events).read()
            #expect(onDisk.events.count == 2)
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
            // Two seeded habits at lamport 1 and 2, one check-in at 3.
            let writer = try WriterIdentity(layout: layout).load()
            let onDisk = try JournalReader(url: layout.events).read()
            #expect(onDisk.highWaterMarks[writer] == 3)

            let second = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())
            #expect(second.events.count == 3)

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
            #expect(event.lamport == 4)
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
            #expect(widget.events.count == 2)
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
