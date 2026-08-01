import Foundation

// The ports, all declared in Domain, all `Sendable`.
// `docs/technical.md` §2, `.claude/skills/architecture.md`.
//
// New capability goes behind an existing port if one fits. New ports are added
// in this file and nowhere else, and **this file holds ports and nothing else**
// — a value object that merely carries ports gets its own file, as
// `ComposedStore.swift` does. Nothing here is implemented in Domain:
// `CompassInfrastructure` supplies the adapters, and its
// `Composition.swift` — the composition root — is the only place they are
// constructed. (That root was `App/CompassApp.compose()` until 2026-07-31; the
// rule did not change, only its location.)

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

/// Line 4 of the tap path: `Task { await log.absorb(event) }`.
/// `docs/technical.md` §4.
///
/// The event handed over here is **already durable** — ``EventRecorder`` wrote
/// it synchronously, before this call exists. So this port is not a write and
/// cannot fail: it is the in-memory array and the disposable snapshot catching
/// up with a fact that is already on disk. That is why it is `async` where
/// ``EventRecorder`` is not, and why it does not throw where ``EventSink`` does.
///
/// It is a port rather than a method on a concrete type for the ordinary reason:
/// `CompassUI` cannot import `CompassInfrastructure`, and `actor EventLog` lives
/// there.
public protocol EventAbsorber: Sendable {
    func absorb(_ event: Event) async
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

/// Line 5 of the tap path: `Task { await achievements.evaluate(projection) }`.
/// `docs/technical.md` §4 and §5.
///
/// **It takes no projection, and that is the one deviation from §4's sketch that
/// could not be avoided.** `docs/achievement-protocol.md` §4.1 builds
/// `evidenceRoot` out of the `content_hash` of the qualifying **events**, and
/// `witness.logHeads` needs every writer's chain head — neither of which a
/// `Projection` carries, because it folds check-ins into booleans and drops the
/// events. The adapter reads the log itself, which it can do because it is
/// Infrastructure and already holds the store's layout.
///
/// Both calls are `async` and both may fail. Nothing on the tap path waits on
/// either: an achievement that is not noticed until the next launch is late, and
/// an achievement noticed at the cost of a frame would break the one rule the
/// whole product is.
public protocol Awarding: Sendable {

    /// Re-runs the engine over the whole log, records what it finds, and returns
    /// everything recorded — including whatever this pass just awarded.
    ///
    /// Safe to call an unlimited number of times. Achievement IDs are
    /// deterministic and filtered against the set already recorded, so replaying
    /// the entire log any number of times produces the identical award set.
    func evaluate() async throws -> AwardBook

    /// What is already recorded, without evaluating anything. The certificate
    /// list reads this.
    func recorded() async throws -> AwardBook
}

/// The anti-rewrite hinge. `OpenTimestampsAttestor` ships first;
/// `SoulboundAttestor` arrives later behind this identical protocol. An
/// achievement holds a list of attestations, so old records carry one and new
/// records carry two, and nothing migrates. `docs/technical.md` §2.
public protocol Attestor: Sendable {
    func attest(_ claim: AchievementClaim) async throws -> Attestation
}

/// Week 4's background pass: anchor the log head weekly, submit what the
/// 72-hour window has released, and upgrade everything still pending.
/// `docs/adr/0004`, `docs/achievement-protocol.md` §7.1.
///
/// **It is a port, and separate from ``Attestor``, because it decides *when* and
/// ``Attestor`` decides *what*.** The pipeline reads clocks and files to work out
/// which claims are due; the attestor takes one claim and anchors it. Merging
/// them would put the 72-hour gate inside the thing whose job is to submit.
///
/// `.claude/skills/ios.md` requires the queue to drain on **both** paths — a
/// `BGProcessingTask`, which carries no execution guarantee, and opportunistically
/// on launch, which is the only one of the two that is observable in a test. This
/// is the call both of them make.
///
/// **It must make no network request when nothing is due**, which is what makes
/// it safe to call every time the app becomes active.
public protocol Anchoring: Sendable {
    func drain() async throws -> AnchorDrain
}

/// What one drain concluded.
public struct AnchorDrain: Sendable {

    /// Every attestation as it now stands, so a confirmation reaches the
    /// certificate without a second read.
    public let attestations: [AchievementID: Attestation]

    /// Sent to the calendars on this pass. Nothing renders this: `submitted`
    /// only means bytes were sent, and anchoring language is forbidden before
    /// `confirmed`.
    public let submitted: [AchievementID]

    /// Upgraded into a Bitcoin block on this pass. **This is the only thing in
    /// the system that earns the word "anchored"**, and the certificate gains
    /// exactly one line of text because of it.
    public let confirmed: [AchievementID]

    /// The newest log-head anchor, or `nil` if none has ever been made.
    public let logAnchor: LogAnchor?

    public init(
        attestations: [AchievementID: Attestation],
        submitted: [AchievementID] = [],
        confirmed: [AchievementID] = [],
        logAnchor: LogAnchor? = nil
    ) {
        self.attestations = attestations
        self.submitted = submitted
        self.confirmed = confirmed
        self.logAnchor = logAnchor
    }
}
