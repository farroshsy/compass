import AppIntents
import CompassDomain
import CompassInfrastructure
import WidgetKit

/// **The App Intent, as substrate.** `docs/technical.md` §11 week 2,
/// `.claude/skills/ios.md`.
///
/// The build order says "App Intents first, as substrate, then the interactive
/// widget", and this is what that means in code: an interactive widget button is
/// a `Button(intent:)`, so the intent is not an optional extra layer under the
/// widget, it is the mechanism the widget's tap arrives through. There is no
/// version of the widget that does not have one.
///
/// ### One intent, not two
///
/// `memory/next-tasks.md` listed `ToggleHabitIntent` **and** `CheckInIntent`.
/// Only this one is written, and the reason is a rule the same corpus states
/// twice: `.claude/skills/ios.md` — "Build App Intents first, as substrate — but
/// ship **only the widget** on top of them in v1" — and `docs/technical.md` §10b,
/// which defers `AppShortcutsProvider` phrases, the Control Center control and
/// the Action Button behind triggers that have not fired. A second intent with
/// no caller is an entry point with no user, and "every extra entry point is
/// another place the tap path must stay correct and another place a wrong day
/// boundary or a lost write can hide". Reported rather than quietly dropped, as
/// §9 requires.
///
/// ### It is a shell, and holds no logic
///
/// `Widget/` is not compiled by `swift test` and has no test target, exactly like
/// `App/`. A mutation pass has twice proved what that costs — a
/// `preconditionFailure` on the store-open path and a dropped argument both left
/// the whole suite green — so every line that can be wrong lives in
/// `AppComposition.widgetPress`, which the suite compiles, and `perform()`
/// forwards one value and returns.
///
/// It does not throw, and that is a decision rather than an omission: the two
/// things a press can be refused for both mean the button outlived the row it was
/// drawn from, and an error dialog thrown over the Home Screen for a button that
/// is merely out of date is worse than the stale button was. The redraw is the
/// message — the row will not be in it. See ``AppComposition/widgetPress(_:storeURL:clock:)``.
struct ToggleHabitIntent: AppIntent {

    static let title: LocalizedStringResource = "Record a habit"

    /// **Not discoverable.** This keeps the intent out of Shortcuts and Siri,
    /// which is `docs/technical.md` §10b's deferral expressed in the one place
    /// that can actually enforce it. `AppShortcutsProvider` phrases wait on "a
    /// Shortcuts automation is actually wanted", and nothing here should register
    /// a spoken phrase the user would have to memorise.
    static let isDiscoverable = false

    /// The opaque `HabitID`, as a string, because that is what an intent
    /// parameter can carry. It is never derived from the habit's name —
    /// `docs/achievement-protocol.md` §3.4 keeps display names out of anything
    /// digested, and a `HabitID` is exactly what `facts` carries.
    @Parameter(title: "Habit")
    var habitID: String

    init() {}

    init(habitID: String) {
        self.habitID = habitID
    }

    func perform() async throws -> some IntentResult {
        _ = AppComposition.widgetPress(HabitID(rawValue: habitID))
        return .result()
    }
}
