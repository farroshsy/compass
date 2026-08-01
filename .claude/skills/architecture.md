# Architecture rules

Read `docs/technical.md` before changing structure. Read `docs/adr/` before
overturning a decision.

- One repository, named `compass`. Never fork it. If you want `compass-v2`,
  delete a file inside `compass` instead.
- **Three tiers of rebuildability, not two.** Irreplaceable: `events.jsonl` and
  `awards.jsonl`. Irreplaceable *in part*: `attestations.jsonl` and, from week 4,
  `anchors.jsonl` — their `otsProof`, `signature`, `publicKey` and `chain` cannot
  be recomputed (a resubmitted OTS proof gets a strictly later Bitcoin timestamp;
  a signature is gone with the key), while only their `state` and timestamps can.
  A log **head** is recomputable from the log at any moment; the proof over it is
  not, and that asymmetry is the whole reason `anchors.jsonl` is in this tier.
  Disposable: `snapshot.json`, the projection, any derived file. ADR 0002.
- Every path gets its base URL from a **single injected `storeURL`**. Construct a
  file path nowhere else. That is what made moving to the App Group container a
  one-line change plus a file move, done in week 1b —
  `group.dev.farros.compass`, with a documented fallback to Documents when the
  container is unreachable, because `docs/technical.md` §6 refuses to let the
  paid developer account gate storage code. Keep the rule: the next store move
  should also be one line.
- **The snapshot cache is disposable and must stay unable to hurt anything.** It
  carries no `lamport`, no chain head and no `device`, and never will: a file
  that may be deleted at any moment must never be able to fork a chain. The
  replay wins and `TodayModel` drops the cache the moment it lands.
- `docs/product.md`'s **non-goals are the authority.** If anything in `docs/` or
  in these skills reserves a field, an event kind or a UI element for something
  listed there, delete it rather than designing around it. Overturn a non-goal in
  `memory/decisions.md` with a date and a reason, or leave it alone.
- **`CompassInfrastructure` imports `CompassApplication` from week 2.** The widget
  is a second writer and must reach the same `CheckIn.toggle` the app reaches; its
  path into the store is Infrastructure. The edge runs Infrastructure →
  Application → Domain, so there is no cycle and the boundary below is untouched.
  `docs/technical.md` §2, `memory/decisions.md` 2026-08-01.
- `CompassDomain` imports Foundation and **CryptoKit**, and nothing else. It must
  never learn that Infrastructure exists. This is the only load-bearing boundary;
  if Application-vs-Domain starts costing edits in four targets for one field,
  collapse Application into Domain. CryptoKit was added in week 1b because
  `content_hash` and `evidenceRoot` both need SHA-256 in the pure layer — a
  hashing port would be an abstraction with a single use site and a hand-rolled
  SHA-256 would be novelty over mature technology. A **platform framework** is not
  a package target and adding one does not weaken the boundary; a third-party
  package still needs a fired trigger in `docs/technical.md` §10.
  `docs/technical.md` §2, `memory/decisions.md` 2026-08-01.
- **The canonical bytes are hand-written and live in exactly one file**,
  `CompassDomain/CanonicalBytes.swift`. Never `JSONEncoder`: key order is not a
  promise Swift makes across releases. The form is the eleven values
  `docs/technical.md` §3 freezes, in that order, and `payload` is inside it —
  omitting `payload` once meant `habitID` sat outside the digest and a meditation
  streak could be rewritten into a reading streak with every proof still
  verifying. Escape `\\`, `\"`, `\n` and reject every other control character at
  write time. If `CanonicalBytesTests` ever needs updating, stop.
- **`prev` chains per writer, never globally**, and the head is recovered
  together with `lamport` — one `WriterResume`, because a `lamport` without its
  head appends onto a chain whose previous link is unknown, which is a fork.
  Canonicalise **before** writing, so a refused event never reaches the file.
- **The `reproject` hatch is used exactly once and is now spent.** It ran on
  2026-08-01 against the real log; `events.jsonl.pre-chain` is the original and is
  never overwritten. It closes for good at the first signature. Do not re-run it
  to "repair" a chain that breaks later — a later break is damage to report, not
  a `prev` to recompute.
