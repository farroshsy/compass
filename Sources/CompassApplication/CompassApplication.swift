import CompassDomain

// CompassApplication — imports CompassDomain. `docs/technical.md` §2.
//
// **This target is one function, and that is deliberate.** §2 says only one
// boundary is load-bearing — Domain must not know Infrastructure exists — and
// that Application-versus-Domain is a nicety: "If adding one field starts
// requiring coordinated edits in four targets, collapse `CompassApplication`
// into `CompassDomain`."
//
// Week 1's tap path has three steps (`docs/technical.md` §4): apply to the
// projection, fire the haptic, append synchronously. The first is Domain, the
// second is UI, the third is Infrastructure. A `TodayService` wrapping those
// would hold no state and make no decision — it would forward three calls and
// add a target to every future change. So it is not written.
//
// What is left over is genuinely neither Domain nor Infrastructure: deciding
// *which* event a tap appends. It reads a projection and returns a kind — no
// I/O, no clock, no state — and it is the one piece the app process and the
// week-2 widget process must agree on exactly, because two writers disagreeing
// about what a tap means is a fork with no lock to catch it.

/// The tap-path decision. `docs/technical.md` §4, `.claude/skills/ui.md`.
///
/// Tap toggles, tap again untoggles, and there is never a confirmation dialog.
/// Untoggling appends a compensating ``EventKind/checkInRevoked`` rather than
/// deleting anything: nothing in this system is ever mutated or deleted, and the
/// fold resolves the `(habit, day)` cell last-writer-wins under the total order.
public enum CheckIn {

    /// The event kind a tap on `habit` appends for `day`.
    ///
    /// `day` is the civil day the tap is *about*, already resolved through the
    /// 04:00 boundary by the caller's ``Clock``. It is passed in rather than
    /// derived here because the boundary is applied exactly once, when the event
    /// is created, and never in the fold.
    public static func kind(
        for habit: HabitID, on day: Day, in projection: Projection
    ) -> EventKind {
        projection.isChecked(habit, on: day) ? .checkInRevoked : .checkedIn
    }

    /// The payload that accompanies that kind. Both check-in kinds carry
    /// `{"habitID":<string>}` and nothing else — `payload` is closed, and new
    /// semantics arrive as a new kind rather than as a new key.
    public static func payload(for habit: HabitID) -> EventPayload {
        .habit(habit)
    }

    /// The `source` that accompanies that kind — present on ``EventKind/checkedIn``
    /// and **absent on every other kind**.
    ///
    /// `docs/technical.md` §3 defines the two check-in events as
    /// `checkedIn(habitID, day, source)` and `checkInRevoked(habitID, day)`: a
    /// revocation has no source. That is not a display detail. `source` sits
    /// inside the canonical form, and absent optional fields are "omitted
    /// entirely, never emitted as `null`" — so stamping a source onto a
    /// revocation writes an out-of-spec digested field to disk on every un-tap,
    /// and once anything is signed that is unfixable.
    ///
    /// It takes the writer's `origin` rather than assuming ``CheckInSource/tap``
    /// because the answer differs per writer: the app taps, and the week-2
    /// widget process asks this same question and answers ``CheckInSource/widget``.
    /// Two writers disagreeing about what a tap means is a fork with no lock to
    /// catch it, which is why the decision lives here rather than in either
    /// caller.
    public static func source(
        for kind: EventKind, from origin: CheckInSource
    ) -> CheckInSource? {
        kind == .checkedIn ? origin : nil
    }
}
