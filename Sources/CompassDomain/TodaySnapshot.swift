import Foundation

/// The disposable launch cache. `docs/technical.md` §4 and §6.
///
/// > A small `TodaySnapshot` (habit names, today's booleans, the totals) is
/// > written on every change and read **synchronously** in `TodayModel.init`.
/// > The full log replays in a `.task` immediately afterwards and reconciles. If
/// > the snapshot and the replay disagree, **the replay wins** and the snapshot
/// > is rewritten.
///
/// It exists because a full rebuild is not free: `docs/technical.md` §6 measures
/// 193 ms at five years × five habits and 865 ms at ten × ten, and §4 requires
/// the first frame to render correct data with **zero awaits**. Reading a
/// two-kilobyte cache synchronously satisfies both; reading a two-megabyte log
/// synchronously satisfies only the second.
///
/// **It is never the source of anything.** `docs/technical.md` §6 puts it in the
/// disposable tier: delete it freely, and the replay that lands a moment later
/// overwrites whatever it said. Nothing is ever recovered from here that is not
/// also in the log — in particular **no `lamport` and no chain head**, because a
/// stale cache handing a writer a `lamport` it has already used would fork that
/// writer's chain, and a disposable file must never be able to do that.
///
/// ### Why the spine is in here
///
/// §4's parenthesis lists "habit names, today's booleans, the totals". The
/// 28-dot spine is not in that list and is in it here, because the alternative
/// is a first frame that renders an empty strip and fills it a moment later —
/// a visible flash on the one screen the whole project is about. Twenty-eight
/// booleans is not what makes a cache expensive.
public struct TodaySnapshot: Codable, Hashable, Sendable {

    /// How many days the strip covers.
    ///
    /// It lives here rather than beside the graphic that draws it because the
    /// cache carries the strip and is written by `CompassInfrastructure`, which
    /// cannot import `CompassUI`. Same argument as ``Projection/habitCap``: two
    /// constants would be two things that can disagree, and the one that is
    /// wrong is the one nobody is looking at. `CompassUI`'s `TodayMetrics` reads
    /// it from here and stays the only place the layout asks the question.
    public static let spineLength = 28

    /// One row, as of ``day``.
    public struct Habit: Codable, Hashable, Sendable {
        public let id: HabitID
        public let name: String
        public let isArchived: Bool
        public let isChecked: Bool
        public let createdOn: Day?

        public init(
            id: HabitID, name: String, isArchived: Bool, isChecked: Bool, createdOn: Day?
        ) {
            self.id = id
            self.name = name
            self.isArchived = isArchived
            self.isChecked = isChecked
            self.createdOn = createdOn
        }
    }

    /// The civil day this snapshot describes, with the 04:00 boundary already
    /// applied. Everything day-relative in here is relative to it, which is what
    /// makes ``rolledForward(to:)`` a total function rather than a guess.
    public let day: Day

    /// Every habit, active and archived, in creation order.
    public let habits: [Habit]

    /// Distinct civil days anything was recorded on, as of ``day``.
    public let daysRecorded: Int

    /// Whether ``day`` itself is one of them.
    ///
    /// It is stored separately so that a check-in landing before the replay does
    /// can move ``daysRecorded`` **exactly** rather than approximately: today is
    /// the only day whose recorded-ness can change in that window, so subtracting
    /// this and adding what the live projection says gives the true count. A
    /// cache that could only be approximately right about the largest number on
    /// the screen would be worse than no cache.
    public let dayIsRecorded: Bool

    /// The earliest recorded day, or `nil` before anything is recorded.
    public let firstRecordedDay: Day?

    /// The dot strip, oldest first, with the **last** element being ``day``.
    public let spine: [Bool]

    /// The optional, self-declared, unverified name. `""` when none.
    public let declaredName: String

    public init(
        day: Day,
        habits: [Habit],
        daysRecorded: Int,
        dayIsRecorded: Bool,
        firstRecordedDay: Day?,
        spine: [Bool],
        declaredName: String
    ) {
        self.day = day
        self.habits = habits
        self.daysRecorded = daysRecorded
        self.dayIsRecorded = dayIsRecorded
        self.firstRecordedDay = firstRecordedDay
        self.spine = spine
        self.declaredName = declaredName
    }

