import Foundation

/// Every taxonomy and identifier this project owns is a `RawRepresentable`
/// struct over `String`, never a Swift enum.
/// `docs/achievement-protocol.md` §2.2, `.claude/skills/architecture.md`.
///
/// An unknown enum case is a decode crash and a `default:` branch to migrate
/// around. A string wrapper decodes an unknown value cleanly and preserves it,
/// which is what lets an older build read a newer file without destroying data
/// it does not understand.
///
/// Enums are permitted **only** for closed sets defined by someone else, or by
/// the protocol document as frozen: `JSONValue`, `AnchorState`, `SignerBacking`,
/// `CheckInSource`.
public protocol StringBacked:
    RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension StringBacked {
    public var description: String { rawValue }

    /// Byte-wise, so two devices sort a set identically regardless of locale or
    /// Unicode collation version. `docs/achievement-protocol.md` §4.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    /// Non-failable by construction: an unknown value decodes instead of
    /// throwing, and is re-emitted unchanged.
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A habit's stable, opaque identifier.
///
/// This — never the display name — is what enters a digest. A name frozen into
/// a signed, anchored, shareable record can never be taken back.
/// `docs/achievement-protocol.md` §3.4.
public struct HabitID: StringBacked {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// A **writer** identifier, not a phone. The app process and the widget process
/// on one phone are two writers with two `DeviceID`s, two `lamport` sequences
/// and two `prev` chains. `docs/technical.md` §3 and §4.
///
/// The value is a randomly generated 128-bit UUID, created on first write and
/// stored locally. It MUST NOT be `identifierForVendor`, an Apple ID, the device
/// name, or anything derived from any of those — it is signed, anchored and
/// present inside every exported achievement handed to a stranger. It is never
/// displayed in the UI. Generating it is `CompassInfrastructure`'s job; Domain
/// only carries and orders it.
public struct DeviceID: StringBacked {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The closed set of event kinds, as a string wrapper rather than an enum so an
/// unknown kind from a newer build decodes cleanly instead of crashing.
/// `docs/technical.md` §3.
public struct EventKind: StringBacked {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let habitCreated = EventKind(rawValue: "habitCreated")
    /// Cosmetic. Never changes a status, a count or a streak.
    public static let habitRenamed = EventKind(rawValue: "habitRenamed")
    public static let habitArchived = EventKind(rawValue: "habitArchived")
    public static let habitUnarchived = EventKind(rawValue: "habitUnarchived")
    public static let checkedIn = EventKind(rawValue: "checkedIn")
    /// The compensating event. Un-checking never deletes or mutates.
    public static let checkInRevoked = EventKind(rawValue: "checkInRevoked")
    public static let achievementAwarded = EventKind(rawValue: "achievementAwarded")
    public static let achievementRevoked = EventKind(rawValue: "achievementRevoked")

    /// The record's declared subject: an **optional, self-declared, unverified**
    /// name for the person the record is about. Payload `{"name":<string>}` —
    /// one key, from the closed set `payload` already has, so nothing about
    /// `docs/technical.md` §3's closed-payload rule changes.
    ///
    /// **Added 2026-07-31, additively, and this is the mechanism §3 describes.**
    /// "`EventKind` is a `RawRepresentable` string precisely so a kind can be
    /// added later without a format change. That is the stated reason it is a
    /// string." A build that predates this kind decodes the line, ignores it in
    /// the fold, and re-emits it unchanged. The decision is recorded in
    /// `memory/decisions.md`; it is option (b) of the share-subject question in
    /// `docs/open-questions.md`.
    ///
    /// **What it does and does not prove.** `docs/product.md` bans accounts,
    /// sign-in and any second party, so nothing can verify that the name is
    /// true, and the app must never imply otherwise. What it does buy is
    /// narrower and real: the declaration is an event in the log, and
    /// `docs/achievement-protocol.md` §4 has `witness.logHeads` commit to the
    /// whole history as of detection — so a name declared before an achievement
    /// is sealed cannot be restated afterwards without breaking that seal. It
    /// proves the name was committed to at the time, never that it is true.
    ///
    /// It is deliberately **not** a field in `facts`. `facts` is inside the
    /// canonical bytes, and §3.4 fixes that shape; a digest field cannot be
    /// added additively, whereas a kind can. Reaching the digest through the log
    /// costs nothing and breaks nothing.
    ///
    /// An empty `name` is meaningful and is how a declaration is withdrawn: the
    /// declaration is superseded going forward, and — like everything else here
    /// — **nothing is deleted.** Both events stay in the log, and a record
    /// sealed while a name stood keeps that name.
    public static let subjectNamed = EventKind(rawValue: "subjectNamed")
}

/// Deterministic: `"<ruleID>@<earnedOn>"`, never a UUID.
/// `docs/achievement-protocol.md` §3.1.
public struct AchievementID: StringBacked {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Where a check-in came from. A frozen closed set, and therefore one of the
/// four permitted enums. `docs/achievement-protocol.md` §2.2.
///
/// Three values in v1, not four. `backfill` is deliberately absent because no
/// backfill surface ships in v1 — `docs/technical.md` §3 and §10b.
public enum CheckInSource: String, Codable, Hashable, Sendable, CaseIterable {
    case tap
    case widget
    case shortcut
}
