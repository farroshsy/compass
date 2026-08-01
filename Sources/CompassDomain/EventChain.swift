import Foundation

/// One writer's chain, and what is wrong with it. `docs/technical.md` §3 and §4,
/// ADR 0002.
///
/// **`prev` chains per writer, never globally.** ADR 0002 rejects a single
/// global hash chain precisely because concurrent appenders fork it, and adopts
/// per-writer chains with the anchor covering the sorted set of heads. The app
/// process and the widget process on one phone are two writers, so week 2 is the
/// first instance of that case rather than the second device.
///
/// The chain is what makes an earlier event unrewritable. Altering any earlier
/// event changes its `content_hash`, so the next event on that writer's chain no
/// longer points at it — and repairing that by re-chaining the tail changes
/// every later event's own `content_hash` in turn, which moves the head the
/// achievement's `witness.logHeads` committed to. That is the whole guarantee,
/// and it holds only because `payload` is inside the canonical bytes: before
/// `payload` was added, editing `habitID` on any line left its `content_hash`
/// unchanged and every proof still verified. `docs/technical.md` §3.
public enum EventChain {

    /// `prev` for the first event on a writer's chain: 32 zero bytes.
    public static let genesis = Event.genesisPrev

    /// Verifies every writer's chain **independently**, and reports each
    /// writer's head.
    ///
    /// Independence is not a convenience. `docs/technical.md` §6's damaged-log
    /// policy says to "continue past the break only for lines belonging to a
    /// *different* writer's chain, since per-writer chains fail independently",
    /// and that is a property of this function rather than a rule its callers
    /// have to remember.
    ///
    /// **One break is reported per discontinuity, not one per event after it.**
    /// After a mismatch the walk continues from the event it actually found, so
    /// a single tampered line produces a single break pointing at the line that
    /// stopped matching — rather than a cascade that buries where the damage
    /// starts. Nothing is repaired: a break is a break, and the caller decides.
    public static func verify(_ events: [Event]) -> ChainVerification {
        var byWriter: [DeviceID: [Event]] = [:]
        for event in events {
            byWriter[event.device, default: []].append(event)
        }

        var heads: [DeviceID: Data] = [:]
        var breaks: [ChainBreak] = []

        for (device, unordered) in byWriter {
            // The total order, restricted to one writer, is `lamport` alone —
            // `EventOrder`'s device half cannot break a tie inside a chain that
            // has one device in it. Never wall-clock. `docs/technical.md` §3.
            let chain = unordered.sorted { $0.order < $1.order }
            var expected = genesis

            for event in chain {
                if event.prev != expected {
                    breaks.append(
                        ChainBreak(
                            device: device,
                            lamport: event.lamport,
                            reason: .prevMismatch(expected: expected, found: event.prev)
                        )
                    )
                }
                guard let hash = try? event.contentHash else {
                    // The canonical form refuses this event, so nothing after it
                    // on this writer's chain can be checked — there is no value
                    // its successor's `prev` could be compared against. Reported
                    // and stopped, never guessed at.
                    breaks.append(
                        ChainBreak(device: device, lamport: event.lamport, reason: .unencodable)
                    )
                    break
                }
                expected = hash
                heads[device] = hash
            }
        }

        return ChainVerification(heads: heads, breaks: breaks.sorted(by: ChainBreak.byWriter))
    }
}

/// The result of walking every writer's chain.
public struct ChainVerification: Hashable, Sendable {

    /// `content_hash` of the last event on each writer's chain — the value
    /// `docs/achievement-protocol.md` §4 anchors as `witness.logHeads`, and the
    /// value the next event on that chain uses as its `prev`.
    ///
    /// A writer with no events has **no entry here**, not a genesis entry: its
    /// next event's `prev` is genesis, and conflating "has never written" with
    /// "wrote something that hashes to zero" would be a second meaning for one
    /// value.
    ///
    /// A head is the last event this build could canonicalise. If a writer's
    /// last line is one a newer build wrote and this one cannot decode, the head
    /// is behind that line and ``breaks`` says so — the honest answer, and the
    /// same "longest valid prefix" rule `docs/technical.md` §6 applies to
    /// replay.
    public let heads: [DeviceID: Data]

    /// Every discontinuity found, ordered by writer then `lamport`. Empty is the
    /// only good answer.
    public let breaks: [ChainBreak]

    public init(heads: [DeviceID: Data], breaks: [ChainBreak]) {
        self.heads = heads
        self.breaks = breaks
    }

    public var isIntact: Bool { breaks.isEmpty }

    /// This writer's head, or ``EventChain/genesis`` when it has never written —
    /// which is exactly what the next event's `prev` should be in both cases.
    public func head(of writer: DeviceID) -> Data {
        heads[writer] ?? EventChain.genesis
    }
}

extension Event {

    /// The same event, linked to `prev`.
    ///
    /// **This is not a mutation and it is not an edit.** Every field that says
    /// what happened is carried over untouched; only the link changes. It exists
    /// for the two callers that legitimately decide a link: `EventJournal`,
    /// stamping a new event onto the head of this writer's chain, and the
    /// one-time `reproject` hatch in `docs/technical.md` §11, which replays a
    /// week-1a log into a freshly chained one.
    ///
    /// It returns a new value rather than mutating, because `Event` has no `var`
    /// on it and must not acquire one: "nothing is ever mutated or deleted"
    /// (`docs/technical.md` §3) is easier to keep when the type cannot express
    /// a mutation.
    public func chained(to prev: Data) -> Event {
        Event(
            v: v,
            id: id,
            device: device,
            lamport: lamport,
            kind: kind,
            day: day,
            recordedAt: recordedAt,
            zoneOffset: zoneOffset,
            source: source,
            payload: payload,
            prev: prev,
            extra: extra,
            unknownFields: unknownFields
        )
    }
}

/// One place a writer's chain stopped being a chain.
public struct ChainBreak: Hashable, Sendable {

    public enum Reason: Hashable, Sendable {
        /// The event's `prev` is not the `content_hash` of its predecessor on
        /// this writer's chain — a tampered earlier event, a fork, or a line
        /// that never belonged here.
        case prevMismatch(expected: Data, found: Data)
        /// The canonical form refuses this event, so the chain cannot be
        /// followed past it. See ``CanonicalEncodingError``.
        case unencodable
    }

    public let device: DeviceID
    public let lamport: Int
    public let reason: Reason

    public init(device: DeviceID, lamport: Int, reason: Reason) {
        self.device = device
        self.lamport = lamport
        self.reason = reason
    }

    /// A deterministic order, so two runs over the same log report the same
    /// list. `Dictionary` iteration order is not stable and the walk above is
    /// per writer, so without this the list is a different permutation each run.
    static func byWriter(_ lhs: ChainBreak, _ rhs: ChainBreak) -> Bool {
        lhs.device == rhs.device ? lhs.lamport < rhs.lamport : lhs.device < rhs.device
    }
}
