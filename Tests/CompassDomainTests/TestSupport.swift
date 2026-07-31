import Foundation
import Testing

@testable import CompassDomain

// Shared fixtures. Pure, deterministic, no clock, no randomness that is not
// seeded, no I/O. `.claude/skills/testing.md`.

/// A `Day` from an ISO literal. Traps on a malformed literal, which is a test
/// authoring error rather than a runtime condition.
func day(_ iso: String) -> Day {
    guard let day = Day(iso: iso) else {
        fatalError("test fixture is not an ISO civil date: \(iso)")
    }
    return day
}

let habitA = HabitID(rawValue: "habit-a")
let habitB = HabitID(rawValue: "habit-b")

/// Two writers on one phone: the app process and the widget process.
/// `docs/technical.md` §4.
let deviceApp = DeviceID(rawValue: "11111111-1111-4111-8111-111111111111")
let deviceWidget = DeviceID(rawValue: "22222222-2222-4222-8222-222222222222")

/// Builds an event with everything except the fields under test defaulted.
///
/// `recordedAt` defaults to a value that *disagrees* with `lamport` ordering, so
/// any fold that reaches for wall-clock time fails rather than passing by
/// coincidence.
func event(
    _ kind: EventKind,
    habit: HabitID? = nil,
    on day: Day = day("2026-07-31"),
    lamport: Int,
    device: DeviceID = deviceApp,
    recordedAt: Int? = nil,
    source: CheckInSource? = nil,
    name: String? = nil,
    payload: EventPayload? = nil,
    prev: Data = Event.genesisPrev,
    extra: [String: JSONValue] = [:]
) -> Event {
    let resolvedPayload: EventPayload
    if let payload {
        resolvedPayload = payload
    } else if let habit {
        resolvedPayload = EventPayload(habitID: habit, name: name)
    } else {
        resolvedPayload = .empty
    }

    return Event(
        id: uuid(lamport: lamport, device: device),
        device: device,
        lamport: lamport,
        kind: kind,
        day: day,
        // Descending in lamport: later events look older by the wall clock.
        recordedAt: recordedAt ?? (2_000_000_000_000 - lamport * 86_400_000),
        zoneOffset: 420,  // Surabaya, UTC+7
        source: source,
        payload: resolvedPayload,
        prev: prev,
        extra: extra
    )
}

/// A stable UUID per `(lamport, device)`, so a fixture is byte-identical on
/// every run.
func uuid(lamport: Int, device: DeviceID) -> UUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    let tag = Array(device.rawValue.utf8.prefix(4))
    for (index, byte) in tag.enumerated() { bytes[index] = byte }
    withUnsafeBytes(of: UInt64(bitPattern: Int64(lamport)).bigEndian) { raw in
        for (index, byte) in raw.enumerated() { bytes[8 + index] = byte }
    }
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

/// A deterministic, order-independent serialisation of a projection, so
/// "byte-identical serialised state" means something. Swift's `Dictionary`
/// iteration order is not stable, so sorting here is the point, not decoration.
func serialise(_ projection: Projection) -> String {
    var lines: [String] = []
    for id in projection.habits.keys.sorted() {
        guard let habit = projection.habits[id] else { continue }
        let days = habit.checkedDays.map(\.iso).sorted().joined(separator: ",")
        lines.append(
            "\(id.rawValue)|name=\(habit.name)|archived=\(habit.isArchived)|days=[\(days)]"
        )
    }
    return lines.joined(separator: "\n")
}

/// A seeded permutation, so a shuffle test is reproducible rather than flaky.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// A canonical mixed corpus: two habits, two writers, creations, renames,
/// archival, check-ins, revocations, a re-check, two achievement events that the
/// v1 fold must ignore, and two `subjectNamed` declarations it must ignore for
/// the same reason.
///
/// The declarations are in here rather than only in their own suite so that
/// every determinism test — shard invariance, shuffle invariance, incremental
/// equals full replay, idempotence — runs over a log that contains a kind
/// `Projection` does not fold. That is the additive claim, exercised rather than
/// asserted.
func corpus() -> [Event] {
    var events: [Event] = []
    var lamport = 0
    func next() -> Int { lamport += 1; return lamport }

    events.append(event(.habitCreated, habit: habitA, lamport: next(), name: "Meditate"))
    events.append(event(.habitCreated, habit: habitB, lamport: next(), name: "Read"))

    for offset in 0..<12 {
        let d = day("2026-07-01").adding(offset)
        events.append(
            event(.checkedIn, habit: habitA, on: d, lamport: next(), source: .tap)
        )
        if offset % 2 == 0 {
            events.append(
                event(
                    .checkedIn, habit: habitB, on: d, lamport: next(),
                    device: deviceWidget, source: .widget
                )
            )
        }
    }

    // A revoked day, and a day revoked then checked in again.
    events.append(
        event(.checkInRevoked, habit: habitA, on: day("2026-07-05"), lamport: next())
    )
    events.append(
        event(.checkInRevoked, habit: habitB, on: day("2026-07-03"), lamport: next(),
              device: deviceWidget)
    )
    events.append(
        event(.checkedIn, habit: habitB, on: day("2026-07-03"), lamport: next(),
              device: deviceWidget, source: .tap)
    )

    events.append(event(.habitRenamed, habit: habitB, lamport: next(), name: "Read a book"))
    events.append(event(.habitArchived, habit: habitB, on: day("2026-07-20"), lamport: next()))
    events.append(event(.habitUnarchived, habit: habitB, on: day("2026-07-21"), lamport: next()))

    events.append(
        event(
            .achievementAwarded, lamport: next(),
            payload: .achievement(AchievementID(rawValue: "streak.habit-a.7@2026-07-07"))
        )
    )
    events.append(
        event(
            .achievementRevoked, lamport: next(),
            payload: .achievement(
                AchievementID(rawValue: "streak.habit-a.7@2026-07-07"),
                reason: "a day it depended on was edited"
            )
        )
    )

    events.append(event(.subjectNamed, lamport: next(), payload: .subject(named: "Farros")))
    events.append(
        event(.subjectNamed, lamport: next(), payload: .subject(named: "Farros Hilmi Syafei"))
    )

    return events
}
