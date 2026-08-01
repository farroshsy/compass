import Foundation

/// Whether a habit was done on a civil day.
///
/// `{ done, missed }` in v1. A third case, `neutral` — travel-bridged or
/// declared rest days — is designed for and deferred with a trigger in
/// `docs/technical.md` §10b. A string wrapper rather than an enum so adding it
/// is additive, per `.claude/skills/architecture.md`.
public struct DayStatus: StringBacked {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let done = DayStatus(rawValue: "done")
    public static let missed = DayStatus(rawValue: "missed")
}

/// One archival transition, kept per day. See ``HabitState/archivalDays``.
struct ArchivalChange: Hashable, Sendable {
    let isArchived: Bool
    let order: EventOrder
}

/// The state of one habit, folded out of the log.
///
/// Every accumulator here is inside a habit. There are no global accumulators —
/// that is not a stylistic rule, it is what the shard-invariance test in
/// `docs/technical.md` §9.3 mechanically enforces, because a globally
/// order-dependent accumulator is the exact bug that destroyed replay
/// determinism in this author's prior event-sourced work.
public struct HabitState: Hashable, Sendable {
    public let id: HabitID

    /// Display only. `habitRenamed` is cosmetic: the name never changes a
    /// status, a count or a streak, and it never enters a digest.
    public private(set) var name: String

    /// Whether the habit has a row **today**. For whether it had one on some
    /// earlier day, see ``isActive(on:)`` — the two are different questions and
    /// the spine needs the second one.
    public private(set) var isArchived: Bool

    /// The days currently checked in. A revoked day is absent, not marked.
    public private(set) var checkedDays: Set<Day>

    /// The civil day this habit started being tracked: the `day` of the earliest
    /// `habitCreated`, kept beside ``createdOrder`` by the same first-writer-wins
    /// rule.
    ///
    /// `nil` when no creation event for this habit is in the log — a damaged log,
    /// or a chain this build has not seen. ``isActive(on:)`` then applies no lower
    /// bound, which is the safe direction: it can only make the spine ask for
    /// *more*, never claim a day was complete when it was not.
    public private(set) var createdOn: Day?

    /// Last-writer-wins registers, one per independently-settable value. Each
    /// holds the ``EventOrder`` of the event that currently owns it, so applying
    /// the same set of events in any order converges on the same state.
    var nameOrder: EventOrder?
    var archiveOrder: EventOrder?
    var cellOrder: [Day: EventOrder]

    /// One last-writer-wins register **per day** holding the archival transitions
    /// that happened on that day — the same shape as ``cellOrder``, and for the
    /// same reason.
    ///
    /// ``isArchived`` above answers "is there a row now". This answers "was there
    /// a row on day D", and nothing else in the fold could: the current flag has
    /// no history in it, so a spine folded over it judges every past day against
    /// today's settings. `habitArchived` and `habitUnarchived` both carry the day
    /// they happened on, so the timeline is in the log already and this is a
    /// derivation of it, not a new fact.
    var archivalDays: [Day: ArchivalChange]

    /// The order of the **earliest** `habitCreated` for this habit — a
    /// first-writer-wins register, and the only one here that keeps the minimum
    /// rather than the maximum.
    ///
    /// It exists because ``Projection/activeHabits`` has to put the rows on the
    /// screen in some order, and until habits could be added that order was the
    /// byte order of the ``HabitID``. That was fine while every ID was a seed
    /// constant and stopped being fine the moment the settings sheet could mint
    /// one: an ID is deliberately opaque and carries no name and no date, so
    /// sorting by it put a habit added this afternoon in a position decided by
    /// random hex. Creation order is what a person means by "the order my
    /// habits are in", and it is also what makes a habit added today appear
    /// **below** the ones already there rather than jumping the queue.
    ///
    /// A minimum over a set is commutative, associative and idempotent, so this
    /// is order-independent exactly like the registers above, and it is per
    /// habit — `.claude/skills/architecture.md`'s "no global accumulators in the
    /// fold" is untouched.
    var createdOrder: EventOrder?

