import CompassDomain
import Foundation
import Synchronization

// Fakes for the one screen's state. `TodayModel` holds ports and nothing else,
// so these three are the whole world it can see: what time it is, where a write
// goes, and what a replay returns.
//
// Time enters through a fake `Clock`, never `Date()`. `.claude/skills/testing.md`.

let habitA = HabitID(rawValue: "habit-a")
let habitB = HabitID(rawValue: "habit-b")
let writerApp = DeviceID(rawValue: "11111111-1111-4111-8111-111111111111")

/// Surabaya, UTC+7 — the single user's timezone. `docs/product.md`.
let surabayaOffsetSeconds = 7 * 3_600

func day(_ iso: String) -> Day {
    guard let day = Day(iso: iso) else {
        fatalError("test fixture is not an ISO civil date: \(iso)")
    }
    return day
}

func instant(_ iso8601: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: iso8601) else {
        fatalError("test fixture is not an ISO 8601 instant: \(iso8601)")
    }
    return date
}

/// A clock the test drives by hand: it hands out a scripted list of instants,
/// one per read, and repeats the last one forever after.
///
/// Scripted rather than frozen because the bug this suite exists to pin is a
/// *second* read of the day disagreeing with the first. A frozen clock cannot
/// express that, and a real clock cannot be asked to cross 04:00 on cue.
///
/// The 04:00 boundary is applied here the way `SystemClock` applies it — integer
/// arithmetic on a fixed UTC offset, no `Calendar` — because `CompassUI` cannot
/// import `CompassInfrastructure` and this suite does not test that arithmetic.
/// `SystemClockTests` pins the arithmetic; these tests pin `TodayModel`'s use of
/// the port. ``reads`` is what makes "one interaction, one day" assertable.
final class ScriptedClock: Clock {

    private struct State {
        var instants: [Date]
        var reads: Int
    }

    private let state: Mutex<State>

    init(_ iso8601: String...) {
        precondition(!iso8601.isEmpty, "a scripted clock needs at least one instant")
        state = Mutex(State(instants: iso8601.map(instant), reads: 0))
    }

    /// How many times the day has been read. One interaction should read it once.
    var reads: Int { state.withLock { $0.reads } }

    func now() -> Date {
        state.withLock { state in
            defer { state.reads += 1 }
            let index = min(state.reads, state.instants.count - 1)
            return state.instants[index]
        }
    }

    func today(cutoffHour: Int) -> Day {
        ScriptedClock.day(for: now(), cutoffHour: cutoffHour)
    }

    /// The civil day an instant belongs to, with the day starting at
    /// `cutoffHour` in UTC+7.
    static func day(for date: Date, cutoffHour: Int) -> Day {
        let local = Int(date.timeIntervalSince1970.rounded(.down)) + surabayaOffsetSeconds
        let shifted = local - cutoffHour * 3_600
        let days = shifted >= 0 ? shifted / 86_400 : (shifted - 86_399) / 86_400
        return Day(year: 1970, month: 1, day: 1).adding(days)
    }
}

/// A recorder that stamps like the journal does and keeps what it was given.
/// Set ``fails`` and it throws instead — the full-disk case, and the case where
/// the store was never opened at all.
final class FakeRecorder: EventRecorder {

    struct Failure: Error {}

    private struct State {
        var recorded: [Event] = []
        var nextLamport = 1
        var fails = false
    }

    private let state = Mutex(State())

    init(fails: Bool = false) {
        state.withLock { $0.fails = fails }
    }

    /// A recorder that resumes the sequence an existing log already used, the
    /// way the real journal does from its high-water mark.
    ///
    /// It matters for more than tidiness: `lamport` is what orders events, and
    /// since habit rows are ordered by the order of their creation, a recorder
    /// that restarted at 1 would make a habit added now sort *before* the ones
    /// already on screen — a fixture artefact that would hide the behaviour
    /// under test.
    init(continuing events: [Event], fails: Bool = false) {
        state.withLock {
            $0.fails = fails
            $0.nextLamport = (events.map(\.lamport).max() ?? 0) + 1
        }
    }

