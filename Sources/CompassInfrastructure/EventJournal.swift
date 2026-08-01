import CompassDomain
import Darwin
import Foundation
import Synchronization

/// The append-only JSON Lines journal. `docs/technical.md` §4 and §6, ADR 0002.
///
/// One event per line, appended to a descriptor opened `O_APPEND`, as **one
/// `write(2)` of one complete line including its trailing newline.** At ~120
/// bytes that is a single atomic append: there is no seek-then-write sequence
/// for a second process to interleave with, and no partially written line can
/// land in the middle of another writer's. That property is what lets the widget
/// share this file in week 2 without a cross-process lock on the tap path.
///
/// **This is deliberately not the pattern inherited from the `before`
/// repository.** `Log.persist()` there re-encodes and rewrites the whole array
/// on every append — correct for one entry a day, and measured at 145 ms and a
/// 1.9 MB flash write per checkbox tap at a five-year Compass workload
/// (ADR 0002 §5). Appending one line to an open descriptor does not appear in
/// that table because it is O(1).
///
/// The class is a `final class` guarding its state with `Synchronization.Mutex`
/// and is called synchronously from the main actor: there is no `await` between
/// the tap and durability. `docs/technical.md` §4 lines 1–3.
///
/// ### Who stamps an event
///
/// `EventSink` in `docs/technical.md` §2 takes a fully-formed `Event`, while the
/// tap path in §4 writes `Event(kind:habit:day:at:)` — a four-argument
/// initialiser that cannot produce the `device`, `lamport`, `recordedAt` and
/// `zoneOffset` that §3 requires on every record from the very first write. The
/// corpus never says who supplies them. They are supplied here, in ``record``,
/// because `lamport` is a property of *this writer's* sequence and recovering it
/// after a cold start means reading this file — both of which are this type's
/// business and nobody else's. ``append(_:)`` keeps the documented port
/// behaviour: it writes the event it is given, verbatim.
public final class EventJournal: Sendable {

    /// Mutable state, all of it behind one lock.
    private struct State {
        var descriptor: Int32
        /// `nil` until this process's first write, which is when the tail is
        /// read to recover the sequence **and** the chain head. See ``record``.
        ///
        /// The two are one register with two halves and are recovered together:
        /// a `lamport` without its head would stamp an event onto a chain whose
        /// previous link is unknown, which is a fork rather than an append.
        var resume: WriterResume?
        var isClosed: Bool
    }

    public let layout: StoreLayout

    /// This process's writer identity. Not the phone. `docs/technical.md` §4.
    public let writer: DeviceID

    private let clock: SystemClock
    private let state: Mutex<State>

    /// Opens the log for appending, creating it if it is not there.
    ///
    /// `resume` is where **this writer** left off — the highest `lamport` it has
    /// used and the `content_hash` of its last event — when the caller already
    /// knows. Supplying it is what keeps a full decode of the log off the tap
    /// path: without it the first `record` of the process falls back to reading
    /// and decoding the whole file, measured at 193 ms at five years and 865 ms
    /// at ten (`docs/technical.md` §6) — on the main actor, inside the
    /// synchronous steps §4 requires to be microseconds.
    ///
    /// The composition root has both numbers for free when it reads the log
    /// synchronously to render the first frame: ``JournalRead/resume(for:)``
    /// falls out of the same pass. When it launches from the snapshot cache
    /// instead it does not read the log at all, passes `nil`, and the first
    /// write of the process pays for the recovery under the advisory `flock` —
    /// which is exactly the cold-start path `docs/technical.md` §4 describes.
    ///
    /// Two conditions make passing it in safe, and both are worth stating because
    /// they are the reason this is not just an optimisation with a race in it:
    ///
    /// - It must be derived from **this store's log, for this writer** — from
    ///   ``JournalRead/resume(for:)``, whose `lamport` half counts lines this
    ///   build cannot decode. Nothing verifies it here; that is the point.
    /// - Reading it outside the advisory `flock` is safe because a `lamport`
    ///   sequence and a chain belong to one writer and **no two processes share
    ///   a writer identity** (`docs/technical.md` §4). The widget appending
    ///   concurrently cannot move this writer's mark or its head, so there is
    ///   nothing for the lock to protect. The lock still guards the fallback
    ///   path below, where the tail is read and appended to in one operation.
    public init(
        layout: StoreLayout,
        writer: DeviceID,
        clock: SystemClock = SystemClock(),
        resume: WriterResume? = nil
    ) throws {
        try layout.prepare()

        self.layout = layout
        self.writer = writer
        self.clock = clock
        self.state = Mutex(
            State(
                descriptor: try EventJournal.openForAppend(layout.events),
                resume: resume,
                isClosed: false
            )
        )
    }

