import AppIntents
import CompassDomain
import CompassInfrastructure
import CompassUI
import SwiftUI
import WidgetKit

/// **The interactive Home Screen widget.** `docs/technical.md` §10a and §11,
/// `.claude/skills/ios.md`, `.claude/skills/ui.md`.
///
/// It is the highest-value item per line of code in the project, and the reason
/// is arithmetic rather than taste: the app's loop is open, tap, close in about
/// three seconds, and this one is press — about 0.7. It is also the *reminder*,
/// which is why `docs/product.md` can ban notifications outright: it sits where
/// the thumb already is, and it costs no permission prompt, no fixed-hour
/// decision and no contradiction.
///
/// ### The rules it inherits, and does not get to reinterpret
///
/// - Press toggles, press again untoggles. **Never a confirmation dialog.**
/// - A checked row is a deep field in the habit's hue with a paper label; an
///   unchecked one is grey with no hue in it, so a fresh install is greys.
///   `HabitTint` is `CompassUI`'s, read from where it lives rather than copied.
/// - No number that resets. The line under the rows is days recorded, the same
///   quantity Today makes the largest thing on its screen, and never the streak.
/// - No badge, no confetti, no progress bar, no "streak at risk". A missed day is
///   simply a row that is not filled.
///
/// ### Why the shell holds nothing
///
/// This folder is not compiled by `swift test` and has no test target — the same
/// standing as `App/`, and the same evidence behind the rule: mutation showed
/// two real fixes living there were covered by no test at all. So the timeline is
/// two calls into `CompassInfrastructure` and the rest is layout.
struct CompassWidget: Widget {

    /// A **static** configuration: nothing about this widget is configurable.
    /// `docs/product.md`'s loop has no decisions in it, and a configuration
    /// intent would put the first one on the Home Screen.
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.farros.compass.today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Record today's habits without opening the app.")
        // **One family.** `docs/product.md` budgets surfaces by counting them, and
        // every extra family is another layout that has to stay correct for one
        // user. Small is the one the thumb reaches.
        .supportedFamilies([.systemSmall])
    }
}

@main
struct CompassWidgetBundle: WidgetBundle {
    var body: some Widget {
        CompassWidget()
    }
}

// MARK: - The timeline

struct TodayEntry: TimelineEntry {
    let date: Date
    let habits: [TodaySnapshot.Habit]
    let daysRecorded: Int
}

/// Reads the log and says when what it read stops being true.
///
/// **The timeline holds exactly one entry.** Everything on this widget is a fact
/// about today, and there is no second moment between now and the 04:00 boundary
/// at which any of it changes on its own — so a second entry would be the same
/// screen with a different timestamp on it. The reload after a press is WidgetKit
/// re-asking, not a scheduled entry.
struct TodayProvider: TimelineProvider {

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, habits: [], daysRecorded: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(entry(AppComposition.widgetScreen()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let screen = AppComposition.widgetScreen()
        completion(Timeline(entries: [entry(screen)], policy: .after(screen.staleAfter)))
    }

    private func entry(_ screen: WidgetScreen) -> TodayEntry {
        TodayEntry(
            date: .now, habits: screen.habits, daysRecorded: screen.daysRecorded
        )
    }
}

// MARK: - The screen

struct TodayWidgetView: View {

    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if entry.habits.isEmpty {
                empty
            } else {
                ForEach(Array(entry.habits.enumerated()), id: \.element.id) { index, habit in
                    WidgetHabitRow(habit: habit, tint: HabitTint.tint(at: index))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A phone where the app has never been opened, or a build whose profile
    /// carries no App Group. It says what is true and does not invent rows.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Compass").font(.headline)
            Text("Open the app once to begin.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// One row, and **the whole row is the button** — the same rule Today's
/// `HabitRow` follows, for the same reason: a glyph-sized target on a Home Screen
/// widget is a target that gets missed.
struct WidgetHabitRow: View {

    let habit: TodaySnapshot.Habit
    let tint: HabitTint

    @Environment(\.colorScheme) private var colorScheme

    private static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        Button(intent: ToggleHabitIntent(habitID: habit.id.rawValue)) {
            HStack(spacing: 6) {
                Text(habit.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                mark
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .foregroundStyle(habit.isChecked ? HabitTint.paper : Color.primary)
            // Grey with no hue when unchecked, exactly as on Today. Colour is
            // what a check *does*, not what a habit *is*.
            .background(
                habit.isChecked ? tint.field(for: colorScheme) : Color.primary.opacity(0.06),
                in: WidgetHabitRow.shape
            )
            .contentShape(WidgetHabitRow.shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(habit.name)
        .accessibilityValue(habit.isChecked ? "done" : "not done")
    }

    /// A rounded square, never `checkmark.circle.fill` — the same form as one
    /// cell in the seal die, so the daily gesture and the sealed record are one
    /// shape at two scales.
    private var mark: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Group {
            if habit.isChecked {
                shape.fill(HabitTint.paper)
            } else {
                shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5)
            }
        }
        .frame(width: 12, height: 12)
    }
}
