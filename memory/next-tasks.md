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

**Settled, and it worked. Week 1a shipped on 2026-07-31, weeks 1b and 2 on
2026-08-01.** `swift test` reports 482 tests in 46 suites passing, a history many
commits deep, and the app builds, installs on a simulator, launches onto four grey
habit rows, and carries an interactive Home Screen widget. This section is kept as
the record of a blocker that was wrong, not as a live instruction.

**What is next is still not code.** Week 1b's entry condition — the app opened
three days running — was waived on 2026-08-01, not met. The honest next action is
unchanged and is now overdue: put it on the phone and use it.
`memory/current-focus.md`.

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

## Week 1b — the encoding. **Shipped 2026-08-01.**

**Entry condition: the app has been opened three days running.** Waived by the
owner on 2026-08-01 — `memory/decisions.md` — not met. The `reproject` hatch was
the mitigation §11 provided for exactly that, and it is now spent.

- [x] The **hand-written canonical byte encoding** and `content_hash`, per
      `docs/technical.md` §3. `device`, `lamport` and `prev` all inside it, and
      `payload` per kind, closed. `CompassDomain/CanonicalBytes.swift`; it is the
      only place the form exists in code.
- [x] Encoding-stability test with a hardcoded digest hex —
      `CanonicalBytesTests`. The expected byte string is transcribed from §3 by
      hand and its SHA-256 comes from two tools outside this project, so the test
      pins the *document* rather than the code. **The signature half of this is
      week 3's**, when there is a key: a signature over `canonicalBytes` must
      verify against `canonicalBytes` and fail against `digest`.
- [x] The one-time **`reproject`** step. `CompassInfrastructure/Reproject.swift`.
      It has run on the real log; `events.jsonl.pre-chain` holds the original and
      is never overwritten. It refuses on a damaged log, refuses once anything is
      signed, and refuses to run a second time on a log that broke later.
- [x] Replay-parity test — already existed, kept. The truncate-at-every-offset
      test now also asserts the surviving prefix is an **unbroken chain**.
- [ ] Damaged-log recovery policy per `docs/technical.md` §6, with its test.
      **Half done and the half that is missing is the visible one.** Damage is
      now detected and reported — `JournalRead.chain` walks every writer's chain
      and lists each break — but nothing writes `events.jsonl.damaged-<timestamp>`
      and nothing surfaces the one notice §6 owes. See `memory/known-bugs.md`.
- [x] Move `storeURL` to the App Group container. One line plus a file move, as
      promised. `group.dev.farros.compass`, `App/Compass.entitlements`, and a
      documented fallback to Documents when the container is unreachable.
      `NSFileProtectionCompleteUntilFirstUserAuthentication` was already applied
      by `StoreLayout.prepare()`.
- [x] `actor EventLog` for replay and the in-memory array. It also owns the
      snapshot and primes the journal from the read it does anyway.
- [x] Snapshot cache, read synchronously in `TodayModel.init` — via the
      composition root, which no longer decodes the log when a usable cache
      exists. It carries no `lamport` and no chain head, deliberately.
- [x] **`export` as a bundle** — `events.jsonl` + `awards.jsonl` +
      `attestations.jsonl` + `anchors.jsonl` + frozen rule JSON + `habits.json` +
      public keys + every `.ots` proof + `manifest.json` of per-file digests. Stated in these
      exact words in `docs/product.md`, `docs/technical.md` §8 and ADR 0002 so
      the four copies cannot drift. Not the log alone — the log alone contains
      neither the achievements nor the proofs it is claimed to preserve.
      **Shipped early, in week 1a**, as `Sources/CompassInfrastructure/Export.swift`
      with `export`, `verify` and `restore`. It writes only the artifacts whose
      features exist, so a bundle today is `events.jsonl`, `habits.json` and
      `manifest.json`, and gains the rest as they land.
- [x] Bundle-restore round-trip test. An unexercised escape hatch is not one.
      `ExportTests`.
- [x] **Give export a surface. Shipped 2026-08-01.** The two boxes above were
      ticked for weeks while the user still could not export: nothing in
      `CompassUI` called `Exporter`, so the insurance policy was unreachable and
      the phone-loss hazard in `memory/known-bugs.md` was unmitigated in
      practice. It was not in the original plan because the plan assumed the code
      would arrive with its button.

      What shipped: an `Exporting` port in `CompassDomain/Ports.swift`,
      `Exporter.bundle(at:)` returning the bundle in memory,
      `CompassUI/ExportDocument.swift`, and an export section at the bottom of
      the settings sheet using **`fileExporter`** — not `ShareLink`, which
      `.claude/skills/ui.md` reserves for the certificate and which
      `docs/product.md` builds the certificate's whole justification on.
      `ExportTests` pins that the in-memory bundle is byte-for-byte the one
      `export(to:at:)` writes and that the composition root wires the port;
      `ExportControlTests` pins the document, the failure sentence and the
      filename.

