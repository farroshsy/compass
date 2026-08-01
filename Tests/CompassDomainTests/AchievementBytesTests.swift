import CryptoKit
import Foundation
import Testing

@testable import CompassDomain

/// The achievement canonical form and the signing convention.
/// `docs/achievement-protocol.md` §6, `docs/technical.md` §9.7,
/// `.claude/skills/testing.md`.
///
/// **The event half of this landed in week 1b** — `CanonicalBytesTests` — and
/// this is the achievement half it was called the pattern for. The same rule
/// applies with the same force: **if a test in this suite ever needs updating,
/// something irreversible has happened.** Everything downstream is computed over
/// these exact bytes: the digest, the P-256 signature, the OpenTimestamps
/// submission, and eventually a Bitcoin block.
@Suite("The achievement canonical form, and what is signed")
struct AchievementBytesTests {

    // MARK: The fixture the suite is pinned to

    /// A fixed achievement, chosen so that every branch of the encoder is on the
    /// path: a habit-scoped rule (so `scope.habit` is present), three optional
    /// integers that are `nil` (so the omit-never-null rule is exercised), five
    /// fact keys that do **not** sort in the order they are written in, and two
    /// writers in `logHeads` (so the byte-wise key sort has something to do).
    ///
    /// `version`, `titleKey` and `fallbackTitle` are set to values nothing else
    /// uses. §6.2 omits all three from the digest, and
    /// ``ruleDisplayFieldsAreNotInTheDigest`` is what holds that true.
    static let fixture = Achievement(
        id: AchievementID(rawValue: "streak.habit-a.100@2026-03-14"),
        rule: RuleSpec(
            id: RuleID(rawValue: "streak.habit-a.100"),
            version: 3,
            kind: .streak,
            scope: Scope(habit: HabitID(rawValue: "habit-a")),
            threshold: 100,
            titleKey: "rule.streak.100",
            fallbackTitle: "100 consecutive days"
        ),
        earnedOn: Day(year: 2026, month: 3, day: 14),
        // Not in the digest. A value far from `earnedOn`, so that a mistake
        // putting it in would be obvious rather than plausible.
        detectedAt: Date(timeIntervalSince1970: 1_800_000_000),
        facts: [
            .streak: .int(100),
            .habitID: .string("habit-a"),
            .from: .string("2025-12-05"),
            .sourceLive: .int(100),
            .sourceBackfill: .int(0),
        ],
        witness: Witness(
            firstDay: Day(year: 2025, month: 12, day: 5),
            lastDay: Day(year: 2026, month: 3, day: 14),
            dayCount: 100,
            // `00 01 … 1F` rather than a run of zeroes, so a truncation or a
            // doubling inside the base64 below is visible to a reader.
            evidenceRoot: Data((0x00..<0x20).map { UInt8($0) }),
            logHeads: [
                "22222222-2222-4222-8222-222222222222": Data((0x40..<0x60).map { UInt8($0) }),
                "11111111-1111-4111-8111-111111111111": Data((0x20..<0x40).map { UInt8($0) }),
            ]
        ),
        extra: ["somethingNewer": .string("preserved, never digested")]
    )

