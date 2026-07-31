# Next tasks

Ordered. Do not skip ahead. Each block should end with something usable.

## Nothing blocks the first line of code

There used to be a "blocking — before any code" section here holding a $99
purchase, an individual-verification wait, and two product decisions. It was
wrong, and it was wrong in the most expensive possible direction for this
particular project: the documented failure mode is that 58 of 76 attempts died
on the day they were created, and the task list made day one impossible to
finish.

Both blockers are refuted by the corpus itself:

- `README.md` says `swift test` runs the domain suite, which "is pure, has no
  simulator dependency, and is where roughly eighty per cent of the tests live."
  That suite, plus `Day`, `Event` and `project()`, needs no account, no profile
  and no device.
- "Name the two habits" was blocking because "the layout, the notification hour
  and the milestone cadence all depend on them". There is no notification any
  more, and `docs/technical.md` defines `habitRenamed` as cosmetic and never
  affecting the fold — so a name is by construction the cheapest thing in the
  project to change.

**Start with week 1a. Today.**

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

The goal of this block is a working checkbox, not a correct one. Ship it.

- [ ] `Package.swift` with four targets; `project.yml` for xcodegen.
- [ ] `Day` as an integer ordinal, encoded as `"YYYY-MM-DD"`. Exhaustive tests
      first — see `.claude/skills/testing.md`. `swift test`, no device needed.
- [ ] `Event` as a plain struct with `JSONEncoder`, and `project(_:)` as a pure
      fold. Shard-invariance test — the highest-value single test in the project.
- [ ] `Journal` — synchronous append of one line to an open `FileHandle`.
      **Base URL comes from a single injected `storeURL`.** Construct a file
      path nowhere else; that is what makes the App Group move a one-liner.
- [ ] `TodayView`, `HabitRow`, `SpineView`, `TodayModel`. Bottom-anchored. **Four
      habits seeded in the bundle with names already set** — Move, Read, Build,
      Reflect, per the entry above — no first-launch naming flow, no keyboard,
      no permission prompt.
- [ ] **Install on the phone. Use it.** Free profile is acceptable here.

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
- [ ] Replay-parity test. Truncate-at-every-offset crash test.
- [ ] Damaged-log recovery policy per `docs/technical.md` §6, with its test.
- [ ] Move `storeURL` to the App Group container. One line plus a file move.
      Set `NSFileProtectionCompleteUntilFirstUserAuthentication`.
- [ ] `actor EventLog` for replay and the in-memory array.
- [ ] Snapshot cache, read synchronously in `TodayModel.init`.
- [ ] **`export` as a bundle** — `events.jsonl` + `awards.jsonl` +
      `attestations.jsonl` + frozen rule JSON + `habits.json` + public keys +
      every `.ots` proof + `manifest.json` of per-file digests. Stated in these
      exact words in `docs/product.md`, `docs/technical.md` §8 and ADR 0002 so
      the four copies cannot drift. Not the log alone — the log alone contains
      neither the achievements nor the proofs it is claimed to preserve.
- [ ] Bundle-restore round-trip test. An unexercised escape hatch is not one.

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
overturning a `docs/product.md` non-goal — see ADR 0003 §2.5. It is refused, not
deferred, until that exists.