    deinit {
        state.withLock { state in
            if !state.isClosed { Darwin.close(state.descriptor) }
            state.isClosed = true
        }
    }

    /// Hands the journal a resume it did not have, **if it still has none.**
    ///
    /// This is how the launch path keeps a full log decode off both the first
    /// frame and the first tap at the same time. When the app launches from the
    /// snapshot cache the composition root never reads the log, so this journal
    /// starts unprimed and its first write would pay for the recovery under the
    /// `flock` — measured at 193 ms at five years and 865 ms at ten
    /// (`docs/technical.md` §6), on the main actor, inside steps §4 requires to
    /// be microseconds. ``EventLog/replay()`` reads the log a moment later, from
    /// the `.task` that follows the first frame, and hands the answer here.
    ///
    /// **The head is never overwritten.** If a tap beat the replay, this writer's
    /// head is already the truth about a line that is already on disk, and a
    /// value read *before* that write would move it backwards and fork the chain.
    /// Losing the optimisation is free; losing the chain is not.
    ///
    /// **The clock only ever goes forwards, and it does move.** That half is not
    /// an optimisation and refusing it was wrong once the widget existed: a
    /// process that has been alive across a background period holds a mark from
    /// whenever it was primed, and the *other* writer has been appending in the
    /// meantime. Its next event would then be stamped with a `lamport` no greater
    /// than one the widget already used, and `docs/technical.md` §3 resolves the
    /// `(habit, day)` cell last-writer-wins under `(lamport, device)` — so the
    /// tap the user just made could lose to a widget press from ten minutes ago,
    /// decided by which random UUID sorts higher. Adopting a strictly greater
    /// mark is always safe, because a `lamport` is a lower bound this writer must
    /// exceed and never a claim about which line is its own.
    ///
    /// Reading it outside the `flock` is safe for the stated reason the
    /// `resume:` initialiser is: a chain belongs to one writer, and no two
    /// processes share a writer identity (`docs/technical.md` §4). The clock half
    /// is safe to read unlocked because it is only ever raised.
    public func prime(_ resume: WriterResume) {
        state.withLock { state in
            guard !state.isClosed else { return }
            guard let current = state.resume else {
                state.resume = resume
                return
            }
            guard resume.lamport > current.lamport else { return }
            state.resume = WriterResume(lamport: resume.lamport, head: current.head)
        }
    }

    /// Closes the descriptor. Further appends throw. Reading a closed journal
    /// still works — a reader opens its own descriptor.
    public func close() {
        state.withLock { state in
            guard !state.isClosed else { return }
            Darwin.close(state.descriptor)
            state.isClosed = true
        }
    }

    // MARK: Writing