    init(id: HabitID) {
        self.id = id
        self.name = ""
        self.isArchived = false
        self.checkedDays = []
        self.createdOn = nil
        self.nameOrder = nil
        self.archiveOrder = nil
        self.cellOrder = [:]
        self.createdOrder = nil
        self.archivalDays = [:]
    }

    /// Rehydrates one row from the launch cache. See
    /// ``Projection/restored(from:)`` for what such a value does and does not
    /// describe.
    ///
    /// It is here rather than beside the snapshot because the properties above
    /// are `private(set)` and this file is what that word means. Every
    /// last-writer-wins register is deliberately left unset: an `EventOrder`
    /// invented for a cache would be a claim about a write that never happened.
    init(
        restoring id: HabitID,
        name: String,
        isArchived: Bool,
        checkedDays: Set<Day>,
        createdOn: Day?
    ) {
        self.init(id: id)
        self.name = name
        self.isArchived = isArchived
        self.checkedDays = checkedDays
        self.createdOn = createdOn
    }

    public func isChecked(on day: Day) -> Bool {
        checkedDays.contains(day)
    }

    public func status(on day: Day) -> DayStatus {
        isChecked(on: day) ? .done : .missed
    }

    /// Whether this habit was being tracked on `day` — whether it had a row on
    /// the screen that day, and therefore whether that day's dot is entitled to
    /// ask about it.
    ///
    /// **Tracking runs from the day the habit was created up to, but not
    /// including, the day it was archived** — `[createdOn, archivedOn)`, with an
    /// unarchive re-opening the interval from the day it happened. Three
    /// consequences, all of them the point:
    ///
    /// - A day before the habit existed is not judged against it. Creating a
    ///   habit cannot turn yesterday's dot off.
    /// - A day the habit was tracked through stays judged against it forever.
    ///   Archiving cannot turn a day the user missed into a day they made.
    /// - The one day an archive *does* change is the day it happens on, forward
    ///   from the moment of the tap — never a settled past day. That is also what
    ///   makes a mis-tapped Remove undoable in the record and not only in the
    ///   interface: create and archive on the same day leaves an empty interval
    ///   and no mark on the spine at all.
    public func isActive(on day: Day) -> Bool {
        if let createdOn, day < createdOn { return false }
        var latest: (day: Day, change: ArchivalChange)?
        for (transitionDay, change) in archivalDays where transitionDay <= day {
            if let current = latest, transitionDay < current.day { continue }
            // Two transitions on one day are already resolved into one entry by
            // `setArchived`, so a strictly-later day is the only tiebreak needed.
            latest = (transitionDay, change)
        }
        guard let latest else { return true }
        return !latest.change.isArchived
    }

    // MARK: Fold

    /// `true` when `order` beats whatever currently owns the register.
    private static func wins(_ order: EventOrder, over incumbent: EventOrder?) -> Bool {
        guard let incumbent else { return true }
        return incumbent < order
    }

    fileprivate mutating func setName(_ newName: String, at order: EventOrder) {
        guard HabitState.wins(order, over: nameOrder) else { return }
        name = newName
        nameOrder = order
    }

    /// Both registers, from one event. The flag answers "is there a row now"; the
    /// per-day entry answers "was there a row on `day`". They are written
    /// together and read apart.
    fileprivate mutating func setArchived(_ archived: Bool, on day: Day, at order: EventOrder) {
        if HabitState.wins(order, over: archiveOrder) {
            isArchived = archived
            archiveOrder = order
        }
        if HabitState.wins(order, over: archivalDays[day]?.order) {
            archivalDays[day] = ArchivalChange(isArchived: archived, order: order)
        }
    }

    fileprivate mutating func setChecked(_ checked: Bool, on day: Day, at order: EventOrder) {
        guard HabitState.wins(order, over: cellOrder[day]) else { return }
        cellOrder[day] = order
        if checked {
            checkedDays.insert(day)
        } else {
            checkedDays.remove(day)
        }
    }

