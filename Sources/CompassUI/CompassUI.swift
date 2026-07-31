// CompassUI — imports CompassApplication and CompassDomain.
// `docs/technical.md` §2.
//
// It cannot import CompassInfrastructure: Swift enforces `import` at target
// granularity, so the adapters are constructed in `App/`, the composition root,
// and reach this target only as the ports declared in `CompassDomain/Ports.swift`.
//
//   TodayModel.swift  the tap path (§4) and the launch path, plus the haptic.
//                     `@MainActor @Observable final class`, never an actor.
//   TodayView.swift   the one screen on the launch path, with HabitRow and
//                     SpineView. Bottom-anchored, one-handed, at most four rows.
//
// The surface budget off the launch path is exactly three — settings sheet,
// certificate, certificate list — and it is counted in `docs/product.md`. None
// of them is built yet: the settings sheet needs export and rename, and the
// certificate needs the achievement engine in week 3. Adding a fourth means
// editing that list first.
