import Foundation

/// One append-only fact. Events are the only truth; everything else in the app
/// is a view over them. `docs/technical.md` §3.
///
/// Nothing is ever mutated or deleted. Un-checking appends a
/// ``EventKind/checkInRevoked``, and the fold resolves the `(habit, day)` cell
/// last-writer-wins under ``EventOrder``.
///
/// `device`, `lamport` and `prev` exist from the very first write even though
/// there is one device and no sync. They cost nothing now and cannot be
/// retrofitted later without invalidating every hash computed before the change.
public struct Event: Hashable, Sendable, Codable {

    /// Always 1, never bumped. A version bump is a migration, and a migration is
    /// the documented death mechanism for this codebase.
    /// `docs/achievement-protocol.md` §6.8.
    public static let currentVersion = 1

    /// 32 zero bytes — `prev` for the first event on a writer's chain.
    public static let genesisPrev = Data(repeating: 0, count: 32)

    /// Length of a `content_hash`, and therefore of `prev`. SHA-256.
    public static let hashLength = 32

    public let v: Int
    /// For cross-device dedupe.
    public let id: UUID
    /// The writer, not the phone. See ``DeviceID``.
    public let device: DeviceID
    /// Per-writer monotonic counter. First half of the total order.
    public let lamport: Int
    public let kind: EventKind
    /// The civil day this event is **about** — not when it was recorded.
    public let day: Day
    /// The instant the user tapped, as an integer count of milliseconds since
    /// the Unix epoch. Metadata, **never read by the fold**: clocks move
    /// backwards, so wall-clock is not a safe sort key. There is no floating
    /// point anywhere in a digested value.
    public let recordedAt: Int
    /// Device UTC offset in minutes at record time.
    public let zoneOffset: Int
    /// Present on ``EventKind/checkedIn``. Absent fields are omitted entirely,
    /// never emitted as `null`.
    public let source: CheckInSource?
    /// The kind-specific fields. Required, always present, never `null`.
    public let payload: EventPayload
    /// `content_hash` of the previous event on **this writer's** chain, or
    /// ``genesisPrev`` for the first event on a chain. `prev` participates in
    /// the canonical bytes: that is what makes the chain a chain.
    public let prev: Data
    /// Forward-compatibility bag, round-tripped losslessly. **Does not
    /// participate** in the canonical bytes — an old build cannot hash fields it
    /// has never seen. Anything that has to be provable goes in a named field,
    /// never here.
    public let extra: [String: JSONValue]

    public init(
        v: Int = Event.currentVersion,
        id: UUID,
        device: DeviceID,
        lamport: Int,
        kind: EventKind,
        day: Day,
        recordedAt: Int,
        zoneOffset: Int,
        source: CheckInSource? = nil,
        payload: EventPayload = .empty,
        prev: Data = Event.genesisPrev,
        extra: [String: JSONValue] = [:]
    ) {
        self.v = v
        self.id = id
        self.device = device
        self.lamport = lamport
        self.kind = kind
        self.day = day
        self.recordedAt = recordedAt
        self.zoneOffset = zoneOffset
        self.source = source
        self.payload = payload
        self.prev = prev
        self.extra = extra
    }

    /// The total order. **Never wall-clock.**
    public var order: EventOrder { EventOrder(lamport: lamport, device: device) }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case v, id, device, lamport, kind, day, recordedAt, zoneOffset, source, payload, prev, extra
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        id = try container.decode(UUID.self, forKey: .id)
        device = try container.decode(DeviceID.self, forKey: .device)
        lamport = try container.decode(Int.self, forKey: .lamport)
        kind = try container.decode(EventKind.self, forKey: .kind)
        day = try container.decode(Day.self, forKey: .day)
        recordedAt = try container.decode(Int.self, forKey: .recordedAt)
        zoneOffset = try container.decode(Int.self, forKey: .zoneOffset)
        source = try container.decodeIfPresent(CheckInSource.self, forKey: .source)
        payload = try container.decode(EventPayload.self, forKey: .payload)

        let prev = try container.decode(Data.self, forKey: .prev)
        guard prev.count == Event.hashLength else {
            throw DecodingError.dataCorruptedError(
                forKey: .prev,
                in: container,
                debugDescription: "prev must be \(Event.hashLength) bytes, got \(prev.count)"
            )
        }
        self.prev = prev