    /// Absorbs another view of the same habit — the shard-merge path.
    ///
    /// It is here rather than in ``Projection/merge(_:)`` because every register
    /// it touches belongs to this type, and two of them (the current archive flag
    /// and the per-day timeline) must be merged from the register that carries
    /// them rather than from each other: a shard that saw only an unarchive must
    /// not be able to erase a day another shard recorded an archive on.
    fileprivate mutating func absorb(_ incoming: HabitState) {
        if let order = incoming.nameOrder {
            setName(incoming.name, at: order)
        }
        if let order = incoming.createdOrder {
            noteCreated(on: incoming.createdOn, at: order)
        }
        if let order = incoming.archiveOrder, HabitState.wins(order, over: archiveOrder) {
            isArchived = incoming.isArchived
            archiveOrder = order
        }
        for (day, change) in incoming.archivalDays
        where HabitState.wins(change.order, over: archivalDays[day]?.order) {
            archivalDays[day] = change
        }
        for (day, order) in incoming.cellOrder {
            setChecked(incoming.checkedDays.contains(day), on: day, at: order)
        }
    }

    /// First writer wins, and the day comes with it. See ``createdOrder`` and
    /// ``createdOn`` — they are one register with two halves, because "when was
    /// this habit created" has one answer and a later duplicate is not it.
    fileprivate mutating func noteCreated(on day: Day?, at order: EventOrder) {
        guard let incumbent = createdOrder else {
            createdOrder = order
            createdOn = day
            return
        }
        if order < incumbent {
            createdOrder = order
            createdOn = day
        }
    }

    /// Creation order, then the ``HabitID`` as a deterministic tiebreak. A habit
    /// that has only ever been checked into — no `habitCreated` anywhere in the
    /// log — sorts last, because there is no honest place to put it.
    static func byCreation(_ lhs: HabitState, _ rhs: HabitState) -> Bool {
        switch (lhs.createdOrder, rhs.createdOrder) {
        case let (left?, right?):
            return left == right ? lhs.id < rhs.id : left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.id < rhs.id
        }
    }
}

/// The fold of the event log. `docs/technical.md` §3.
///
/// Pure and total: no clock, no `Calendar.current`, no `TimeZone.current`, no
/// locale, no I/O, no floating point. Applying events is commutative and
/// idempotent, so an incremental apply equals a from-zero rebuild, a permuted
/// arrival order produces an identical projection, and folding per-habit shards
/// and merging equals folding the whole log.
public struct Projection: Hashable, Sendable {

    /// **A hard cap, not a default.** `docs/product.md`: "the one-handed
    /// bottom-anchored layout stops holding past four rows, at which point the
    /// three-second promise quietly becomes false."
    ///
    /// It counts **active** habits. An archived habit is still in the log, still
    /// in this projection and still carrying every day it recorded, and it does
    /// not occupy a slot — the cap is about how many rows a thumb can reach, and
    /// an archived habit has no row.
    ///
    /// The number lives here, beside the fold that can answer how many there
    /// are, and `CompassUI`'s layout budget reads it from here. Two constants
    /// would be two things that can disagree, and the one that is wrong would be
    /// the one nobody is looking at.
    public static let habitCap = 4

    public private(set) var habits: [HabitID: HabitState]

    public init() {
        self.habits = [:]
    }

    // MARK: Reading

    public func habit(_ id: HabitID) -> HabitState? { habits[id] }

    public func isChecked(_ id: HabitID, on day: Day) -> Bool {
        habits[id]?.isChecked(on: day) ?? false
    }

    public func status(_ id: HabitID, on day: Day) -> DayStatus {
        habits[id]?.status(on: day) ?? .missed
    }

    /// The habits with rows on Today, oldest first. See ``HabitState/createdOrder``.
    public var activeHabits: [HabitState] {
        habits.values.filter { !$0.isArchived }.sorted(by: HabitState.byCreation)
    }

    /// The habits that were being tracked on `day`, oldest first — the set that
    /// day is entitled to be judged against.
    ///
    /// **This is not ``activeHabits`` evaluated for another day, and the
    /// difference is the whole of it.** `activeHabits` is today's set; folding a
    /// history over it makes every past day a function of the current settings,
    /// so creating a habit turns every earlier dot off and archiving one fills
    /// dots that were never earned. `habitCreated`, `habitArchived` and
    /// `habitUnarchived` all carry the day they happened on, so the set is a fact
    /// about the log rather than a setting — see ``HabitState/isActive(on:)``.
    public func habitsActive(on day: Day) -> [HabitState] {
        habits.values.filter { $0.isActive(on: day) }.sorted(by: HabitState.byCreation)
    }

