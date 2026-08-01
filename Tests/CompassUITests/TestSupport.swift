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

/// The path an unreadable `awards.jsonl` reports, in the shape the simulator
/// actually produces: a home directory, a CoreSimulator device UUID and an App
/// Group UUID. Every one of them was on screen in the Records footer until
/// 2026-08-01.
let unreadableAwardsPath =
    "/Users/someone/Library/Developer/CoreSimulator/Devices"
    + "/4D361587-08AE-4292-81F8-3DCA61DD5226/data/Containers/Shared"
    + "/AppGroup/64541B32-7B21-4256-844C-7E1EB82D2F45/Compass/awards.jsonl"

/// The error a real failure produces — `NSCocoaErrorDomain` 257, the one
/// `Data(contentsOf:)` throws on a file it may not read.
///
/// Built rather than provoked so it is the same on every machine, and built with
/// its `userInfo` populated because **that is where the path lives**: interpolate
/// this value and the whole of ``unreadableAwardsPath`` comes with it. A fixture
/// without it would let `awardFailure = "\(error)"` pass.
///
/// A function rather than a global `let`, because `NSError` is a reference type
/// and a shared mutable global is not what a fixture should be.
func cocoaReadFailure(path: String = unreadableAwardsPath) -> NSError {
    NSError(
        domain: NSCocoaErrorDomain,
        code: 257,
        userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey:
                "The file “awards.jsonl” couldn’t be opened because you don’t "
                + "have permission to view it.",
        ]
    )
}

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

/// The achievement engine, faked. `TodayModel` holds it as a port and can see
/// nothing else about it: what it awarded, and what is on record.
///
/// It counts passes, because the two behaviours worth pinning are both about how
/// often the engine runs — line 5 of the tap path dispatches one, and `reconcile`
/// runs one after the replay lands.
final class FakeAwarding: Awarding {

    struct Failure: Error {}

    private struct State {
        var book: AwardBook
        var passes = 0
        var fails = false
        var error: (any Error)?
    }

    private let state: Mutex<State>

    init(book: AwardBook = .empty, fails: Bool = false) {
        state = Mutex(State(book: book, fails: fails))
    }

    /// Fails with a **specific** error, rather than with the bare marker above.
    ///
    /// It exists because one property of `TodayModel.awardFailure` cannot be
    /// tested with an error that carries nothing: whether what the failure says
    /// on screen is the error's own text. `Failure()` has no message and no path,
    /// so it would pass either way — the failure mode this whole helper is here
    /// to avoid. `CertificateModelTests.aFailureNeverCarriesTheErrorsOwnText`
    /// hands it a real `NSCocoaErrorDomain` read failure with a real path in it.
    convenience init(failingWith error: any Error) {
        self.init(fails: true)
        state.withLock { $0.error = error }
    }

    var passes: Int { state.withLock { $0.passes } }

    /// Replaces what the next pass will return — a milestone falling out of the
    /// log while the app is open.
    func issue(_ book: AwardBook) {
        state.withLock { $0.book = book }
    }

    /// Stops failing and answers with `book` from the next pass onwards — the
    /// transient failure the engine's idempotence is supposed to absorb. It is
    /// what makes "a later successful pass clears the failure" something a test
    /// can drive rather than something a comment asserts.
    func succeed(with book: AwardBook) {
        state.withLock {
            $0.fails = false
            $0.book = book
        }
    }

    func evaluate() async throws -> AwardBook {
        try state.withLock { state in
            state.passes += 1
            guard !state.fails else { throw state.error ?? Failure() }
            return state.book
        }
    }

    func recorded() async throws -> AwardBook {
        try state.withLock { state in
            guard !state.fails else { throw state.error ?? Failure() }
            return AwardBook(
                achievements: state.book.achievements,
                revoked: state.book.revoked,
                attestations: state.book.attestations
            )
        }
    }
}