    /// Stamps and appends one event: this writer's `device`, the next `lamport`
    /// on its sequence, the instant of the tap, and the device's UTC offset.
    ///
    /// `day` is passed in rather than read from the clock here because the
    /// 04:00 boundary is applied **once, when the event is created**, by the
    /// caller that also applied it to the projection — never twice, and never in
    /// the fold. `docs/technical.md` §3, `.claude/skills/ios.md`.
    ///
    /// On this process's first write the tail is read to recover `lamport` **and
    /// this writer's chain head**, and that read-then-append is held under an
    /// advisory `flock` for its duration, per `docs/technical.md` §4. **This is
    /// the only place a cross-process lock is taken, and it is never taken on
    /// the tap path after the first write of a process's lifetime.**
    ///
    /// `prev` is the `content_hash` of the previous event on **this writer's**
    /// chain, or 32 zero bytes for the first event on it. It is computed here
    /// rather than by the caller because the head is this writer's state and
    /// nobody else's — the same argument that puts `lamport` here.
    @discardableResult
    public func record(
        kind: EventKind,
        day: Day,
        source: CheckInSource? = nil,
        payload: EventPayload = .empty
    ) throws -> Event {
        let instant = clock.now()

        return try state.withLock { state in
            guard !state.isClosed else { throw JournalError.closed }

            func stamp(_ resume: WriterResume) -> Event {
                Event(
                    id: UUID(),
                    device: writer,
                    lamport: resume.lamport + 1,
                    kind: kind,
                    day: day,
                    recordedAt: clock.milliseconds(at: instant),
                    zoneOffset: clock.zoneOffsetMinutes(at: instant),
                    source: source,
                    payload: payload,
                    prev: resume.head
                )
            }

            if let resume = state.resume {
                let event = stamp(resume)
                state.resume = try EventJournal.write(event, to: state.descriptor)
                return event
            }

            return try EventJournal.withExclusiveLock(state.descriptor) {
                let recovered = try JournalReader(url: layout.events).read().resume(for: writer)
                let event = stamp(recovered)
                state.resume = try EventJournal.write(event, to: state.descriptor)
                return event
            }
        }
    }

    /// Appends an event **verbatim** — the ``EventSink`` behaviour. Used to
    /// re-append events this writer did not stamp, such as a restored bundle.
    /// Nothing is rewritten, nothing is renumbered, and no `prev` is rewritten:
    /// a foreign event arrives with its own chain already on it.
    public func appendSync(_ event: Event) throws {
        try state.withLock { state in
            guard !state.isClosed else { throw JournalError.closed }
            let written = try EventJournal.write(event, to: state.descriptor)
            guard let resume = state.resume else { return }

            // The clock advances past **any** writer's event, because that is
            // what a Lamport clock is: this process has now seen this line, so
            // whatever it stamps next must sort after it.
            let clock = max(resume.lamport, event.lamport)

            // The head moves only for this writer's own event, and only when the
            // event is a later one than anything seen — otherwise the next
            // `record` would chain onto an event this one has already superseded,
            // forking the chain against a line that is already on disk.
            let isOwnAndLater = event.device == writer && event.lamport >= resume.lamport
            state.resume = WriterResume(
                lamport: clock,
                head: isOwnAndLater ? written.head : resume.head
            )
        }
    }

    // MARK: Reading

    /// Reads the whole log back. The log is the source of truth; the snapshot
    /// cache is disposable and may be deleted at any moment.
    public func read() throws -> JournalRead {
        try JournalReader(url: layout.events).read()
    }

    // MARK: File primitives

    /// Internal rather than private since week 3, so `awards.jsonl` and
    /// `attestations.jsonl` open their files the same way this one does. The
    /// "one `write(2)` of one complete line to an `O_APPEND` descriptor"
    /// discipline in `docs/technical.md` §4 is a property of how this project
    /// appends to any file, not of the event log specifically, and writing it a
    /// second time is how two files end up with two different answers about what
    /// a torn line is.
    static func openForAppend(_ url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { path -> Int32 in
            var result: Int32 = -1
            repeat {
                result = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            } while result < 0 && errno == EINTR
            return result
        }
        guard descriptor >= 0 else { throw JournalError.openFailed(code: errno) }
        return descriptor
    }

