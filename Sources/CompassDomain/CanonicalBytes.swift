import CryptoKit
import Foundation

/// The hand-written canonical byte encoding, and `content_hash`.
/// `docs/technical.md` §3, `docs/achievement-protocol.md` §6.3.
///
/// **This is not `JSONEncoder`, and it must never become `JSONEncoder`.**
/// `docs/technical.md` §1: "key order is not a promise Swift makes across
/// releases". A verifier recomputing this in three years must get byte-identical
/// output from the same event, and `JSONEncoder`'s keyed-container order is a
/// Foundation implementation detail — three lines pulled off the live simulator
/// log each carried a different top-level key order. The precedent is the
/// `Entry.sealBytes` discipline in the `before` repository, copied here as a
/// discipline rather than as code.
///
/// The form is fixed by `docs/technical.md` §3, and this file is the only place
/// it exists in code:
///
/// ```
/// {"v":1,"id":<string>,"device":<string>,"lamport":<int>,"kind":<string>,
///  "day":<string>,"recordedAt":<int>,"zoneOffset":<int>,"source":<string>?,
///  "payload":<object>,"prev":<base64>}
/// ```
///
/// Eleven values, a closed list, in exactly that order, UTF-8, no whitespace.
/// **`extra` and unknown top-level keys are not in it and never can be** — an
/// old build cannot hash a field it has never seen, which is why anything that
/// has to be provable goes in a named field.
///
/// ### Why this is in Domain, and what that cost
///
/// `docs/technical.md` §2 said `CompassDomain` imports "Foundation only", and
/// this file adds `CryptoKit`. The line was changed rather than worked around
/// because the corpus already requires SHA-256 in the pure layer:
/// `docs/achievement-protocol.md` §4.1 builds `evidenceRoot` out of per-event
/// `content_hash` values inside an engine `docs/technical.md` §5 requires to be
/// "a pure, idempotent, re-runnable function". The two honest alternatives were
/// worse: a hashing port in Domain is an abstraction with a single use site,
/// which `PROJECT_CONSTITUTION.md` §8 forbids, and a hand-rolled SHA-256 is
/// novelty over mature technology, which §5 forbids. CryptoKit is a platform
/// framework, not a package target, so the boundary that is actually
/// load-bearing — Domain must never learn Infrastructure exists — is untouched.
/// `docs/technical.md` §2 and `.claude/skills/architecture.md` were updated in
/// this same change.
extension Event {

    /// The canonical bytes of this event. Hand-written, never `JSONEncoder`.
    ///
    /// It throws rather than substituting anything, because every failure it can
    /// have is a string the escaping rules in
    /// `docs/achievement-protocol.md` §6.3 refuse to represent. Throwing at the
    /// moment of the write is the documented behaviour — "rejected at write time
    /// rather than escaped, so the escaping rules can never drift" — and
    /// `EventJournal.record` canonicalises before it writes, so a refused event
    /// never reaches the file.
    public var canonicalBytes: Data {
        get throws {
            var out = CanonicalBytes()

            out.open()
            out.key("v")
            // The literal value, not the constant `1`. `v` is 1 and
            // `docs/achievement-protocol.md` §6.8 says it MUST NOT be bumped —
            // but if a line ever carries another value, the digest of *that*
            // event has to differ from the digest of the same event at v1.
            // Encoding the constant instead would make two different events
            // hash the same, which is the one thing a digest may never do.
            out.int(v)
            out.comma()
            out.key("id")
            // `UUID.uuidString` — uppercase, hyphenated, and the same form
            // `JSONEncoder` already writes on the line, so the canonical bytes
            // and the stored line agree about what the identifier is.
            try out.string(id.uuidString, field: "id")
            out.comma()
            out.key("device")
            try out.string(device.rawValue, field: "device")
            out.comma()
            out.key("lamport")
            out.int(lamport)
            out.comma()
            out.key("kind")
            try out.string(kind.rawValue, field: "kind")
            out.comma()
            out.key("day")
            try out.string(day.iso, field: "day")
            out.comma()
            out.key("recordedAt")
            out.int(recordedAt)
            out.comma()
            out.key("zoneOffset")
            out.int(zoneOffset)
            // Absent optionals are **omitted entirely, never emitted as
            // `null`**, and in v1 `source` is the only optional in the form.
            // A `checkInRevoked` has no source, so this is the branch that keeps
            // an un-tap's digest correct. `docs/technical.md` §3.
            if let source {
                out.comma()
                out.key("source")
                try out.string(source.rawValue, field: "source")
            }
            out.comma()
            out.key("payload")
            try out.append(payload.canonicalBytes)
            out.comma()
            out.key("prev")
            // Standard base64 **with** padding, RFC 4648 §4.
            // `docs/achievement-protocol.md` §6.5.
            try out.string(prev.base64EncodedString(), field: "prev")
            out.close()

            return out.data
        }
    }

