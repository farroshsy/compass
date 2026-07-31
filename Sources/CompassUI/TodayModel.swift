import CompassApplication
import CompassDomain
import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#endif

/// The one screen's state. `docs/technical.md` §4, `.claude/skills/ios.md`.
///
/// `@MainActor @Observable final class`, and deliberately **not** an actor:
/// Observation cannot synchronously observe state across an actor hop, and the
/// hop would land in the tap path.
///
/// It holds ports only. `CompassUI` cannot import `CompassInfrastructure` —
/// Swift enforces that at target granularity — so the adapters are constructed
/// in `App/`, the composition root, and injected here.
@MainActor
@Observable
public final class TodayModel {

    /// How many days the spine shows. A display, never a control.
    public static let spineLength = 28

    /// The fold of the log. Every read on this screen goes through it.
    public private(set) var projection: Projection

    /// The civil day the screen is about, with the 04:00 boundary already
    /// applied. Refreshed when the app becomes active, so a phone left open
    /// overnight does not keep tapping into yesterday.
    public private(set) var today: Day

    /// `false` when the composition root could not open the store at all.
    ///
    /// `docs/technical.md` §6 ends its damaged-log policy with "never silently
    /// drop lines and **never refuse to launch**", so an unopenable store is a
    /// screen, not a crash. The screen it produces is deliberately a poor one —
    /// no habits, no days, and a tap that does nothing — because the recorder
    /// behind it throws and ``toggle`` treats a failed write as "the tap does
    /// nothing and the screen keeps telling the truth". This flag is the one
    /// thing that makes that state legible instead of looking like an app that
    /// forgot everything.
    public let isStoreAvailable: Bool

    private let clock: any Clock
    private let recorder: any EventRecorder
    private let source: any EventSource

    /// Events applied while a replay was in flight. The replay wins, but it
    /// cannot win over an event it never saw.
    private var appliedDuringReplay: [Event] = []
    private var isReplaying = false

    /// The first frame renders from `events`, which the composition root read
    /// **synchronously**. There is no `await` before anything is shown.
    ///
    /// `docs/technical.md` §4 has that synchronous read coming from a small
    /// `TodaySnapshot` cache. The cache is week 1b (§11), and on a week-1a log
    /// the synchronous read is the log itself; ``reconcile()`` is already
    /// written against the rule the cache needs, so week 1b changes what is
    /// read and not how it reconciles.
    public init(
        events: [Event],
        clock: any Clock,
        recorder: any EventRecorder,
        source: any EventSource,
        isStoreAvailable: Bool = true
    ) {
        self.projection = project(events)
        self.today = clock.today(cutoffHour: DayBoundary.cutoffHour)
        self.clock = clock
        self.recorder = recorder
        self.source = source
        self.isStoreAvailable = isStoreAvailable
    }

    /// The launch initialiser: everything the composition root resolved, in one
    /// value.
    ///
    /// This exists so that `App/` — which `swift test` does not compile and no
    /// test target covers — has no argument list to get wrong. Forwarding five
    /// arguments there meant a future session could drop
    /// ``ComposedStore/isStoreAvailable`` in silence and turn the unopenable-store
    /// screen back into an app that looks like it forgot everything. Here, the
    /// forwarding is compiled and tested like everything else.
    public convenience init(_ store: ComposedStore) {
        self.init(
            events: store.events,
            clock: store.clock,
            recorder: store.recorder,
            source: store.source,
            isStoreAvailable: store.isStoreAvailable
        )
    }

    // MARK: Reading

    /// At most four. The cap is enforced where habits are created, not here:
    /// hiding a row would make its taps impossible while its data kept
    /// accumulating. `docs/product.md`.
    public var habits: [HabitState] { projection.activeHabits }

    /// The largest number on the screen. Never the streak — a number that
    /// resets to zero teaches starting over, which is the behaviour this
    /// project exists to defend against.
    public var totalDays: Int { projection.totalCheckedDays }

    public func isChecked(_ habit: HabitState) -> Bool {
        habit.isChecked(on: today)
    }

    /// The 28-dot spine, oldest first, ending on ``today``.
    ///
    /// A dot is filled when **every** active habit was done that day. A missed
    /// day is a plain gap: no red, no warning, no "streak at risk".
    ///
    /// Which of "all habits" or "any habit" fills a dot is not stated anywhere
    /// in the corpus. All-habits is chosen because completion is an all-habits
    /// idea everywhere else in the documents — "finishing all habits does not
    /// change the layout" — and because the honest reading of a gap is "that
    /// day is not done".
    public var spine: [Bool] {
        let habits = projection.activeHabits
        guard !habits.isEmpty else {
            return Array(repeating: false, count: TodayModel.spineLength)
        }
        return (0..<TodayModel.spineLength).map { offset in
            let day = today.adding(offset - (TodayModel.spineLength - 1))
            return habits.allSatisfy { $0.isChecked(on: day) }
        }
    }

    // MARK: The tap path

