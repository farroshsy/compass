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
