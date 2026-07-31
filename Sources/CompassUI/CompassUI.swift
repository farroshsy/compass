// CompassUI — imports CompassApplication and CompassDomain.
// `docs/technical.md` §2.
//
// It cannot import CompassInfrastructure: Swift enforces `import` at target
// granularity, so the adapters are constructed in `App/`, the composition root,
// and reach this target only as the ports declared in `CompassDomain/Ports.swift`.
//
//   TodayModel.swift    the tap path (§4) and the launch path, plus the haptic.
//                       `@MainActor @Observable final class`, never an actor.
//   TodayView.swift     the one screen on the launch path, with HabitRow and
//                       SpineView. Bottom-anchored, one-handed, at most four rows.
//   TodayMetrics.swift  every number those two are built from, as arithmetic a
//                       test can assert rather than a rendering it cannot.
//   TodayCaption.swift  the words in the header: the caption sentence, and the
//                       store notice, which is both shown and spoken.
//   HabitTint.swift     the four row colours, and the only colour on Today.
//   SettingsView.swift  the settings sheet's layout.
//   SettingsEdits.swift the settings sheet's behaviour — what has been typed and
//                       not yet confirmed, and what each control commits. It is
//                       beside the view rather than inside it because `@State`
//                       in a `View` is state no test can construct or drive, and
//                       two data bugs lived there undetected.
//   SettingsCopy.swift  the sentences that sheet says, so that what the app
//                       claims is a thing a test can read.
//
// The surface budget off the launch path is exactly three — settings sheet,
// certificate, certificate list — and it is counted in `docs/product.md`. **The
// settings sheet is built**: rename in place, add, remove, restore, and the
// declared name. Export is budgeted to it and not wired to it yet; the
// certificate and the certificate list need the achievement engine in week 3.
// Adding a *fourth* surface means editing that list first.