    /// Tap toggles, tap again untoggles, and there is never a confirmation
    /// dialog. Untoggling appends a compensating `checkInRevoked`; nothing in
    /// this system is ever mutated or deleted.
    ///
    /// **`docs/technical.md` §4, the whole design.** Every step below is
    /// synchronous: there is no `await` between the tap and the pixel, and none
    /// between the tap and durability. Kill the app 10ms after the tap and the
    /// check-in survives.
    ///
    /// One deviation from §4's line order, stated rather than hidden. §4 reads:
    ///
    /// ```
    /// let event = Event(kind:habit:day:at:)
    /// projection.apply(event)   // 1
    /// haptics.impact(.soft)     // 2
    /// journal.appendSync(event) // 3
    /// ```
    ///
    /// That four-argument initialiser cannot produce the `device`, `lamport`,
    /// `recordedAt` and `zoneOffset` that §3 requires on every record, and the
    /// corpus never says who supplies them — a gap already reported in
    /// `EventJournal.swift`. They are supplied by the ``EventRecorder`` port,
    /// which therefore returns the stamped event, so the apply can only happen
    /// after the write. The haptic moves to first, which is strictly earlier
    /// than §4 asks for.
    ///
    /// Nothing observable changes: all three run in one synchronous main-actor
    /// turn, so no frame can render between them, and the properties §4
    /// actually states — synchronous, no await, durable at the moment of the
    /// tap — hold exactly.
    public func toggle(_ habit: HabitState) {
        // **One interaction, one day.** The clock is read exactly once here, and
        // that read updates ``today`` — the same property every row and the
        // spine render from.
        //
        // Reading the clock for the write while the screen kept rendering a
        // `today` refreshed only in `init`, `.task` and on `scenePhase` active
        // meant the two could disagree: crossing 04:00 with the app open in the
        // foreground, a tap wrote for the new day while the row still rendered
        // the old one, so the haptic fired, the event landed on disk, and the
        // checkbox did not fill. `docs/technical.md` §3 says the 04:00 boundary
        // exists to remove exactly that "I did it but the app says I didn't"
        // moment; a second read of the day is how it came back.
        refreshDay()
        let day = today

        let kind = CheckIn.kind(for: habit.id, on: day, in: projection)

        Haptics.tap()                                            // §4 line 2

        guard let event = try? recorder.record(                  // §4 line 3
            kind: kind,
            day: day,
            // Present on `checkedIn`, absent on `checkInRevoked`. §3's canonical
            // form, not a display detail — see ``CheckIn/source(for:from:)``.
            source: CheckIn.source(for: kind, from: .tap),
            payload: CheckIn.payload(for: habit.id)
        ) else {
            // The write failed — a full disk, or a store that went away.
            // Applying to the projection anyway would show a check that is not
            // on disk, which is exactly the "did my tap actually save?" doubt
            // the synchronous write exists to remove. So the tap does nothing,
            // and the screen keeps telling the truth.
            //
            // A *single* failed write says nothing on screen: there is no
            // failure surface here by design, and one unlucky tap is not worth a
            // sentence. A store that never opened at all is different in kind
            // and is surfaced once, through ``isStoreAvailable``.
            return
        }

        projection.apply(event)                                  // §4 line 1
        if isReplaying { appliedDuringReplay.append(event) }

        // §4 lines 4 and 5 — `Task { await log.absorb(event) }` and
        // `Task { await achievements.evaluate(projection) }` — have nothing to
        // dispatch to yet. `actor EventLog` is week 1b and the achievement
        // engine is week 3 (§11 build order). They attach here.
    }

    // MARK: The launch path

    /// The full replay, run from a `.task` immediately after the first frame.
    ///
    /// **The replay wins.** The log is the source of truth and whatever the
    /// first frame rendered from is a disposable cache. The one thing the
    /// replay cannot win over is an event appended while it was in flight —
    /// that event is on disk but was not in the snapshot the replay read, so it
    /// is re-applied afterwards.
    public func reconcile() async {
        isReplaying = true
        defer { isReplaying = false; appliedDuringReplay.removeAll() }

        guard let events = try? await source.replay() else { return }

        var replayed = project(events)
        let seen = Set(events.map(\.id))
        for event in appliedDuringReplay where !seen.contains(event.id) {
            replayed.apply(event)
        }
        projection = replayed
    }

    /// Re-reads the civil day. Called when the view appears, whenever the app
    /// becomes active, and **at the head of every tap** — so crossing 04:00
    /// either in the background or in the foreground leaves the screen and the
    /// write agreeing on which day it is. This is the only place ``today`` is
    /// assigned, and ``toggle`` is the only reason it is not enough to refresh
    /// it on `scenePhase` alone.
    public func refreshDay() {
        today = clock.today(cutoffHour: DayBoundary.cutoffHour)
    }
}

/// The haptic. `.claude/skills/ui.md`: it fires synchronously with the tap,
/// before any write completes.
///
/// `UIImpactFeedbackGenerator` rather than SwiftUI's `.sensoryFeedback`, which
/// is declarative and fires on a state change during a view update — that is
/// after the tap, not with it. This is the "no UIKit unless forced" exception,
/// and the force is that the whole point is the ordering.
enum Haptics {
    @MainActor static func tap() {
        #if canImport(UIKit) && !os(watchOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }
}
