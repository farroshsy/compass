# Next tasks

Ordered. Do not skip ahead. Each block should end with something usable.

## Nothing blocks the first line of code

There used to be a "blocking — before any code" section here holding a $99
purchase, an individual-verification wait, and two product decisions. It was
wrong, and it was wrong in the most expensive possible direction for this
particular project: the documented failure mode is that 58 of 76 attempts died
on the day they were created, and the task list made day one impossible to
finish.

Both blockers were refuted by the corpus itself:

- `swift test` needs no account, no profile and no device. `Day`, `Event`,
  `project()` and the journal are all reachable from it.
- "Name the two habits" was blocking because "the layout, the notification hour
  and the milestone cadence all depend on them". There is no notification any
  more, and `docs/technical.md` defines `habitRenamed` as cosmetic and never
  affecting the fold — so a name is by construction the cheapest thing in the
  project to change.

**Settled, and it worked. Week 1a shipped on 2026-07-31.** `swift test` reports
218 tests in 23 suites passing, a history many commits deep, and the
app builds, installs on a simulator and launches onto four grey habit rows. This
section is kept as the record of a blocker that was wrong, not as a live
instruction.

**What is next is not code.** Week 1b's entry condition is that the app has been
opened three days running, and nothing in this repository says it ever has. See
`memory/current-focus.md`; the honest next action is to put it on the phone and
use it.

### Running in parallel, blocking nothing

- [ ] **Start the paid Apple Developer enrolment now**, in a separate sitting,
      because individual verification takes days. It blocks nothing until the
      app goes on the phone to stay.
- [x] **Name the habits — done, 2026-07-31.** Four, seeded in the bundle with
      their names already set: **Move, Read, Build, Reflect**, one per domain —
      health, learning, deep work, reflection. `AppComposition.seededHabits` is
      the list and `CompositionTests` pins it. This seeds at the four-habit cap,
      which is only safe because `TodayMetricsTests` proves four rows still fit
      at AX5. Renaming is a cosmetic event by construction and now has a control:
      the name is editable in place in the settings sheet, so changing one costs
      nothing and keeps the habit's whole history.

### Blocking — before the app lives on the phone permanently

- [ ] **A paid account and a TestFlight install path.** A free profile expires
      after seven days and an app that uninstalls itself weekly cannot become a
      habit. A seven-day profile is fatal to a habit but *not* to a seven-day
      skeleton, so week 1 may ship on a free profile while enrolment processes.
- [ ] **Know the ninety-day rule before relying on TestFlight.** A TestFlight
      build stops launching 90 days after upload. Upload every quarter. When one
      expires, **update in place — never delete and reinstall**, because
      deleting the app destroys the App Group container and the whole log.

---

## Week 1a — something tappable, on the phone, on day one

The goal of this block was a working checkbox, not a correct one. **It shipped
on 2026-07-31.** Every box below except the last is ticked against the machine,
not against another document — `swift test`, `xcodebuild`, and a screenshot of a
fresh simulator install.

- [x] `Package.swift` with four targets; `project.yml` for xcodegen. Both exist;
      `xcodegen && xcodebuild … build` reports `** BUILD SUCCEEDED **`.
- [x] `Day` as an integer ordinal, encoded as `"YYYY-MM-DD"`. `DayTests` is
      exhaustive — civil components round-trip for every ordinal across four
      centuries.
- [x] `Event` as a plain struct with `JSONEncoder`, and `project(_:)` as a pure
      fold. `ProjectionTests` carries the shard-invariance test.
- [x] `Journal` — `EventJournal` appends one line synchronously to an open
      `FileHandle`, and the base URL comes from a single injected `storeURL`
      via `StoreLayout`. Truncate-at-every-byte-offset test passes.
- [x] `TodayView`, `HabitRow`, `SpineView`, `TodayModel`. Bottom-anchored. Four
      habits seeded in the bundle with names already set — Move, Read, Build,
      Reflect. No first-launch flow, no keyboard, no permission prompt.
- [ ] **Install on the phone. Use it.** Free profile is acceptable here.
      **This is the only unticked item in week 1a, and it is the one that
      unlocks week 1b.** A simulator install has been demonstrated; that is a
      build check, not use.

### Landed in week 1a but scheduled nowhere

