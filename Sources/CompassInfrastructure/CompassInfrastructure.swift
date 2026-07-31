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
//
// Still to land here, in build order (`docs/technical.md` §11): the hand-written
// canonical byte encoding, `content_hash` and `prev` chaining with the one-time
// `reproject` hatch, the App Group container move and `actor EventLog` (week
// 1b); `Seal.swift` and `Calendar.swift` copied in from the `before` repository
// with an attribution header, and never `Log.persist()` (weeks 3 and 4).
