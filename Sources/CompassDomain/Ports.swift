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

/// The anti-rewrite hinge. `OpenTimestampsAttestor` ships first;
/// `SoulboundAttestor` arrives later behind this identical protocol. An
/// achievement holds a list of attestations, so old records carry one and new
/// records carry two, and nothing migrates. `docs/technical.md` §2.
public protocol Attestor: Sendable {
    func attest(_ claim: AchievementClaim) async throws -> Attestation
}