    /// Canonicalises the event, then writes it, and returns where this writer's
    /// chain now stands.
    ///
    /// **In that order, deliberately.** `content_hash` is computed over the
    /// canonical bytes, and those bytes can be refused — a control character in
    /// a habit name is rejected at write time rather than escaped
    /// (`docs/achievement-protocol.md` §6.3). Hashing first means a refused
    /// event never reaches the file and never moves the head, so the chain and
    /// the log agree even on the failure path. Hashing afterwards would put a
    /// line on disk that nothing can ever link to.
    private static func write(_ event: Event, to descriptor: Int32) throws -> WriterResume {
        let head = try event.contentHash
        try writeLine(event, to: descriptor)
        return WriterResume(lamport: event.lamport, head: head)
    }

    /// One `write(2)` of one complete line. A short write is reported rather
    /// than looped over: looping would be a second, non-atomic append, which is
    /// the exact interleaving this design exists to prevent.
    private static func writeLine(_ event: Event, to descriptor: Int32) throws {
        try writeLine(try encoder.encode(event), to: descriptor)
    }

    /// The same discipline for any encoded record. `docs/technical.md` §4.
    static func writeLine(_ encoded: Data, to descriptor: Int32) throws {
        var line = encoded
        guard !line.contains(0x0A) else { throw JournalError.embeddedNewline }
        line.append(0x0A)

        let written = line.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var result = -1
            repeat {
                result = Darwin.write(descriptor, base, raw.count)
            } while result < 0 && errno == EINTR
            return result
        }

        guard written >= 0 else { throw JournalError.writeFailed(code: errno) }
        guard written == line.count else {
            throw JournalError.shortWrite(expected: line.count, wrote: written)
        }
    }

    /// Advisory `flock` on the log, for a caller that holds no descriptor of its
    /// own — the `reproject` hatch, which rewrites the file rather than
    /// appending to it.
    ///
    /// `docs/technical.md` §4: "The widget never rewrites, compacts, or
    /// truncates. Only the app process does, and only under the same lock."
    static func withExclusiveLock<T>(onFileAt url: URL, _ body: () throws -> T) throws -> T {
        let descriptor = try EventJournal.openForAppend(url)
        defer { Darwin.close(descriptor) }
        return try withExclusiveLock(descriptor, body)
    }

    /// Advisory `flock` for the duration of a read-tail-then-append.
    /// `docs/technical.md` §4. In-process serialisation is the `Mutex`; this is
    /// the cross-process half, and `Synchronization.Mutex` does not span
    /// processes.
    private static func withExclusiveLock<T>(
        _ descriptor: Int32, _ body: () throws -> T
    ) throws -> T {
        var locked: Int32 = -1
        repeat {
            locked = advisoryLock(descriptor, LOCK_EX)
        } while locked < 0 && errno == EINTR
        guard locked == 0 else { throw JournalError.lockFailed(code: errno) }

        defer { _ = advisoryLock(descriptor, LOCK_UN) }
        return try body()
    }

    /// `withoutEscapingSlashes` only. The on-disk line is not required to be
    /// byte-identical to the canonical form — it carries `extra` and may order
    /// keys differently — so this stays a plain `JSONEncoder`. The canonical
    /// bytes are hand-written and derived from the decoded event, and they land
    /// in week 1b. `docs/technical.md` §3.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - Ports

// ``record`` already has the ``EventRecorder`` shape: it is the synchronous
// tap-path write, and the reason it stamps and writes in one call is stated on
// the port. Conformance therefore costs nothing.
extension EventJournal: EventRecorder {}

extension EventJournal: EventSink, EventSource {
    /// The ``EventSink`` port. Forwards to the synchronous write — durability
    /// does not need an actor hop, and an `await` on this path is the thing the
    /// design forbids.
    public func append(_ event: Event) async throws {
        try appendSync(event)
    }

    /// The ``EventSource`` port.
    public func replay() async throws -> [Event] {
        try read().events
    }
}

// MARK: - Reading