    /// `content_hash = SHA-256(event canonical bytes)`. `docs/technical.md` §3.
    ///
    /// **Recomputed on read, never stored on the line.** Storing it would put a
    /// value on disk that can disagree with the bytes next to it, and the only
    /// honest response to that disagreement is to recompute anyway. It is a
    /// computed property for exactly that reason: there is no stored field it
    /// could drift from.
    public var contentHash: Data {
        get throws {
            Data(SHA256.hash(data: try canonicalBytes))
        }
    }
}

extension EventPayload {

    /// The kind-specific fields, as canonical bytes. `docs/technical.md` §3.
    ///
    /// The document specifies this per kind:
    ///
    /// ```
    /// habitCreated       {"habitID":<string>,"name":<string>}
    /// habitRenamed       {"habitID":<string>,"name":<string>}
    /// habitArchived      {"habitID":<string>}
    /// habitUnarchived    {"habitID":<string>}
    /// checkedIn          {"habitID":<string>}
    /// checkInRevoked     {"habitID":<string>}
    /// achievementAwarded {"achievementID":<string>}
    /// achievementRevoked {"achievementID":<string>,"reason":<string>}
    /// subjectNamed       {"name":<string>}
    /// ```
    ///
    /// **One rule reproduces every row of that table: emit the fields that are
    /// present, in the fixed order `habitID`, `name`, `achievementID`,
    /// `reason`.** Every listed kind is a subsequence of that order — `habitID`
    /// before `name` on the two habit kinds, `achievementID` before `reason` on
    /// a revocation — so the table is satisfied without a switch over `kind`.
    ///
    /// That matters for one specific reason. ``EventKind`` is a
    /// `RawRepresentable` string precisely so a newer build can add a kind
    /// without a format change, and such a kind decodes here into some subset of
    /// the same four keys. A switch would have no branch for it and would have
    /// to invent one; this rule is already total over it, and gives the same
    /// answer in both builds.
    ///
    /// A kind with no fields of its own emits `{}`.
    var canonicalBytes: Data {
        get throws {
            var out = CanonicalBytes()
            out.open()
            var needsComma = false

            func field(_ name: String, _ value: String?) throws {
                guard let value else { return }
                if needsComma { out.comma() }
                out.key(name)
                try out.string(value, field: "payload.\(name)")
                needsComma = true
            }

            try field("habitID", habitID?.rawValue)
            try field("name", name)
            try field("achievementID", achievementID?.rawValue)
            try field("reason", reason)

            out.close()
            return out.data
        }
    }
}

// MARK: - The achievement canonical form

/// The second canonical form in the corpus, `docs/achievement-protocol.md` §6.
///
/// It lives in this file rather than beside ``Achievement`` because
/// `.claude/skills/architecture.md` puts the hand-written canonical bytes in
/// exactly one file — the rule exists so that a session looking for "where the
/// digested bytes are written" finds all of them, and a second file called
/// something else is how two spellings of one escaping rule start.
///
/// The event form and this one are deliberately not merged into a shared writer:
/// they are frozen by two different documents, and a change made "for both" is a
/// change made to a format that is already anchored.
extension Achievement {

    /// The exact bytes the digest commits to. §6.1:
    ///
    /// ```
    /// {"v":1,"id":<string>,"rule":<rule-digest-form>,"earnedOn":<string>,
    ///  "facts":<canonical-map>,"witness":<canonical-witness>}
    /// ```
    ///
    /// `detectedAt` and `extra` are **not here**, and neither are the rule's
    /// `version`, `titleKey` and `fallbackTitle` — §6.2 omits them so a typo stays
    /// correctable forever without breaking a single anchor. Invariant 8 is the
    /// other half of that bargain and lives in `CertificateCopy`: nothing outside
    /// this byte string is ever rendered as part of a verified claim.
    ///
    /// `"v"` is the literal `1` and §6.8 forbids bumping it. Unlike ``Event``,
    /// which stores its own `v` and encodes the stored value so two versions of
    /// one event cannot collide, there is no version field on an ``Achievement``
    /// at all — seven fields, no more — so there is nothing here that could
    /// disagree with the constant.
    public var canonicalBytes: Data {
        get throws {
            var out = CanonicalBytes()
            out.open()
            out.key("v")
            out.int(1)
            out.comma()
            out.key("id")
            try out.string(id.rawValue, field: "id")
            out.comma()
            out.key("rule")
            try out.append(rule.digestForm)
            out.comma()
            out.key("earnedOn")
            try out.string(earnedOn.iso, field: "earnedOn")
            out.comma()
            out.key("facts")
            try out.append(CanonicalBytes.map(facts, field: "facts"))
            out.comma()
            out.key("witness")
            try out.append(witness.canonicalBytes)
            out.close()
            return out.data
        }
    }