    /// Folds a projection down to what one screen needs. Pure: no clock, no I/O.
    public init(
        projection: Projection, subject: SubjectName, today: Day, spineLength: Int
    ) {
        self.day = today
        self.habits = projection.habits.values
            .sorted(by: HabitState.byCreation)
            .map { habit in
                Habit(
                    id: habit.id,
                    name: habit.name,
                    isArchived: habit.isArchived,
                    isChecked: habit.isChecked(on: today),
                    createdOn: habit.createdOn
                )
            }
        self.daysRecorded = projection.daysRecorded
        self.dayIsRecorded = projection.isRecorded(on: today)
        self.firstRecordedDay = projection.firstCheckedDay
        self.spine = TodaySnapshot.spine(
            of: projection, endingOn: today, length: spineLength
        )
        self.declaredName = subject.value
    }

    /// The 28-dot strip: a dot is filled when **every habit that was being
    /// tracked on that day** was done that day.
    ///
    /// Each day is judged against the habits active on it, never against today's
    /// set — the past is not a function of the current settings. A day nothing
    /// was tracked on is a gap, not a completion.
    /// See ``HabitState/isActive(on:)``.
    public static func spine(
        of projection: Projection, endingOn today: Day, length: Int
    ) -> [Bool] {
        (0..<length).map { offset in
            let day = today.adding(offset - (length - 1))
            let tracked = projection.habitsActive(on: day)
            return !tracked.isEmpty && tracked.allSatisfy { $0.isChecked(on: day) }
        }
    }

    /// The same snapshot, described against a later day.
    ///
    /// The daily-driver case is the app being opened the morning after it was
    /// last written, so a cache that were only valid on the day it was written
    /// would be a cache that almost never hits. Everything needed to move it is
    /// already here: the strip slides by the number of days that passed and the
    /// vacated dots are gaps, today's booleans clear, and the totals do not
    /// move because no day between the two was recorded — if one had been, a
    /// write would have happened and the snapshot would have been rewritten.
    ///
    /// Returns `nil` when `day` is **earlier** than this snapshot's. A clock
    /// that moved backwards — an NTP correction, a manual change — is exactly
    /// the condition `docs/technical.md` §3 refuses to sort by, and the honest
    /// answer is to fall back to the log rather than to invent a past.
    public func rolledForward(to day: Day) -> TodaySnapshot? {
        let gap = day - self.day
        guard gap >= 0 else { return nil }
        guard gap > 0 else { return self }

        let rolled = (0..<spine.count).map { index -> Bool in
            let source = index + gap
            return source < spine.count ? spine[source] : false
        }

        return TodaySnapshot(
            day: day,
            habits: habits.map {
                Habit(
                    id: $0.id, name: $0.name, isArchived: $0.isArchived,
                    isChecked: false, createdOn: $0.createdOn
                )
            },
            daysRecorded: daysRecorded,
            dayIsRecorded: false,
            firstRecordedDay: firstRecordedDay,
            spine: rolled,
            declaredName: declaredName
        )
    }
}

extension Projection {

    /// Whether anything at all was recorded on `day`.
    ///
    /// "Recorded", not "completed" — the same word the screen uses. A day with
    /// one of four habits done is a day the user opened the app and recorded
    /// something. See ``daysRecorded``.
    public func isRecorded(on day: Day) -> Bool {
        habits.values.contains { $0.isChecked(on: day) }
    }

    /// Rehydrates a projection from the launch cache.
    ///
    /// **It describes `snapshot.day` and nothing else.** Only today's check-ins
    /// are in the cache, so `daysRecorded`, `firstCheckedDay` and any historical
    /// dot are *not* recoverable from the result and must be read from the
    /// snapshot's own fields until the replay lands. `TodayModel` does exactly
    /// that; nothing else should ask this value a question about the past.
    ///
    /// Every last-writer-wins register is left empty on purpose. An `EventOrder`
    /// invented here would be a claim about a write that never happened, and it
    /// could beat a real one — so instead the registers are unset, which makes
    /// the first real event of any kind win, which is the correct answer while a
    /// replay is in flight.
    public static func restored(from snapshot: TodaySnapshot) -> Projection {
        var projection = Projection()
        for habit in snapshot.habits {
            projection.restore(
                HabitState(
                    restoring: habit.id,
                    name: habit.name,
                    isArchived: habit.isArchived,
                    checkedDays: habit.isChecked ? [snapshot.day] : [],
                    createdOn: habit.createdOn
                )
            )
        }
        return projection
    }
}

extension SubjectName {

    /// Rehydrates the declared name from the launch cache. Same standing as
    /// ``Projection/restored(from:)``: no register, so the first real
    /// declaration to arrive wins.
    public init(restoring value: String) {
        self.init()
        self.restore(value)
    }
}
