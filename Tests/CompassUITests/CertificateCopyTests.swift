import CompassDomain
import Foundation
import Testing

@testable import CompassUI

/// What the certificate **says**. `.claude/skills/ui.md`,
/// `docs/achievement-protocol.md` §7.2 and §9 Invariant 8.
///
/// This is the highest-value suite in `CompassUITests` and the reason the copy is
/// a plain value rather than string literals inside a `View`: the entire product
/// is a claim that what this document says is true, and
/// `.claude/skills/testing.md` refuses the snapshot tests that would otherwise be
/// the only thing looking at it.
@Suite("What the certificate says")
struct CertificateCopyTests {

    // MARK: Fixtures

    static let names: [HabitID: String] = [habitA: "Meditate", habitB: "Read"]

    static func achievement(
        kind: RuleKind = .streak,
        threshold: Int = 100,
        habit: HabitID? = habitA,
        earnedOn: String = "2026-03-14",
        firstDay: String = "2025-12-05",
        sourceLive: Int? = 100
    ) -> Achievement {
        let rule = RuleSpec(
            id: RuleID(rawValue: "\(kind.rawValue).\(habit?.rawValue ?? "recorded").\(threshold)"),
            kind: kind,
            scope: Scope(habit: habit),
            threshold: threshold
        )
        var facts: [FactKey: JSONValue] = [
            kind == .streak ? .streak : .total: .int(threshold),
            .from: .string(firstDay),
            .sourceBackfill: .int(0),
        ]
        if let habit { facts[.habitID] = .string(habit.rawValue) }
        if let sourceLive { facts[.sourceLive] = .int(sourceLive) }

        return Achievement(
            id: AchievementID(rule: rule.id, earnedOn: day(earnedOn)),
            rule: rule,
            earnedOn: day(earnedOn),
            detectedAt: instant("2026-03-14T12:00:00+07:00"),
            facts: facts,
            witness: Witness(
                firstDay: day(firstDay), lastDay: day(earnedOn), dayCount: threshold,
                evidenceRoot: Data(repeating: 0x8F, count: 32), logHeads: [:]
            )
        )
    }

    static func copy(
        _ achievement: Achievement,
        attestation: Attestation? = nil,
        now: Date = instant("2026-03-14T12:00:00+07:00"),
        names: [HabitID: String] = CertificateCopyTests.names
    ) -> CertificateCopy {
        CertificateCopy(
            achievement: achievement,
            digest: Data((0..<32).map { UInt8($0) }),
            names: names,
            attestation: attestation,
            now: now
        )
    }

    static func attestation(
        _ state: AnchorState,
        submittedAt: Date? = nil,
        confirmedAt: Date? = nil
    ) -> Attestation {
        Attestation(
            achievement: AchievementID(rawValue: "streak.habit-a.100@2026-03-14"),
            publicKey: Data([1]), signature: Data([2]), backing: .secureEnclave,
            state: state, submittedAt: submittedAt, confirmedAt: confirmedAt
        )
    }

    // MARK: The claim

    @Test("A streak reads as consecutive days, and names the habit on a second line")
    func streakClaim() {
        let copy = CertificateCopyTests.copy(CertificateCopyTests.achievement())
        #expect(copy.claimLines == ["100 consecutive days.", "Meditate."])
    }

    @Test("A thousand is grouped, and the grouping does not follow the device locale")
    func thousandsAreGrouped() {
        let copy = CertificateCopyTests.copy(
            CertificateCopyTests.achievement(kind: .total, threshold: 1000, habit: nil)
        )
        #expect(copy.claimLines == ["1,000 days recorded."])
    }

    /// The shipped `total` rules are all-habit — `docs/technical.md` §5 — so they
    /// have no habit to name. One line is the honest answer; an invented second
    /// line would be copy nobody wrote.
    @Test("An unscoped rule has one line, not an invented second one")
    func unscopedClaimHasOneLine() {
        let copy = CertificateCopyTests.copy(
            CertificateCopyTests.achievement(kind: .total, threshold: 100, habit: nil)
        )
        #expect(copy.claimLines.count == 1)
    }

