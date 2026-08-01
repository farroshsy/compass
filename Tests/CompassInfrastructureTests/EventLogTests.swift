import CompassDomain
import Foundation
import Testing

@testable import CompassInfrastructure

/// `actor EventLog`, the snapshot cache it owns, and the App Group container the
/// store moved into. `docs/technical.md` §4, §6 and §11.
@Suite("EventLog — the log off the tap path")
struct EventLogTests {

    private func seed(_ layout: StoreLayout, days: Int = 3) throws -> EventJournal {
        let journal = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
        try journal.record(kind: .habitCreated, day: day("2026-07-01"),
                           payload: .habit(habitA, name: "Move"))
        for offset in 0..<days {
            try journal.record(kind: .checkedIn, day: day("2026-07-01").adding(offset),
                               source: .tap, payload: .habit(habitA))
        }
        return journal
    }

    // MARK: The cache

    @Test("The replay writes the cache, and the cache is what the next launch reads")
    func replayWritesTheCache() async throws {
        try await withTemporaryStoreAsync { layout in
            _ = try seed(layout)
            #expect(SnapshotStore(layout: layout).read() == nil, "nothing has replayed yet")

            let log = EventLog(layout: layout, clock: frozenClock())
            let events = try await log.replay()
            #expect(events.count == 4)

            let cached = try #require(SnapshotStore(layout: layout).read())
            #expect(cached.day == day("2026-07-31"))
            #expect(cached.habits.map(\.name) == ["Move"])
            #expect(cached.daysRecorded == 3)
            #expect(cached.firstRecordedDay == day("2026-07-01"))
        }
    }

    @Test("Absorbing rewrites the cache without going back to the file")
    func absorbRewritesTheCache() async throws {
        try await withTemporaryStoreAsync { layout in
            let journal = try seed(layout)
            let log = EventLog(layout: layout, clock: frozenClock())
            _ = try await log.replay()

            // §4 line 3 then line 4: the write is already durable when the actor
            // hears about it.
            let tapped = try journal.record(kind: .checkedIn, day: day("2026-07-31"),
                                            source: .tap, payload: .habit(habitA))
            await log.absorb(tapped)

            let cached = try #require(SnapshotStore(layout: layout).read())
            #expect(cached.daysRecorded == 4)
            #expect(cached.dayIsRecorded)
            #expect(cached.habits.first?.isChecked == true)
            #expect(await log.cached?.count == 5)
        }
    }

    @Test("Absorbing before any replay writes nothing rather than a wrong cache")
    func absorbWithoutAReplayWritesNothing() async throws {
        try await withTemporaryStoreAsync { layout in
            let journal = try seed(layout)
            let log = EventLog(layout: layout, clock: frozenClock())

            let tapped = try journal.record(kind: .checkedIn, day: day("2026-07-31"),
                                            source: .tap, payload: .habit(habitA))
            await log.absorb(tapped)

            // A cache folded from one event would claim the log holds one event
            // — four days of history rendered as one. No cache at all costs one
            // slower launch; a wrong one shows a wrong number.
            #expect(SnapshotStore(layout: layout).read() == nil)
        }
    }

    @Test("The replay hands the journal the resume it read anyway")
    func replayPrimesTheJournal() async throws {
        try await withTemporaryStoreAsync { layout in
            let seeded = try seed(layout)
            seeded.close()

            // A journal that was handed nothing — the launch that rendered from
            // the cache. `EventLog.replay()` reads the log a moment later, from
            // the `.task` after the first frame, and primes it.
            let journal = try EventJournal(layout: layout, writer: writerApp,
                                           clock: frozenClock())
            let log = EventLog(layout: layout, clock: frozenClock(), priming: journal)
            _ = try await log.replay()

            // The proof it was primed: delete the log. A journal that still had
            // to read it would resume from zero.
            try FileManager.default.removeItem(at: layout.events)
            let next = try journal.record(kind: .checkedIn, day: day("2026-08-01"),
                                          source: .tap, payload: .habit(habitA))
            #expect(next.lamport == 5)
            #expect(next.prev != EventChain.genesis)
        }
    }

    @Test("Priming never overwrites a resume a tap already established")
    func primingNeverOverwrites() async throws {
        try await withTemporaryStoreAsync { layout in
            let seeded = try seed(layout)
            seeded.close()

            let journal = try EventJournal(layout: layout, writer: writerApp,
                                           clock: frozenClock())
            // A tap beats the replay. The journal's resume is now the truth
            // about a line that is already on disk.
            let tapped = try journal.record(kind: .checkedIn, day: day("2026-08-01"),
                                            source: .tap, payload: .habit(habitA))

            // The replay read the log *before* that tap landed. Accepting its
            // answer would move the head backwards and fork the chain.
            journal.prime(WriterResume(lamport: 4, head: EventChain.genesis))

            let next = try journal.record(kind: .checkedIn, day: day("2026-08-02"),
                                          source: .tap, payload: .habit(habitA))
            #expect(next.lamport == tapped.lamport + 1)
            #expect(try next.prev == tapped.contentHash)
            #expect(try JournalReader(url: layout.events).read().chain.isIntact)
        }
    }

    @Test("A cache that cannot be decoded is ignored, never fatal")
    func unreadableCacheIsIgnored() throws {
        try withTemporaryStore { layout in
            try Data("not a snapshot".utf8).write(to: layout.snapshot)
            #expect(SnapshotStore(layout: layout).read() == nil)
        }
    }

    // MARK: Launching from the cache