## Week 2 — the widget. **Shipped 2026-08-01.**

- [x] `ToggleHabitIntent`, in the `Widget/` shell. **`CheckInIntent` was not
      written** — `.claude/skills/ios.md` ships only the widget in v1 and §10b
      defers every other entry point, so a second intent would have no caller.
      `memory/decisions.md`.
- [x] Interactive `.systemSmall` widget. One row per active habit, the whole row
      is the button, `HabitTint` shared with Today rather than copied. It is also
      the reminder — that is why there is no notification.
- [x] **The widget is a second writer**: `WriterIdentity.widget`, its own `device`
      UUID and its own `prev` chain, one event per `write(2)` to an `O_APPEND`
      descriptor, advisory `flock` around the read-tail-then-append **and** around
      the identity mint. Its journal is single-use, because several widget
      extension instances share one writer name.
      - **It does not have its own `lamport` sequence, and that line was wrong.**
        The clock resumes from the highest `lamport` in the whole log. See below.
- [x] **Two-writer test, shipped with the widget.** `TwoWritersTests` launches
      `CompassLogWriter` twice against one store. **It found a real defect the day
      it was written:** a cold second writer started at `lamport 1`, so every
      un-check it wrote was outranked by the app's higher-numbered check-ins and
      discarded by the fold — permanently, with the event on disk. Four mutations
      are each caught by a different test in it.
- [x] **No `AppShortcutsProvider` phrases**, no Control Center control, no Action
      Button. Enforced rather than remembered: `isDiscoverable = false`.
- [x] **The app re-reads when it becomes active.** `TodayView` reconciles on
      `.task(id: scenePhase)`; a plain `.task` runs once per view lifetime, which
      was only correct while nothing else could write the log.
- [ ] **Add the widget on a phone and press a row.** The only unticked item.
      Placing a widget on the iOS 18.4 simulator segfaults SpringBoard inside
      Apple's wallpaper code, so the press could not be exercised there. The
      gallery preview *did* render the four real habits from the shared container,
      so the cross-process read path is verified. `memory/known-bugs.md`.

## Week 3 — achievements, sealed locally. **Shipped 2026-08-01.**

**The seal and certificate assets and their full specification are already in
this repository — `Assets/seal/` and its README. Read them before designing
anything here; nothing about the certificate needs to be invented.** That held:
nothing was invented, and the five places the design contradicts itself or
`.claude/skills/ui.md` are adjudicated in `memory/decisions.md` rather than
resolved silently.

- [x] `RuleSpec` and rule JSON in the bundle. `streak` and `total` evaluators
      only; the other four kinds named and unimplemented, skipped with a warning
      and left on disk. `Sources/CompassInfrastructure/Rules/` ships 20 per-habit
      streak rows and 3 all-habit total rows, seeded into the store's own
      `rules/` directory so §6's "bundle + user directory" and §8's `rules/*.json`
      in the export bundle are both literally true.
- [x] The achievement engine, per `docs/achievement-protocol.md`. Deterministic
      IDs. Fire-exactly-once, purity, idempotence and arrival-order tests.
      **It takes the log, not a projection** — §4's sketch cannot be implemented
      as written, because `evidenceRoot` is built from the qualifying events'
      `content_hash`. `memory/decisions.md`, `docs/technical.md` §11.
- [x] `facts` carries **`habitID`, never the habit's display name**, and the same
      rule was extended to `rule.id`, which is also digested and is also printed
      on the certificate. `AchievementEngineTests.theRecordNeverCarriesADisplayName`
      checks the whole byte string rather than one field.
- [x] `facts` carries `source_live` and `source_backfill`, summing to
      `witness.dayCount`. Computed rather than hardcoded to `0`, so the day a
      backfill source exists the partition is already right.
- [x] `evidenceRoot` Merkle construction per §4.1 — leaf/node domain separation,
      promote-don't-duplicate on odd nodes, 32 zero bytes for the empty set, and
      a single leaf **is** the root. Implemented, not redesigned.