    /// `digest = SHA-256(canonicalBytes)`. §6.6.
    ///
    /// **This is what is anchored, and it is not what is signed.** §6.7 signs
    /// ``canonicalBytes`` through CryptoKit's `DataProtocol` overload, which
    /// hashes its argument once — so the signed message *is* this value, with no
    /// second hash. A verifier recomputes `canonicalBytes` and passes that same
    /// byte string to both the hash and the signature check; it never signs or
    /// verifies over the digest itself.
    public var digest: Data {
        get throws { Data(SHA256.hash(data: try canonicalBytes)) }
    }
}

extension RuleSpec {

    /// `rule-digest-form`, §6.2. Exact key order, display fields omitted, and
    /// optional fields that are `nil` omitted entirely rather than emitted as
    /// `null`.
    ///
    /// ```
    /// {"id":<string>,"kind":<string>,"scope":<canonical-scope>,"threshold":<int>,
    ///  "window":<int>?,"requires":<int>?,"maxBackfillLagDays":<int>?,
    ///  "neutralDaysBridge":<bool>,"repeatPolicy":<string>,"members":[<string>…]?}
    /// ```
    var digestForm: Data {
        get throws {
            var out = CanonicalBytes()
            out.open()
            out.key("id")
            try out.string(id.rawValue, field: "rule.id")
            out.comma()
            out.key("kind")
            try out.string(kind.rawValue, field: "rule.kind")
            out.comma()
            out.key("scope")
            try out.append(scope.canonicalBytes)
            out.comma()
            out.key("threshold")
            out.int(threshold)
            if let window {
                out.comma()
                out.key("window")
                out.int(window)
            }
            if let requires {
                out.comma()
                out.key("requires")
                out.int(requires)
            }
            if let maxBackfillLagDays {
                out.comma()
                out.key("maxBackfillLagDays")
                out.int(maxBackfillLagDays)
            }
            out.comma()
            out.key("neutralDaysBridge")
            out.bool(neutralDaysBridge)
            out.comma()
            out.key("repeatPolicy")
            try out.string(repeatPolicy.rawValue, field: "rule.repeatPolicy")
            if let members {
                out.comma()
                out.key("members")
                out.openArray()
                for (index, member) in members.enumerated() {
                    if index > 0 { out.comma() }
                    try out.string(member.rawValue, field: "rule.members")
                }
                out.closeArray()
            }
            out.close()
            return out.data
        }
    }
}

extension Scope {

    /// `canonical-scope`, §6.4. Spelled out rather than implied, because §6.2
    /// references it. `{"habit":<string>?,"requiresAll":<bool>}`
    var canonicalBytes: Data {
        get throws {
            var out = CanonicalBytes()
            out.open()
            if let habit {
                out.key("habit")
                try out.string(habit.rawValue, field: "rule.scope.habit")
                out.comma()
            }
            out.key("requiresAll")
            out.bool(requiresAll)
            out.close()
            return out.data
        }
    }
}

extension Witness {

    /// `canonical-witness`, §6.5.
    ///
    /// ```
    /// {"firstDay":<string>,"lastDay":<string>,"dayCount":<int>,
    ///  "evidenceRoot":<base64>,"logHeads":<canonical-map of deviceID -> base64>}
    /// ```
    ///
    /// Base64 is standard, with padding, RFC 4648 §4 — the same spelling `prev`
    /// already uses on the event form. `logHeads` is a canonical map, so its
    /// device keys are sorted byte-wise, which is what §4 requires.
    var canonicalBytes: Data {
        get throws {
            var out = CanonicalBytes()
            out.open()
            out.key("firstDay")
            try out.string(firstDay.iso, field: "witness.firstDay")
            out.comma()
            out.key("lastDay")
            try out.string(lastDay.iso, field: "witness.lastDay")
            out.comma()
            out.key("dayCount")
            out.int(dayCount)
            out.comma()
            out.key("evidenceRoot")
            try out.string(evidenceRoot.base64EncodedString(), field: "witness.evidenceRoot")
            out.comma()
            out.key("logHeads")
            try out.append(
                CanonicalBytes.map(
                    logHeads.mapValues { JSONValue.string($0.base64EncodedString()) },
                    field: "witness.logHeads"
                )
            )
            out.close()
            return out.data
        }
    }
}