    /// **B5's rendering rule, resolved.** The habit's name is resolved from the
    /// mutable mapping at render time, and the identifier block prints an opaque
    /// rule ID — so a rename changes the claim line and cannot make the two
    /// disagree, because the identifier names no habit at all.
    @Test("A rename changes the claim and leaves the identifier untouched")
    func aRenameCannotMakeTheDocumentContradictItself() {
        let achievement = CertificateCopyTests.achievement()
        let before = CertificateCopyTests.copy(achievement)
        let after = CertificateCopyTests.copy(
            achievement, names: [habitA: "Sitting practice"]
        )

        #expect(before.claimLines[1] == "Meditate.")
        #expect(after.claimLines[1] == "Sitting practice.")
        #expect(before.identifierLines == after.identifierLines)
        #expect(before.identifierLines[0] == "streak.habit-a.100@2026-03-14")
        #expect(!before.identifierLines[0].lowercased().contains("meditate"))
    }

    /// A record whose habit is not in the mapping renders its identifier rather
    /// than a blank line: the record is still complete, and an empty line reads as
    /// a rendering failure rather than as a missing name.
    @Test("A habit with no name renders its identifier, never a blank")
    func aMissingNameFallsBackToTheIdentifier() {
        let copy = CertificateCopyTests.copy(CertificateCopyTests.achievement(), names: [:])
        #expect(copy.claimLines[1] == "habit-a.")
    }

    /// **Invariant 8.** On a bundle received from someone else, every undigested
    /// field is attacker-controllable while the signature still verifies — so a
    /// forged `fallbackTitle` must not be able to put words on a certificate.
    @Test("A forged title on an undigested field cannot reach the certificate")
    func undigestedTitlesAreNeverRendered() {
        let base = CertificateCopyTests.achievement()
        let forged = Achievement(
            id: base.id,
            rule: RuleSpec(
                id: base.rule.id, version: 99, kind: base.rule.kind, scope: base.rule.scope,
                threshold: base.rule.threshold,
                titleKey: "TEN THOUSAND DAYS",
                fallbackTitle: "TEN THOUSAND DAYS"
            ),
            earnedOn: base.earnedOn, detectedAt: base.detectedAt, facts: base.facts,
            witness: base.witness
        )
        let copy = CertificateCopyTests.copy(forged)
        let everything = (copy.claimLines + [copy.date] + copy.attestationLines
            + copy.identifierLines).joined(separator: "\n")
        #expect(!everything.contains("TEN THOUSAND"))
        #expect(copy.claimLines[0] == "100 consecutive days.")
    }

    // MARK: The date

