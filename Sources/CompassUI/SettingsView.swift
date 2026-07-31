import CompassDomain
import SwiftUI

/// The settings sheet — **the only surface reachable from Today**, and one of
/// the three the v1 budget allows off the launch path. `docs/product.md`,
/// `.claude/skills/ui.md`.
///
/// It is a `.sheet` presented over Today, entered through a deliberately
/// hard-to-reach glyph, and never presented unprompted. Nothing here is on the
/// launch path and nothing here may move onto it.
///
/// Three things live here in this build: the habits, adding one, and the
/// optional declared name. `docs/product.md` also budgets rename, export and the
/// certificate list for this sheet; none of those is built yet, and this file is
/// where they land when they are.
///
/// ### The rule this screen exists to keep
///
/// **Nothing in this application deletes anything, ever.** Removing a habit
/// appends a `habitArchived`; the habit, its name and every day it recorded stay
/// in the log. The copy below says so out loud, because a control that reads as
/// "delete" while the system archives is a control that lies about what the user
/// just did — and the whole value of an append-only record is that the user can
/// believe it.
public struct SettingsView: View {

    private let model: TodayModel

    /// The name being typed. Local, not bound to the model: a keystroke must not
    /// append an event. The declaration happens once, on confirm.
    @State private var typedName: String

    /// The habit being typed. Same reason.
    @State private var newHabitName: String = ""

    @Environment(\.dismiss) private var dismiss

    public init(model: TodayModel) {
        self.model = model
        _typedName = State(initialValue: model.declaredName)
    }

    public var body: some View {
        NavigationStack {
            Form {
                habitsSection
                addSection
                if !model.removedHabits.isEmpty { removedSection }
                nameSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Habits

    private var habitsSection: some View {
        Section {
            ForEach(model.habits, id: \.id) { habit in
                HStack {
                    Text(habit.name)
                    Spacer(minLength: 12)
                    Button("Remove") { model.removeHabit(habit) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(habit.name)")
                }
            }
        } header: {
            Text("Habits")
        } footer: {
            Text(
                """
                Removing a habit takes its row off Today. Every day it has \
                already recorded stays in the log — nothing here is ever deleted.
                """
            )
        }
    }

    private var addSection: some View {
        Section {
            HStack {
                TextField("New habit", text: $newHabitName)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.borderless)
                    .disabled(!canAdd)
            }
        } header: {
            Text("Add a habit")
        } footer: {
            // The cap is a product rule, not a layout accident, so the sentence
            // says what it is rather than disabling a button in silence.
            Text(
                model.mayAddHabit
                    ? "A habit is a name and a boolean per day. Four at a time is the limit."
                    : "Four at a time is the limit. Remove one to add another."
            )
        }
    }

    /// A name, and a confirm. **Nothing else** — no icon, no colour, no
    /// category, no schedule, no reminder, and no list of suggestions to pick
    /// from. `docs/product.md` bans habit templates, and each of the others is
    /// a decision inside a loop whose entire purpose is having none in it.
    private var canAdd: Bool {
        model.mayAddHabit
            && !newHabitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        guard model.addHabit(named: newHabitName) else { return }
        newHabitName = ""
    }

    /// A display, never a control. It is here so that "nothing is deleted" is
    /// something the user can see rather than something the documentation
    /// claims.
    private var removedSection: some View {
        Section {
            ForEach(model.removedHabits, id: \.id) { habit in
                Text(habit.name)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Removed")
        } footer: {
            Text("Kept, with every day they recorded. They do not count towards the four.")
        }
    }

    // MARK: The declared name

    private var nameSection: some View {
        Section {
            // **Autocorrection off, and this is not a preference.** Running the
            // build proved it: typing "Farros Hilmi Syafei" into a corrected
            // field produced "Farris Hilmi Stacie" and sealed that. A proper
            // noun is exactly what a dictionary does not contain, and this is
            // the one field in the app whose entire value is that its contents
            // cannot be restated afterwards — so a keyboard that edits it is
            // editing the record. The habit field is disabled for the same
            // reason: a habit name is a personal noun more often than not.
            TextField("Your name", text: $typedName)
                .autocorrectionDisabled()
                .onSubmit(declare)
            Button("Save", action: declare)
                .disabled(!hasNameChanged)
        } header: {
            Text("Name on the record")
        } footer: {
            // Every clause here is load-bearing. There is no account and no
            // second party that could check this name — `docs/product.md` makes
            // that a permanent non-goal — so the app must never say or imply it
            // was verified. What it can honestly claim is the narrower thing:
            // the name is written into the log, and a record sealed afterwards
            // commits to that log, so the name cannot be restated later.
            Text(
                """
                Optional, and nobody checks it. Saving a name records it in the \
                log, so anything sealed afterwards carries it and it cannot be \
                changed without breaking the seal. That proves you committed to \
                this name at the time — not that the name is true.
                """
            )
        }
    }

    private var hasNameChanged: Bool {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines) != model.declaredName
    }

    private func declare() {
        model.declare(name: typedName)
        // Whatever the model settled on is what the field shows — including the
        // trim, and including a refused write, which must not leave the field
        // claiming something the log does not say.
        typedName = model.declaredName
    }
}