        extra = try container.decodeIfPresent([String: JSONValue].self, forKey: .extra) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(device, forKey: .device)
        try container.encode(lamport, forKey: .lamport)
        try container.encode(kind, forKey: .kind)
        try container.encode(day, forKey: .day)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(zoneOffset, forKey: .zoneOffset)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(payload, forKey: .payload)
        try container.encode(prev, forKey: .prev)
        if !extra.isEmpty {
            try container.encode(extra, forKey: .extra)
        }
    }
}

/// The total order over events: `(lamport, device)`. **Never wall-clock.**
/// `docs/technical.md` §3.
///
/// Lamport first so causality holds; device as a deterministic byte-wise
/// tiebreak so two devices compute identical results from the same set.
public struct EventOrder: Hashable, Comparable, Sendable {
    public let lamport: Int
    public let device: DeviceID

    public init(lamport: Int, device: DeviceID) {
        self.lamport = lamport
        self.device = device
    }

    public static func < (lhs: EventOrder, rhs: EventOrder) -> Bool {
        if lhs.lamport != rhs.lamport { return lhs.lamport < rhs.lamport }
        return lhs.device < rhs.device
    }
}

/// The kind-specific fields of an event. `docs/technical.md` §3.
///
/// **`payload` is a closed structure, not a second `extra`.** Every key has a
/// frozen meaning and a frozen position, and **an unknown payload key makes the
/// event invalid** — it is not ignored, not round-tripped, not tolerated.
/// Silently accepting a semantic field you cannot hash is precisely the failure
/// `payload` was added to close. New semantics arrive as a new ``EventKind``,
/// never as a new key here.
///
/// Per kind:
/// ```
/// habitCreated       {"habitID":<string>,"name":<string>}
/// habitRenamed       {"habitID":<string>,"name":<string>}
/// habitArchived      {"habitID":<string>}
/// habitUnarchived    {"habitID":<string>}
/// checkedIn          {"habitID":<string>}
/// checkInRevoked     {"habitID":<string>}
/// achievementAwarded {"achievementID":<string>}
/// achievementRevoked {"achievementID":<string>,"reason":<string>}
/// ```
/// A kind with no fields of its own emits `{}`.
public struct EventPayload: Hashable, Sendable, Codable {
    public let habitID: HabitID?
    public let name: String?
    public let achievementID: AchievementID?
    public let reason: String?

    public init(
        habitID: HabitID? = nil,
        name: String? = nil,
        achievementID: AchievementID? = nil,
        reason: String? = nil
    ) {
        self.habitID = habitID
        self.name = name
        self.achievementID = achievementID
        self.reason = reason
    }

    public static let empty = EventPayload()

    public static func habit(_ id: HabitID) -> EventPayload {
        EventPayload(habitID: id)
    }

    public static func habit(_ id: HabitID, name: String) -> EventPayload {
        EventPayload(habitID: id, name: name)
    }

    public static func achievement(_ id: AchievementID) -> EventPayload {
        EventPayload(achievementID: id)
    }

    public static func achievement(_ id: AchievementID, reason: String) -> EventPayload {
        EventPayload(achievementID: id, reason: reason)
    }

    // MARK: Codable — closed, so an unknown key is a decode failure

    private enum Key: String, CaseIterable {
        case habitID, name, achievementID, reason
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ key: Key) { self.stringValue = key.rawValue }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)

        let known = Set(Key.allCases.map(\.rawValue))
        let present = container.allKeys.map(\.stringValue)
        if let unknown = present.first(where: { !known.contains($0) }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: """
                        Unknown payload key "\(unknown)". payload is a closed structure — \
                        an unknown key makes the event invalid, and new semantics arrive as \
                        a new event kind. docs/technical.md §3.
                        """
                )
            )
        }

        habitID = try container.decodeIfPresent(HabitID.self, forKey: AnyKey(.habitID))
        name = try container.decodeIfPresent(String.self, forKey: AnyKey(.name))
        achievementID = try container.decodeIfPresent(
            AchievementID.self, forKey: AnyKey(.achievementID)
        )
        reason = try container.decodeIfPresent(String.self, forKey: AnyKey(.reason))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encodeIfPresent(habitID, forKey: AnyKey(.habitID))
        try container.encodeIfPresent(name, forKey: AnyKey(.name))
        try container.encodeIfPresent(achievementID, forKey: AnyKey(.achievementID))
        try container.encodeIfPresent(reason, forKey: AnyKey(.reason))
    }
}