- [x] `Signer` **copied in** from the `before` repository with both fixes made
      during the copy: the enclave key persisted to the keychain under
      `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and restored through
      `init(store:)`, and `sign(_ text:)` **not copied at all**.
- [x] Test: two `Signer` constructions across a relaunch yield the same
      `publicKey`, against the **real** keychain.
- [x] `CertificateView`. Serif on the `largeTitle` metric — not the fixed 34pt a
      superseded turn's build spec asks for, which would have voided the whole
      accessibility pass. Fades up, no confetti, no colour at all. Reads
      **"Sealed on this device"** and nothing about anchoring, in every state but
      `confirmed`.
- [x] Certificate list in the settings sheet. No "new" indicator. A row
      **re-presents the same certificate** rather than pushing a detail view, so
      the surface budget is still three.
- [x] The 72-hour hold, as arithmetic in Domain, so week 4's submission path is
      not the place the rule is first written down.
- [x] Revocation as an appended `Revocation`, never a deletion, and posted once
      rather than once per launch.

### Owed from week 3

- [ ] **Look at the AX5 seal on a phone.** The 120pt size was rendered and looked
      at on the simulator, which is more than had been done and less than a
      measurement. `memory/known-bugs.md`.
- [ ] **Decide whether a habit added in the settings sheet can earn a streak.**
      It cannot today, because a rule is static data keyed to a `HabitID`. The
      mechanism to close it needs no new concept; the decision does.
- [ ] **The `nameFooter` claim the seal has now earned.** Understating, not
      overstating, so it is safe — but it is no longer the whole truth.

## Week 4 — anchoring, and making the claim checkable. **Shipped 2026-08-01.**

- [x] `OpenTimestampsAttestor` behind the `Attestor` port. **Submits to all three
      calendars**, not first-success-wins — `Calendars.submit` returns one result
      per calendar and the caller keeps all of them. The inherited
      `Calendars.anchor(_:)` returned the first and dropped the other two; that
      was fixed during the copy, not after it.
      - **Measured on the first real submission:** three submissions bought
        **two** independent operators, because `a.pool` is a pool and routed to
        `alice`. ADR 0004 and `memory/known-bugs.md` now say so.
- [x] 72-hour provisional window before submission, enforced from Domain
      (`AnchorSchedule`), so week 4's submission path is not the place the rule is
      first written down.
- [x] **Weekly log-head anchoring.** `anchors.jsonl`, `LogAnchorSchedule`, and a
      third canonical form fixed in `docs/technical.md` §6 because ADR 0004
      mandated the work and specified no shape. Unchanged heads are never
      re-anchored.
- [x] `BGProcessingTask` with exponential backoff **and** an opportunistic drain
      of the pending queue on launch. Both. The backoff needs no new field: both
      files are append-only, so the count of `failed` lines **is** the attempt
      counter.
- [x] The certificate gains its anchor line, and **only** once `AnchorState` is
      `confirmed`. The line and its tests already existed from week 3; week 4
      built the only thing that can reach that state.
- [ ] Scheduled export of the full bundle to iCloud Drive, plus a first-launch
      check that the last successful export has not aged out. **Not done, and no
      longer blocked** — the export surface it was waiting on shipped 2026-08-01,
      and the reason it was waiting stands: a scheduled export the user cannot
      also run by hand is a backup nobody has ever seen work. It has a bundle
      builder that needs no surface and no user, `Exporter.bundle(at:)`, which is
      what a `BGProcessingTask` requires.
- [x] **The standalone verifier** — `verifier/compass-verify.py`. Python 3,
      standard library only, no dependency on the app. 579 lines of code rather
      than the estimated ~200: re-deriving the claim from the log and
      implementing P-256 by hand were not in the estimate. `VerifierTests` runs
      it against a bundle the suite produced, and it has been run against a real
      bundle exported from the simulator.
- [x] The one real network test. `CalendarNetworkTests`, tagged so a run without
      the internet can skip it explicitly — `swift test --skip-tag network` —
      rather than silently.

### Owed from week 4

- [ ] **Watch a proof reach a Bitcoin block.** The first real submission is hours
      old; a calendar aggregates on its own schedule. `confirmed` is exercised by
      tests and by a hand-built Bitcoin attestation, and not yet by Bitcoin.
- [ ] **Anchor a real achievement.** The four awards in the real store are inside
      their 72-hour window, so the only thing anchored for real so far is the log
      head. Re-open the app after 2026-08-04.

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