// MARK: - The log-head anchor canonical form

/// The third canonical form, and the only one this repository fixes itself.
///
/// `docs/technical.md` §3 fixes the event form and `docs/achievement-protocol.md`
/// §6 fixes the achievement form. ADR 0004 requires the event-log head to be
/// anchored weekly and **specifies no encoding for it at all**, so one is chosen
/// here and written down in `docs/technical.md` §6 in the same change. It is
/// deliberately the smallest thing that can be said:
///
/// ```
/// {"v":1,"kind":"logHeads","heads":<canonical-map of deviceID -> base64>}
/// ```
///
/// **There is no timestamp in it.** ADR 0004's own argument against putting
/// `attainedAt` on a chain applies here word for word: a self-asserted instant
/// is "just a number the issuer typed in". The whole reason to submit this to a
/// calendar is that the calendar supplies the time, so putting a claimed one
/// inside the digest would be claiming the thing being proved.
///
/// The consequence is that two anchors over the same heads have the same digest,
/// which is why ``LogAnchorSchedule`` refuses to re-anchor unchanged heads: a
/// second submission of one digest gets a strictly *later* Bitcoin timestamp for
/// a value that already has an earlier one.
extension LogAnchor {

    /// The exact bytes the anchor digest commits to. `heads` is a canonical map,
    /// so its device keys are sorted byte-wise — the same rule
    /// `docs/achievement-protocol.md` §4 already imposes on `witness.logHeads`,
    /// and for the same reason: a verifier must sort identically without knowing
    /// which platform wrote the file.
    public static func canonicalBytes(heads: [String: Data]) throws -> Data {
        var out = CanonicalBytes()
        out.open()
        out.key("v")
        out.int(1)
        out.comma()
        out.key("kind")
        try out.string("logHeads", field: "kind")
        out.comma()
        out.key("heads")
        try out.append(
            CanonicalBytes.map(
                heads.mapValues { JSONValue.string($0.base64EncodedString()) }, field: "heads"
            )
        )
        out.close()
        return out.data
    }

    /// `SHA-256` over ``canonicalBytes(heads:)`` — the value submitted to the
    /// calendars.
    public static func digest(heads: [String: Data]) throws -> Data {
        Data(SHA256.hash(data: try canonicalBytes(heads: heads)))
    }

    public var canonicalBytes: Data {
        get throws { try LogAnchor.canonicalBytes(heads: heads) }
    }
}

/// A byte buffer that writes exactly the JSON this project's canonical forms
/// are made of, and nothing else.
///
/// It is deliberately small and deliberately not general. There is no pretty
/// printing, no key sorting, no number formatting beyond `Int`, and no
/// floating-point path at all — `docs/achievement-protocol.md` §2.3 bans
/// floating point from anything digested, so the type that writes digested bytes
/// should not be able to express one.
struct CanonicalBytes {
    private(set) var bytes: [UInt8] = []

    var data: Data { Data(bytes) }

    mutating func open() { bytes.append(UInt8(ascii: "{")) }
    mutating func close() { bytes.append(UInt8(ascii: "}")) }
    mutating func comma() { bytes.append(UInt8(ascii: ",")) }
    mutating func openArray() { bytes.append(UInt8(ascii: "[")) }
    mutating func closeArray() { bytes.append(UInt8(ascii: "]")) }

    /// The separator after a key that had to be escaped, and therefore could not
    /// be written by ``key(_:)``. See ``map(_:field:)``.
    mutating func colon() { bytes.append(UInt8(ascii: ":")) }

    /// `true` or `false`, lowercase, as JSON spells them. Added for the
    /// achievement form — `neutralDaysBridge` and `Scope.requiresAll` are the
    /// only two booleans in any digested value in the corpus.
    mutating func bool(_ value: Bool) {
        bytes.append(contentsOf: (value ? "true" : "false").utf8)
    }

    mutating func null() {
        bytes.append(contentsOf: "null".utf8)
    }

    /// A key and its colon. Keys are literals from `docs/technical.md` §3 and
    /// carry nothing escapable, so they are written directly.
    mutating func key(_ name: String) {
        bytes.append(UInt8(ascii: "\""))
        bytes.append(contentsOf: name.utf8)
        bytes.append(contentsOf: [UInt8(ascii: "\""), UInt8(ascii: ":")])
    }

    /// A decimal integer. Swift's `String(Int)` is base 10, ASCII, with a
    /// leading `-` for negatives and no separators, on every platform — which is
    /// the whole requirement. `zoneOffset` is negative west of UTC.
    mutating func int(_ value: Int) {
        bytes.append(contentsOf: String(value).utf8)
    }

