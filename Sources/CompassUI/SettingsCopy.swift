import Foundation

/// The sentences the settings sheet says, in one place, so that what the app
/// claims is a thing a test can read.
///
/// Copy is not usually worth extracting. This copy is: every string here makes a
/// claim about what the record can and cannot prove, and the interface is the
/// only place the user ever meets that claim. `.claude/skills/ui.md` puts the
/// rule as **"never render anchoring language before `confirmed`"** — a
/// certificate that claims permanence it does not have, in an app forbidden to
/// correct itself, is worse than one that claims less. The same rule applies to
/// every other claim of a seal, and this file is what makes it checkable.
public enum SettingsCopy {

    /// The two things the habits section does, and the promise under both of
    /// them. Removing is archiving: the control must not read as "delete" while
    /// the system archives.
    public static let habitsFooter = """
        Tap a name to change it — a rename changes the label and nothing else. \
        Removing takes the row off Today; every day it has already recorded \
        stays in the log, and nothing here is ever deleted.
        """

    public static let removedFooter = """
        Kept, with every day they recorded. They do not count towards the four. \
        Restore one to put its row back on Today.
        """

    public static let removedFooterAtCap = """
        Kept, with every day they recorded. Four active habits is the limit, so \
        removing one is what makes room to restore another.
        """

    public static let addFooter =
        "A habit is a name and a boolean per day. Four at a time is the limit."

    public static let addFooterAtCap = "Four at a time is the limit. Remove one to add another."

    /// The name on the record.
    ///
    /// **What this used to say, and why it was false.** It read: "Saving a name
    /// records it in the log, so anything sealed afterwards carries it and it
    /// cannot be changed without breaking the seal. That proves you committed to
    /// this name at the time." Every clause of that is true of week 1b onward and
    /// none of it is true today. There is no `content_hash`, no chain and no
    /// signature in week 1a: every event's `prev` is 32 zero bytes, the log is a
    /// text file, and a name in it can be edited in a text editor with nothing
    /// left to notice. `SettingsTests` asserts both halves — that the chain is
    /// still absent, and that this sentence does not claim one.
    ///
    /// So it says only the two things that are true now: the name is written into
    /// the log beside the record, and nothing checks it. The second sentence is
    /// the one the verification pass judged correct and is kept verbatim in
    /// spirit — the app has no second party and can never acquire one, so it must
    /// never imply the name was verified.
    ///
    /// When the seal actually exists, this is the sentence that earns the
    /// stronger claim, and the test above is what will say so.
    public static let nameFooter = """
        Optional, and nobody checks it. Saving a name records it in the log, \
        alongside the days you have recorded. Nothing verifies it, and it is not \
        evidence that the name is true.
        """

    /// The certificate list — surface 3, and the reason the card never has to be
    /// re-shown unprompted.
    ///
    /// **"Sealed on this device" is a claim this build has earned**, and week 1a's
    /// build had not: `AchievementIssuer` signs every award with the P-256 key in
    /// the same pass that records it, `docs/achievement-protocol.md` §7.1 step 2.
    /// Nothing here says *anchored*, because nothing is: the calendars are week 4,
    /// and anchoring language before `AnchorState == .confirmed` is the one thing
    /// `.claude/skills/ui.md` names twice.
    ///
    /// The last clause is the append-only rule in the user's own terms. A row that
    /// disappeared would be the app quietly rewriting its own record, which is
    /// exactly what the whole apparatus exists to make impossible.
    public static let certificatesFooter = """
        Issued once, when a milestone falls out of the log. Each one is sealed on \
        this device and carries its full digest. Nothing here is ever removed — a \
        record whose days later changed is marked as such and keeps its place.
        """

    /// A revoked row's title and tag, at 45% ink. No colour, no icon.
    public static let revokedInk: Double = 0.45

    // MARK: Export

    /// The control `docs/product.md` budgets for this sheet — "Rename, archive,
    /// **export**" — and which had no surface until 2026-08-01.
    public static let exportButton = "Export a copy"

    /// What the bundle is, in the terms a person can act on.
    ///
    /// Every word here is checked by `SettingsTests` against
    /// ``unearnedClaims``, so it does not say "seal", "proof" or "signature"
    /// even though the bundle contains all three — the sheet describes what the
    /// file *is*, and the claims about what it proves are the certificate's and
    /// the verifier's to make.
    ///
    /// The last sentence is the point of the whole feature and is the mission
    /// sentence in the user's own words.
    public static let exportFooter = """
        Writes out everything this app holds — the log, the records it has \
        issued, the timestamp files, and a list of digests so a reader can tell \
        the copy is intact. You choose where it goes; it does not leave the \
        phone until you do. Anyone can check it with the script in the \
        repository, without this app.
        """

    /// The default filename offered to the exporter: `Compass-2026-08-01`.
    ///
    /// A civil date and nothing else. No time, because two exports on one day
    /// are the same day's record and the system already refuses to silently
    /// overwrite; no name, because the declared name is optional, unverified,
    /// and a filename travels further than most fields do — the same argument
    /// `docs/achievement-protocol.md` §3.4 makes about `rule.id`.
    ///
    /// It is computed here rather than in the view for the reason every other
    /// decision in this sheet is: a `View` is not a thing a test can drive.
    public static func exportFilename(at instant: Date, in zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(
            format: "Compass-%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// The store never opened, so there is nothing to copy. The same condition
    /// ``TodayModel/isStoreAvailable`` reports on Today, said where the user
    /// asked for a file.
    public static let exportUnavailable =
        "There is nothing to export: this app could not open its own store."

    /// A bundle that could not be built. The reason is included verbatim because
    /// there is nobody to file a report with — one person, one phone — and a
    /// message that says only "something went wrong" is a message that costs a
    /// future session the whole diagnosis.
    public static func exportFailed(reason: String) -> String {
        "The copy could not be written: \(reason)"
    }

    /// The exporter itself failed, after the bundle was built — the user
    /// cancelled, or the destination refused it.
    public static func exportNotSaved(reason: String) -> String {
        "The copy was not saved: \(reason)"
    }

    /// Vocabulary this build has not earned. A claim that the record is sealed,
    /// chained, anchored or tamper-evident is a claim about cryptography that
    /// does not ship until week 1b.
    ///
    /// Kept beside the copy rather than inside the test so that the next person
    /// writing a sentence here reads the list first.
    public static let unearnedClaims = [
        "seal", "sealed", "anchor", "anchored", "tamper", "immutable",
        "cannot be changed", "cannot be altered", "proves", "proof", "signed",
        "signature", "hash", "verified by", "certified",
    ]
}