/// Reads a JSON Lines log. Separate from ``EventJournal`` because reading needs
/// no descriptor, no writer identity and no lock: a fresh reader over the same
/// path is how a restarted process, an export and a test all see the log.
public struct JournalReader: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() throws -> JournalRead {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return JournalRead(
                events: [], damagedLines: [], droppedPartialTail: false, highWaterMarks: [:],
                chain: ChainVerification(heads: [:], breaks: [])
            )
        }

        let data = try Data(contentsOf: url)
        let segments = data.split(separator: 0x0A, omittingEmptySubsequences: false)

        // A file ending in a newline yields a trailing empty segment; anything
        // else is a line that was being appended when the process died. Dropping
        // it is what makes the synchronous-append design honest rather than
        // decorative. `docs/technical.md` §9.6.
        var lines = Array(segments)
        var droppedPartialTail = false
        if let last = lines.last {
            lines.removeLast()
            droppedPartialTail = !last.isEmpty
        }

        let decoder = JSONDecoder()
        var events: [Event] = []
        var damagedLines: [Int] = []
        var highWaterMarks: [DeviceID: Int] = [:]

        func mark(_ device: DeviceID, _ lamport: Int) {
            highWaterMarks[device] = max(highWaterMarks[device] ?? 0, lamport)
        }

        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            do {
                let event = try decoder.decode(Event.self, from: Data(line))
                events.append(event)
                mark(event.device, event.lamport)
            } catch {
                damagedLines.append(index + 1)
                // A line this build cannot decode still consumed a `lamport` on
                // its writer's sequence. The stamp is read on its own so the
                // mark survives the decode failure — see ``EventStamp``.
                if let stamp = try? decoder.decode(EventStamp.self, from: Data(line)) {
                    mark(stamp.device, stamp.lamport)
                }
            }
        }

        return JournalRead(
            events: events,
            damagedLines: damagedLines,
            droppedPartialTail: droppedPartialTail,
            highWaterMarks: highWaterMarks,
            chain: EventChain.verify(events)
        )
    }
}

/// The two envelope fields a writer's sequence depends on, decodable **on their
/// own**.
///
/// Deliberately not `Event`. `docs/technical.md` §3 makes `payload` a closed
/// structure — an unknown payload key makes the event invalid — so an event
/// written by a newer build is undecodable to this one *by design*, not by
/// corruption. Its `device` and `lamport` are top-level envelope fields and are
/// still perfectly readable, and reading them is what stops this build from
/// reissuing a `lamport` that writer has already used.
private struct EventStamp: Decodable {
    let device: DeviceID
    let lamport: Int
}

/// The result of reading a log: what was recovered, and what was not.
///
/// Damage is **reported, never hidden**. `docs/technical.md` §6 specifies the
/// full policy — copy the file to `events.jsonl.damaged-<timestamp>` first,
/// replay the longest valid prefix, continue past the break only for other
/// writers' chains, and surface one notice — and that policy needs `prev`
/// chaining to detect a forked chain at all. Chaining is week 1b, so what is
/// implemented here is the part that does not depend on it: every line that
/// parses is kept, in order; every line that does not is listed by number; a
/// partial tail is dropped and said so. Nothing is silently dropped and the app
/// never refuses to launch.
public struct JournalRead: Hashable, Sendable {
    public let events: [Event]
    /// 1-based line numbers that failed to decode.
    public let damagedLines: [Int]
    /// A final line with no terminating newline — a crash mid-append.
    public let droppedPartialTail: Bool

    /// The highest `lamport` seen per writer, counting **every** line that
    /// carries a stamp — including the ones this build could not decode into an
    /// `Event` and therefore left out of ``events``.
    ///
    /// That distinction is the whole reason this field exists. Folding the mark
    /// out of ``events`` instead silently skips undecodable lines, so a writer
    /// whose last line is undecodable recovers a mark that is too low and its
    /// next write reuses a `lamport` — breaking the `(lamport, device)`
    /// uniqueness `docs/technical.md` §9.10 requires and the total order in §3
    /// depends on. It is reachable by design rather than by corruption: §3 makes
    /// `payload` closed, so any event carrying a payload key from a newer build
    /// is undecodable here.
    public let highWaterMarks: [DeviceID: Int]