/// An achievement with everything but the fields under test defaulted.
func award(
    _ ruleID: String = "streak.habit-a.100",
    kind: RuleKind = .streak,
    habit: HabitID? = habitA,
    threshold: Int = 100,
    earnedOn: String = "2026-03-14",
    detectedAt: String = "2026-03-14T12:00:00+07:00",
    evidenceRoot: UInt8 = 0x8F
) -> Achievement {
    let rule = RuleSpec(
        id: RuleID(rawValue: ruleID), kind: kind, scope: Scope(habit: habit),
        threshold: threshold
    )
    var facts: [FactKey: JSONValue] = [
        kind == .streak ? .streak : .total: .int(threshold),
        .from: .string("2025-12-05"),
        .sourceLive: .int(threshold),
        .sourceBackfill: .int(0),
    ]
    if let habit { facts[.habitID] = .string(habit.rawValue) }

    return Achievement(
        id: AchievementID(rule: rule.id, earnedOn: day(earnedOn)),
        rule: rule,
        earnedOn: day(earnedOn),
        detectedAt: instant(detectedAt),
        facts: facts,
        witness: Witness(
            firstDay: day("2025-12-05"), lastDay: day(earnedOn), dayCount: threshold,
            evidenceRoot: Data(repeating: evidenceRoot, count: 32), logHeads: [:]
        )
    )
}

/// The week-4 anchoring pass, faked. `TodayModel` holds it as a port and can see
/// nothing else about it.
///
/// It counts drains, because the behaviour worth pinning is that the drain
/// happens at all: `.claude/skills/ios.md` requires the queue to be drained on
/// **two** paths, and the launch drain is the only one of the two that a test
/// can observe — a `BGProcessingTask` fires when the system feels like it.
final class FakeAnchoring: Anchoring {

    struct Failure: Error {}

    private struct State {
        var attestations: [AchievementID: Attestation]
        var drains = 0
        var fails: Bool
    }

    private let state: Mutex<State>

    init(attestations: [AchievementID: Attestation] = [:], fails: Bool = false) {
        state = Mutex(State(attestations: attestations, fails: fails))
    }

    var drains: Int { state.withLock { $0.drains } }

    /// What the next drain will report — a calendar answering while the app is
    /// open.
    func confirm(_ attestations: [AchievementID: Attestation]) {
        state.withLock { $0.attestations = attestations }
    }

    func drain() async throws -> AnchorDrain {
        try state.withLock { state in
            state.drains += 1
            guard !state.fails else { throw Failure() }
            return AnchorDrain(
                attestations: state.attestations,
                confirmed: state.attestations
                    .filter { $0.value.state == .confirmed }
                    .keys.sorted()
            )
        }
    }
}

/// An attestation with everything but the fields under test defaulted. The
/// signature and key are placeholders: nothing on the certificate renders them,
/// and what the certificate says about anchoring depends only on `state`.
func attestation(
    for id: AchievementID,
    state: AnchorState = .sealed,
    confirmedAt: String? = nil,
    submittedAt: String? = nil
) -> Attestation {
    Attestation(
        achievement: id,
        publicKey: Data(repeating: 0x04, count: 65),
        signature: Data(repeating: 0x5E, count: 64),
        backing: .secureEnclave,
        state: state,
        submittedAt: submittedAt.map(instant),
        confirmedAt: confirmedAt.map(instant)
    )
}

/// The export port, answering from a value. It records how many bundles were
/// asked for, because the control must build one per press and not one per
/// render.
final class FakeExporting: Exporting {

    struct Failure: Error, CustomStringConvertible {
        var description: String { "the store went away" }
    }

    private struct State {
        var bundle: ExportBundle
        var calls = 0
        var fails: Bool
    }

    private let state: Mutex<State>

    init(bundle: ExportBundle = ExportBundle(files: [:], exportedAt: .distantPast), fails: Bool = false) {
        state = Mutex(State(bundle: bundle, fails: fails))
    }

    var calls: Int { state.withLock { $0.calls } }

    func exportBundle() async throws -> ExportBundle {
        try state.withLock { state in
            state.calls += 1
            guard !state.fails else { throw Failure() }
            return state.bundle
        }
    }
}

/// A bundle with the shape a real one has — a nested member under `rules/`, a
/// manifest, and bytes that differ per file so a wrapper that mixed two up
/// would be visible.
func sampleBundle(at iso: String = "2026-08-01T09:00:00+07:00") -> ExportBundle {
    ExportBundle(
        files: [
            "events.jsonl": Data("{\"v\":1}\n".utf8),
            "awards.jsonl": Data("{\"id\":\"total.recorded.100@2026-01-01\"}\n".utf8),
            "rules/totals.json": Data("[]".utf8),
            "proofs/total.recorded.100@2026-01-01.ots": Data([0x00, 0x4F, 0x54, 0x53]),
            "manifest.json": Data("{\"exportedAt\":0,\"files\":{}}".utf8),
        ],
        exportedAt: instant(iso)
    )
}