- Infrastructure is constructed in exactly one file, the composition root
  `Sources/CompassInfrastructure/Composition.swift`. Nowhere else. It lives
  inside the package, not in `App/`, because `App/` is not compiled by
  `swift test` — mutation showed two real fixes there were covered by no test at
  all. `App/` is a thin shell that calls the root and holds no branch, no
  `catch` and no forwarded argument. `docs/technical.md` §2,
  `memory/decisions.md` 2026-07-31.
- **`Widget/` is a shell, exactly as `App/` is.** Not compiled by `swift test`, no
  test target. An `AppIntent` conformance, a timeline provider and a view — no
  branch, no `catch`, no decision. Everything that can be wrong lives in
  `CompassInfrastructure/WidgetStore.swift` and the two entry points beside it,
  `AppComposition.widgetScreen` and `AppComposition.widgetPress`, both of which
  take a `storeURL` so a test can drive them.
- **Behaviour never lives in `@State` inside a `View`.** What a control commits,
  discards or refuses goes in a plain value beside the view; the view keeps the
  layout. `@State` inside a `View` is state no test can construct or drive, and
  `.claude/skills/testing.md` refuses snapshot tests and a broad XCUITest suite
  out loud — so "test it through the view" is not available here, and pretending
  otherwise is how bugs live forever. Measured, not aesthetic: two data bugs sat
  in three `@State` properties in `SettingsView` — Done discarding the declared
  name, and Done writing a rename the user had cancelled by removing the habit —
  and **both survived a suite of 206 tests.** `Sources/CompassUI/SettingsEdits.swift`
  is the pattern. It is the same rule as the composition root above, one target
  down. `memory/decisions.md` 2026-07-31.
- **The canonical bytes are THREE forms in ONE file.** `CanonicalBytes.swift`
  holds the event form (`docs/technical.md` §3), the achievement form
  (`docs/achievement-protocol.md` §6) and, from week 4, the log-head anchor form
  (`docs/technical.md` §6). They are frozen by different documents and must never
  be merged into a shared writer: a change made "for both" is a change made to a
  format that is already signed. Each has its own hardcoded digest hex,
  transcribed from its document by hand and computed by tools outside this
  project.
  - **The log-head form carries no timestamp, and that is load-bearing.** ADR
    0004's argument against `attainedAt` on a chain — a self-asserted instant is
    "just a number the issuer typed in" — applies to it word for word. The
    consequence is that unchanged heads always digest to the same value, which is
    why they are never re-anchored: a second submission buys a strictly *later*
    Bitcoin timestamp for a value that already has an earlier one.
- **The proof is the one thing in the store that cannot be recomputed.** Never
  discard an OTS proof, never replace one with a fresh submission, and never
  "clean up" `anchors.jsonl` or `attestations.jsonl`. Merging two proofs is a
  union and never a replacement. Everything else in this system can be rebuilt
  from `events.jsonl`; a timestamp cannot be rebuilt at all, only re-obtained,
  and a re-obtained one is later and therefore weaker.
- **Nothing frozen into a record ever carries a habit's display name — including
  `rule.id`.** `facts` carries `habitID`, and a rule ID reads
  `streak.habit-a.100`, never `streak.meditate.100`. `rule.id` is digested and is
  printed verbatim on the certificate, so the protocol's own example would put an
  unredactable name on the artifact handed to a stranger. The name is resolved at
  render time from the mutable mapping. `memory/decisions.md` 2026-08-01.
- **`awards.jsonl` has no deletion path, in any state, for any reason.** A
  revocation is an appended `Revocation` beside the record, never a removal — you
  never erase a published entry, you post a reversal. `attestations.jsonl` is
  append-only too and last-write-wins **on read**; nothing rewrites a line.
- **The achievement engine is a pure function of the log, and takes the log.**
  `docs/technical.md` §4's `evaluate(projection)` cannot be implemented:
  `evidenceRoot` is built from the qualifying events' `content_hash` and a
  projection has no events. Do not teach `Projection` to carry events — it is
  rehydrated from a cache that has none.
