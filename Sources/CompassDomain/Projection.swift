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

    public private(set) var isArchived: Bool

    /// The days currently checked in. A revoked day is absent, not marked.
    public private(set) var checkedDays: Set<Day>

    /// Last-writer-wins registers, one per independently-settable value. Each
    /// holds the ``EventOrder`` of the event that currently owns it, so applying
    /// the same set of events in any order converges on the same state.
    var nameOrder: EventOrder?
    var archiveOrder: EventOrder?
    var cellOrder: [Day: EventOrder]

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
        self.nameOrder = nil
        self.archiveOrder = nil
        self.cellOrder = [:]
        self.createdOrder = nil
    }

    public func isChecked(on day: Day) -> Bool {
        checkedDays.contains(day)
    }

    public func status(on day: Day) -> DayStatus {
        isChecked(on: day) ? .done : .missed
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

    fileprivate mutating func setArchived(_ archived: Bool, at order: EventOrder) {
        guard HabitState.wins(order, over: archiveOrder) else { return }
        isArchived = archived
        archiveOrder = order
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

    /// First writer wins. See ``createdOrder``.
    fileprivate mutating func noteCreated(at order: EventOrder) {
        guard let incumbent = createdOrder else {
            createdOrder = order
            return
        }
        if order < incumbent { createdOrder = order }
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

    /// The largest number on the screen. Computed from the per-habit shards on
    /// read, never accumulated in the fold — see ``HabitState``.
    public var totalCheckedDays: Int {
        habits.values.reduce(0) { $0 + $1.checkedDays.count }
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
    /// ``totalCheckedDays``, and never accumulated in the fold. A minimum kept
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
                habit.noteCreated(at: event.order)
            }
            habits[id] = habit

        case .habitArchived, .habitUnarchived:
            guard let id = event.payload.habitID else { return }
            var habit = habits[id] ?? HabitState(id: id)
            habit.setArchived(event.kind == .habitArchived, at: event.order)
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
            if let order = incoming.nameOrder {
                mine.setName(incoming.name, at: order)
            }
            if let order = incoming.archiveOrder {
                mine.setArchived(incoming.isArchived, at: order)
            }
            if let order = incoming.createdOrder {
                mine.noteCreated(at: order)
            }
            for (day, order) in incoming.cellOrder {
                mine.setChecked(incoming.checkedDays.contains(day), on: day, at: order)
            }
            habits[id] = mine
        }
    }

    public func merging(_ other: Projection) -> Projection {
        var copy = self
        copy.merge(other)
        return copy
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
}

/// Folds a list of events into the declared subject. Pure and total.
public func declaredSubject(_ events: [Event]) -> SubjectName {
    var subject = SubjectName()
    for event in events {
        subject.apply(event)
    }
    return subject
}