    /// The bytes `docs/achievement-protocol.md` §6.1–§6.5 specify, **written out
    /// by hand from the document** rather than captured from the encoder.
    ///
    /// That is the whole value of the assertion. A string captured from a run
    /// pins whatever the code happens to do, and the first session to reorder a
    /// key simply re-records it; a string transcribed from the document pins the
    /// document, which is what a stranger's verifier will be written from.
    static let expectedLine = #"""
        {"v":1,"id":"streak.habit-a.100@2026-03-14","rule":{"id":"streak.habit-a.100","kind":"streak","scope":{"habit":"habit-a","requiresAll":false},"threshold":100,"neutralDaysBridge":false,"repeatPolicy":"once"},"earnedOn":"2026-03-14","facts":{"from":"2025-12-05","habitID":"habit-a","source_backfill":0,"source_live":100,"streak":100},"witness":{"firstDay":"2025-12-05","lastDay":"2026-03-14","dayCount":100,"evidenceRoot":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","logHeads":{"11111111-1111-4111-8111-111111111111":"ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=","22222222-2222-4222-8222-222222222222":"QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8="}}}
        """#

    // MARK: Stability

    @Test("A fixed achievement encodes to exactly the bytes the protocol specifies")
    func encodesToTheDocumentedForm() throws {
        let bytes = try AchievementBytesTests.fixture.canonicalBytes
        #expect(String(decoding: bytes, as: UTF8.self) == AchievementBytesTests.expectedLine)
    }

    @Test("The digest of a fixed achievement equals a hardcoded hex string")
    func digestIsPinned() throws {
        // Computed outside this project, from the expected line above, by two
        // tools that share no code with CryptoKit:
        //
        //   printf '%s' '<the line above>' | shasum -a 256
        //   python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"
        //
        // Both give this. A verifier written in three years from §6 alone must
        // reach the same value, and that is exactly what this hex makes checkable.
        #expect(
            hex(try AchievementBytesTests.fixture.digest)
                == "ce97c40a3d3a3108bf14cfb7d21811800a00be12d6c2443a894134d6bfd5f7aa"
        )
    }

    @Test("Encoding the same achievement twice gives the same bytes")
    func encodingIsStable() throws {
        #expect(
            try AchievementBytesTests.fixture.canonicalBytes
                == AchievementBytesTests.fixture.canonicalBytes
        )
    }

    @Test("A round trip through the stored line does not move the digest")
    func survivesTheStoredLine() throws {
        // `awards.jsonl` is written with `JSONEncoder`, whose key order is a
        // Foundation implementation detail. The canonical bytes are derived from
        // the **decoded** record, which is what makes that safe.
        let line = try JSONEncoder().encode(AchievementBytesTests.fixture)
        let decoded = try JSONDecoder().decode(Achievement.self, from: line)
        #expect(try decoded.digest == AchievementBytesTests.fixture.digest)
        #expect(decoded.extra == AchievementBytesTests.fixture.extra)
    }

    // MARK: What is and is not covered

    /// Every semantic field, one mutation each, and no two mutations collapsing
    /// onto one digest. `.claude/skills/testing.md`.
    @Test("Every digested field changes the digest, and no two changes collide")
    func digestCoversEverySemanticField() throws {
        let base = AchievementBytesTests.fixture
        var digests: [String: String] = [:]

        func record(_ name: String, _ mutated: Achievement) throws {
            digests[name] = hex(try mutated.digest)
        }

        try record("baseline", base)
        try record("id", base.with(id: AchievementID(rawValue: "streak.habit-a.100@2026-03-15")))
        try record("earnedOn", base.with(earnedOn: Day(year: 2026, month: 3, day: 15)))
        try record("rule.id", base.with(rule: base.rule.with(id: RuleID(rawValue: "other"))))
        try record("rule.kind", base.with(rule: base.rule.with(kind: .total)))
        try record("rule.threshold", base.with(rule: base.rule.with(threshold: 101)))
        try record(
            "rule.scope.habit",
            base.with(rule: base.rule.with(scope: Scope(habit: HabitID(rawValue: "habit-b"))))
        )
        try record(
            "rule.scope.requiresAll",
            base.with(rule: base.rule.with(scope: Scope(habit: nil, requiresAll: true)))
        )
        try record("rule.window", base.with(rule: base.rule.with(window: 7)))
        try record("rule.requires", base.with(rule: base.rule.with(requires: 5)))
        try record(
            "rule.maxBackfillLagDays", base.with(rule: base.rule.with(maxBackfillLagDays: 3))
        )
        try record(
            "rule.neutralDaysBridge", base.with(rule: base.rule.with(neutralDaysBridge: true))
        )
        try record(
            "rule.repeatPolicy", base.with(rule: base.rule.with(repeatPolicy: .everyOccurrence))
        )
        try record(
            "rule.members", base.with(rule: base.rule.with(members: [RuleID(rawValue: "a")]))
        )

        var facts = base.facts
        facts[.streak] = .int(101)
        try record("facts.streak", base.with(facts: facts))
        facts = base.facts
        facts[.habitID] = .string("habit-b")
        try record("facts.habitID", base.with(facts: facts))
        facts = base.facts
        facts[.sourceBackfill] = .int(1)
        try record("facts.source_backfill", base.with(facts: facts))

        let witness = base.witness
        try record(
            "witness.firstDay",
            base.with(
                witness: Witness(
                    firstDay: witness.firstDay.adding(1), lastDay: witness.lastDay,
                    dayCount: witness.dayCount, evidenceRoot: witness.evidenceRoot,
                    logHeads: witness.logHeads
                )
            )
        )
        try record(
            "witness.dayCount",
            base.with(
                witness: Witness(
                    firstDay: witness.firstDay, lastDay: witness.lastDay,
                    dayCount: witness.dayCount + 1, evidenceRoot: witness.evidenceRoot,
                    logHeads: witness.logHeads
                )
            )
        )
        try record(
            "witness.evidenceRoot",
            base.with(
                witness: Witness(
                    firstDay: witness.firstDay, lastDay: witness.lastDay,
                    dayCount: witness.dayCount,
                    evidenceRoot: Data(repeating: 0xAB, count: 32),
                    logHeads: witness.logHeads
                )
            )
        )
        var heads = witness.logHeads
        heads["11111111-1111-4111-8111-111111111111"] = Data(repeating: 0x99, count: 32)
        try record(
            "witness.logHeads",
            base.with(
                witness: Witness(
                    firstDay: witness.firstDay, lastDay: witness.lastDay,
                    dayCount: witness.dayCount, evidenceRoot: witness.evidenceRoot,
                    logHeads: heads
                )
            )
        )

        #expect(Set(digests.values).count == digests.count, "two mutations share one digest")
    }

    /// §6.2 omits `version`, `titleKey` and `fallbackTitle` "and therefore
    /// freely correctable forever". §3.3 and §3.5 omit `detectedAt` and `extra`.
    ///
    /// This is the assertion that makes `docs/achievement-protocol.md` §5.2's
    /// benefit real — a typo correctable without breaking a single anchor — and
    /// it is also what makes Invariant 8 necessary, which is why
    /// `CertificateCopy` renders from the rule and never from `titleKey`.
    @Test("Display fields, detectedAt and extra are outside the digest")
    func ruleDisplayFieldsAreNotInTheDigest() throws {
        let base = AchievementBytesTests.fixture
        let expected = try base.digest

        #expect(try base.with(rule: base.rule.with(version: 99)).digest == expected)
        #expect(try base.with(rule: base.rule.with(titleKey: "anything")).digest == expected)
        #expect(
            try base.with(rule: base.rule.with(fallbackTitle: "A forged title")).digest
                == expected
        )
        #expect(
            try base.with(rule: base.rule.with(extra: ["x": .int(1)])).digest == expected
        )
        #expect(
            try base.with(detectedAt: Date(timeIntervalSince1970: 0)).digest == expected
        )
        #expect(try base.with(extra: [:]).digest == expected)
    }

    /// §6.2 and §6.4: "Optional fields that are `nil` are omitted entirely, never
    /// emitted as `null`."
    @Test("A nil optional is omitted, never written as null")
    func nilOptionalsAreOmitted() throws {
        let unscoped = AchievementBytesTests.fixture.with(
            rule: AchievementBytesTests.fixture.rule.with(scope: Scope())
        )
        let text = String(decoding: try unscoped.canonicalBytes, as: UTF8.self)
        #expect(!text.contains("null"))
        #expect(text.contains(#""scope":{"requiresAll":false}"#))
    }

    /// §6.3: keys sorted by **UTF-8 byte value**, ascending — not by `String`'s
    /// `<`, which is Unicode-canonical ordering and depends on the collation
    /// tables shipped with the OS.
    @Test("Fact keys are sorted by UTF-8 byte value, not by dictionary order")
    func factKeysAreSortedByBytes() throws {
        let text = String(
            decoding: try AchievementBytesTests.fixture.canonicalBytes, as: UTF8.self
        )
        let facts = #""facts":{"from":"2025-12-05","habitID":"habit-a","#
            + #""source_backfill":0,"source_live":100,"streak":100}"#
        #expect(text.contains(facts))
    }

    @Test("logHeads are sorted byte-wise, whatever order the dictionary is built in")
    func logHeadsAreSorted() throws {
        let text = String(
            decoding: try AchievementBytesTests.fixture.canonicalBytes, as: UTF8.self
        )
        let first = text.range(of: "11111111-1111-4111-8111-111111111111")
        let second = text.range(of: "22222222-2222-4222-8222-222222222222")
        #expect(first != nil && second != nil)
        #expect(first!.lowerBound < second!.lowerBound)
    }

    // MARK: The signing convention — §6.7

    /// **The half of §9.7 that week 1b could not write, because there was no
    /// key.** `.claude/skills/testing.md`: "a signature made over
    /// `canonicalBytes` verifies against `canonicalBytes` and **fails** against
    /// `digest`. That second assertion is what catches a future session
    /// reintroducing the inherited double hash."
    ///
    /// It is here, in the pure suite, against a plain `P256.Signing.PrivateKey`
    /// rather than against `Signer`, because the convention is a property of the
    /// *bytes* rather than of where the key is kept. `SignerTests` covers the
    /// key.
    @Test("A signature is made over canonicalBytes, and fails against the digest")
    func signsCanonicalBytesAndNotTheDigest() throws {
        let key = P256.Signing.PrivateKey()
        let bytes = try AchievementBytesTests.fixture.canonicalBytes
        let digest = try AchievementBytesTests.fixture.digest

        // CORRECT — the `DataProtocol` overload hashes its argument once, so the
        // signed message is `SHA-256(canonicalBytes)`, which *is* `digest`.
        let signature = try key.signature(for: bytes)

        #expect(key.publicKey.isValidSignature(signature, for: bytes))

        // The inherited `Signer.sign(_ text:)` hashes first and then hands the
        // hash to the same overload, signing `SHA-256(SHA-256(text))`. If that
        // ever comes back, this expectation flips: verification against the
        // digest would start succeeding.
        #expect(!key.publicKey.isValidSignature(signature, for: digest))

        // And the mirror: signing the digest does not verify against the bytes.
        let doubleHashed = try key.signature(for: digest)
        #expect(!key.publicKey.isValidSignature(doubleHashed, for: bytes))
    }
}

// MARK: - Field-at-a-time copies, for the mutation tests

extension Achievement {
    func with(
        id: AchievementID? = nil,
        rule: RuleSpec? = nil,
        earnedOn: Day? = nil,
        detectedAt: Date? = nil,
        facts: [FactKey: JSONValue]? = nil,
        witness: Witness? = nil,
        extra: [String: JSONValue]? = nil
    ) -> Achievement {
        Achievement(
            id: id ?? self.id,
            rule: rule ?? self.rule,
            earnedOn: earnedOn ?? self.earnedOn,
            detectedAt: detectedAt ?? self.detectedAt,
            facts: facts ?? self.facts,
            witness: witness ?? self.witness,
            extra: extra ?? self.extra
        )
    }
}

extension RuleSpec {
    func with(
        id: RuleID? = nil,
        version: Int? = nil,
        kind: RuleKind? = nil,
        scope: Scope? = nil,
        threshold: Int? = nil,
        window: Int? = nil,
        requires: Int? = nil,
        maxBackfillLagDays: Int? = nil,
        neutralDaysBridge: Bool? = nil,
        repeatPolicy: RepeatPolicy? = nil,
        members: [RuleID]? = nil,
        titleKey: String? = nil,
        fallbackTitle: String? = nil,
        extra: [String: JSONValue]? = nil
    ) -> RuleSpec {
        RuleSpec(
            id: id ?? self.id,
            version: version ?? self.version,
            kind: kind ?? self.kind,
            scope: scope ?? self.scope,
            threshold: threshold ?? self.threshold,
            window: window ?? self.window,
            requires: requires ?? self.requires,
            maxBackfillLagDays: maxBackfillLagDays ?? self.maxBackfillLagDays,
            neutralDaysBridge: neutralDaysBridge ?? self.neutralDaysBridge,
            repeatPolicy: repeatPolicy ?? self.repeatPolicy,
            members: members ?? self.members,
            titleKey: titleKey ?? self.titleKey,
            fallbackTitle: fallbackTitle ?? self.fallbackTitle,
            extra: extra ?? self.extra
        )
    }
}
