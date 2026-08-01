import CompassDomain
import Foundation

/// Every string on the certificate, and the rule about where each one may come
/// from. `docs/achievement-protocol.md` §9 Invariant 8, `.claude/skills/ui.md`.
///
/// It is a plain value beside the view, not `@State` inside it, for the reason
/// `.claude/skills/architecture.md` states as measured rather than aesthetic:
/// two data bugs once sat in three `@State` properties in `SettingsView` and
/// **both survived a suite of 206 tests**. What the certificate *says* is exactly
/// the kind of thing that must be testable, because the whole product is a claim
/// that what it says is true.
///
/// ### Invariant 8, which is why nothing here reads `titleKey`
///
/// > A verifier, and the certificate view when showing a record it did not itself
/// > produce, MUST draw display text only from **digest-covered** fields —
/// > `rule.id`, `rule.kind`, `rule.threshold`, `rule.scope`, `earnedOn`, `facts`
/// > and `witness`. A title is rendered *from the rule*, not from `titleKey`.
///
/// On a bundle received from someone else, every field outside the digest is
/// attacker-controllable while the signature still verifies. `titleKey` and
/// `fallbackTitle` are outside it — deliberately, so a typo stays correctable
/// forever — so a forged bundle could otherwise render an arbitrary title under a
/// valid signature and a genuine Bitcoin anchor. Every line below is built from
/// `kind`, `threshold`, `scope`, `earnedOn`, `facts` and `witness`, and from the
/// digest itself.
///
/// ### The one exception, and why it is not one
///
/// The habit's **display name** is not in the digest and cannot be: §3.4 keeps it
/// out on purpose, because a name frozen into a signed, anchored, shareable
/// record can never be taken back. It is resolved at render time from the mutable
/// local mapping that travels in the export bundle as `habits.json`, keyed by the
/// `habitID` that **is** in the digest. So what is verified is the identifier, and
/// what is displayed is the current name for it — which is exactly the
/// reveal-the-preimage control ADR 0004 uses on-chain.
public struct CertificateCopy: Hashable, Sendable {

    /// "Record" — one word. "Attested record" was cut in the design's own words:
    /// **"attested" claimed a third party that does not exist.**
    public static let masthead = "Record"

    /// One line for an unscoped rule, two for a habit-scoped one.
    public let claimLines: [String]

    /// "Attained 14 March 2026."
    public let date: String

    /// One line normally. It gains a line, and never moves anything.
    public let attestationLines: [String]

    /// Four lines. The **full 64-hex digest**, wrapped at 32 characters, because
    /// "sixteen hex characters verify nothing" — the truncated hash the design
    /// first drew invited a verification it could not support.
    public let identifierLines: [String]

    public init(
        achievement: Achievement,
        digest: Data,
        names: [HabitID: String],
        attestation: Attestation?,
        now: Date
    ) {
        claimLines = CertificateCopy.claim(for: achievement, names: names)
        date = "Attained \(CertificateCopy.long(achievement.earnedOn))."
        attestationLines = CertificateCopy.attestation(attestation, now: now)
        identifierLines = CertificateCopy.identifier(achievement, digest: digest)
    }

    // MARK: The claim

    /// Rendered **from the rule**, never from `titleKey`.
    ///
    /// - `streak` reads "100 consecutive days."
    /// - `total` reads "1,000 days recorded." — the same words the number on
    ///   Today uses, because it counts the same thing.
    ///
    /// A habit-scoped rule gains a second line naming the habit. An unscoped rule
    /// has no second line rather than an invented one: the design's examples are
    /// all habit-scoped, and the shipped `total` rules are not, so the honest
    /// answer for those is one line and a shorter block. The layout reflows.
    static func claim(for achievement: Achievement, names: [HabitID: String]) -> [String] {
        let count = grouped(achievement.rule.threshold)
        let headline =
            achievement.rule.kind == .streak
            ? "\(count) consecutive days."
            : "\(count) days recorded."

        guard let habit = achievement.rule.scope.habit else { return [headline] }
        // The mapping is the authority; the identifier is the fallback. A habit
        // whose name is missing renders its own ID rather than a blank line —
        // the record is still complete, and an empty line would read as a
        // rendering failure rather than as a missing name.
        return [headline, "\(names[habit] ?? habit.rawValue)."]
    }

    // MARK: The attestation

    /// **`.claude/skills/ui.md` lines 48–50 fix these strings literally**, and it
    /// is frozen:
    ///
    /// > It shows **"Sealed on this device"** immediately, and keeps saying
    /// > exactly that until `AnchorState` is `confirmed`, at which point it reads
    /// > **"Sealed on this device · Anchored <date>"**.
    ///
    /// The design renders two separate sentences with full stops instead, and a
    /// third turn renders them as one continuous sentence — three treatments
    /// across one bundle, none of them `ui.md`'s. `ui.md` wins.
    /// `memory/decisions.md`, 2026-08-01.
    ///
    /// **Anchoring language is never rendered before `confirmed`.** Not on
    /// `submitted`, which only means bytes were sent: a fresh OpenTimestamps
    /// submission is an incomplete proof, and a certificate claiming Bitcoin
    /// permanence it does not have, in an app forbidden to correct it, is worse
    /// than one claiming less.
    static func attestation(_ attestation: Attestation?, now: Date) -> [String] {
        var lines = [sealedLine(attestation)]
        if let attestation, hasFailedTooLong(attestation, now: now) {
            lines.append(anchoringDidNotComplete)
        }
        return lines
    }

