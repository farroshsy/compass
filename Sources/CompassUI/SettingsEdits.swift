import CompassDomain

/// Everything the settings sheet holds that the user has typed and **not yet
/// confirmed**: the declared name, the habit being added, and any habit name
/// being edited in place.
///
/// Nothing here is bound to the model. A keystroke must never append an event —
/// every field below turns into a log entry once, on confirm, and until then it
/// is text on a screen and nothing else.
///
/// ### Why this is a type and not three `@State` properties
///
/// It was three `@State` properties inside ``SettingsView``, and two data bugs
/// lived in them where no test could reach:
///
/// - **Done discarded the declared name.** The Done handler committed habit
///   renames and returned. A name typed and not submitted was dropped in
///   silence — the exact loss that handler's own comment says it exists to
///   prevent, on the one field the sheet was added for.
/// - **Done committed a rename the user had cancelled by removing the habit.**
///   An in-flight edit was cleared only by committing it, and the sweep ran over
///   active habits only, so an entry for a habit archived mid-edit survived.
///   Remove then Restore put a name on screen that the log did not have — the
///   thing ``habitNames`` is documented to make impossible — and Done then wrote
///   it.
///
/// Both are ordinary logic, and both were unreachable from a test because
/// `@State` inside a `View` is state no test can construct or drive.
/// `.claude/skills/testing.md` refuses snapshot tests and a broad XCUITest suite
/// out loud, so "test it through the view" is not available and pretending
/// otherwise is how these two survived.
///
/// This is the same move, for the same reason, that `AppComposition` already
/// records: the wiring left `App/` because "an argument in `App/` is an argument
/// no test can see", and a mutation pass proved two real fixes could be deleted
/// in silence. `@State` is that folder again, one target down. The view keeps
/// the layout; the value below keeps the behaviour, and the behaviour is what
/// `SettingsTests` drives.
///
/// It is deliberately not `@Observable` and not a class: it is a value the sheet
/// owns for as long as the sheet is on screen, and it dies with it. Reopening
/// the sheet builds a fresh one from the model, which is what makes "the name
/// is there when I come back" a statement about the log rather than about a
/// cache.
@MainActor
struct SettingsEdits {

    /// The declared name being typed. Seeded from the log when the sheet opens.
    var typedName: String

    /// The habit being typed into the add field.
    var newHabitName: String = ""

    /// Names being edited in place, keyed by habit. An entry exists only while
    /// the user is mid-edit; the row falls back to the model the moment the edit
    /// is committed, refused, or abandoned by removing the habit — so the field
    /// can never show a name the log does not have.
    private var habitNames: [HabitID: String] = [:]

    init(_ model: TodayModel) {
        self.typedName = model.declaredName
    }

    // MARK: The habit rows

    /// The row's name: the model's name until the user types, the typed text
    /// while they are typing.
    func name(of habit: HabitState) -> String {
        habitNames[habit.id] ?? habit.name
    }

    mutating func setName(_ text: String, of habit: HabitState) {
        habitNames[habit.id] = text
    }

    /// Commits one row's edit. A rename is an event, so — exactly like the
    /// declared name below — it happens once, on confirm, never on a keystroke.
    mutating func commitName(of habit: HabitState, into model: TodayModel) {
        guard let typed = habitNames[habit.id] else { return }
        model.rename(habit, to: typed)
        // Whatever the model settled on is what the row shows, including a
        // refused write: the field must not keep claiming a name the log does
        // not have.
        habitNames[habit.id] = nil
    }

    /// Removes the habit — which archives it, and **discards any name the user
    /// was part-way through typing into it.**
    ///
    /// Dropping the edit is the whole of the second bug above. Removing a row is
    /// the user abandoning it, not confirming it, so a half-typed name must not
    /// outlive the row: it survived here, reappeared verbatim if the habit was
    /// restored, and was written to the log by Done.
    ///
    /// The edit is dropped **only when the archive actually landed**. A write
    /// that fails changes nothing on screen anywhere else in this app, and
    /// silently binning the user's typing on a failed write would be the same
    /// class of loss in the other direction.
    mutating func remove(_ habit: HabitState, from model: TodayModel) {
        guard model.removeHabit(habit) else { return }
        habitNames[habit.id] = nil
    }

    // MARK: Adding

    /// A name, and a confirm. **Nothing else** — no icon, no colour, no
    /// category, no schedule, no reminder, and no list of suggestions to pick
    /// from. `docs/product.md` bans habit templates, and each of the others is
    /// a decision inside a loop whose entire purpose is having none in it.
    func canAdd(in model: TodayModel) -> Bool {
        model.mayAddHabit
            && !newHabitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func add(into model: TodayModel) {
        guard model.addHabit(named: newHabitName) else { return }
        newHabitName = ""
    }

    // MARK: The declared name

    func hasDeclaredNameChanged(in model: TodayModel) -> Bool {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines) != model.declaredName
    }

    mutating func commitDeclaredName(into model: TodayModel) {
        model.declare(name: typedName)
        // Whatever the model settled on is what the field shows — including the
        // trim, and including a refused write, which must not leave the field
        // claiming something the log does not say.
        typedName = model.declaredName
    }

    // MARK: Done

    /// What the Done button commits: **every edit, and no creation.**
    ///
    /// Committing the edits: a name typed and not submitted is a change the user
    /// believes they made, and dismissing over it discards it in silence. That
    /// was already the stated reason this handler exists, and the declared name —
    /// the one field the sheet was added for — was the one it did not cover. So
    /// habit renames and the declared name are both swept below.
    ///
    /// **``newHabitName`` is deliberately not swept, and this is the reason.**
    /// Every other field on this sheet *edits* something that already exists and
    /// is revisable: a rename is cosmetic and another rename undoes it, and a
    /// declared name is withdrawn by declaring an empty one. Creating a habit is
    /// neither. It mints a `HabitID` and appends a `habitCreated` to a log that
    /// is append-only and has no tidying pass, so a habit minted from three
    /// abandoned characters is on disk forever, inside `witness.logHeads` for
    /// every achievement sealed afterwards — and Remove does not take it back,
    /// because Remove archives. It could also spend the last free slot under the
    /// four-habit cap without the user asking.
    ///
    /// It is the same rule ``remove(_:from:)`` already keeps in the other
    /// direction: **abandoning a field is not confirming it.** Dismissal is
    /// ambiguous, and where it is ambiguous this sheet does the reversible thing.
    /// Adding is one visible, enabled tap away on the same row, and the text is
    /// still there until the sheet closes.
    mutating func commitAll(into model: TodayModel) {
        // Active habits only, which is now exactly right: an edit for a habit
        // removed mid-session was dropped by ``remove(_:from:)`` when the row
        // went away, so there is nothing left here that has no row.
        for habit in model.habits { commitName(of: habit, into: model) }
        commitDeclaredName(into: model)
        // No `add(into:)`. See above — it is refused, not forgotten.
    }
}
