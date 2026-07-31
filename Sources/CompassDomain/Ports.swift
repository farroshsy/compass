import Foundation

// The ports, all declared in Domain, all `Sendable`.
// `docs/technical.md` §2, `.claude/skills/architecture.md`.
//
// New capability goes behind an existing port if one fits. New ports are added
// in this file and nowhere else. Nothing here is implemented in Domain —
// `CompassInfrastructure` supplies the adapters and `App/`, the composition
// root, is the only place they are constructed.

/// Appends one event to the log. Durability is the adapter's problem; the
/// synchronous tap-path write is a separate, narrower concern.
public protocol EventSink: Sendable {
    func append(_ event: Event) async throws
}

/// The narrower concern ``EventSink`` names: **the synchronous tap-path write.**
/// `docs/technical.md` §4, `.claude/skills/ios.md`.
///
/// `record` stamps the event onto this writer's chain — `device`, the next
/// `lamport`, `recordedAt`, `zoneOffset` — and makes it durable, in one
/// synchronous call. There is no `async` here on purpose: **no `await` between
/// the tap and durability.** An `await` on this path is the thing the design
/// forbids, so the port cannot offer one.
///
/// The stamping and the write are one call rather than two because `lamport`
/// belongs to the writer's own sequence and recovering it after a cold start
/// means reading the tail of the log — and `docs/technical.md` §4 requires that
/// read-then-append to happen under a single advisory `flock`. Splitting them
/// would put the lock's two halves in the caller's hands.
///
/// `day` is passed in rather than derived: the 04:00 civil-day boundary is
/// applied **once**, when the event is created, and never in the fold.
public protocol EventRecorder: Sendable {
    @discardableResult
    func record(
        kind: EventKind, day: Day, source: CheckInSource?, payload: EventPayload
    ) throws -> Event
}

/// Replays the whole log. The log is the source of truth; the snapshot cache is
/// disposable and may be deleted at any moment.
public protocol EventSource: Sendable {
    func replay() async throws -> [Event]
}

/// The only way time enters Domain. Never `Date()`, never `Calendar.current`,
/// never `TimeZone.current` inside `CompassDomain`.
///
/// `today(cutoffHour:)` is the single place a `Date` becomes a ``Day``, and it
/// is applied once when the event is created — never in the fold.
public protocol Clock: Sendable {
    func now() -> Date
    func today(cutoffHour: Int) -> Day
}

/// The day-start hour. A check-in at 01:30 counts for the day the user was
/// awake for. `docs/technical.md` §3.
///
/// One constant, in Domain, zero UI. It removes the single most common
/// "I did it but the app says I didn't" moment.
public enum DayBoundary {
    public static let cutoffHour = 4
}

/// Everything the composition root resolves, as **one value**.
///
/// It exists so that composing the app can be a function that returns something
/// a test can look at, rather than a block of wiring inside `App/`. `App/` is
/// not compiled by `swift test` and has no test target, so every line living
/// there is unprotected — proved by mutation: restoring a `preconditionFailure`
/// on the store-open failure path, and deleting the argument that hands the
/// journal its already-known high-water mark, both left the entire suite green.
/// Each of those lines was a fix for a real bug.
///
/// It carries **ports and nothing else** — no concrete type from
/// `CompassInfrastructure` appears in it — which is what lets `CompassUI` accept
/// one without learning that Infrastructure exists. That boundary is the only
/// load-bearing one in `docs/technical.md` §2.
public struct ComposedStore: Sendable {

    /// The events the first frame renders from, read **synchronously**.
    /// `docs/technical.md` §4: the first frame must render correct data with
    /// zero awaits, and `await log.replay()` must not happen before anything is
    /// shown.
    public let events: [Event]

    public let clock: any Clock
    public let recorder: any EventRecorder
    public let source: any EventSource

    /// `false` when the store could not be opened at all.
    ///
    /// `docs/technical.md` §6 ends its damaged-log policy with "never silently
    /// drop lines and **never refuse to launch**", so an unopenable store is a
    /// screen and never a crash. The ports behind it throw on every call rather
    /// than accepting taps in memory and losing them at exit.
    public let isStoreAvailable: Bool

    public init(
        events: [Event],
        clock: any Clock,
        recorder: any EventRecorder,
        source: any EventSource,
        isStoreAvailable: Bool = true
    ) {
        self.events = events
        self.clock = clock
        self.recorder = recorder
        self.source = source
        self.isStoreAvailable = isStoreAvailable
    }
}

/// The anti-rewrite hinge. `OpenTimestampsAttestor` ships first;
/// `SoulboundAttestor` arrives later behind this identical protocol. An
/// achievement holds a list of attestations, so old records carry one and new
/// records carry two, and nothing migrates. `docs/technical.md` §2.
public protocol Attestor: Sendable {
    func attest(_ claim: AchievementClaim) async throws -> Attestation
}
