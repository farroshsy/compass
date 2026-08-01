import CompassDomain
import Foundation

/// The log, off the tap path. `docs/technical.md` §4 and §6.
///
/// §4 gives it two jobs and one sentence each:
///
/// ```
/// journal.appendSync(event)          // 3. durable NOW — one write(2)
/// Task { await log.absorb(event) }   // 4. actor catches up
/// ```
///
/// and, on the launch path, "the full log replays in a `.task` immediately
/// afterwards and reconciles."
///
/// **It is an actor and ``EventJournal`` is not, and that split is the design.**
/// §4's third concurrency boundary is "`actor EventLog` — owns the file and the
/// in-memory event array. Serial by construction, so no locks." Its first is
/// `@MainActor`, where an `await` "lands directly in the tap path". So the
/// durable write stays a synchronous `final class` guarding a descriptor with
/// `Synchronization.Mutex`, and everything that may take a millisecond — reading
/// the whole log, folding it, rewriting the cache — lives here, behind an
/// `await` the finger never waits on.
///
/// What it owns is therefore the *reading* half of the file plus the disposable
/// cache. It never appends: `EventJournal` does, synchronously, before this type
/// hears about the event at all. That ordering is what makes "kill the app 10 ms
/// after the tap and the check-in survives" true.
public actor EventLog {

    private let layout: StoreLayout
    private let clock: SystemClock
    private let snapshots: SnapshotStore

    /// The journal this replay primes, when there is one. See
    /// ``EventJournal/prime(_:)``: reading the log is this type's job, and the
    /// writer's resume falls out of the same pass.
    private let journal: EventJournal?

    /// The in-memory event array §4 names. `nil` until the first ``replay()``,
    /// because before that this type has never read the file and an empty array
    /// would be a claim that the log is empty.
    private var events: [Event]?

    public init(
        layout: StoreLayout,
        clock: SystemClock = SystemClock(),
        priming journal: EventJournal? = nil
    ) {
        self.layout = layout
        self.clock = clock
        self.journal = journal
        self.snapshots = SnapshotStore(layout: layout)
    }

    /// Reads the whole log, keeps it, rewrites the cache from it, and hands the
    /// journal the resume that fell out of the same read.
    ///
    /// **The replay wins.** `docs/technical.md` §4: "If the snapshot and the
    /// replay disagree, the replay wins and the snapshot is rewritten." That is
    /// not a reconciliation step somewhere else — it is this line, and it is why
    /// the cache can be deleted at any moment without consequence.
    public func replay() async throws -> [Event] {
        let read = try JournalReader(url: layout.events).read()
        events = read.events
        if let journal {
            journal.prime(read.resume(for: journal.writer))
        }
        writeSnapshot(from: read.events)
        return read.events
    }

    /// Catches up with an event the tap path has **already made durable**.
    ///
    /// It cannot fail and it does not throw, because there is nothing here worth
    /// failing over: the event is on disk, `EventJournal` put it there
    /// synchronously, and everything this method touches is the disposable tier.
    /// A cache that could not be rewritten is a cache that is stale for one
    /// launch, and the replay that follows that launch fixes it.
    ///
    /// **Nothing promises these arrive in the order they were written**, because
    /// each is carried by its own `Task` and that is what keeps the `await` off
    /// the finger. Nothing here needs them ordered: `project` is commutative and
    /// idempotent under `(lamport, device)`, which the shard-, shuffle- and
    /// replay-invariance tests in `CompassDomainTests` make a fact rather than a
    /// hope. The array below is a set that happens to be stored in a line.
    public func absorb(_ event: Event) async {
        guard var events else {
            // No replay has happened yet, so there is no array to append to and
            // no honest snapshot to write — a cache folded from one event would
            // claim the log holds one event. The `.task` replay that is already
            // in flight writes the correct one a moment later.
            return
        }
        events.append(event)
        self.events = events
        writeSnapshot(from: events)
    }

    /// The events read so far, without touching the file. `nil` before the first
    /// ``replay()``.
    public var cached: [Event]? { events }

    private func writeSnapshot(from events: [Event]) {
        let snapshot = TodaySnapshot(
            projection: project(events),
            subject: declaredSubject(events),
            today: clock.today(cutoffHour: DayBoundary.cutoffHour),
            spineLength: TodaySnapshot.spineLength
        )
        snapshots.write(snapshot)
    }
}

extension EventLog: EventSource, EventAbsorber {}

/// Reads and writes `snapshot.json`. `docs/technical.md` §6, disposable tier.
///
/// **Every failure here is swallowed, deliberately.** A cache that cannot be
/// written is a slower launch; a cache that cannot be read is a launch that
/// reads the log instead. Neither is worth a thrown error travelling up into a
/// path whose entire job is to not fail — and `docs/technical.md` §6 is explicit
/// that this file may be deleted at any moment and that the replay always wins.
/// The one thing that must never happen is the *log* being treated this way,
/// which is why the two live in different types.
public struct SnapshotStore: Sendable {

    public let layout: StoreLayout

    public init(layout: StoreLayout) {
        self.layout = layout
    }

    /// The cached screen, or `nil` when there is none, it cannot be read, or it
    /// was written by a build whose shape this one does not understand.
    ///
    /// **Read synchronously on the launch path**, which is the whole point:
    /// `docs/technical.md` §4 requires the first frame to render correct data
    /// with zero awaits, and §6 measures a full log decode at 193 ms at five
    /// years and 865 ms at ten.
    public func read() -> TodaySnapshot? {
        guard let data = try? Data(contentsOf: layout.snapshot) else { return nil }
        return try? JSONDecoder().decode(TodaySnapshot.self, from: data)
    }

    /// Writes the cache, atomically so a crash mid-write leaves the previous one
    /// rather than half of this one.
    public func write(_ snapshot: TodaySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? layout.prepare()
        try? data.write(to: layout.snapshot, options: .atomic)
    }

    /// Removes the cache. Used by the tests, and safe at any moment by
    /// definition.
    public func delete() {
        try? FileManager.default.removeItem(at: layout.snapshot)
    }
}
