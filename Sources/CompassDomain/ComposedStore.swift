// The composition root's return value.
//
// It lives here rather than in `Ports.swift` because it is not a port.
// `.claude/skills/architecture.md` scopes that file to ports and says new ports
// are added there "and nowhere else"; a value object that happens to *carry*
// ports is a different thing, and leaving it there blurs the one rule that file
// exists to state.
//
// It is in Domain rather than in `CompassInfrastructure` alongside the function
// that builds it, because `CompassUI` consumes it and cannot import
// Infrastructure. `docs/technical.md` §2.

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

    /// The events the first frame renders from, read **synchronously** — and
    /// empty when ``snapshot`` supplied the first frame instead.
    /// `docs/technical.md` §4: the first frame must render correct data with
    /// zero awaits, and `await log.replay()` must not happen before anything is
    /// shown.
    public let events: [Event]

    /// The disposable launch cache, when there was a usable one.
    ///
    /// It is the *preferred* first frame and the log read is the fallback,
    /// rather than the other way round: `docs/technical.md` §6 measures a full
    /// decode at 193 ms at five years and 865 ms at ten, and §4 wants that
    /// nowhere near a launch. It is never the source of anything — the replay
    /// that follows a moment later wins, and deleting the file at any moment
    /// costs one slower launch.
    public let snapshot: TodaySnapshot?

    public let clock: any Clock
    public let recorder: any EventRecorder
    public let source: any EventSource

    /// Line 4 of the tap path — the actor catching up with an event that is
    /// already durable. `nil` only in a test that does not care.
    public let absorber: (any EventAbsorber)?

    /// Line 5 of the tap path — the achievement engine. `nil` only in a test that
    /// does not care, and on a launch that could not open the store at all: there
    /// is nothing to evaluate over and nowhere to record what it found.
    public let awarding: (any Awarding)?

    /// Week 4's anchoring pass. `nil` on a launch that could not open the store,
    /// and in a test that does not care — and when it is `nil` the app is exactly
    /// what it was in week 3: every record still sealed, and no surface claiming
    /// otherwise.
    public let anchoring: (any Anchoring)?

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
        snapshot: TodaySnapshot? = nil,
        absorber: (any EventAbsorber)? = nil,
        awarding: (any Awarding)? = nil,
        anchoring: (any Anchoring)? = nil,
        isStoreAvailable: Bool = true
    ) {
        self.events = events
        self.clock = clock
        self.recorder = recorder
        self.source = source
        self.snapshot = snapshot
        self.absorber = absorber
        self.awarding = awarding
        self.anchoring = anchoring
        self.isStoreAvailable = isStoreAvailable
    }
}
