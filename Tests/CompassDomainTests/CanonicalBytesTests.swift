import Foundation
import Testing

@testable import CompassDomain

/// The canonical byte encoding and `content_hash`. `docs/technical.md` §3,
/// `docs/achievement-protocol.md` §6.3, `docs/technical.md` §9.7.
///
/// **This format cannot be changed later.** Everything downstream — `prev`
/// chaining, `witness.evidenceRoot`, `witness.logHeads`, the signature, the
/// Bitcoin anchor — is computed over these exact bytes. If a test in this suite
/// ever needs updating, something irreversible has happened; stop and find out
/// what.
@Suite("Canonical bytes — the form that cannot be changed later")
struct CanonicalBytesTests {

    // MARK: The fixture the whole suite is pinned to

    /// A fixed event, every field set to a value that is nothing else's default.
    ///
    /// `prev` is `00 01 02 … 1F` rather than genesis so that the base64 in the
    /// expected string below is a value with structure in it: a run of zeroes
    /// would encode to a run of `A`s and a truncation or a doubling inside it
    /// would be invisible to a reader checking the literal by eye.
    static let fixture = Event(
        id: UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!,
        device: DeviceID(rawValue: "11111111-1111-4111-8111-111111111111"),
        lamport: 7,
        kind: .checkedIn,
        day: Day(year: 2026, month: 7, day: 31),
        recordedAt: 1_784_000_000_000,
        zoneOffset: 420,
        source: .tap,
        payload: .habit(HabitID(rawValue: "habit-a")),
        prev: Data((0..<32).map { UInt8($0) })
    )