    /// Every writer's chain, walked. `docs/technical.md` §3.
    ///
    /// Reported rather than acted on. `docs/technical.md` §6 makes the response
    /// to damage a policy — copy the file aside first, replay the longest valid
    /// prefix, surface one notice — and a reader that decided any of that for
    /// its caller would be making that policy in the wrong place. What it owes
    /// the caller is the truth about what is on disk.
    public let chain: ChainVerification

    public init(
        events: [Event],
        damagedLines: [Int],
        droppedPartialTail: Bool,
        highWaterMarks: [DeviceID: Int] = [:],
        chain: ChainVerification = ChainVerification(heads: [:], breaks: [])
    ) {
        self.events = events
        self.damagedLines = damagedLines
        self.droppedPartialTail = droppedPartialTail
        self.highWaterMarks = highWaterMarks
        self.chain = chain
    }

    public var isIntact: Bool {
        damagedLines.isEmpty && !droppedPartialTail && chain.isIntact
    }

    /// Where `writer` resumes: the `lamport` its next event must exceed, and the
    /// `content_hash` of its own last event.
    ///
    /// **The two halves come from different places, and that is not an
    /// accident.**
    ///
    /// The head is this writer's and only this writer's: `prev` chains per
    /// writer, never globally, and it can only come from a line this build *can*
    /// decode, because a `content_hash` is computed over canonical bytes and an
    /// undecodable line has none.
    ///
    /// The clock is the maximum over **every** writer, which is what makes it a
    /// Lamport clock rather than a per-writer serial number — see below. It folds
    /// over ``highWaterMarks``, which counts every stamped line including the ones
    /// this build cannot decode, because reissuing a `lamport` a newer build
    /// already used would break the `(lamport, device)` uniqueness the total order
    /// depends on.
    ///
    /// So on a log carrying a line from a newer build, the next event's
    /// `lamport` skips past it while its `prev` points at the last line this
    /// build understood. The chain reports that as a break, which is the honest
    /// answer and the same "longest valid prefix" rule §6 applies to replay. The
    /// alternative — refusing to write — is refusing to record a tap because
    /// some other build wrote something, and `docs/technical.md` §6 ends its
    /// damage policy with "never refuse to launch".
    ///
    /// ### Why the clock reads every writer's mark, and not just this one's
    ///
    /// **This changed in week 2, when the widget made a second writer real, and
    /// it is a correctness fix rather than a refinement.** It used to read
    /// `highWaterMarks[writer]` — this writer's own mark. With one writer those
    /// are the same number and nothing could tell them apart. With two they are
    /// not, and the difference is silent, permanent and wrong:
    ///
    /// > The app seeds four habits and records a check-in, reaching `lamport 5`.
    /// > The widget process, which has never written, starts its sequence at
    /// > **1**. The user presses the widget to un-check that habit, and the
    /// > revocation is written at `(1, widget)`. `docs/technical.md` §3 resolves
    /// > the `(habit, day)` cell last-writer-wins under `(lamport, device)` — so
    /// > `(5, app)` beats `(1, widget)`, the fold keeps the check-in, and the
    /// > un-check is discarded. Not delayed: discarded, for as long as the log
    /// > exists, with the event sitting on disk the whole time.
    ///
    /// §3 justifies the ordering with "Lamport first so causality holds", and
    /// causality is exactly what a per-writer serial number does not carry. A
    /// Lamport clock advances past everything the writer has *seen*, which is
    /// what this now does: an event written after reading another writer's event
    /// is strictly greater than it, so "the user's most recent action wins" is a
    /// property of the fold rather than a coincidence of which process happened to
    /// start first.
    ///
    /// Per-writer monotonicity is untouched — a maximum over a set that includes
    /// this writer's own mark can never be less than it — and so is
    /// `(lamport, device)` uniqueness: two writers may now land on the same
    /// `lamport`, which is what the `device` tiebreak has always been for, and
    /// neither ever reuses one of its own.
    public func resume(for writer: DeviceID) -> WriterResume {
        WriterResume(
            lamport: highWaterMarks.values.max() ?? 0,
            head: chain.head(of: writer)
        )
    }
}