    static let sealedOnThisDevice = "Sealed on this device"

    /// **The state `ui.md` lines 66–70 require and no turn of the design ever
    /// drew.** If an achievement has been `failed` for more than 30 days, that is
    /// said **once**, here, in the certificate's own detail area — "so permanent
    /// failure is discoverable rather than structurally unsayable".
    ///
    /// The string is new: nothing in the corpus supplies one, so it is written in
    /// the certificate's register — plain declarative, past tense, no second
    /// person, no offer to fix, no colour and no icon. Reported in
    /// `memory/decisions.md` rather than smuggled in.
    ///
    /// It cannot fire before week 4, because nothing submits anything yet. The
    /// slot exists now because building the layout without it would make the rule
    /// unimplementable later without reworking the layout.
    static let anchoringDidNotComplete = "Anchoring did not complete."

    static let anchoringFailureGrace: TimeInterval = 30 * 24 * 60 * 60

    private static func sealedLine(_ attestation: Attestation?) -> String {
        guard let attestation, attestation.state == .confirmed,
              let confirmed = attestation.confirmedAt
        else { return sealedOnThisDevice }
        return "\(sealedOnThisDevice) · Anchored \(long(confirmed))"
    }

    private static func hasFailedTooLong(_ attestation: Attestation, now: Date) -> Bool {
        guard attestation.state == .failed, let since = attestation.submittedAt else {
            return false
        }
        return now.timeIntervalSince(since) > anchoringFailureGrace
    }

    // MARK: The identifier block

    /// Four monospaced lines:
    ///
    /// ```
    /// streak.habit-a.100@2026-03-14
    /// sha-256 8f2c94a1d0e7a91d3b6045c2e8f17a90
    ///         5c14d9e0a26b78f3419dcb0e6a2f8d51
    /// First day 2025-12-05 · 100 days recorded live
    /// ```
    ///
    /// The digest is printed **in full**, wrapped at 32 characters, and the third
    /// line's eight-space indent is exactly the width of `"sha-256 "` — which is
    /// why the block is monospaced and why line 3 aligns under line 2's first hex
    /// character.
    ///
    /// The always-zero `0 backfilled` field is **deleted from display**.
    /// `source_backfill` stays inside the digest, where §3.4 requires it; it is
    /// simply not printed, because a field that can only ever say one thing is
    /// noise on a document with four lines of small print.
    static func identifier(_ achievement: Achievement, digest: Data) -> [String] {
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let head = String(hex.prefix(32))
        let tail = String(hex.dropFirst(32))

        var lines = [
            achievement.id.rawValue,
            "sha-256 \(head)",
            String(repeating: " ", count: 8) + tail,
        ]

        var last = "First day \(achievement.witness.firstDay.iso)"
        if case .int(let live)? = achievement.facts[.sourceLive] {
            last += " · \(grouped(live)) days recorded live"
        }
        lines.append(last)
        return lines
    }

    // MARK: The certificate list

    /// One row in the list inside the settings sheet. Plain reverse-chronological
    /// rows, **no "new" indicator** — a "new" badge is a re-engagement affordance
    /// and badges are banned.
    public static func listTitle(
        for achievement: Achievement, names: [HabitID: String]
    ) -> String {
        claim(for: achievement, names: names)
            .map { String($0.dropLast()) }  // the sentence full stops
            .joined(separator: " — ")
    }

    public static func listSubtitle(for achievement: Achievement) -> String {
        long(achievement.earnedOn)
    }

    /// **The revoked row keeps its place.** No colour, no icon, no offer to fix.
    /// You never erase a published entry; you post a reversal.
    public static let revokedSubtitle = "Revoked — a day it depended on was edited."
    public static let revokedTag = "Revoked"

    // MARK: Formatting

    /// "14 March 2026". English month names, from ``Day``'s civil components —
    /// **not** `DateFormatter`, which is locale-dependent, and not `Calendar`,
    /// which `Day` exists to avoid. The certificate's whole copy register is fixed
    /// English ("Attained", "Sealed on this device"), so a date that switched
    /// language while the sentence around it did not would be worse than one that
    /// did not switch at all.
    static func long(_ day: Day) -> String {
        "\(day.day) \(monthNames[day.month - 1]) \(day.year)"
    }

    static func long(_ date: Date) -> String {
        // The only place in `CompassUI` a `Date` becomes a civil date. It is an
        // anchor confirmation time, which arrives from a Bitcoin block and is a
        // genuine instant rather than a civil day, so there is nothing to read
        // from `Day`.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else {
            return ""
        }
        return "\(dayOfMonth) \(monthNames[month - 1]) \(year)"
    }

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// "1,000". Grouped by hand rather than by `NumberFormatter`, for the same
    /// reason the month names are: this document's copy is fixed English, and a
    /// grouping separator that followed the device locale would put a full stop
    /// inside a number in a sentence that ends with one.
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(abs(value)))
        var out: [Character] = []
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index).isMultiple(of: 3) { out.append(",") }
            out.append(digit)
        }
        return (value < 0 ? "-" : "") + String(out)
    }
}