    @Test("The date is a civil day in fixed English, from the digested field")
    func dateReadsAsAttained() {
        #expect(
            CertificateCopyTests.copy(CertificateCopyTests.achievement()).date
                == "Attained 14 March 2026."
        )
    }

    // MARK: The attestation — the honesty rules

    /// `.claude/skills/ui.md` lines 48–50 fix this string literally. The design
    /// renders "Sealed on this device." with a full stop, and elsewhere as two
    /// sentences; `ui.md` is frozen and wins. `memory/decisions.md`, 2026-08-01.
    @Test("A sealed record says exactly what ui.md says, with no full stop")
    func sealedCopyIsExact() {
        let copy = CertificateCopyTests.copy(
            CertificateCopyTests.achievement(),
            attestation: CertificateCopyTests.attestation(.sealed)
        )
        #expect(copy.attestationLines == ["Sealed on this device"])
    }

    /// **The rule this suite exists for.** "Never render anchoring language
    /// before `confirmed`." `submitted` only means bytes were sent, and an
    /// un-upgraded OpenTimestamps proof proves nothing.
    @Test("No anchoring language appears in any state before confirmed")
    func anchoringIsNeverClaimedEarly() {
        for state in AnchorState.allCases where state != .confirmed {
            let copy = CertificateCopyTests.copy(
                CertificateCopyTests.achievement(),
                attestation: CertificateCopyTests.attestation(
                    state,
                    submittedAt: instant("2026-03-15T00:00:00+00:00"),
                    // Even a confirmation timestamp left on a non-confirmed
                    // attestation must not produce the anchored line: the state
                    // is what decides, never the presence of a date.
                    confirmedAt: instant("2026-03-17T00:00:00+00:00")
                ),
                now: instant("2026-03-18T00:00:00+00:00")
            )
            let text = copy.attestationLines.joined(separator: " ").lowercased()
            #expect(!text.contains("anchored"), "\(state) rendered anchoring language")
            #expect(!text.contains("bitcoin"))
        }
    }

    @Test("A record with no attestation at all still says only that it is sealed")
    func noAttestationStillSaysSealed() {
        let copy = CertificateCopyTests.copy(CertificateCopyTests.achievement())
        #expect(copy.attestationLines == ["Sealed on this device"])
    }

    /// **It changes by gaining a line, never by moving anything** — the anchored
    /// form keeps the sealed sentence and extends it.
    @Test("Confirmed gains the anchor on the same line, keeping the sealed clause")
    func confirmedGainsTheAnchorLine() {
        let copy = CertificateCopyTests.copy(
            CertificateCopyTests.achievement(),
            attestation: CertificateCopyTests.attestation(
                .confirmed, confirmedAt: instant("2026-03-17T05:00:00+07:00")
            )
        )
        #expect(copy.attestationLines.count == 1)
        #expect(copy.attestationLines[0].hasPrefix("Sealed on this device · Anchored"))
        #expect(copy.attestationLines[0].contains("March 2026"))
    }

    /// **The state `ui.md` requires and no turn of the design ever drew.** If an
    /// achievement has been `failed` for more than 30 days, say so **once**, here,
    /// "so permanent failure is discoverable rather than structurally unsayable".
    @Test("Anchoring failed for over 30 days is said once, and not before")
    func permanentFailureIsSayable() {
        let submitted = instant("2026-03-15T00:00:00+00:00")

        let quiet = CertificateCopyTests.copy(
            CertificateCopyTests.achievement(),
            attestation: CertificateCopyTests.attestation(.failed, submittedAt: submitted),
            now: submitted.addingTimeInterval(29 * 24 * 3600)
        )
        #expect(quiet.attestationLines == ["Sealed on this device"])

        let escalated = CertificateCopyTests.copy(
            CertificateCopyTests.achievement(),
            attestation: CertificateCopyTests.attestation(.failed, submittedAt: submitted),
            now: submitted.addingTimeInterval(31 * 24 * 3600)
        )
        #expect(
            escalated.attestationLines == [
                "Sealed on this device", "Anchoring did not complete.",
            ]
        )
    }

    // MARK: The identifier block

    /// **The full 64-hex digest, wrapped at 32 characters**, because "sixteen hex
    /// characters verify nothing" — an elided hash in text invites a verification
    /// it cannot support.
    @Test("The whole digest is printed, in two aligned halves")
    func theWholeDigestIsPrinted() {
        let copy = CertificateCopyTests.copy(CertificateCopyTests.achievement())
        #expect(copy.identifierLines.count == 4)
        #expect(copy.identifierLines[0] == "streak.habit-a.100@2026-03-14")
        #expect(copy.identifierLines[1] == "sha-256 000102030405060708090a0b0c0d0e0f")
        #expect(copy.identifierLines[2] == "        101112131415161718191a1b1c1d1e1f")

        // The two halves are the whole 64-hex digest and nothing is missing.
        let printed = copy.identifierLines[1].dropFirst(8)
            + copy.identifierLines[2].trimmingCharacters(in: .whitespaces)
        #expect(printed.count == 64)
    }

    /// The eight-space indent is exactly the width of `"sha-256 "`, which is the
    /// whole reason the block is monospaced.
    @Test("The continuation aligns under the first hex character")
    func theHashHalvesAlign() {
        let copy = CertificateCopyTests.copy(CertificateCopyTests.achievement())
        let prefix = copy.identifierLines[1].prefix(while: { $0 != "0" })
        let indent = copy.identifierLines[2].prefix(while: { $0 == " " })
        #expect(prefix.count == indent.count)
        #expect(indent.count == 8)
    }

    /// The always-zero `0 backfilled` field is deleted **from display only**.
    /// `source_backfill` stays inside the digest, where §3.4 requires it.
    @Test("The last line reports live days and never the always-zero backfill")
    func theLastLineOmitsTheAlwaysZeroField() {
        let copy = CertificateCopyTests.copy(CertificateCopyTests.achievement())
        #expect(copy.identifierLines[3] == "First day 2025-12-05 · 100 days recorded live")
        #expect(!copy.identifierLines[3].contains("backfill"))
        // And it is still sealed, which is the half that matters.
        #expect(CertificateCopyTests.achievement().facts[.sourceBackfill] == .int(0))
    }

    /// A record from elsewhere may not carry the partition. Invariant 8 forbids
    /// substituting an undigested value for it, so the clause is dropped rather
    /// than filled in from `dayCount`.
    @Test("A record with no source partition drops the clause rather than guessing")
    func aMissingPartitionIsNotInvented() {
        let copy = CertificateCopyTests.copy(
            CertificateCopyTests.achievement(sourceLive: nil)
        )
        #expect(copy.identifierLines[3] == "First day 2025-12-05")
    }

    // MARK: The certificate list

    @Test("A list row reads as one line, and a revoked row says what happened")
    func listRows() {
        let achievement = CertificateCopyTests.achievement()
        #expect(
            CertificateCopy.listTitle(for: achievement, names: CertificateCopyTests.names)
                == "100 consecutive days — Meditate"
        )
        #expect(CertificateCopy.listSubtitle(for: achievement) == "14 March 2026")
        #expect(CertificateCopy.revokedSubtitle == "Revoked — a day it depended on was edited.")
    }

    // MARK: The register

    /// Plain declarative, past tense, no second person. **No congratulations, no
    /// next milestone, no progress toward one, and no reason to return** — and
    /// none of the banned gamification vocabulary, anywhere.
    @Test("Nothing on the certificate congratulates, gamifies, or invites a return")
    func theRegisterHolds() {
        let banned = [
            "congratulations", "congrats", "well done", "keep going", "next",
            "you ", "your ", "level", "points", "xp", "badge", "streak!", "rare",
            "unlock", "earned!", "amazing", "great job",
        ]
        for kind in [RuleKind.streak, .total] {
            for state in AnchorState.allCases {
                let copy = CertificateCopyTests.copy(
                    CertificateCopyTests.achievement(kind: kind),
                    attestation: CertificateCopyTests.attestation(
                        state, submittedAt: instant("2026-03-15T00:00:00+00:00"),
                        confirmedAt: instant("2026-03-17T00:00:00+00:00")
                    ),
                    now: instant("2026-06-01T00:00:00+00:00")
                )
                let text = (copy.claimLines + [copy.date] + copy.attestationLines
                    + copy.identifierLines).joined(separator: " ").lowercased()
                for word in banned {
                    #expect(!text.contains(word), "\"\(word)\" is on the certificate")
                }
            }
        }
    }

    /// Three sentences and a footnote. The claim, the date, and the attestation —
    /// and the identifier block, which is the footnote.
    @Test("The document is three sentences and a footnote, and no more")
    func theDocumentStaysShort() {
        let copy = CertificateCopyTests.copy(
            CertificateCopyTests.achievement(),
            attestation: CertificateCopyTests.attestation(.sealed)
        )
        #expect(copy.claimLines.count <= 2)
        #expect(copy.attestationLines.count == 1)
        #expect(copy.identifierLines.count == 4)
    }
}