    /// The bytes `docs/technical.md` §3 specifies, written out by hand.
    ///
    /// Transcribed from the document, **not** from the encoder. That is the
    /// whole value of the assertion: if it were captured from a run, it would
    /// pin whatever the code happened to do rather than what the corpus says,
    /// and the first session to reorder a key would simply re-record it.
    static let expectedLine = #"""
        {"v":1,"id":"3F2504E0-4F89-41D3-9A0C-0305E82C3301","device":"11111111-1111-4111-8111-111111111111","lamport":7,"kind":"checkedIn","day":"2026-07-31","recordedAt":1784000000000,"zoneOffset":420,"source":"tap","payload":{"habitID":"habit-a"},"prev":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="}
        """#

    // MARK: Stability

    @Test("A fixed event encodes to exactly the bytes the document specifies")
    func encodesToTheDocumentedForm() throws {
        let bytes = try CanonicalBytesTests.fixture.canonicalBytes
        #expect(String(decoding: bytes, as: UTF8.self) == CanonicalBytesTests.expectedLine)
    }

    @Test("The digest of a fixed event equals a hardcoded hex string")
    func digestIsPinned() throws {
        // Computed outside this project, from the expected line above, by two
        // independent tools that share no code with CryptoKit:
        //
        //   printf '%s' '<the line above>' | shasum -a 256
        //   python3 -c "import hashlib; print(hashlib.sha256(open(0,'rb').read()).hexdigest())"
        //
        // Both give this. A verifier written in three years from
        // `docs/technical.md` §3 alone must reach the same value, and that is
        // exactly what this hex is here to make checkable.
        #expect(
            hex(try CanonicalBytesTests.fixture.contentHash)
                == "1546def10a078a3cd79cbb1eeeca2b6a3fa7f5107601ed5237032507f8a2b709"
        )
    }

    @Test("Encoding the same event twice gives the same bytes")
    func encodingIsStable() throws {
        let once = try CanonicalBytesTests.fixture.canonicalBytes
        let twice = try CanonicalBytesTests.fixture.canonicalBytes
        #expect(once == twice)
    }

    @Test("A round trip through the stored line does not move the digest")
    func survivesTheStoredLine() throws {
        // The on-disk line is **not** required to be byte-identical to the
        // canonical form — `docs/technical.md` §3 says so, it carries `extra`
        // and `JSONEncoder` may order its keys differently on any run. What must
        // hold is that the canonical bytes are derived from the *decoded* event
        // and are therefore immune to that. This is the assertion that makes
        // "nothing may be derived from the byte layout of the line" safe.
        let line = try JSONEncoder().encode(CanonicalBytesTests.fixture)
        let decoded = try JSONDecoder().decode(Event.self, from: line)
        #expect(try decoded.contentHash == CanonicalBytesTests.fixture.contentHash)
    }

    // MARK: The digest covers every semantic field

    @Test("Mutating habitID moves the digest")
    func habitIDIsDigested() throws {
        // The one this whole apparatus exists for. `docs/technical.md` §3: the
        // first version of the canonical form omitted `payload`, so every field
        // saying *which habit an event is about* sat outside the digest —
        // "a hundred-day meditation streak could have been rewritten into a
        // hundred-day reading streak with every proof still checking out,
        // Bitcoin anchor included."
        let rewritten = CanonicalBytesTests.fixture.with(
            payload: .habit(HabitID(rawValue: "habit-b"))
        )
        #expect(try rewritten.contentHash != CanonicalBytesTests.fixture.contentHash)
    }

    @Test("Every field inside the canonical form moves the digest")
    func everySemanticFieldIsDigested() throws {
        let base = CanonicalBytesTests.fixture
        let original = try base.contentHash

        let mutations: [(String, Event)] = [
            ("v", base.with(v: 2)),
            ("id", base.with(id: UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3302")!)),
            ("device", base.with(device: DeviceID(rawValue: "22222222-2222-4222-8222-222222222222"))),
            ("lamport", base.with(lamport: 8)),
            ("kind", base.with(kind: .checkInRevoked)),
            ("day", base.with(day: Day(year: 2026, month: 8, day: 1))),
            ("recordedAt", base.with(recordedAt: 1_784_000_000_001)),
            ("zoneOffset", base.with(zoneOffset: 421)),
            ("source", base.with(source: .widget)),
            ("payload.name", base.with(payload: .habit(HabitID(rawValue: "habit-a"), name: "Move"))),
            ("prev", base.chained(to: Event.genesisPrev)),
        ]

        for (field, mutated) in mutations {
            #expect(try mutated.contentHash != original, "\(field) is outside the digest")
        }

        // And they are all different from each other, not merely from the
        // original — a digest that collapsed two distinct mutations onto one
        // value would pass every assertion above.
        let digests = try Set(mutations.map { try hex($0.1.contentHash) })
        #expect(digests.count == mutations.count)
    }

    @Test("extra and unknown top-level keys are outside the digest, by construction")
    func undigestedBagsAreOutside() throws {
        let base = CanonicalBytesTests.fixture
        let withExtra = base.with(extra: ["clientBuild": .string("1.2.3")])
        let withUnknown = base.with(unknownFields: ["evidence": .object(["sha256": .string("de")])])

        // `docs/technical.md` §3: "an old build cannot hash fields it has never
        // seen. The consequence is identical and must be understood — anything
        // that has to be provable goes in a named field, never in `extra`."
        #expect(try withExtra.contentHash == base.contentHash)
        #expect(try withUnknown.contentHash == base.contentHash)

        // The bags are real and are carried; they are simply not hashed.
        #expect(withExtra != base)
        #expect(withUnknown != base)
    }

    // MARK: The shape of the form

    @Test("An absent source is omitted entirely, never emitted as null")
    func absentSourceIsOmitted() throws {
        // `checkInRevoked` has no source — `docs/technical.md` §3 defines the
        // pair as `checkedIn(habitID, day, source)` and
        // `checkInRevoked(habitID, day)`. Emitting `"source":null` on every
        // un-tap would be an out-of-spec digested field, and once anything is
        // signed it is unfixable.
        let revoked = CanonicalBytesTests.fixture
            .with(kind: .checkInRevoked)
            .withoutSource()
        let line = String(decoding: try revoked.canonicalBytes, as: UTF8.self)

        #expect(!line.contains("source"))
        #expect(!line.contains("null"))
        #expect(line.contains(#""zoneOffset":420,"payload":"#))
    }

    @Test("payload is required, and a kind with no fields of its own emits {}")
    func payloadIsAlwaysPresent() throws {
        let bare = CanonicalBytesTests.fixture.with(payload: .empty)
        let line = String(decoding: try bare.canonicalBytes, as: UTF8.self)
        #expect(line.contains(#""payload":{},"prev":"#))
    }

    @Test("Every kind's payload carries exactly the keys the document freezes, in order")
    func payloadKeyOrderMatchesTheDocument() throws {
        let habit = HabitID(rawValue: "habit-a")
        let award = AchievementID(rawValue: "streak.habit-a.7@2026-07-07")

        // Transcribed from the table in `docs/technical.md` §3.
        let expected: [(EventKind, EventPayload, String)] = [
            (.habitCreated, .habit(habit, name: "Move"), #"{"habitID":"habit-a","name":"Move"}"#),
            (.habitRenamed, .habit(habit, name: "Move"), #"{"habitID":"habit-a","name":"Move"}"#),
            (.habitArchived, .habit(habit), #"{"habitID":"habit-a"}"#),
            (.habitUnarchived, .habit(habit), #"{"habitID":"habit-a"}"#),
            (.checkedIn, .habit(habit), #"{"habitID":"habit-a"}"#),
            (.checkInRevoked, .habit(habit), #"{"habitID":"habit-a"}"#),
            (
                .achievementAwarded, .achievement(award),
                #"{"achievementID":"streak.habit-a.7@2026-07-07"}"#
            ),
            (
                .achievementRevoked, .achievement(award, reason: "edited"),
                #"{"achievementID":"streak.habit-a.7@2026-07-07","reason":"edited"}"#
            ),
            (.subjectNamed, .subject(named: "Farros"), #"{"name":"Farros"}"#),
        ]

        for (kind, payload, form) in expected {
            let bytes = try CanonicalBytesTests.fixture
                .with(kind: kind)
                .with(payload: payload)
                .canonicalBytes
            let line = String(decoding: bytes, as: UTF8.self)
            #expect(line.contains(#""payload":"# + form + #","prev":"#), "\(kind.rawValue)")
        }
    }

    @Test("A kind this build has never seen still encodes, in the same fixed order")
    func unknownKindStillEncodes() throws {
        // `EventKind` is a `RawRepresentable` string precisely so a kind can be
        // added later without a format change. A canonical encoder that switched
        // on the kind would have no branch for one — and would have to invent
        // an ordering that a newer build, which knows the kind, might not agree
        // with. Two builds must produce the same bytes for the same line.
        let future = CanonicalBytesTests.fixture
            .with(kind: EventKind(rawValue: "habitPaused"))
            .with(payload: EventPayload(habitID: HabitID(rawValue: "habit-a"), name: "Move"))
        let line = String(decoding: try future.canonicalBytes, as: UTF8.self)
        #expect(line.contains(#""payload":{"habitID":"habit-a","name":"Move"},"prev":"#))
    }

    @Test("prev is standard base64 with padding")
    func prevIsPaddedBase64() throws {
        // RFC 4648 §4, per `docs/achievement-protocol.md` §6.5. Genesis is 32
        // zero bytes, which is 43 base64 characters plus one pad.
        let genesis = CanonicalBytesTests.fixture.chained(to: Event.genesisPrev)
        let line = String(decoding: try genesis.canonicalBytes, as: UTF8.self)
        #expect(line.hasSuffix(#""prev":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#))
    }

    // MARK: Escaping

    @Test("Only backslash, quote and newline are escaped")
    func escapingIsExactlyThree() throws {
        let named = CanonicalBytesTests.fixture
            .with(kind: .subjectNamed)
            .with(payload: .subject(named: "a\\b\"c\nd"))
        let line = String(decoding: try named.canonicalBytes, as: UTF8.self)
        #expect(line.contains(#"{"name":"a\\b\"c\nd"}"#))
    }

    @Test("Non-ASCII is raw UTF-8, never a \\u escape")
    func nonASCIIIsRaw() throws {
        // Two spellings of one character is two digests for one event. There is
        // no `\u` path, and adding one is the drift §6.3 exists to prevent.
        let named = CanonicalBytesTests.fixture
            .with(kind: .subjectNamed)
            .with(payload: .subject(named: "Café — 日本"))
        let bytes = try named.canonicalBytes
        let line = String(decoding: bytes, as: UTF8.self)

        #expect(line.contains(#"{"name":"Café — 日本"}"#))
        #expect(!line.contains(#"\u"#))
        // The bytes really are UTF-8 rather than something re-encoded on the way
        // out: "é" is C3 A9.
        #expect(bytes.range(of: Data([0xC3, 0xA9])) != nil)
    }

    @Test("A control character is refused at write time rather than escaped")
    func controlCharactersAreRefused() throws {
        // `docs/achievement-protocol.md` §6.3: "any other control character MUST
        // be rejected at write time rather than escaped, so the escaping rules
        // can never drift." Refusing is what keeps the rule finite.
        for scalar in [UInt32(0x00), 0x09, 0x1F, 0x7F, 0x85] {
            let name = "Move" + String(Unicode.Scalar(scalar)!)
            let event = CanonicalBytesTests.fixture
                .with(kind: .subjectNamed)
                .with(payload: .subject(named: name))

            #expect(throws: CanonicalEncodingError.self) {
                _ = try event.canonicalBytes
            }
        }

        // A newline is not refused — it is one of the three the rules name.
        let newline = CanonicalBytesTests.fixture
            .with(kind: .subjectNamed)
            .with(payload: .subject(named: "Move\nRead"))
        #expect(throws: Never.self) { _ = try newline.canonicalBytes }
    }

    @Test("The refusal names the field and never the value")
    func refusalDoesNotCarryUserText() throws {
        // An error is a string that gets logged, printed and pasted into an
        // issue. `docs/achievement-protocol.md` §3.4 goes to real lengths to
        // keep a habit name — a recovery programme, a medical routine, a therapy
        // task — out of anything that travels, and an error message travels.
        let event = CanonicalBytesTests.fixture
            .with(kind: .habitCreated)
            .with(payload: .habit(HabitID(rawValue: "habit-a"), name: "Therapy\u{7}"))

        do {
            _ = try event.canonicalBytes
            Issue.record("a control character must be refused")
        } catch let error as CanonicalEncodingError {
            #expect(error == .controlCharacter(scalar: 0x07, field: "payload.name"))
            #expect(!"\(error)".contains("Therapy"))
        }
    }
}
