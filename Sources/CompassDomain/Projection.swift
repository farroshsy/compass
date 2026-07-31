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

    init(id: HabitID) {
        self.id = id
        self.name = ""
        self.isArchived = false
        self.checkedDays = []
        self.nameOrder = nil
        self.archiveOrder = nil
        self.cellOrder = [:]
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
}

/// The fold of the event log. `docs/technical.md` §3.
///
/// Pure and total: no clock, no `Calendar.current`, no `TimeZone.current`, no
/// locale, no I/O, no floating point. Applying events is commutative and
/// idempotent, so an incremental apply equals a from-zero rebuild, a permuted
/// arrival order produces an identical projection, and folding per-habit shards
/// and merging equals folding the whole log.
public struct Projection: Hashable, Sendable {
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

    public var activeHabits: [HabitState] {
        habits.values.filter { !$0.isArchived }.sorted { $0.id < $1.id }
    }

    /// The largest number on the screen. Computed from the per-habit shards on
    /// read, never accumulated in the fold — see ``HabitState``.
    public var totalCheckedDays: Int {
        habits.values.reduce(0) { $0 + $1.checkedDays.count }
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
