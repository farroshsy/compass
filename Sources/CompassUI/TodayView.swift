import CompassDomain
import SwiftUI

/// The one screen on the launch path. `.claude/skills/ui.md`, `docs/product.md`.
///
/// No `TabView`, no `NavigationStack`, no first-launch flow, no "+" button, no
/// card and no nav bar — the background is full bleed. Information at the top,
/// out of thumb reach; actions at the bottom, in the thumb arc. That inverts the
/// normal habit-app layout on purpose.
///
/// Every number here comes from ``TodayMetrics``, which `TodayMetricsTests`
/// asserts against.
///
/// **The settings glyph is deliberately absent.** The design adds one — a
/// `gearshape` at 30% ink in the top-right corner, on the number's cap line —
/// and records it as a decision taken on the user's behalf, "justified only
/// because the sheet is already budgeted and otherwise unreachable". The sheet
/// is week 3. A glyph shipped before it opens anything is a control that lies,
/// and `.claude/skills/ui.md`'s surface budget is a budget for surfaces that
/// exist. It lands with the sheet, at the position the design measured — a 44 x
/// 44 target centred at (371, 128), overhanging the margin by 11pt so the
/// glyph's trailing edge falls on the margin line and the target still reaches
/// 44. Recorded in `docs/open-questions.md`.
public struct TodayView: View {

    @State private var model: TodayModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: TodayModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: TodayMetrics.minimumSpacer)
            rows
        }
        .padding(.horizontal, TodayMetrics.horizontalMargin)
        // The last row sits 24pt above the home indicator.
        .padding(.bottom, TodayMetrics.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .task {
            model.refreshDay()
            await model.reconcile()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDay() }
        }
    }

    // MARK: Information, at the top

    /// Dynamic Type rule 1: **clamp the display, never the controls.** The
    /// header stops growing at `accessibility2`; ``rows`` below take no clamp at
    /// all, because someone who needs AX5 needs it on the thing they tap.
    private var header: some View {
        VStack(alignment: .leading, spacing: TodayMetrics.headerSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                // Rule 2: a fixed graphic. `Font.system(size:)` does not respond
                // to Dynamic Type, which is the whole requirement.
                Text("\(model.totalDays)")
                    .font(.system(
                        size: TodayMetrics.numberPointSize,
                        weight: .bold,
                        design: .rounded
                    ))
                    .tracking(TodayMetrics.numberTracking)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                // Directly under it, no gap inside the block.
                Text(model.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SpineView(dots: model.spine)
            if !model.isStoreAvailable { storeNotice }
        }
        .dynamicTypeSize(...TodayMetrics.headerClamp)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, TodayMetrics.headerTopInset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.caption)
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
        VStack(spacing: TodayMetrics.rowSpacing) {
            ForEach(Array(model.habits.enumerated()), id: \.element.id) { index, habit in
                HabitRow(
                    name: habit.name,
                    isChecked: model.isChecked(habit),
                    tint: HabitTint.tint(at: index)
                ) {
                    model.toggle(habit)
                }
            }
        }
    }
}

// MARK: - A habit row

/// 76pt tall, full width minus the margins, 12pt apart, corner radius 16
/// `.continuous`. **The whole row is the hit target**, not the mark.
///
/// Tap toggles, tap again untoggles. Never a confirmation dialog. Finishing all
/// habits does not change the layout — the rows just sit there filled.
///
/// Checked is a deep field in the habit's hue with a paper label and a paper
/// mark; unchecked is 6% ink with a 45% stroke. See ``HabitTint`` for the
/// measurements that forced that, and ``TodayMetrics`` for the numbers.
struct HabitRow: View {

    let name: String
    let isChecked: Bool
    let tint: HabitTint
    let toggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The mark grows with the name: 20pt at the default size, ~48 at AX5.
    /// **No clamp on this view** — Dynamic Type rule 1.
    @ScaledMetric(relativeTo: .title3) private var markSide = TodayMetrics.markSide

    init(name: String, isChecked: Bool, tint: HabitTint, toggle: @escaping () -> Void) {
        self.name = name
        self.isChecked = isChecked
        self.tint = tint
        self.toggle = toggle
    }

    private static let shape = RoundedRectangle(
        cornerRadius: TodayMetrics.rowCornerRadius, style: .continuous
    )

    private var field: Color { tint.field(for: colorScheme) }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Text(name)
                    .font(.title3.weight(.medium))
                    .tracking(TodayMetrics.nameTracking)
                    // Rule 3: two lines above accessibility1. `lineLimit(1)` at
                    // 49pt truncates any name longer than about eight
                    // characters, and renaming is a supported feature — so a
                    // user could silently make their own row unreadable.
                    .lineLimit(TodayMetrics.nameLineLimit(at: dynamicTypeSize))
                Spacer(minLength: 0)
                mark
            }
            .padding(.horizontal, TodayMetrics.rowHorizontalPadding)
            .padding(.vertical, TodayMetrics.rowVerticalPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: TodayMetrics.rowHeight(at: dynamicTypeSize)
            )
            .foregroundStyle(isChecked ? HabitTint.paper : Color.primary)
            .background(
                isChecked ? field : Color.primary.opacity(0.06),
                in: HabitRow.shape
            )
            .contentShape(HabitRow.shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(isChecked ? "done" : "not done")
        .accessibilityAddTraits(.isButton)
    }

    /// A rounded square, never `checkmark.circle.fill`. It is the same form as
    /// one cell in the seal die, so the daily gesture and the sealed record are
    /// one shape at two scales.
    private var mark: some View {
        let shape = RoundedRectangle(
            cornerRadius: markSide * TodayMetrics.markCornerRatio, style: .continuous
        )
        return Group {
            if isChecked {
                shape.fill(HabitTint.paper)
            } else {
                shape.strokeBorder(
                    Color.primary.opacity(0.45),
                    lineWidth: TodayMetrics.markStrokeWidth(at: dynamicTypeSize)
                )
            }
        }
        .frame(width: markSide, height: markSide)
    }
}

// MARK: - The spine

/// 28 dots, 9 x 9 with a 2pt gap, oldest first, ending today. A missed day is a
/// plain gap: no red, no warning, no guilt copy.
///
/// **A display, never a control.** Nothing on it is tappable, and it is hidden
/// from accessibility interaction for the same reason — a forgotten day stays
/// forgotten, and there is no editing of a past day in v1.
///
/// Dynamic Type rule 4: it does not scale, and that is accepted. It is already
/// `accessibilityHidden`, and the honest alternative — showing fewer days —
/// would change what the graphic claims. 28 dots occupy 306 of the 362
/// available points; `TodayMetricsTests` pins that.
struct SpineView: View {

    let dots: [Bool]

    var body: some View {
        HStack(spacing: TodayMetrics.spineGap) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, isDone in
                Circle()
                    .fill(Color.primary.opacity(isDone ? 0.85 : 0.12))
                    .frame(width: TodayMetrics.spineDot, height: TodayMetrics.spineDot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
