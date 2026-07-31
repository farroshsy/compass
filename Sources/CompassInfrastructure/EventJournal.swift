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
        /// read to recover the sequence. See ``record``.
        var nextLamport: Int?
        var isClosed: Bool
    }

    public let layout: StoreLayout

    /// This process's writer identity. Not the phone. `docs/technical.md` §4.
    public let writer: DeviceID

    private let clock: SystemClock
    private let state: Mutex<State>

    /// Opens the log for appending, creating it if it is not there.
    ///
    /// `highWaterMark` is the highest `lamport` **this writer** has already used,
    /// when the caller already knows it. Supplying it is what keeps a full decode
    /// of the log off the tap path: without it the first `record` of the process
    /// falls back to reading and decoding the whole file, measured at 193 ms at
    /// five years and 865 ms at ten (`docs/technical.md` §6) — on the main actor,
    /// inside the synchronous steps §4 requires to be microseconds.
    ///
    /// The composition root has that number for free: it reads the log
    /// synchronously to render the first frame, and ``JournalRead/highWaterMarks``
    /// falls out of the same pass.
    ///
    /// Two conditions make passing it in safe, and both are worth stating because
    /// they are the reason this is not just an optimisation with a race in it:
    ///
    /// - It must be derived from **this store's log, for this writer** — from
    ///   ``JournalRead/highWaterMarks``, which counts lines this build cannot
    ///   decode. Nothing verifies it here; that is the point.
    /// - Reading it outside the advisory `flock` is safe because a `lamport`
    ///   sequence belongs to one writer and **no two processes share a writer
    ///   identity** (`docs/technical.md` §4). The widget appending concurrently
    ///   cannot move this writer's mark, so there is nothing for the lock to
    ///   protect. The lock still guards the fallback path below, where the tail
    ///   is read and appended to in one operation.
    public init(
        layout: StoreLayout,
        writer: DeviceID,
        clock: SystemClock = SystemClock(),
        highWaterMark: Int? = nil
    ) throws {
        try layout.prepare()

        self.layout = layout
        self.writer = writer
        self.clock = clock
        self.state = Mutex(
            State(
                descriptor: try EventJournal.openForAppend(layout.events),
                nextLamport: highWaterMark.map { $0 + 1 },
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
    /// On this process's first write the tail is read to recover `lamport`, and
    /// that read-then-append is held under an advisory `flock` for its duration,
    /// per `docs/technical.md` §4. **This is the only place a cross-process lock
    /// is taken, and it is never taken on the tap path after the first write of
    /// a process's lifetime.**
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

            func stamp(_ lamport: Int) -> Event {
                Event(
                    id: UUID(),
                    device: writer,
                    lamport: lamport,
                    kind: kind,
                    day: day,
                    recordedAt: clock.milliseconds(at: instant),
                    zoneOffset: clock.zoneOffsetMinutes(at: instant),
                    source: source,
                    payload: payload,
                    // `prev` is the genesis value for every week-1a event. The
                    // hash chain lands in week 1b together with the canonical
                    // byte encoding and `content_hash`, and the one-time
                    // `reproject` hatch in `docs/technical.md` §11 replays this
                    // log into a chained one. Chaining here first would mean
                    // hashing bytes whose canonical form does not exist yet.
                    prev: Event.genesisPrev
                )
            }

            if state.nextLamport == nil {
                return try EventJournal.withExclusiveLock(state.descriptor) {
                    let recovered = try EventJournal.highWaterMark(
                        at: layout.events, writer: writer
                    )
                    let event = stamp(recovered + 1)
                    try EventJournal.writeLine(event, to: state.descriptor)
                    state.nextLamport = event.lamport + 1
                    return event
                }
            }

            let event = stamp(state.nextLamport!)
            try EventJournal.writeLine(event, to: state.descriptor)
            state.nextLamport = event.lamport + 1
            return event
        }
    }

    /// Appends an event **verbatim** — the ``EventSink`` behaviour. Used to
    /// re-append events this writer did not stamp, such as a restored bundle.
    /// Nothing is rewritten and nothing is renumbered.
    public func appendSync(_ event: Event) throws {
        try state.withLock { state in
            guard !state.isClosed else { throw JournalError.closed }
            try EventJournal.writeLine(event, to: state.descriptor)
            if event.device == writer, let next = state.nextLamport {
                state.nextLamport = max(next, event.lamport + 1)
            }
        }
    }

    // MARK: Reading

    /// Reads the whole log back. The log is the source of truth; the snapshot
    /// cache is disposable and may be deleted at any moment.
    public func read() throws -> JournalRead {
        try JournalReader(url: layout.events).read()
    }

    // MARK: File primitives

    private static func openForAppend(_ url: URL) throws -> Int32 {
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

    /// One `write(2)` of one complete line. A short write is reported rather
    /// than looped over: looping would be a second, non-atomic append, which is
    /// the exact interleaving this design exists to prevent.
    private static func writeLine(_ event: Event, to descriptor: Int32) throws {
        var line = try encoder.encode(event)
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

    /// The highest `lamport` this writer has already used, or `0` if it has
    /// never written. Read under the lock taken by ``record``.
    ///
    /// This folds over ``JournalRead/highWaterMarks`` and **not** over
    /// `.events`, because `events` holds only the lines this build could decode.
    /// See ``JournalRead/highWaterMarks`` for why the difference is a
    /// correctness bug and not a rounding error.
    private static func highWaterMark(at url: URL, writer: DeviceID) throws -> Int {
        try JournalReader(url: url).read().highWaterMarks[writer] ?? 0
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
                events: [], damagedLines: [], droppedPartialTail: false, highWaterMarks: [:]
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
            highWaterMarks: highWaterMarks
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

    public init(
        events: [Event],
        damagedLines: [Int],
        droppedPartialTail: Bool,
        highWaterMarks: [DeviceID: Int] = [:]
    ) {
        self.events = events
        self.damagedLines = damagedLines
        self.droppedPartialTail = droppedPartialTail
        self.highWaterMarks = highWaterMarks
    }

    public var isIntact: Bool { damagedLines.isEmpty && !droppedPartialTail }
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