    @Test("A launch with a usable cache renders from it and decodes no log")
    func launchesFromTheCache() throws {
        try withTemporaryStore { layout in
            _ = try seed(layout)
            SnapshotStore(layout: layout).write(
                TodaySnapshot(
                    projection: project(try JournalReader(url: layout.events).read().events),
                    subject: SubjectName(),
                    today: day("2026-07-31"),
                    spineLength: TodaySnapshot.spineLength
                )
            )

            let store = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())

            // The tell: the first frame has a snapshot and **no events**, which
            // is only possible if the log was never decoded on the launch path.
            #expect(store.events.isEmpty)
            let snapshot = try #require(store.snapshot)
            #expect(snapshot.habits.map(\.name) == ["Move"])
            #expect(snapshot.daysRecorded == 3)
            #expect(store.absorber != nil)
        }
    }

    @Test("A cache from yesterday still serves the first frame, moved to today")
    func launchesFromYesterdaysCache() throws {
        try withTemporaryStore { layout in
            _ = try seed(layout)
            SnapshotStore(layout: layout).write(
                TodaySnapshot(
                    projection: project(try JournalReader(url: layout.events).read().events),
                    subject: SubjectName(),
                    today: day("2026-07-30"),
                    spineLength: TodaySnapshot.spineLength
                )
            )

            let store = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())
            let snapshot = try #require(store.snapshot)
            #expect(snapshot.day == day("2026-07-31"))
            #expect(snapshot.habits.allSatisfy { !$0.isChecked })
        }
    }

    @Test("A cache with no habits falls through to the log, so a fresh install still seeds")
    func emptyCacheDoesNotBlockTheSeed() throws {
        try withTemporaryStore { layout in
            SnapshotStore(layout: layout).write(
                TodaySnapshot(
                    projection: Projection(), subject: SubjectName(),
                    today: day("2026-07-31"), spineLength: TodaySnapshot.spineLength
                )
            )

            let store = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())
            // A launch that rendered four empty rows would look exactly like one
            // that lost them.
            #expect(store.snapshot == nil)
            #expect(store.events.count == AppComposition.seededHabits.count)
        }
    }

    @Test("A composed launch chains, and reprojects a week-1a log on the way in")
    func composeReprojects() throws {
        try withTemporaryStore { layout in
            // A week-1a log: real events, `prev = genesis` on every line.
            let identity = try WriterIdentity(layout: layout).load()
            let encoder = JSONEncoder()
            var body = Data()
            for lamport in 1...2 {
                let event = stamped(
                    .checkedIn, device: identity, lamport: lamport, on: "2026-07-30",
                    payload: .habit(habitA)
                )
                body.append(try encoder.encode(event))
                body.append(0x0A)
            }
            try body.write(to: layout.events)

            _ = AppComposition.compose(storeURL: layout.storeURL, clock: frozenClock())

            #expect(try JournalReader(url: layout.events).read().chain.isIntact)
            #expect(FileManager.default.fileExists(atPath: layout.preChainEvents.path))
        }
    }

    // MARK: The App Group move

    @Test("The Documents store is copied into the container and the original is kept")
    func movesToTheAppGroup() throws {
        try withTemporaryStore { root in
            // Nested, so the renamed copy lands inside the directory this
            // fixture deletes — the real one lands beside Documents/Compass.
            let source = StoreLayout(
                storeURL: root.storeURL.appendingPathComponent("Documents/Compass")
            )
            let destination = root.storeURL.appendingPathComponent("Group/Compass")
            try source.prepare()

            do {
                let identity = try WriterIdentity(layout: source).load()
                _ = try seed(source)
                let before = try rawLog(source)

                #expect(AppComposition.moveToAppGroupIfNeeded(
                    from: source.storeURL, to: destination
                ))

                // Every file, not only the log: the writer identity travels with
                // it, or the app comes up as a different writer and forks its own
                // chain.
                let moved = StoreLayout(storeURL: destination)
                #expect(try Data(contentsOf: moved.events) == before)
                #expect(try WriterIdentity(layout: moved).load() == identity)

                // `PROJECT_CONSTITUTION.md` §5: existing data survives every
                // change. Renamed, never removed.
                let kept = source.storeURL.deletingLastPathComponent()
                    .appendingPathComponent("Compass.moved-to-group")
                #expect(FileManager.default.fileExists(atPath: kept.path))
                #expect(!FileManager.default.fileExists(atPath: source.storeURL.path))
            }
        }
    }

    @Test("A container that already holds a log is never overwritten")
    func doesNotMoveOntoAnExistingLog() throws {
        try withTemporaryStore { source in
            try withTemporaryStore { destination in
                _ = try seed(source)
                _ = try seed(destination, days: 9)
                let existing = try rawLog(destination)

                #expect(!AppComposition.moveToAppGroupIfNeeded(
                    from: source.storeURL, to: destination.storeURL
                ))
                #expect(try rawLog(destination) == existing)
                #expect(FileManager.default.fileExists(atPath: source.events.path))
            }
        }
    }

    @Test("With no container reachable, nothing moves and the app still records")
    func noContainerIsNotAFailure() throws {
        // `docs/technical.md` §6 refuses to let the paid developer account gate
        // storage code: an App Group needs an entitlement, which needs a
        // provisioning profile, which needs the account. A build without one
        // falls back to Documents and loses nothing but the widget.
        try withTemporaryStore { source in
            _ = try seed(source)
            #expect(!AppComposition.moveToAppGroupIfNeeded(from: source.storeURL, to: nil))
            #expect(FileManager.default.fileExists(atPath: source.events.path))
        }
    }
}