- New capability goes behind an existing port if one fits. New ports are added
  in `CompassDomain/Ports.swift` and nowhere else.
- Never mutate or delete an event. Un-checking appends `checkInRevoked`.
- Never sort by wall-clock time. Total order is `(lamport, device)`.
- **`lamport` is a Lamport clock, not a per-writer serial number.** A writer
  resumes from the highest `lamport` in the **whole log**, never from the highest
  of its own — that is what "Lamport first so causality holds" means, and week 1b
  implemented the other thing while `docs/technical.md` §3 said this one. With one
  writer they are the same number; with two they are not, and the difference is
  silent. Week 2's measurement: a cold widget starting at 1 had every un-check
  outranked by the app's higher-numbered check-ins and discarded by the fold,
  permanently, with the event on disk the whole time. Per-writer monotonicity and
  `(lamport, device)` uniqueness both survive — a maximum over a set containing
  this writer's mark cannot be below it. **The chain head is not the clock:** the
  head is this writer's own and is never raised by another writer's event. They are
  recovered together and updated apart.
- **A long-lived process re-primes its clock on every replay**, and the app
  reconciles whenever it becomes active rather than once per view lifetime. A
  `lamport` read at launch is stale the moment the other writer appends, and a tap
  made a second ago must not tie with a widget press from ten minutes ago.
- **The two writers go through one append API.** `CheckIn.toggle` decides the
  kind, the `source` and the payload, and both the app and the widget call it —
  which is why `CompassInfrastructure` imports `CompassApplication` from week 2.
  Writing that decision twice is the fork `docs/technical.md` §4 exists to prevent,
  and it has no lock behind it to catch it.
- **The widget's journal is single-use, and the app's is not.** One press opens a
  journal, records one event under the advisory `flock`, and closes it — because
  iOS may run several widget extension instances and all of them share the writer
  name `widget`, so a cached resume would go stale behind another instance. The app
  is one long-lived primed journal because §4 forbids a full decode on its tap
  path. Do not "optimise" the widget by handing its journal a resume: that is what
  makes `record` skip the lock.
- `device` is a **random 128-bit UUID** generated at first write and stored
  locally. Never `identifierForVendor`, never the device name, never anything
  derived from hardware or the Apple ID, and never displayed. It is signed,
  anchored and shipped to strangers inside every exported achievement.
- `device` means **writer, not phone.** The app and the widget are two writers
  with two UUIDs, two `lamport` sequences and two `prev` chains. One event per
  `write(2)` to an `O_APPEND` descriptor; take an advisory `flock` around any
  read-tail-then-append. `docs/technical.md` §4.
- Habit display names never enter a digest. `facts` carries `habitID`; the name
  lives in a mutable local `habits.json` resolved at render time.
- Never use `Calendar.current`, `TimeZone.current`, `Date()` or a locale inside
  `CompassDomain`. Time enters through the injected `Clock` port.
- No global accumulators in the fold. Every accumulator is keyed by `habitID`.
- No floating point anywhere in the fold or in any digested value.
- Additive changes only. Do not bump `"v"`. Do not rename a field. Do not remove
  a field. Add an optional one, or use `extra`.
- Preserve unknown fields and unknown event kinds on read and re-emit them
  unchanged. Never drop data you do not understand.
- Every taxonomy this project owns is a `RawRepresentable` struct over `String`,
  never a Swift enum. Enums only for closed sets someone else defined.
- No third-party dependency without a written trigger in `docs/technical.md`
  §10 that has actually fired. Code reused from the `before` repository is
  **copied in** with an attribution header — never an SPM path dependency, never
  a submodule. A build that breaks because an unrelated folder was tidied is a
  restart trigger.
- No server, no backend, no hosted service. Ever. Two named consequences: the
  OpenTimestamps calendars are the one operational dependency the project does
  take, and it is declared as an exception in `docs/product.md`; and a hosted
  `apple-app-site-association` file would violate this rule, which is part of
  why the identity limb in ADR 0003 is refused rather than deferred.
- Before adding a file, check whether the change belongs in an existing one.
  This codebase should stay small enough to read in an afternoon.
