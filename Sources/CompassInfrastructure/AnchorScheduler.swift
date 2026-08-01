import CompassDomain
import Foundation

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

/// The **other** anchoring path. `.claude/skills/ios.md`,
/// `docs/achievement-protocol.md` §7.1, `docs/technical.md` §9.8.
///
/// > Anchoring retries with exponential backoff via `BGProcessingTask` **and**
/// > drains the pending queue opportunistically on launch. Both.
///
/// Three files in this corpus once specified two incompatible behaviours here
/// and the resolution was to do both, for a stated reason: `BGProcessingTask`
/// carries **no execution guarantee**, and `.claude/skills/ui.md` forbids showing
/// anchoring failure on the main screen — so if the scheduler path were chosen
/// alone and simply never fired, the failure would be undetectable by design.
/// The launch drain in `TodayModel.reconcile()` is the other half, and it is also
/// the only one of the two a test can observe.
///
/// This half is therefore deliberately thin: it registers a handler, asks the
/// system to run it when it feels like it, and re-asks afterwards. Everything
/// that can be wrong lives in ``AnchorPipeline``, which `swift test` compiles.
public enum AnchorScheduler {

    /// Must also appear in the app's `BGTaskSchedulerPermittedIdentifiers`, or
    /// registration throws at launch. `project.yml` carries it.
    public static let taskIdentifier = "dev.farros.compass.anchor"

    /// An hour. The system will run it later than this and often much later —
    /// that is what "no execution guarantee" means, and it is why the launch
    /// drain exists.
    public static let earliestDelay: TimeInterval = 60 * 60

    /// Registers the handler. **Must be called before the app finishes
    /// launching**, which is why `App/CompassApp.swift` calls it from `init` —
    /// the one line of week 4 that touches that folder.
    public static func register(storeURL: URL = AppComposition.storeURL) {
        #if canImport(BackgroundTasks) && os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier, using: nil
        ) { task in
            // `BGTask` is not `Sendable` and this handler is, so the one hop
            // between them has to be spelled out rather than inferred.
            //
            // What makes it safe is `using: nil`: the system delivers the task
            // **on the main queue**, and every line that touches it below is
            // `@MainActor`. So the value never actually leaves the isolation it
            // arrived on — the compiler simply cannot see that through an
            // Objective-C callback signature that predates the model.
            let arrived = UncheckedSendable(task)
            MainActor.assumeIsolated { run(arrived.value, storeURL: storeURL) }
        }
        schedule(storeURL: storeURL)
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    @MainActor
    private static func run(_ task: BGTask, storeURL: URL) {
        // Re-scheduled first, so a crash inside the drain still leaves a request
        // in the queue. A queue that empties itself on the one run that failed is
        // a queue that stops trying exactly when it matters.
        schedule(storeURL: storeURL)

        let work = Task { @MainActor in
            let pipeline = AnchorPipeline(layout: StoreLayout(storeURL: storeURL))
            let drained = try? await pipeline.drain()
            // `false` is not a failure report — the system uses it to decide
            // whether to keep giving this app time. A drain that reached no
            // calendar has not failed at anything it controls.
            task.setTaskCompleted(success: drained != nil)
        }
        task.expirationHandler = { work.cancel() }
    }
    #endif

    /// Asks for one run, no earlier than ``earliestDelay`` from now.
    public static func schedule(storeURL: URL = AppComposition.storeURL) {
        #if canImport(BackgroundTasks) && os(iOS)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(earliestDelay)
        // The whole pass is network. Without this the system would wake the app
        // to discover it cannot reach a calendar and record a failure that means
        // nothing.
        request.requiresNetworkConnectivity = true
        // Anchoring is a few HTTP requests and some SHA-256. Demanding a charger
        // for that would be asking for a run that never comes.
        request.requiresExternalPower = false
        // A duplicate submission throws; there is nothing to do about it and
        // nothing to say. `BGTaskScheduler` is also unavailable in an app
        // extension and in a simulator without the entitlement.
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}

/// Carries one value across the single boundary above, and exists for nothing
/// else.
///
/// It is `@unchecked Sendable` and that is a promise rather than a fact, so the
/// promise is written next to it: the only thing ever put in one is a `BGTask`
/// delivered on the main queue, unwrapped inside `MainActor.assumeIsolated`, and
/// used only from `@MainActor` code. If a second call site ever appears, this
/// reasoning has to be re-made for it — that is why the type is `fileprivate`.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
