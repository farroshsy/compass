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

    /// Every **top-level** key this build does not recognise, kept verbatim and
    /// re-emitted unchanged. `.claude/skills/architecture.md`: "Preserve unknown
    /// fields and unknown event kinds on read and re-emit them unchanged. Never
    /// drop data you do not understand."
    ///
    /// ``extra`` catches only what is inside the `extra` object. A key beside it
    /// — at the top level of the line — used to go nowhere at all: it decoded
    /// into no property and re-encoding did not contain it, so an older build
    /// reading and rewriting a newer build's log silently destroyed it.
    ///
    /// That matters for one specific reason. `docs/technical.md` §3 reserves a
    /// top-level `evidence` object, **outside both `payload` and the envelope**,
    /// precisely so that attaching a photo or a voice note to a check-in can be
    /// added additively later without disturbing any digested field or its
    /// ordering. A build that drops unknown top-level keys turns that additive
    /// change into a format change the moment two builds coexist.
    ///
    /// **It does not enter the canonical bytes, and it never can.** §3 fixes
    /// those bytes as a closed list of eleven named values in a frozen order,
    /// and this is the same rule as ``extra``: preserved on disk, never
    /// digested. An old build cannot hash a field it has never seen, so anything
    /// that has to be provable goes in a named field.
    ///
    /// A value here is a ``JSONValue``, which has no floating-point case — so a
    /// top-level key carrying a fraction makes the line undecodable rather than
    /// being silently rounded, exactly as it already does inside ``extra``.
    /// Losing precision inside a bag whose whole purpose is lossless
    /// round-tripping would be worse than refusing the line, and
    /// ``JournalReader`` already keeps a line it cannot decode out of the
    /// projection without dropping it from the file or refusing to launch.
    public let unknownFields: [String: JSONValue]

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
        extra: [String: JSONValue] = [:],
        unknownFields: [String: JSONValue] = [:]
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
        // A key that this build *does* know is never an unknown field, whatever
        // a caller passes. Normalising here rather than on encode is what makes
        // "the unknown bag can never overwrite a named value" an invariant of
        // every `Event` rather than a property of one code path.
        self.unknownFields = unknownFields.filter { !Event.envelopeKeys.contains($0.key) }
    }

    /// The total order. **Never wall-clock.**
    public var order: EventOrder { EventOrder(lamport: lamport, device: device) }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case v, id, device, lamport, kind, day, recordedAt, zoneOffset, source, payload, prev, extra
    }

    /// The top-level keys this build knows. Everything else on a line is an
    /// unknown field and is preserved as one.
    private static let envelopeKeys = Set(CodingKeys.allCases.map(\.rawValue))

    /// One arbitrary top-level key, so a line can be read and written with keys
    /// that are not in ``CodingKeys``.
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ key: CodingKeys) { self.stringValue = key.rawValue }
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

        // Everything else on the line. Read through a second, key-agnostic view
        // of the same container, because `CodingKeys` can only ever see the
        // keys it already knows about — which is precisely how a top-level key
        // used to reach no property at all and vanish on re-encode.
        let anyKeys = try decoder.container(keyedBy: AnyKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in anyKeys.allKeys where !Event.envelopeKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try anyKeys.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    public func encode(to encoder: any Encoder) throws {
        // One key-agnostic container for the whole envelope, rather than a typed
        // one plus a second container for the unknown keys: two keyed containers
        // writing into one object is a Foundation implementation detail, and the
        // line this produces is on the survival path for every event ever
        // recorded.
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(v, forKey: AnyKey(.v))
        try container.encode(id, forKey: AnyKey(.id))
        try container.encode(device, forKey: AnyKey(.device))
        try container.encode(lamport, forKey: AnyKey(.lamport))
        try container.encode(kind, forKey: AnyKey(.kind))
        try container.encode(day, forKey: AnyKey(.day))
        try container.encode(recordedAt, forKey: AnyKey(.recordedAt))
        try container.encode(zoneOffset, forKey: AnyKey(.zoneOffset))
        try container.encodeIfPresent(source, forKey: AnyKey(.source))
        try container.encode(payload, forKey: AnyKey(.payload))
        try container.encode(prev, forKey: AnyKey(.prev))
        if !extra.isEmpty {
            try container.encode(extra, forKey: AnyKey(.extra))
        }

        // Re-emitted unchanged, so nothing a newer build wrote is lost by an
        // older one reading and rewriting the line. `init` has already
        // guaranteed none of these can collide with a named key above.
        //
        // The sort makes the *sequence of encode calls* deterministic. It does
        // **not** make the emitted bytes stable, and an earlier version of this
        // comment claimed it did: `JSONEncoder` does not promise to preserve
        // keyed-container order, and three lines pulled off the live simulator
        // log each carried a different top-level key order. Two encodings of one
        // event are therefore equal as JSON, not as bytes.
        //
        // That is permitted rather than tolerated. `docs/technical.md` §3: "The
        // on-disk JSON line is not required to be byte-identical to the
        // canonical form — it carries `extra` and may order keys differently."
        // Byte-stability is the job of the hand-written canonical encoder that
        // lands in week 1b, which orders keys itself and never sees `extra`.
        // Nothing may be derived from the byte layout of this line.
        for key in unknownFields.keys.sorted() {
            guard let value = unknownFields[key] else { continue }
            try container.encode(value, forKey: AnyKey(stringValue: key))
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