Recorded rather than back-dated into the plan above, because the plan is
evidence about what was expected and rewriting it destroys that. `docs/technical.md`
§11 carries the same note.

- [x] **The settings sheet** — `SettingsView`, `SettingsEdits`, `SettingsCopy` —
      with add, remove (appends `habitArchived`, deletes nothing), restore, and
      rename in place. The build order put habit management no earlier than
      week 3; the four-habit seed made renaming the only way to change a name,
      so it came forward.
- [x] **The declared name on the record**, optional, never verified, and the
      sheet says so.
- [x] **The Record app icon**, wired into `App/Assets.xcassets` and compiling
      into `Assets.car`.
- [x] **`Export`** as a bundle — implemented and tested at
      `Sources/CompassInfrastructure/Export.swift`, scheduled below in week 1b.
      **No surface calls it yet**, so it is code the user cannot run.
      `memory/known-bugs.md`.
- [x] **`AppComposition`** as a composition root inside the package rather than
      in `App/`, so the wiring is testable. `memory/decisions.md`, 2026-07-31.
- [x] **The unopenable-store path**: the app never refuses to launch, and says
      on screen that it is not recording. `docs/technical.md` §6.

## Week 1b — the encoding, once the app is being used

**Entry condition: the app has been opened three days running.** Not before.

- [ ] The **hand-written canonical byte encoding** and `content_hash`, per
      `docs/technical.md` §3. Include `device`, `lamport` and `prev`. `device`
      is a **random 128-bit UUID** — never `identifierForVendor`, never the
      device name.
- [ ] Encoding-stability test with a hardcoded digest hex, plus the assertion
      that a signature over `canonicalBytes` fails against `digest`.
- [ ] The one-time **`reproject`** step: replay the week-1a log into a freshly
      chained log, keeping the old file as `events.jsonl.pre-chain`. This hatch
      may be used exactly once and closes the moment anything is signed.
- [ ] Replay-parity test. **The truncate-at-every-offset crash test already
      exists** and passes — `EventJournalTests`, "truncating at every byte
      offset drops only the partial tail".
- [ ] Damaged-log recovery policy per `docs/technical.md` §6, with its test.
- [ ] Move `storeURL` to the App Group container. One line plus a file move.
      Set `NSFileProtectionCompleteUntilFirstUserAuthentication`.
- [ ] `actor EventLog` for replay and the in-memory array.
- [ ] Snapshot cache, read synchronously in `TodayModel.init`.
- [x] **`export` as a bundle** — `events.jsonl` + `awards.jsonl` +
      `attestations.jsonl` + frozen rule JSON + `habits.json` + public keys +
      every `.ots` proof + `manifest.json` of per-file digests. Stated in these
      exact words in `docs/product.md`, `docs/technical.md` §8 and ADR 0002 so
      the four copies cannot drift. Not the log alone — the log alone contains
      neither the achievements nor the proofs it is claimed to preserve.
      **Shipped early, in week 1a**, as `Sources/CompassInfrastructure/Export.swift`
      with `export`, `verify` and `restore`. It writes only the artifacts whose
      features exist, so a bundle today is `events.jsonl`, `habits.json` and
      `manifest.json`, and gains the rest as they land.
- [x] Bundle-restore round-trip test. An unexercised escape hatch is not one.
      `ExportTests`.
- [ ] **Give export a surface.** The two boxes above are ticked and the user
      still cannot export: nothing in `CompassUI` calls `Exporter`. Until that
      exists, the insurance policy is unreachable and the phone-loss hazard in
      `memory/known-bugs.md` is unmitigated in practice. This is the smallest
      remaining piece of week 1b and it is not in the original plan because the
      plan assumed the code would arrive with its button.

## Week 2 — the widget

- [ ] `ToggleHabitIntent` and `CheckInIntent` in a shared target. Substrate only.
- [ ] Interactive `.systemSmall` widget with two buttons. This takes the loop
      from ~3s to ~0.7s and is the highest-value item per line of code here.
      It is also the reminder — that is why there is no notification.
- [ ] **The widget is a second writer**: its own `device` UUID, its own `lamport`
      sequence, its own `prev` chain. One event per `write(2)` to an `O_APPEND`
      descriptor; advisory `flock` around any read-tail-then-append.
- [ ] **Two-writer test, shipped with the widget, not after it.** Every other
      test uses synthesised in-process streams and would pass while real data
      silently corrupts.
