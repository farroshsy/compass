// CompassInfrastructure — imports CompassDomain. `docs/technical.md` §2.
//
// The port adapters, and the only place in the codebase that touches a file
// descriptor, a timezone or a syscall.
//
//   StoreLayout.swift     the single injected `storeURL`, and every path built
//                         from it — nowhere else constructs one. §6, ADR 0002.
//   SystemClock.swift     the `Clock` port, and the ONLY place a `Date` becomes
//                         a `Day`, applying the 04:00 civil-day boundary. §3.
//   WriterIdentity.swift  this writer's random 128-bit `DeviceID`. §3, §4.
//   EventJournal.swift    the append-only JSON Lines log: one `write(2)` of one
//                         complete line to an `O_APPEND` descriptor. §4, §6.
//   Export.swift          the export bundle and the import that verifies it.
//                         §8, §10a — scheduled for week 1.
//   Composition.swift     the composition root: the ONE place the adapters above
//                         are wired together. It is here rather than in `App/`
//                         because `App/` is not compiled by `swift test` and has
//                         no test target, so the two behaviours that decide
//                         whether a launch succeeds — a store that cannot be
//                         opened does not crash, and the journal starts already
//                         knowing its high-water mark — were unprotected.
//                         `App/` is now a shell with no logic in it. §2, §4, §6.
//
//   Signer.swift          copied from `before` in week 3, with both §8 fixes and
//                         without `sign(_ text:)`, which double-hashes.
//   Calendars.swift       copied from `before` in week 4, with its
//                         first-success-wins behaviour fixed **during** the
//                         copy: ADR 0004 requires all three, not the first.
//   OpenTimestamps.swift  the proof format, by hand. Needed because holding
//                         three answers in one artifact and asking for an
//                         upgrade both require the format itself.
//   Anchoring.swift       the weekly log-head anchor, the 72-hour gate, the
//                         upgrade pass, and the `Attestor` adapter. §9.8.
//   AnchorScheduler.swift the `BGProcessingTask` half. Deliberately thin: it is
//                         the half no test can watch.
//
// `Log.persist()` from `before` is **not** copied and never will be — it
// rewrites the whole array on every append. §1, ADR 0002.
//
// Everything in `docs/technical.md` §11's build order has now landed. What is
// owed is in `memory/known-bugs.md`, and it needs a phone rather than a file.