    /// The habits that have been removed from Today, oldest first.
    ///
    /// **Removing a habit archives it; it never deletes it.** A habit dropped
    /// after sixty days keeps those sixty days here, in the projection and in
    /// the log, which is the whole premise of an append-only record.
    public var archivedHabits: [HabitState] {
        habits.values.filter(\.isArchived).sorted(by: HabitState.byCreation)
    }

    /// Whether another habit may be created. ``habitCap`` on the **active**
    /// ones; archived habits do not count.
    public var mayCreateHabit: Bool {
        habits.values.lazy.filter { !$0.isArchived }.count < Projection.habitCap
    }

    /// The largest number on the screen: **how many distinct civil days anything
    /// was recorded on.** `docs/product.md` and `.claude/skills/ui.md` both call
    /// it "total days", and the caption under it reads "N days recorded since
    /// <date>", so it has to be a count of days.
    ///
    /// It used to be `checkedDays.count` summed across habits, which is a count
    /// of habit-days: four habits done this morning displayed "4 days recorded"
    /// on the first day of use. Nothing on the screen was a lie about a habit —
    /// the sum was correct — but the sentence the screen says was false, and the
    /// sentence is what a person reads.
    ///
    /// **A day counts when anything was recorded on it, not when everything
    /// was.** The word on screen is "recorded", not "completed"; a day with one
    /// of four habits done is a day the user opened the app and recorded
    /// something, and calling it zero would be the same class of error in the
    /// other direction. Every-habit completion is what the 28-dot spine already
    /// means, and it is deliberate that the two say different things: the number
    /// cannot reset and cannot be gamed, and the spine is honest about gaps.
    ///
    /// Computed from the per-habit shards on read, never accumulated in the fold
    /// — see ``HabitState``.
    public var daysRecorded: Int {
        var days: Set<Day> = []
        for habit in habits.values {
            days.formUnion(habit.checkedDays)
        }
        return days.count
    }

    /// The earliest day any habit was checked in on, or `nil` when nothing has
    /// been recorded yet.
    ///
    /// The screen says "128 days recorded since 5 December 2025", and this is
    /// the second half of that sentence — a fact that cannot reset, cannot be
    /// gamed, and implies no target, which is why the design put it under the
    /// number in place of the bare word "days".
    ///
    /// Computed from the per-habit shards on read, exactly like
    /// ``daysRecorded``, and never accumulated in the fold. A minimum kept
    /// as a global accumulator would be order-dependent under revocation, which
    /// is the class of bug the shard-invariance test in `docs/technical.md`
    /// §9.3 exists to forbid.
    public var firstCheckedDay: Day? {
        habits.values.compactMap { $0.checkedDays.min() }.min()
    }

    // MARK: Folding

    /// Applies one event. Called synchronously on the tap path, before the
    /// haptic and before the journal write. `docs/technical.md` §4.
    public mutating func apply(_ event: Event) {
        switch event.kind {
        case .habitCreated, .habitRenamed:
            guard let id = event.payload.habitID else { return }
            var habit = habits[id] ?? HabitState(id: id)
            if let name = event.payload.name {
                habit.setName(name, at: event.order)
            }
            // Only a creation establishes creation order. A rename is cosmetic
            // and must not move a habit's row.
            if event.kind == .habitCreated {
                habit.noteCreated(on: event.day, at: event.order)
            }
            habits[id] = habit

        case .habitArchived, .habitUnarchived:
            guard let id = event.payload.habitID else { return }
            var habit = habits[id] ?? HabitState(id: id)
            habit.setArchived(event.kind == .habitArchived, on: event.day, at: event.order)
            habits[id] = habit

        case .checkedIn, .checkInRevoked:
            guard let id = event.payload.habitID else { return }
            var habit = habits[id] ?? HabitState(id: id)
            habit.setChecked(event.kind == .checkedIn, on: event.day, at: event.order)
            habits[id] = habit

        default:
            // `achievementAwarded` and `achievementRevoked` carry no habit state;
            // the award record lives in `awards.jsonl` and is projected by the
            // achievement engine. An unknown kind from a newer build is ignored
            // here and preserved on disk — never dropped.
            return
        }
    }