- [ ] **No `AppShortcutsProvider` phrases.** No Control Center control, no Action
      Button. Their triggers are in `docs/technical.md` §10 and have not fired.

## Week 3 — achievements, sealed locally

**The seal and certificate assets and their full specification are already in
this repository — `Assets/seal/` and its README. Read them before designing
anything here; nothing about the certificate needs to be invented.**

- [ ] `RuleSpec` and rule JSON in the bundle. `streak` and `total` evaluators
      only; the other four kinds named but unimplemented.
- [ ] The achievement engine, per `docs/achievement-protocol.md`. Deterministic
      IDs. Fire-exactly-once tests.
- [ ] `facts` carries **`habitID`, never the habit's display name.** The name
      lives in a mutable local `habits.json` resolved at render time. A name
      frozen into a signed, anchored, shareable record can never be taken back.
- [ ] `facts` must carry `source_live` and `source_backfill`, summing to
      `witness.dayCount`. Required even though no backfill surface ships in v1 —
      these are inside the digest and cannot be added later. `source_backfill`
      is `0` on every v1 record.
- [ ] `evidenceRoot` Merkle construction per `docs/achievement-protocol.md` §4.1
      — leaf/node domain separation, promote-don't-duplicate on odd nodes. It is
      already specified; implement it, do not redesign it.
- [ ] `Signer` **copied in** from the `before` repository, with two fixes made
      during the copy: persist the enclave key to the keychain with
      `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and add
      `init(enclaveKeyData:)`, or every launch gets a different public key; and
      never call `sign(_ text:)` on this path. `docs/achievement-protocol.md`
      §6.7 fixes the convention.
- [ ] Test: two `Signer` constructions across a relaunch yield the same
      `publicKey`.
- [ ] `CertificateView`. Serif. Fades up. No confetti. Reads **"Sealed on this
      device"** and nothing about anchoring.
- [ ] Certificate list in the settings sheet, so a certificate is re-openable and
      shareable after dismissal. No "new" indicator.

## Week 4 — anchoring, and making the claim checkable

- [ ] `OpenTimestampsAttestor` behind the `Attestor` port. **Submit to all three
      calendars**, not first-success-wins.
- [ ] 72-hour provisional window before submission.
- [ ] **Weekly log-head anchoring.** Not deferred — the week-3 engine backfills
      historical 7-day and 30-day awards the first time it runs, which is the
      trigger. Ship this before `CertificateView` claims anything about the past.
- [ ] `BGProcessingTask` with exponential backoff **and** an opportunistic drain
      of the pending queue on launch. Both — `BGProcessingTask` has no execution
      guarantee, and the launch drain is the only path observable in a test.
- [ ] The certificate gains its anchor line, and **only** once `AnchorState` is
      `confirmed`. A submitted proof is not an anchored one.
- [ ] Scheduled export of the full bundle to iCloud Drive, plus a first-launch
      check that the last successful export has not aged out.
- [ ] **The standalone verifier**, ~200 lines, in this repository. Without it the
      mission sentence describes something the project does not ship.
- [ ] The one real network test.

## Measurements owed, per standing evidence rules

- [ ] Cold launch to first frame, on the actual phone. Measure, then write the
      number into a failing test. 400ms is a proposal, not a measured figure.
- [ ] Full replay time on the actual phone. That number becomes the ADR 0002
      trigger. 250ms is a proposal.
- [ ] Confirm on device that `Button` is genuinely interactive in Lock Screen
      accessory widget families before designing a tap into one.

## Not now, and do not drift into them

The chain limb, sync, watchOS, GRDB, compaction, rarity, neutral days, backfill,
Siri phrases, Control Center, the Action Button, and the four unimplemented rule
kinds. Each has a written trigger in `docs/technical.md` §10. Check the trigger
has actually fired before starting.

The chain limb additionally requires a dated entry in `memory/decisions.md`
overturning a `docs/product.md` non-goal — see ADR 0003 §2.5 and
`PROJECT_CONSTITUTION.md` §14. **What that refuses is ADR 0003's specific
recovery ceremony, not the subsystem:** §3 of the constitution makes the
blockchain mandatory, and this line said "it is refused, not deferred" until
2026-08-01, which reads as permission to drop it. Build it; do not build it that
way, and resolve §14 first.
