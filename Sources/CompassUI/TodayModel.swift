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

    /// How many days the spine shows. A display, never a control. The number
    /// itself lives in ``TodayMetrics`` beside the geometry that has to fit it.
    public static let spineLength = TodayMetrics.spineLength

    /// The fold of the log. Every read on this screen goes through it.
    public private(set) var projection: Projection

    /// The declared subject of the record — the optional, self-declared,
    /// unverified name from the settings sheet. A second, separate fold over the
    /// same log; see ``CompassDomain/SubjectName`` for why it is not inside
    /// ``projection``.
    public private(set) var subject: SubjectName

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
        self.subject = declaredSubject(events)
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

    /// At most four, oldest first. The cap is enforced where habits are created,
    /// not here: hiding a row would make its taps impossible while its data kept
    /// accumulating. `docs/product.md`.
    public var habits: [HabitState] { projection.activeHabits }

    /// The habits that have been removed from Today — **archived, never
    /// deleted.** They keep every day they recorded, they are still in the log,
    /// and they do not occupy one of the four slots.
    public var removedHabits: [HabitState] { projection.archivedHabits }

    /// Whether the settings sheet may add another habit. Four active is the cap;
    /// removed ones do not count. `docs/product.md`.
    public var mayAddHabit: Bool { projection.mayCreateHabit }

    /// The declared name, or `""`. Never verified, and the interface must never
    /// say or imply that it was.
    public var declaredName: String { subject.value }

    /// The largest number on the screen: distinct days on which something was
    /// recorded. Never the streak — a number that resets to zero teaches starting
    /// over, which is the behaviour this project exists to defend against.
    public var totalDays: Int { projection.daysRecorded }

    /// The earliest recorded day, or `nil` before anything is recorded.
    public var firstRecordedDay: Day? { projection.firstCheckedDay }

    /// The line under the number: "128 days recorded since 5 December 2025".
    ///
    /// It replaced the bare word "days", and the design records why: the number
    /// alone carries no signal — 128 to 129 is imperceptible — and it was
    /// nonetheless the largest thing on the screen. See ``TodayCaption``.
    public var caption: String {
        TodayCaption.text(totalDays: totalDays, firstDay: firstRecordedDay)
    }

    /// What VoiceOver reads for the header, which is ``caption`` **plus the
    /// store notice when there is one.**
    ///
    /// The header is a single merged accessibility element whose label is
    /// replaced, so anything rendered inside it that is not in that label is
    /// invisible to a screen reader. ``caption`` alone announced "0 days
    /// recorded" on a launch where the store could not be opened, and said
    /// nothing about why — which is the reading ``isStoreAvailable`` exists to
    /// prevent. The label the view renders is this, never ``caption``.
    public var spokenCaption: String {
        TodayCaption.spokenHeader(caption: caption, isStoreAvailable: isStoreAvailable)
    }

    public func isChecked(_ habit: HabitState) -> Bool {
        habit.isChecked(on: today)
    }

    /// The 28-dot spine, oldest first, ending on ``today``.
    ///
    /// A dot is filled when **every habit that was being tracked on that day**
    /// was done that day. A missed day is a plain gap: no red, no warning, no
    /// "streak at risk".
    ///
    /// Which of "all habits" or "any habit" fills a dot is not stated anywhere
    /// in the corpus. All-habits is chosen because completion is an all-habits
    /// idea everywhere else in the documents — "finishing all habits does not
    /// change the layout" — and because the honest reading of a gap is "that
    /// day is not done".
    ///
    /// **Each day is judged against the habits active on it, never against
    /// today's set.** `docs/product.md` calls this "a 28-day dot strip showing
    /// gaps honestly", and a strip folded over ``Projection/activeHabits`` was
    /// not that: a habit created this morning has no check-ins on the previous
    /// 27 days, so adding one turned every earlier dot off, and archiving one
    /// filled dots the user never earned. The past is not a function of the
    /// current settings. See ``CompassDomain/HabitState/isActive(on:)`` for the
    /// interval the log supplies.
    ///
    /// A day nothing was tracked on is a gap, not a completion: `allSatisfy` over
    /// an empty set is `true`, and the days before the first habit existed are
    /// exactly that set.
    public var spine: [Bool] {
        (0..<TodayModel.spineLength).map { offset in
            let day = today.adding(offset - (TodayModel.spineLength - 1))
            let tracked = projection.habitsActive(on: day)
            return !tracked.isEmpty && tracked.allSatisfy { $0.isChecked(on: day) }
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

    // MARK: The settings sheet

    /// Creates a habit. Returns `false` and writes nothing when the name is
    /// blank, when four are already active, or when the write fails.
    ///
    /// The identifier is minted here, opaque, and **never derived from the
    /// name.** `docs/achievement-protocol.md` §3.4: a `HabitID` is what `facts`
    /// carries into a signed, anchored, shareable record, and there is no
    /// redaction path and can never be one — so a habit called after a recovery
    /// programme or a medical routine must not put that word inside the digest.
    /// A random UUID cannot.
    @discardableResult
    public func addHabit(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        // The cap is enforced here, at the one place a habit can be created,
        // rather than by hiding a row: a hidden row is a habit whose taps are
        // impossible while its data keeps accumulating. `docs/product.md`.
        guard projection.mayCreateHabit else { return false }

        let id = HabitID(rawValue: "h-\(UUID().uuidString.lowercased())")
        guard let event = append(kind: .habitCreated, payload: .habit(id, name: name)) else {
            return false
        }
        projection.apply(event)
        return true
    }

    /// Renames a habit. Returns `false` and writes nothing when the name is
    /// blank, unchanged, or the write fails.
    ///
    /// **It keeps the habit.** `habitRenamed` is cosmetic — `docs/technical.md`
    /// §3 marks it "never affects the fold" — so the identifier, every day it has
    /// recorded and its position among the rows all survive, and no digest
    /// changes. That is the entire reason this exists: `docs/product.md` justifies
    /// banning a first-launch naming flow with "renaming lives in the settings
    /// sheet, where it already belongs", and until it did, changing a name at the
    /// four-habit cap meant Remove followed by Add — which mints a **new**
    /// ``CompassDomain/HabitID``, leaves the old history behind an archived row,
    /// and starts the new one at zero. A cosmetic change was costing the user
    /// their record.
    @discardableResult
    public func rename(_ habit: HabitState, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        // The projection, not the passed-in snapshot: a view can hand back a row
        // it rendered before the last write landed.
        guard let current = projection.habit(habit.id), current.name != name else { return false }

        guard let event = append(kind: .habitRenamed, payload: .habit(habit.id, name: name)) else {
            return false
        }
        projection.apply(event)
        return true
    }

    /// Puts a removed habit back on Today by appending a `habitUnarchived`.
    /// Returns `false` and writes nothing when the habit is not removed, when
    /// four are already active, or when the write fails.
    ///
    /// Remove is one tap and there is no confirmation dialog — `.claude/skills/ui.md`
    /// forbids one — so without this a mis-tap was unrecoverable from the
    /// interface: the row was gone, and the only way back was to add a habit,
    /// which mints a new identifier and orphans the history behind the old row.
    /// The event kind and the fold have supported this since the first commit;
    /// only the way in was missing.
    ///
    /// The cap is checked here for the same reason it is checked in ``addHabit``:
    /// four rows is what the layout holds, and restoring a fifth would put a
    /// habit on screen whose row cannot be reached.
    @discardableResult
    public func restoreHabit(_ habit: HabitState) -> Bool {
        guard projection.habit(habit.id)?.isArchived == true else { return false }
        guard projection.mayCreateHabit else { return false }

        guard let event = append(kind: .habitUnarchived, payload: .habit(habit.id)) else {
            return false
        }
        projection.apply(event)
        return true
    }

    /// Removes a habit from Today by appending a `habitArchived`.
    ///
    /// **It never deletes.** A habit dropped after sixty days keeps those sixty
    /// days in the log, in ``projection``, and in every export — that is the
    /// whole premise of an append-only record, and it is the same rule that
    /// makes un-checking a day a `checkInRevoked` rather than a mutation. There
    /// is no code path in this application that removes anything from the log,
    /// and there must never be one.
    @discardableResult
    public func removeHabit(_ habit: HabitState) -> Bool {
        guard let event = append(kind: .habitArchived, payload: .habit(habit.id)) else {
            return false
        }
        projection.apply(event)
        return true
    }

    /// Declares the optional, self-declared name for the record, or withdraws it
    /// by passing an empty string. Returns `false` when nothing changed or the
    /// write failed.
    ///
    /// It is an event, so it is in the log, so it is under
    /// `witness.logHeads` in every achievement sealed afterwards — which is the
    /// entire claim: **the name was committed to at the time.** It is not a
    /// login, there is no account, no server sees it, and nothing verifies it.
    /// Nothing in the interface may imply otherwise.
    @discardableResult
    public func declare(name rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != subject.value else { return false }
        guard let event = append(kind: .subjectNamed, payload: .subject(named: name)) else {
            return false
        }
        subject.apply(event)
        return true
    }

    /// Records one event off the tap path, on the same terms as ``toggle``: the
    /// day is refreshed first so one interaction uses one day, `source` is
    /// absent because only a check-in has one, and **a failed write changes
    /// nothing on screen** — no state that is not on disk.
    private func append(kind: EventKind, payload: EventPayload) -> Event? {
        refreshDay()
        guard let event = try? recorder.record(
            kind: kind, day: today, source: nil, payload: payload
        ) else {
            return nil
        }
        if isReplaying { appliedDuringReplay.append(event) }
        return event
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
        var replayedSubject = declaredSubject(events)
        let seen = Set(events.map(\.id))
        for event in appliedDuringReplay where !seen.contains(event.id) {
            replayed.apply(event)
            replayedSubject.apply(event)
        }
        projection = replayed
        subject = replayedSubject
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