    /// Merges another projection into this one. Used to recombine per-habit
    /// shards; the result equals folding the whole log.
    public mutating func merge(_ other: Projection) {
        for (id, incoming) in other.habits {
            guard var mine = habits[id] else {
                habits[id] = incoming
                continue
            }
            mine.absorb(incoming)
            habits[id] = mine
        }
    }

    public func merging(_ other: Projection) -> Projection {
        var copy = self
        copy.merge(other)
        return copy
    }

    /// Puts one rehydrated row in place. See ``restored(from:)``; ``habits`` is
    /// `private(set)` and this file is what that word means.
    mutating func restore(_ habit: HabitState) {
        habits[habit.id] = habit
    }
}

/// Folds a list of events into state. Pure and total.
/// `docs/technical.md` §3.
public func project(_ events: [Event]) -> Projection {
    var projection = Projection()
    for event in events {
        projection.apply(event)
    }
    return projection
}

// MARK: - The declared subject

/// The optional, self-declared, **unverified** name of the person the record is
/// about — the fold of ``EventKind/subjectNamed``.
///
/// `docs/open-questions.md` records the gap this closes: the certificate proves
/// that *a device* recorded a hundred consecutive days, and says nothing about
/// whose. Option (b) was chosen on 2026-07-31 — a name the user types, with no
/// account, no sign-in, no server and nothing checking it.
///
/// **The claim is deliberately weak and must be stated weakly.** Nothing here
/// proves the name is true; `docs/product.md` bans the second party that would
/// be needed to. What it proves is that the name was committed to at the time,
/// because the declaration is an event in the log and
/// `docs/achievement-protocol.md` §4's `witness.logHeads` commits to the whole
/// history as of detection. Restating it afterwards breaks that seal. Any copy
/// the app renders about this must say that and not more.
///
/// ### Why this is not part of ``Projection``
///
/// It is not a habit-scoped fact, and `Projection` is habits: every accumulator
/// in it is keyed by `habitID`, which is what
/// `.claude/skills/architecture.md` requires and what the shard-invariance test
/// in `docs/technical.md` §9.3 mechanically enforces. A log-scoped register
/// inside that type would be the one field the shard partition does not
/// describe. A second, tiny, separate fold costs one line at each of the three
/// call sites and leaves both rules literally true.
///
/// Last writer wins under the same total order as everything else — never
/// wall-clock.
public struct SubjectName: Hashable, Sendable {

    /// The declared name, or `""` when none has been declared or the
    /// declaration has been withdrawn. Never `nil`: "no name" and "the empty
    /// name" are the same state, and having two of them would mean the settings
    /// field and the certificate could disagree about which one they are in.
    public private(set) var value: String

    /// The order of the event that currently owns ``value``.
    private var order: EventOrder?

    public init() {
        self.value = ""
        self.order = nil
    }

    /// Applies one event. Every kind but ``EventKind/subjectNamed`` is ignored,
    /// including kinds this build has never heard of.
    public mutating func apply(_ event: Event) {
        guard event.kind == .subjectNamed, let name = event.payload.name else { return }
        if let order, !(order < event.order) { return }
        value = name
        order = event.order
    }

    /// Rehydrates the declared name from the launch cache, leaving the register
    /// unset so the first real declaration to arrive wins. See
    /// ``Projection/restored(from:)``; ``value`` is `private(set)` and this file
    /// is what that word means.
    mutating func restore(_ declared: String) {
        value = declared
    }
}

/// Folds a list of events into the declared subject. Pure and total.
public func declaredSubject(_ events: [Event]) -> SubjectName {
    var subject = SubjectName()
    for event in events {
        subject.apply(event)
    }
    return subject
}
