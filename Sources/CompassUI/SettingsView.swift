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
/// Four things live here in this build: the habits — renamed in place and
/// removed — adding one, restoring a removed one, and the optional declared name.
/// `docs/product.md` also budgets export and the certificate list for this sheet;
/// neither is built yet, and this file is where they land when they are.
///
/// ### Why rename is a text field and not a screen
///
/// `docs/product.md` justifies banning a first-launch naming flow with "renaming
/// lives in the settings sheet, where it already belongs", and
/// `.claude/skills/ui.md` says adding, renaming and deleting all live behind the
/// settings glyph. Only add and remove existed, which made that justification
/// false and — with four names seeded at the cap — made changing one name cost
/// the user the habit's entire history: Remove then Add mints a new `HabitID`.
/// So the name is simply editable where it is already displayed. No row to tap
/// into, no detail screen, no fourth surface.
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

    /// Everything typed and not yet confirmed, and every rule about what
    /// happens to it. Local, not bound to the model: a keystroke must not append
    /// an event. See ``SettingsEdits`` for why the sheet's behaviour is a value
    /// beside this file rather than three `@State` properties inside it — two
    /// data bugs lived in those properties, where nothing could test them.
    @State private var edits: SettingsEdits

    @Environment(\.dismiss) private var dismiss

    public init(model: TodayModel) {
        self.model = model
        _edits = State(initialValue: SettingsEdits(model))
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
                    // Committing first: a name typed and not submitted is an edit
                    // the user believes they made, and dismissing over it would
                    // discard it in silence. **Every** field, including the
                    // declared name — see ``SettingsEdits/commitAll(into:)``,
                    // which is where that sentence became true.
                    Button("Done") {
                        edits.commitAll(into: model)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: Habits

    private var habitsSection: some View {
        Section {
            ForEach(model.habits, id: \.id) { habit in
                HStack {
                    // Autocorrection off for the same reason as the name field
                    // below: a habit name is a personal noun more often than not,
                    // and a keyboard that "corrects" it is editing the record.
                    TextField("Name", text: editableName(of: habit))
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { edits.commitName(of: habit, into: model) }
                        .accessibilityLabel("Name of \(habit.name)")
                    Spacer(minLength: 12)
                    // Removing also discards whatever was half-typed into the
                    // row above. ``SettingsEdits/remove(_:from:)``.
                    Button("Remove") { edits.remove(habit, from: model) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(habit.name)")
                }
            }
        } header: {
            Text("Habits")
        } footer: {
            Text(SettingsCopy.habitsFooter)
        }
    }

    /// The row's name field: the model's name until the user types, the typed
    /// text while they are typing.
    private func editableName(of habit: HabitState) -> Binding<String> {
        Binding(
            get: { edits.name(of: habit) },
            set: { edits.setName($0, of: habit) }
        )
    }

    private var addSection: some View {
        Section {
            HStack {
                TextField("New habit", text: $edits.newHabitName)
                    .autocorrectionDisabled()
                    .onSubmit { edits.add(into: model) }
                Button("Add") { edits.add(into: model) }
                    .buttonStyle(.borderless)
                    .disabled(!edits.canAdd(in: model))
            }
        } header: {
            Text("Add a habit")
        } footer: {
            // The cap is a product rule, not a layout accident, so the sentence
            // says what it is rather than disabling a button in silence.
            Text(model.mayAddHabit ? SettingsCopy.addFooter : SettingsCopy.addFooterAtCap)
        }
    }

    /// Proof that "nothing is deleted" is something the user can see rather than
    /// something the documentation claims — and, since this build, the way back.
    ///
    /// Remove is one tap with no confirmation, which `.claude/skills/ui.md`
    /// requires, so a mis-tap has to be undoable somewhere. Restoring appends a
    /// `habitUnarchived`; it is the same shape as everything else here, and the
    /// habit comes back with every day it recorded still attached.
    private var removedSection: some View {
        Section {
            ForEach(model.removedHabits, id: \.id) { habit in
                HStack {
                    Text(habit.name)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("Restore") { model.restoreHabit(habit) }
                        .buttonStyle(.borderless)
                        .disabled(!model.mayAddHabit)
                        .accessibilityLabel("Restore \(habit.name)")
                }
            }
        } header: {
            Text("Removed")
        } footer: {
            Text(model.mayAddHabit ? SettingsCopy.removedFooter : SettingsCopy.removedFooterAtCap)
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
            TextField("Your name", text: $edits.typedName)
                .autocorrectionDisabled()
                .onSubmit { edits.commitDeclaredName(into: model) }
            Button("Save") { edits.commitDeclaredName(into: model) }
                .disabled(!edits.hasDeclaredNameChanged(in: model))
        } header: {
            Text("Name on the record")
        } footer: {
            // Every clause is load-bearing, and one of them used to be false.
            // There is no account and no second party that could check this name
            // — `docs/product.md` makes that a permanent non-goal — so the app
            // must never say or imply it was verified. Nor may it claim the seal
            // it does not have yet: see ``SettingsCopy/nameFooter``.
            Text(SettingsCopy.nameFooter)
        }
    }
}
