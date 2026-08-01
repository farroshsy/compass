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
/// Five things live here in this build: the habits — renamed in place and
/// removed — adding one, restoring a removed one, the **certificate list**, and
/// the optional declared name. `docs/product.md` also budgets export for this
/// sheet; that is the one thing still missing, and this file is where it lands.
///
/// The certificate list is surface 3 and it re-presents surface 2 rather than
/// pushing anything: `docs/product.md` cut a separate certificate detail screen
/// from v1 explicitly so it could not be smuggled back in as already designed,
/// and a chevron inside a `NavigationStack` is exactly how it would come back.
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

    /// Which certificate the list is showing, if any. It holds an identifier and
    /// no decision — what the certificate *says* is `CertificateCopy`, which is a
    /// plain value with tests behind it.
    @State private var presentedCertificate: AchievementID?

    /// The bundle waiting for `fileExporter`, or `nil`.
    ///
    /// Presentation, not behaviour: setting it opens the system sheet and
    /// clearing it closes one. **What** it holds is
    /// ``CompassUI/TodayModel/export()``, and what the sheet says about it is
    /// ``SettingsCopy`` — both of which are values a test drives directly. That
    /// split is the rule `.claude/skills/architecture.md` states, and the reason
    /// it states it is that two data bugs lived in `@State` in this exact file.
    @State private var exportDocument: BundleDocument?

    /// The sentence under the export button when something went wrong, or `nil`.
    /// Cleared when the button is pressed again — an old failure beside a fresh
    /// attempt is a lie about the fresh one.
    @State private var exportProblem: String?

    /// `true` while the bundle is being built. It digests every file in the
    /// store, so on a long log it is not instant, and a button that looks inert
    /// invites a second press.
    @State private var isExporting = false

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
                // **Also when there are no records but the pass failed.** That
                // is the case the failure matters most in: a first milestone
                // that could not be issued leaves an empty list, which is
                // exactly what "never earned" looks like.
                if !model.certificates.isEmpty || model.awardFailure != nil {
                    certificatesSection
                }
                nameSection
                exportSection
            }
            .navigationTitle("Settings")
            // **`fileExporter`, and deliberately not `ShareLink`.**
            // `.claude/skills/ui.md` reserves the single `ShareLink` for the
            // certificate, and `docs/product.md` builds the certificate's whole
            // justification on being the one thing you hand to someone. This
            // writes a bundle to wherever the user keeps files; the app never
            // learns where, and asks for no folder permission.
            .fileExporter(
                isPresented: exportIsPresented,
                document: exportDocument,
                contentType: .folder,
                defaultFilename: exportDocument.map {
                    SettingsCopy.exportFilename(at: $0.bundle.exportedAt)
                }
            ) { result in
                exportDocument = nil
                if case .failure(let error) = result {
                    exportProblem = SettingsCopy.exportNotSaved(reason: "\(error)")
                }
            }
            // **Surface 2 re-presented, never a fourth surface.**
            //
            // `docs/product.md` cut "a separate certificate detail screen" from
            // v1 explicitly "so they are not smuggled back in as already
            // designed", and budgets exactly three surfaces. The design draws a
            // chevron on each row, and a chevron inside a `NavigationStack` is a
            // push — which is how the cut screen comes back. So the row presents
            // the same `CertificateView` the milestone raises, over this sheet.
            .certificateCover(item: $presentedCertificate) { id in
                if let presentation = model.certificate(id) {
                    CertificateView(presentation: presentation) {
                        presentedCertificate = nil
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Committing first: a name typed and not submitted is an edit
                    // the user believes they made, and dismissing over it would
                    // discard it in silence. **Every edit — the habit names and
                    // the declared name — and no creation.** The "New habit"
                    // field is left uncommitted on purpose, because minting a
                    // permanent `habitCreated` from a half-typed string nobody
                    // confirmed is the one loss here that cannot be undone.
                    // ``SettingsEdits/commitAll(into:)`` argues it in full.
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

    // MARK: The certificate list

    /// Surface 3, and the reason the card does not have to be re-shown
    /// unprompted: it is where a certificate stays reachable after it is
    /// dismissed, and where the single `ShareLink` stays reachable with it.
    ///
    /// **Plain reverse-chronological rows, and no "new" indicator** — a "new"
    /// badge is a re-engagement affordance and badges are banned.
    ///
    /// A **revoked entry keeps its place.** Its title drops to 45% ink, its
    /// subtitle says what happened, and an uppercase tag replaces the chevron.
    /// No colour, no icon, and no offer to fix it: you never erase a published
    /// entry, you post a reversal, and the list is where the reversal is read.
    private var certificatesSection: some View {
        Section {
            ForEach(model.certificates, id: \.id) { achievement in
                let isRevoked = model.book.isRevoked(achievement.id)
                Button {
                    presentedCertificate = achievement.id
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                CertificateCopy.listTitle(
                                    for: achievement, names: model.habitNames
                                )
                            )
                            .foregroundStyle(
                                Color.primary.opacity(isRevoked ? SettingsCopy.revokedInk : 1)
                            )
                            Text(
                                isRevoked
                                    ? CertificateCopy.revokedSubtitle
                                    : CertificateCopy.listSubtitle(for: achievement)
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if isRevoked {
                            Text(CertificateCopy.revokedTag)
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.9)
                                .textCase(.uppercase)
                                .foregroundStyle(
                                    Color.primary.opacity(SettingsCopy.revokedInk)
                                )
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isRevoked ? CertificateCopy.revokedSubtitle : "Opens the record")
            }
        } header: {
            Text("Records")
        } footer: {
            // **Where the achievement pass gets to fail out loud.**
            // `.claude/skills/ui.md` keeps Today silent about the engine, and it
            // stays silent; this is the same arrangement anchoring already has,
            // where the failure is invisible on the main screen and sayable on
            // the certificate. A milestone that failed to issue and said nothing
            // anywhere is indistinguishable from one that was never earned.
            if let failure = model.awardFailure {
                Text(SettingsCopy.awardFailed(reason: failure))
            } else {
                Text(SettingsCopy.certificatesFooter)
            }
        }
    }

    // MARK: Export

    /// The control `docs/product.md` has budgeted for this sheet since the first
    /// draft — "Rename, archive, export" — and which had no surface at all until
    /// 2026-08-01.
    ///
    /// `Exporter` was written in week 1, tested from week 1, and reachable from
    /// nothing: `grep` found no call site outside its own test file. Every bundle
    /// this project has ever verified, including the one the standalone verifier
    /// was first run against, was produced by a helper process written beside the
    /// app. That makes `docs/product.md`'s mission sentence — a record "you can
    /// hand to a stranger" — unreachable from the product, which is a different
    /// and worse thing than unimplemented.
    ///
    /// It is the **last** section on the sheet, below the declared name, because
    /// it is the one thing here that is not part of the daily loop and
    /// `.claude/skills/ui.md` puts everything off the launch path behind
    /// deliberate reach.
    private var exportSection: some View {
        Section {
            Button {
                startExport()
            } label: {
                HStack {
                    Text(SettingsCopy.exportButton)
                    if isExporting {
                        Spacer(minLength: 12)
                        ProgressView()
                    }
                }
            }
            .disabled(isExporting)

            if let exportProblem {
                // Said once, plainly, where the user asked for the file. This is
                // not the anchoring case `.claude/skills/ui.md` keeps silent —
                // that one is a background pass nobody requested, and this is a
                // button somebody just pressed.
                Text(exportProblem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Export")
        } footer: {
            Text(SettingsCopy.exportFooter)
        }
    }

    /// Builds the bundle off the main actor's critical path and hands it to the
    /// exporter. Every decision it makes lives in ``TodayModel/export()``.
    private func startExport() {
        exportProblem = nil
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            switch await model.export() {
            case .ready(let bundle): exportDocument = BundleDocument(bundle: bundle)
            case .failed(let message): exportProblem = message
            }
        }
    }

    /// `fileExporter` takes a `Bool` binding and an optional document, and the
    /// two have to agree. Deriving the flag from the document is what stops them
    /// disagreeing — a `true` with no document presents an empty sheet.
    private var exportIsPresented: Binding<Bool> {
        Binding(
            get: { exportDocument != nil },
            set: { if !$0 { exportDocument = nil } }
        )
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
