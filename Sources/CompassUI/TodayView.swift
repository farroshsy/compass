import CompassDomain
import SwiftUI

/// The one screen on the launch path. `.claude/skills/ui.md`, `docs/product.md`.
///
/// No `TabView`, no `NavigationStack`, no first-launch flow, no "+" button.
/// Information at the top, out of thumb reach; actions at the bottom, in the
/// thumb arc. That inverts the normal habit-app layout on purpose.
public struct TodayView: View {

    @State private var model: TodayModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: TodayModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 32)
            rows
        }
        .padding(.horizontal, TodayView.margin)
        // The last row sits 24pt above the home indicator.
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .task {
            model.refreshDay()
            await model.reconcile()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDay() }
        }
    }

    /// Full width minus 20pt margins.
    static let margin: CGFloat = 20

    // MARK: Information, at the top

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(model.totalDays)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(model.totalDays == 1 ? "day" : "days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            SpineView(dots: model.spine)
            if !model.isStoreAvailable { storeNotice }
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.totalDays) days recorded")
    }

    /// Shown only when the store could not be opened. `docs/technical.md` §6
    /// forbids refusing to launch, and this is the sentence that keeps the
    /// launched app honest: without it the screen shows zero days and two rows
    /// that do nothing when tapped, which reads as "the app lost everything"
    /// rather than "the app cannot reach the file".
    ///
    /// One line, secondary, no colour and no icon — this is not the anchoring
    /// failure state `.claude/skills/ui.md` bans from the main screen, it is the
    /// screen saying that it is not recording. It cannot nag: it is present
    /// exactly while the condition is.
    private var storeNotice: some View {
        Text("Compass cannot reach its store. Taps are not being saved.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions, at the bottom

    private var rows: some View {
        VStack(spacing: 12) {
            ForEach(Array(model.habits.enumerated()), id: \.element.id) { index, habit in
                HabitRow(
                    name: habit.name,
                    isChecked: model.isChecked(habit),
                    tint: TodayView.tint(at: index)
                ) {
                    model.toggle(habit)
                }
            }
        }
    }

    /// Two habits get two colours. Everything else on this screen is greyscale.
    /// Four entries because four habits is the hard cap.
    private static let palette: [Color] = [.teal, .orange, .indigo, .pink]

    private static func tint(at index: Int) -> Color {
        palette[index % palette.count]
    }
}

// MARK: - A habit row

/// 76pt tall, full width minus the margins, 12pt apart, corner radius 16.
/// **The whole row is the hit target**, not the glyph.
///
/// Tap toggles, tap again untoggles. Never a confirmation dialog. Finishing all
/// habits does not change the layout — the rows just sit there filled.
struct HabitRow: View {

    let name: String
    let isChecked: Bool
    let tint: Color
    let toggle: () -> Void

    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Text(name)
                    .font(.title3.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isChecked ? Color.white : Color.primary.opacity(0.25))
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76)
            .foregroundStyle(isChecked ? Color.white : Color.primary)
            .background(isChecked ? tint : Color.primary.opacity(0.06), in: HabitRow.shape)
            .contentShape(HabitRow.shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(isChecked ? "done" : "not done")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - The spine

/// 28 dots, oldest first, ending today. A missed day is a plain gap: no red, no
/// warning, no guilt copy.
///
/// **A display, never a control.** Nothing on it is tappable, and it is hidden
/// from accessibility interaction for the same reason — a forgotten day stays
/// forgotten, and there is no editing of a past day in v1.
struct SpineView: View {

    let dots: [Bool]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, isDone in
                Circle()
                    .fill(Color.primary.opacity(isDone ? 0.85 : 0.12))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
