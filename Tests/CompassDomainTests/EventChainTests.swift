import Foundation
import Testing

@testable import CompassDomain

/// Per-writer `prev` chaining. `docs/technical.md` §3 and §4, ADR 0002.
///
/// The guarantee under test is the one the whole corpus rests on: **a sealed
/// record cannot be restated afterwards.** It is not "you cannot edit a file" —
/// anyone can edit a file. It is that editing one costs you every hash after it,
/// including the head an achievement's `witness.logHeads` committed to and the
/// digest that went to Bitcoin.
@Suite("The hash chain — per writer, never global")
struct EventChainTests {

    // MARK: The happy shape

    @Test("A freshly chained log verifies, and each writer starts at genesis")
    func chainedLogVerifies() throws {
        let events = try chained(corpus())
        let verification = EventChain.verify(events)

        #expect(verification.isIntact)
        #expect(verification.breaks.isEmpty)

        // Two writers, two chains, two heads. ADR 0002 rejects a single global
        // chain precisely because concurrent appenders fork it.
        #expect(verification.heads.count == 2)
        for writer in [deviceApp, deviceWidget] {
            let first = events.filter { $0.device == writer }.min { $0.order < $1.order }
            #expect(first?.prev == Event.genesisPrev)
        }
    }

    @Test("A writer that has never written has no head, and its next prev is genesis")
    func silentWriterHasNoHead() throws {
        let verification = EventChain.verify(try chained(corpus()))
        let never = DeviceID(rawValue: "33333333-3333-4333-8333-333333333333")

        // No entry, rather than an entry holding genesis: conflating "has never
        // written" with "wrote something that hashes to zero" would be a second
        // meaning for one value.
        #expect(verification.heads[never] == nil)
        #expect(verification.head(of: never) == Event.genesisPrev)
    }

    @Test("A head is the content hash of that writer's last event")
    func headIsTheLastContentHash() throws {
        let events = try chained(corpus())
        let verification = EventChain.verify(events)

        for writer in [deviceApp, deviceWidget] {
            let last = try #require(
                events.filter { $0.device == writer }.max { $0.order < $1.order }
            )
            #expect(try verification.head(of: writer) == last.contentHash)
        }
    }

    // MARK: What tampering costs

    @Test("Altering an earlier event breaks the chain at the event after it")
    func tamperingBreaksTheNextLink() throws {
        var events = try chained(corpus())
        let target = try #require(events.firstIndex { $0.kind == .checkedIn })

        // The documented attack: rewrite which habit a check-in was about. Every
        // other field, including this event's own `prev`, is left alone.
        events[target] = events[target].with(payload: .habit(habitB))

        let breaks = EventChain.verify(events).breaks
        let device = events[target].device
        let next = try #require(
            events
                .filter { $0.device == device && $0.lamport > events[target].lamport }
                .min { $0.order < $1.order }
        )

        #expect(breaks.count == 1)
        #expect(breaks.first?.device == device)
        #expect(breaks.first?.lamport == next.lamport)
    }

    @Test("Repairing the break costs every hash after it, including the head")
    func repairingTheBreakMovesEveryLaterHash() throws {
        // This is the assertion the chain exists for, and it is deliberately not
        // "the file cannot be edited". An attacker who edits an earlier event
        // and then re-chains the tail gets a log that verifies — and a head that
        // no longer matches the one `witness.logHeads` sealed, so every
        // achievement over that history stops checking out.
        let original = try chained(corpus())
        let originalHeads = EventChain.verify(original).heads

        var tampered = original
        let target = try #require(tampered.firstIndex { $0.kind == .checkedIn })
        let device = tampered[target].device
        tampered[target] = tampered[target].with(payload: .habit(habitB))

        let repaired = try chained(tampered)
        let repairedVerification = EventChain.verify(repaired)

        // The repair works — that is the point. It is not free.
        #expect(repairedVerification.isIntact)
        #expect(repairedVerification.head(of: device) != originalHeads[device])

        // And it is not one hash: every event after the edit on that writer's
        // chain has a different `content_hash` than it had before.
        let edited = tampered[target].lamport
        var moved = 0
        for (before, after) in zip(original, repaired)
        where before.device == device && before.lamport > edited {
            #expect(try before.contentHash != after.contentHash)
            moved += 1
        }
        #expect(moved > 0)
    }

    @Test("One writer's broken chain leaves the other writer's alone")
    func writersFailIndependently() throws {
        // `docs/technical.md` §6: "continue past the break only for lines
        // belonging to a *different* writer's chain, since per-writer chains
        // fail independently." That is a property of the walk, not a rule its
        // callers have to remember.
        var events = try chained(corpus())
        let target = try #require(events.firstIndex { $0.device == deviceWidget })
        events[target] = events[target].with(recordedAt: 1)

        let breaks = EventChain.verify(events).breaks
        #expect(breaks.allSatisfy { $0.device == deviceWidget })

        let intact = try chained(corpus())
        #expect(
            EventChain.verify(events).head(of: deviceApp)
                == EventChain.verify(intact).head(of: deviceApp)
        )
    }

    @Test("A prev pointing at nothing is a break, not a silently accepted link")
    func fabricatedPrevIsABreak() throws {
        var events = try chained(corpus())
        let target = try #require(events.indices.first { events[$0].lamport == 3 })
        events[target] = events[target].chained(to: Data(repeating: 0xAB, count: 32))

        let breaks = EventChain.verify(events).breaks
        #expect(breaks.contains { $0.lamport == 3 })

        guard case .prevMismatch(_, let found)? = breaks.first(where: { $0.lamport == 3 })?.reason
        else {
            Issue.record("a fabricated prev is a mismatch")
            return
        }
        #expect(found == Data(repeating: 0xAB, count: 32))
    }

    @Test("An event the canonical form refuses stops its chain and says so")
    func unencodableEventStopsTheChain() throws {
        // Reachable by design rather than by corruption: a line written by a
        // build whose escaping rules differ, or a name carrying a control
        // character. There is no value the next event's `prev` could be checked
        // against, so the walk stops rather than guessing.
        var events = try chained(
            [
                event(.habitCreated, habit: habitA, lamport: 1, name: "Move"),
                event(.checkedIn, habit: habitA, lamport: 2, source: .tap),
                event(.checkedIn, habit: habitA, lamport: 3, source: .tap),
            ]
        )
        events[1] = events[1].with(payload: EventPayload(habitID: habitA, name: "Mo\u{7}ve"))

        let breaks = EventChain.verify(events).breaks
        #expect(breaks.contains { $0.lamport == 2 && $0.reason == .unencodable })
        // Nothing is reported past it, because nothing past it can be checked.
        #expect(!breaks.contains { $0.lamport == 3 })
    }

    // MARK: Determinism

    @Test("Verification does not depend on the order the events arrive in")
    func verificationIsOrderIndependent() throws {
        let events = try chained(corpus())
        var generator = SeededGenerator(seed: 20_260_801)
        let shuffled = events.shuffled(using: &generator)

        let straight = EventChain.verify(events)
        let permuted = EventChain.verify(shuffled)

        #expect(straight.heads == permuted.heads)
        #expect(straight.breaks == permuted.breaks)
    }
}