/// Where one writer resumes: the `lamport` its next event must exceed, and the
/// `content_hash` that the next event on its chain must carry as `prev`.
///
/// One value rather than two arguments because they are only ever correct
/// together. A `lamport` recovered without its head stamps an event onto a chain
/// whose previous link is unknown, which is a fork rather than an append —
/// exactly the failure per-writer chains exist to prevent.
public struct WriterResume: Hashable, Sendable {

    /// The highest `lamport` **any** writer has used in this log; `0` on an empty
    /// one, so the first event ever stamped is `1`.
    ///
    /// It is a Lamport clock, not this writer's serial number: it advances past
    /// everything this writer has seen, so an event recorded after reading
    /// another writer's event sorts strictly after it. See
    /// ``JournalRead/resume(for:)`` for the check-in a per-writer counter
    /// silently discarded.
    public let lamport: Int

    /// `prev` for this writer's next event: the `content_hash` of its last one,
    /// or ``EventChain/genesis`` when it has never written.
    public let head: Data

    public init(lamport: Int, head: Data) {
        self.lamport = lamport
        self.head = head
    }

    /// A writer that has never written anything.
    public static let fresh = WriterResume(lamport: 0, head: EventChain.genesis)
}

// MARK: - When the store cannot be opened at all

/// The ports to fall back on when the store could not be opened — a full disk,
/// or a container that is gone.
///
/// `docs/technical.md` §6 ends its damaged-log policy with "never silently drop
/// lines and **never refuse to launch**", and a `preconditionFailure` in the
/// composition root refuses to launch in the worst available way: it crashes on
/// every launch, for a condition that is often transient, with the log sitting
/// intact on disk the whole time.
///
/// Every call throws, deliberately, and that is what makes the fallback honest.
/// `TodayModel.toggle` already treats a throwing recorder as "the tap does
/// nothing and the screen keeps telling the truth". The alternative — a silent
/// in-memory store — would accept taps the user believes are recorded and drop
/// every one of them at exit, which is the failure this project is least able to
/// afford.
public struct UnavailableStore: EventRecorder, EventSource {

    /// Why the store could not be opened. Carried so the failure can be said out
    /// loud rather than guessed at; never rendered as an error code.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    @discardableResult
    public func record(
        kind: EventKind, day: Day, source: CheckInSource?, payload: EventPayload
    ) throws -> Event {
        throw JournalError.storeUnavailable(reason: reason)
    }

    public func replay() async throws -> [Event] {
        throw JournalError.storeUnavailable(reason: reason)
    }
}

/// `flock(2)`, the function — Darwin exports a `struct flock` under the same
/// name, and the type wins in expression position. Binding it once here is the
/// disambiguation.
private let advisoryLock: @convention(c) (Int32, Int32) -> Int32 = flock

// MARK: - Errors

public enum JournalError: Error, Hashable, Sendable {
    case openFailed(code: Int32)
    case writeFailed(code: Int32)
    case lockFailed(code: Int32)
    /// A single `write(2)` did not place the whole line. Looping would append
    /// the remainder as a second, interleavable write.
    case shortWrite(expected: Int, wrote: Int)
    /// An encoded event containing a raw newline would tear its own line in two.
    case embeddedNewline
    case closed
    /// Thrown by every call on ``UnavailableStore``: the store was never opened,
    /// so nothing can be written and nothing can be read.
    case storeUnavailable(reason: String)
}
