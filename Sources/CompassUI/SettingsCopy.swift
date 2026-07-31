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