    mutating func append(_ raw: Data) throws {
        bytes.append(contentsOf: raw)
    }

    /// A quoted string, escaped per `docs/achievement-protocol.md` §6.3:
    /// `\\`, `\"`, `\n` — **and nothing else.**
    ///
    /// "Any other control character MUST be rejected at write time rather than
    /// escaped, so the escaping rules can never drift." Rejecting is what keeps
    /// the rule finite: the moment one more escape is permitted, a verifier
    /// written from the document and a verifier written from the code can
    /// disagree about a byte, and the digest is the only thing that tells them
    /// apart.
    ///
    /// Everything outside those three is emitted as raw UTF-8, including every
    /// non-ASCII character. There is no `\uXXXX` path, and adding one would be
    /// exactly the drift this rejects — two spellings of one character is two
    /// digests for one event.
    ///
    /// What counts as a control character is stated rather than left to the
    /// reader: **C0 (U+0000–U+001F) except U+000A, DEL (U+007F), and C1
    /// (U+0080–U+009F)** — the Unicode `Cc` category. Only a habit name or a
    /// declared name can carry one, both of which are user text, and refusing
    /// the write is the documented answer.
    mutating func string(_ value: String, field: String) throws {
        bytes.append(UInt8(ascii: "\""))
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case "\"":
                bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case "\n":
                bytes.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            default:
                guard !CanonicalBytes.isControl(scalar) else {
                    throw CanonicalEncodingError.controlCharacter(
                        scalar: scalar.value, field: field
                    )
                }
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
    }

    // MARK: canonical-map — `docs/achievement-protocol.md` §6.3

    /// **Keys sorted by UTF-8 byte value, ascending.** Values emitted per §2.3.
    ///
    /// Byte-wise rather than by `String`'s `<`, which is Unicode-canonical
    /// ordering and depends on the collation tables shipped with the OS. A
    /// verifier recomputing this in three years has to sort identically, and the
    /// only ordering that is a property of the data rather than of the platform is
    /// the one over the encoded bytes. It is the same rule ``StringBacked``
    /// already applies to ``DeviceID``, for the same reason.
    ///
    /// **It is total over ``JSONValue``, including the array, object and null
    /// cases that §3.4 forbids the engine from writing into `facts`.** That is
    /// deliberate: this encoder is also how a bundle received *from someone else*
    /// is re-encoded to check its digest, and a writer that refuses to spell a
    /// value cannot check the record that contains it. Restricting what goes in
    /// is the engine's job; spelling what is there is this one's.
    static func map(_ values: [String: JSONValue], field: String) throws -> Data {
        var out = CanonicalBytes()
        out.open()
        let keys = values.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for (index, key) in keys.enumerated() {
            if index > 0 { out.comma() }
            try out.string(key, field: "\(field) key")
            out.colon()
            try out.value(values[key] ?? .null, field: "\(field).\(key)")
        }
        out.close()
        return out.data
    }

    static func map(_ values: [FactKey: JSONValue], field: String) throws -> Data {
        var byName: [String: JSONValue] = [:]
        for (key, value) in values { byName[key.rawValue] = value }
        return try map(byName, field: field)
    }

    /// One ``JSONValue``, per §2.3. There is no floating-point path because the
    /// type has no floating-point case and one must not be added.
    private mutating func value(_ value: JSONValue, field: String) throws {
        switch value {
        case .string(let text): try string(text, field: field)
        case .int(let number): int(number)
        case .bool(let flag): bool(flag)
        case .null: null()
        case .array(let items):
            openArray()
            for (index, item) in items.enumerated() {
                if index > 0 { comma() }
                try self.value(item, field: field)
            }
            closeArray()
        case .object(let nested):
            // The same sorted-key rule applies at every depth. A nested object
            // whose keys kept their dictionary order would make the digest of one
            // record depend on Foundation's hash seed.
            try append(CanonicalBytes.map(nested, field: field))
        }
    }
}

/// Why an event could not be canonicalised.
///
/// The offending **value is deliberately not carried** — only which field it was
/// in. An error is a string that gets logged, printed and pasted into an issue,
/// and the two fields that can produce this are a habit name and the declared
/// name of the person the record is about. `docs/achievement-protocol.md` §3.4
/// goes to real lengths to keep those out of anything that travels; an error
/// message is somewhere they can travel.
public enum CanonicalEncodingError: Error, Hashable, Sendable {
    /// A control character the escaping rules refuse to represent.
    /// `docs/achievement-protocol.md` §6.3.
    case controlCharacter(scalar: UInt32, field: String)
}
