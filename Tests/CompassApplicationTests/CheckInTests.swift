import CompassApplication
import CompassDomain
import Foundation
import Testing

/// The tap-path decision. `docs/technical.md` §4.
@Suite("CheckIn — tap toggles, tap again untoggles")
struct CheckInTests {

    private let habit = HabitID(rawValue: "habit-a")
    private let today = Day(iso: "2026-07-31")!

    private func projection(_ events: [Event]) -> Projection {
        project(events)
    }

    private func event(_ kind: EventKind, on day: Day, lamport: Int) -> Event {
        Event(
            id: UUID(),
            device: DeviceID(rawValue: "11111111-1111-4111-8111-111111111111"),
            lamport: lamport,
            kind: kind,
            day: day,
            recordedAt: 1_784_000_000_000,
            zoneOffset: 420,
            source: kind == .checkedIn ? .tap : nil,
            payload: .habit(habit)
        )
    }

    @Test("an unchecked habit checks in")
    func firstTap() {
        #expect(CheckIn.kind(for: habit, on: today, in: Projection()) == .checkedIn)
    }

    @Test("a checked habit revokes rather than deletes")
    func secondTap() {
        let state = projection([event(.checkedIn, on: today, lamport: 1)])
        #expect(CheckIn.kind(for: habit, on: today, in: state) == .checkInRevoked)
    }

    @Test("a third tap checks in again")
    func thirdTap() {
        let state = projection([
            event(.checkedIn, on: today, lamport: 1),
            event(.checkInRevoked, on: today, lamport: 2),
        ])
        #expect(CheckIn.kind(for: habit, on: today, in: state) == .checkedIn)
    }

    @Test("yesterday's check-in does not decide today's tap")
    func perDay() {
        let state = projection([event(.checkedIn, on: today.adding(-1), lamport: 1)])
        #expect(CheckIn.kind(for: habit, on: today, in: state) == .checkedIn)
        #expect(CheckIn.kind(for: habit, on: today.adding(-1), in: state) == .checkInRevoked)
    }

    @Test("only a check-in carries a source")
    func sourceIsPresentOnlyOnCheckedIn() {
        // `docs/technical.md` §3: `checkedIn(habitID, day, source)` and
        // `checkInRevoked(habitID, day)`. `source` is inside the canonical form
        // and absent optionals are omitted entirely, so a source on a revocation
        // is an out-of-spec digested field, not a harmless extra.
        #expect(CheckIn.source(for: .checkedIn, from: .tap) == .tap)
        #expect(CheckIn.source(for: .checkInRevoked, from: .tap) == nil)
    }

    @Test("the source is the writer's own, not a constant")
    func sourceIsPerWriter() {
        // The app taps; the week-2 widget process asks the same question and
        // answers `.widget`.
        for origin in CheckInSource.allCases {
            #expect(CheckIn.source(for: .checkedIn, from: origin) == origin)
            #expect(CheckIn.source(for: .checkInRevoked, from: origin) == nil)
        }
    }

    @Test("no kind other than checkedIn ever carries a source")
    func everyOtherKindIsSourceless() {
        let others: [EventKind] = [
            .habitCreated, .habitRenamed, .habitArchived, .habitUnarchived,
            .checkInRevoked, .achievementAwarded, .achievementRevoked,
            EventKind(rawValue: "somethingANewerBuildWrote"),
        ]
        for kind in others {
            #expect(CheckIn.source(for: kind, from: .tap) == nil, "\(kind) must carry no source")
        }
    }

    @Test("the payload is the closed one-key structure")
    func payload() {
        let payload = CheckIn.payload(for: habit)
        #expect(payload.habitID == habit)
        #expect(payload.name == nil)
        #expect(payload.achievementID == nil)
        #expect(payload.reason == nil)
    }
}