    var recorded: [Event] { state.withLock { $0.recorded } }
    var last: Event? { state.withLock { $0.recorded.last } }

    @discardableResult
    func record(
        kind: EventKind, day: Day, source: CheckInSource?, payload: EventPayload
    ) throws -> Event {
        try state.withLock { state in
            guard !state.fails else { throw Failure() }
            let event = Event(
                id: UUID(),
                device: writerApp,
                lamport: state.nextLamport,
                kind: kind,
                day: day,
                recordedAt: 1_784_000_000_000,
                zoneOffset: surabayaOffsetSeconds / 60,
                source: source,
                payload: payload
            )
            state.nextLamport += 1
            state.recorded.append(event)
            return event
        }
    }
}

/// A replay that returns a fixed log, or throws — the store that is not there.
///
/// With a ``ReplayGate`` it can also be held open, which is the only way to
/// observe what happens to an event recorded *while* a replay is in flight.
struct FakeSource: EventSource {

    struct Failure: Error {}

    var events: [Event] = []
    var fails = false
    var gate: ReplayGate?

    func replay() async throws -> [Event] {
        await gate?.enter()
        if fails { throw Failure() }
        return events
    }
}

/// A replay suspended on purpose.
///
/// `TodayModel.reconcile()` says the replay wins over whatever the first frame
/// rendered, "the one thing the replay cannot win over is an event appended
/// while it was in flight". Every fold the model keeps has to honour that, and a
/// fold added later is exactly the one that gets forgotten — so the window has
/// to be openable by a test rather than argued about.
@MainActor
final class ReplayGate {

    private var entered = false
    private var isOpen = false
    private var waitingForOpen: [CheckedContinuation<Void, Never>] = []
    private var waitingForEntry: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the replay: announces that it has started, then
    /// suspends until ``open()``.
    func enter() async {
        entered = true
        for waiter in waitingForEntry { waiter.resume() }
        waitingForEntry.removeAll()

        guard !isOpen else { return }
        await withCheckedContinuation { waitingForOpen.append($0) }
    }

    /// Returns once the replay is suspended inside ``enter()``.
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waitingForEntry.append($0) }
    }

    /// Lets the replay finish.
    func open() {
        isOpen = true
        for waiter in waitingForOpen { waiter.resume() }
        waitingForOpen.removeAll()
    }
}

/// A `habitCreated` for the seeded rows, so a model has something to tap.
///
/// `on` is the day the habit started being tracked, and it is not decoration: the
/// spine judges each day against the habits that had a row on it, so a fixture
/// that creates every habit on the same arbitrary day cannot express the case the
/// spine exists to get right.
func created(
    _ habit: HabitID, name: String, lamport: Int, on day: Day = day("2026-07-01")
) -> Event {
    Event(
        id: UUID(),
        device: writerApp,
        lamport: lamport,
        kind: .habitCreated,
        day: day,
        recordedAt: 1_784_000_000_000,
        zoneOffset: surabayaOffsetSeconds / 60,
        payload: .habit(habit, name: name)
    )
}

/// The bundle seed, as the composition root writes it: four habits at the cap,
/// in the order the owner chose them on 2026-07-31.
///
/// Written out here rather than imported from `AppComposition`, because
/// `CompassUITests` does not depend on `CompassInfrastructure` and should not —
/// what the sheet does with four habits is not a fact about the composition root.
func seededFour() -> [Event] {
    let names = ["Move", "Read", "Build", "Reflect"]
    return names.enumerated().map { index, name in
        created(HabitID(rawValue: "habit-\(index)"), name: name, lamport: index + 1)
    }
}

/// A `checkedIn`, for building a history a spine can be read off.
func checkedIn(_ habit: HabitID, on iso: String, lamport: Int) -> Event {
    Event(
        id: UUID(),
        device: writerApp,
        lamport: lamport,
        kind: .checkedIn,
        day: day(iso),
        recordedAt: 1_784_000_000_000,
        zoneOffset: surabayaOffsetSeconds / 60,
        source: .tap,
        payload: .habit(habit)
    )
}
