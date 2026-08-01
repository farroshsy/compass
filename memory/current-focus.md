# Current focus

**As of 2026-08-01.**

> ## Weeks 1a, 1b, 2, 3 and 4 shipped. The app builds, installs and runs, it has
> ## an interactive Home Screen widget and a second writer, it issues and signs
> ## certificates, and it anchors them to Bitcoin through OpenTimestamps.
>
> **If you are a new session: do not start anything from scratch.** There is a
> Swift package, an Xcode project, an app that launches, and a test suite that
> passes. Every previous version of this file said the opposite, and a session
> that believed it would have rebuilt what already exists — which is the exact
> failure `PROJECT_CONSTITUTION.md` §5 exists to prevent, invited by the corpus
> itself.
>
> **The encoding is frozen, and now irreversibly.** `content_hash`, the canonical
> bytes and per-writer `prev` chaining are on disk in the real log; the one-time
> `reproject` hatch has been used and is spent; and **week 3 signed something**,
> which is the moment §11 says that hatch closes for good. Do not "improve" the
> canonical form, in either document — see `docs/technical.md` §3,
> `docs/achievement-protocol.md` §6, and `.claude/skills/architecture.md`.

## Where the project actually is

Measured on this machine on 2026-08-01, by running the commands, not by reading
another document.

```
swift test          -> 482 tests in 46 suites passed
git rev-list --count HEAD   -> run it; a number written here is wrong by the
                               commit that writes it
```

The app builds, installs on a simulator, and launches:

```
xcodegen && xcodebuild -project Compass.xcodeproj -scheme Compass \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug \
  CONFIGURATION_BUILD_DIR=$PWD/.build/products build

xcrun simctl install booted .build/products/Compass.app
xcrun simctl launch  booted dev.farros.compass
```

`** BUILD SUCCEEDED **`, and the icon is in the product — `Assets.car`,
`AppIcon60x60@2x.png`, and `CFBundleIconName = AppIcon` under `CFBundleIcons` in
the built `Info.plist`.

**What a fresh install shows,** screenshotted from that launch: `0` at 44pt
(`TodayMetrics.numberPointSize`; design turn 6 brought it down from 64),
"0 days recorded", an empty 28-dot spine, the settings glyph, and **four grey
rows — Move, Read, Build, Reflect** — bottom-anchored. Grey, not coloured:
`HabitTint` carries only *checked*-row fields and `HabitRow` fills an unchecked
row with `Color.primary.opacity(0.06)`. Colour appears on the first check.

### What exists

- `Package.swift` — one package, four targets, no third-party dependencies:
  `CompassDomain`, `CompassApplication`, `CompassInfrastructure`, `CompassUI`,
  plus four test targets. Swift 6 language mode.
- `project.yml` and a generated `Compass.xcodeproj`; `App/` is the composition
  root and holds nothing else.
- **Domain:** `Day` as an integer ordinal, `Event`, `project()` as a pure fold,
  `Projection` with `habitCap = 4`, `Identifiers`, `JSONValue`, `Ports`,
  `Attestation`, `ComposedStore`, and from week 1b `CanonicalBytes`,
  `EventChain` and `TodaySnapshot`.
- **Infrastructure:** `EventJournal` appending one `write(2)` per event to an
  `O_APPEND` descriptor, `StoreLayout`, `SystemClock` with the 04:00 boundary,
  `WriterIdentity`, `Export`, and from week 1b `EventLog`, `SnapshotStore` and
  `Reproject`; plus `AppComposition` — which seeds the four habits as
  `habitCreated` events on a first launch and, when the store cannot be opened,
  returns an `UnavailableStore` rather than refusing to launch.
- **UI:** `TodayView`, `HabitRow`, `SpineView`, `TodayModel`, `TodayMetrics`,
  `TodayCaption`, `HabitTint`, the settings sheet — `SettingsView`,
  `SettingsEdits`, `SettingsCopy` — and from week 3 the certificate:
  `CertificateView`, `CertificateDocument`, `CertificateExport`, `SealView`,
  `CertificateCopy`, `CertificateMetrics`.
- **The settings sheet arrived in week 1a, ahead of the plan**: add, remove
  (archives, never deletes), restore, rename in place, and the optional declared
  name on the record. `docs/technical.md` §11 now records that it landed early.
- The Record app icon; the seal die frames in `Sources/CompassUI/SealFrames/`,
  vendored from `Assets/seal/`. **`Assets/seal/reference/matrix-*` are comparison
  renders of one particular record and must never be linked into a target** —
  `SealTests` reads the source tree to enforce that, because the bundle-only
  version of the check passed with a render sitting in the repository.

### What week 1b added, 2026-08-01

- **`CompassDomain/CanonicalBytes.swift`** — the hand-written canonical byte
  encoder, the eleven values `docs/technical.md` §3 freezes in that exact order,
  and `content_hash` as SHA-256 over them, recomputed on read and never stored.
  `payload` is inside the digest, per kind, closed. `extra` and unknown top-level
  keys are outside it and always will be.
- **`CompassDomain/EventChain.swift`** — per-writer chain verification, heads,
  and breaks. Never one global chain; ADR 0002 rejects that.
- **`CompassDomain/TodaySnapshot.swift`** — the disposable launch cache, its
  roll-forward to a later day, and the rehydration that gives the first frame a
  projection. It carries **no `lamport`, no head and no `device`**, on purpose.
- **`CompassInfrastructure/EventJournal.swift`** — `prev` computed from this
  writer's head, `WriterResume` recovering `lamport` and the head together under
  the advisory `flock`, and canonicalisation **before** the write so a refused
  event never reaches the file.
- **`CompassInfrastructure/Reproject.swift`** — the one-time hatch. **It has been
  used.** The real log now chains and `events.jsonl.pre-chain` holds the
  original.
- **`CompassInfrastructure/EventLog.swift`** — `actor EventLog` and
  `SnapshotStore`. §4 line 4 is wired: `Task { await absorber.absorb(event) }`.
- **The App Group container**, `group.dev.farros.compass`, with the one-time file
  move that renames rather than deletes the old store.

Verified on the simulator against the real week-1a log: the store moved, the
hatch ran, the chain verifies, and a **Python verifier written from
`docs/technical.md` §3 alone** — sharing no code with the app — reproduces every
`content_hash` and every link, including after a live tap.

### What week 2 added, 2026-08-01

- **`CheckIn.toggle` — one append API for two writers.** It decides the kind,
  attaches the `source` the kind is entitled to and the closed payload, and
  records. `TodayModel.toggle` passes `.tap`; the widget passes `.widget`. Nothing
  else differs, and nothing else may.
- **`WriterIdentity.widget` and `CompassInfrastructure/WidgetStore.swift`** — the
  second writer's whole path into the store: read the log to draw, record one
  check-in, rewrite the disposable cache. It never migrates, reprojects or seeds,
  because §4 says only the app process rewrites.
- **`Widget/`** — a shell holding `ToggleHabitIntent`, a timeline provider and a
  view, in exactly the sense `App/` is a shell. One `.systemSmall` family, a
  `StaticConfiguration`, and a timeline whose entire refresh policy is the next
  04:00.
- **`Tests/.../TwoWritersTests.swift` and `CompassLogWriter`** — §9.10 with two
  real processes. It found a real defect on the day it was written.
- **The `lamport` fix.** A writer now resumes from the highest `lamport` in the
  whole log rather than its own. `memory/decisions.md` has the un-check that was
  being silently discarded.
- `TodayView` reconciles on `.task(id: scenePhase)`; both targets carry matching
  version keys; `HabitTint` is public so the two surfaces share one palette.

Verified on the simulator: the extension is embedded, entitled to
`group.dev.farros.compass`, registered with WidgetKit, and its provider renders
the four real habits from the shared log. **The press is not verified** — see
`memory/known-bugs.md`.

### What week 3 added, 2026-08-01

- **`CompassDomain/RuleSpec.swift`, `Achievement.swift`, `EvidenceRoot.swift`,
  `AchievementEngine.swift`** — rules as data, the record's seven fields, the
  Merkle construction §4.1 freezes, and the engine as a pure, idempotent,
  re-runnable function of the log. Two evaluator kinds; four named and skipped.
- **The achievement canonical form**, in the same file the event one lives in,
  with its own hardcoded digest hex transcribed from `docs/achievement-protocol.md`
  §6 by hand and hashed by two tools outside this project.
- **`CompassInfrastructure/Signer.swift`** — copied from the `before` repository
  with both §8 fixes and without `sign(_ text:)`, which double-hashes.
  `KeychainStore` persists the enclave key under
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **`AwardStore` and `AchievementIssuer`** — `awards.jsonl` append-only with no
  deletion path in any state, `attestations.jsonl` last-write-wins on read, and
  the guarded step that records an earned achievement as a fact and seals it in
  the same pass.
- **`CompassUI/CertificateMetrics.swift`, `CertificateCopy.swift`,
  `SealView.swift`, `CertificateView.swift`** — surface 2, full-bleed paper, no
  colour at all, the claim on the `largeTitle` metric, the seal struck from the
  first 64 bits of `witness.evidenceRoot`, the full digest printed, and the AX5
  structural variant.
- **The certificate list** in the settings sheet, which re-presents the same
  certificate rather than pushing a fourth surface.

Verified on the simulator against a real chained 32-day history: four awards
backfilled with `earnedOn` on the historical day, each signed and verifying, each
`sealed` and saying nothing about anchoring, the seal drawn from that record's own
evidence root, and the list re-opening any of them. Twenty mutations were run
against it; every one was caught.

### What week 4 added, 2026-08-01

- **`CompassInfrastructure/Calendars.swift`** — copied from the `before`
  repository with its **first-success-wins behaviour fixed during the copy**. A
  digest goes to all three calendars concurrently and every answer is kept.
- **`CompassInfrastructure/OpenTimestamps.swift`** — the proof format, read and
  written by hand. Needed because holding three responses in one artifact and
  asking a calendar for an upgrade both require the format itself. Parsing
  applies nothing, so a proof carrying an operation this build cannot compute is
  still read in full, reported, and re-emitted unchanged.
- **`CompassInfrastructure/Anchoring.swift`** — `AnchorPipeline` (upgrade what is
  pending, anchor the log head when a week is up, submit what the 72-hour window
  has released) and `OpenTimestampsAttestor` behind the `Attestor` port. **A pass
  with nothing due makes no request at all**, which is what makes it safe on
  every foreground.
- **`anchors.jsonl`, `LogAnchor` and a third canonical form** — ADR 0004
  mandated weekly log-head anchoring and specified no shape, so one is fixed in
  `docs/technical.md` §6. No timestamp in it, deliberately.
- **`CompassInfrastructure/AnchorScheduler.swift`** — the `BGProcessingTask`
  half, plus the launch drain in `TodayModel.reconcile()`. Both, per §9.8. The
  simulator log confirms registration and submission:
  `submitTaskRequest: <BGProcessingTaskRequest: dev.farros.compass.anchor …>`.
- **`verifier/compass-verify.py`** — the standalone verifier. Python 3, standard
  library only, no shared code with the app.
- `Exporter` now writes `proofs/*.ots` and `publickey.pem`, which §8 had always
  listed and nothing had produced.

**Verified against the real calendars.** The app on the simulator computed the
log head, digested it to
`33a6fc1429640437cf9711e800e9a3fe46c873407eaa8f53f44c2b4e2361d106`, and submitted
it to all three. **That digest had already been computed, hours earlier, by the
Python verifier reading `events.jsonl` alone** — two programs, no shared code,
same answer. The bundle exported from that store passes every check the verifier
can run.

**The certificate gained one line and nothing else in the app changed.** The line
and its tests already existed from week 3; week 4 built the only thing that can
reach `confirmed`.

### What does not exist yet

**The app's own proof has not reached a Bitcoin block yet — but the digest has.**
Block **960500** commits the log-head digest `33a6fc14…`, via a proof submitted by
hand thirty-three minutes before the app's while the canonical form was being
pinned. The app's own submission landed in a later aggregation round. Same digest,
different path, and only the app's path is in `anchors.jsonl` — so one inch is
unexercised, `AnchorPipeline.upgradeAll` writing `confirmed` from a real upgrade
response. **Open the app again and it clears.** The four real achievements are
still inside their 72-hour window, so only the log head is anchored at all.

No damaged-log *notice* — the damage is detected and reported in
`JournalRead.chain`, and nothing renders it. No scheduled iCloud Drive backup,
which needed the export button first. All of it is in `memory/next-tasks.md` and
`memory/known-bugs.md`.

**The export surface landed on 2026-08-01**, and a verification pass found three
other things in the same change. All four are written up in
`memory/known-bugs.md`:

- `verifier/compass-verify.py` built the Merkle evidence root over the leaves in
  **day** order, while `docs/achievement-protocol.md` §4.1 freezes them in
  `(lamport, device)` order. It agreed with the app on every bundle the suite had,
  because every one of them was appended in day order by one writer; on a log two
  writers interleave it computes a different root. The spec was the arbiter and
  the Swift side was already right.
- **Export had no surface at all.** `Exporter` shipped in week 1, was tested from
  week 1, and had no call site outside its own test file — so the artifact the
  whole survival story rests on could only be produced by a helper process. It is
  now the last section of the settings sheet, through `fileExporter`.
- **`Attestation.backing` was carried, exported and printed, and required
  nowhere.** Hardcoding `.secureEnclave` in `AchievementIssuer.seal` left all 493
  tests passing, and the verifier's conclusion read identically for a
  software-signed bundle and an enclave-signed one.
- **The achievement pass discarded every failure**, on both call sites, so a
  milestone that failed to issue was indistinguishable from one that was never
  earned. It is now recorded and shown in the settings sheet — never on Today.

**A second pass later the same day found three more, all in what the app and the
verifier *claim*.** Also in `memory/known-bugs.md`:

- **The verifier asserted the one claim it could not check.** `backing` sits
  outside the digest, and the `secureEnclave` reading printed with the same `ok`
  marker as the P-256 signature and the manifest digests — while the two weaker
  readings hedged correctly. Flip one word on a genuine software-signed bundle,
  recompute the manifest, and the run says "Every check that could run, passed."
  `ok` is now reserved for a check that recomputed something.
- **"On the simulator there is no enclave" is false**, and it was stated in five
  places. `SecureEnclave.isAvailable` is `true` in the iOS Simulator on every T2
  and Apple Silicon Mac, and the bundle exported from the simulator on this host
  carries `"backing":"secureEnclave"`. So `docs/achievement-protocol.md` §7's
  "a simulator-made proof must never look as strong as a phone-made one" has
  never been delivered. Corrected in all five, and the gap is recorded rather
  than papered over with a new mechanism — §7.0 bis.
- **A raw Swift error was rendered into the UI.** `awardFailure = "\(error)"` put
  an `NSCocoaErrorDomain Code=257` sentence into the Records footer, carrying the
  host's absolute path, the CoreSimulator device UUID and the App Group UUID, and
  overflowing off the bottom of the sheet. It is now an `AwardFailure` carrying
  the error's domain and code and nothing else — a type, so the raw interpolation
  no longer compiles.

## What the next session should do

**Put the app on the phone and use it.** That is still the one unticked item of
week 1a, and it is the thing that keeps the project alive.

> **Week 1b's entry condition — the app opened three days running — was waived
> by the owner on 2026-08-01, not met.** `memory/decisions.md` has the waiver and
> what it costs. `docs/technical.md` §11 keeps the gate as written.

What that cost, stated exactly: the `reproject` hatch was the mitigation §11
provided for exactly this, and it is now **spent**. It closes for good at the
first signature, which is week 3. So the encoding can no longer be revised by
replaying the log — if the canonical form is wrong, it is wrong permanently once
week 3 lands. The four high-severity defects found on 2026-07-31 were all cases
of the app asserting something untrue and none was caught by a green suite; real
use is still the detector that has not run.

1. **Put the app on the phone and open it for three days.** A free provisioning
   profile is acceptable — it expires after seven days, which is fatal to a habit
   but not to a three-day condition. Note the App Group entitlement: a free
   profile may not carry it, and `AppComposition.storeURL` falls back to
   Documents, which is fine until the widget.
2. **Start the paid Apple Developer enrolment in parallel** if it has not been
   started. Individual verification takes days.
3. **Week 2 is done.** The widget, the second writer identity and the adversarial
   two-process test all landed on 2026-08-01, and the test found the `lamport`
   ordering defect the same day — so "every test in the suite would pass while
   real data corrupts" turned out to be literally true, and is now false. What is
   still owed from week 2 is one thing and it needs a phone: **add the widget to
   the Home Screen and press a row.** `memory/known-bugs.md`.
4. **Week 3 is done**, and with it the `reproject` hatch is closed for good.
   Three things are owed from it, all in `memory/known-bugs.md`: a look at the
   120pt AX5 seal on a physical phone, a decision about whether a habit added in
   the settings sheet can earn a streak certificate, and the `nameFooter` claim
   the seal has now earned.
5. **Week 4 is done.** What is owed from it needs only time and a phone: open
   the app again tomorrow and watch a proof reach a Bitcoin block, and again
   after 2026-08-04, when the four real achievements leave their 72-hour window
   and become the first records anchored for their own sake rather than through
   the log head.
6. ~~**Then the export button.**~~ **Done 2026-08-01.** It was the smallest
   remaining piece of week 1b and it is what makes the verifier reachable by the
   person the record is about. The scheduled iCloud Drive backup is now
   unblocked: it has a bundle builder — `Exporter.bundle(at:)` — that needs no
   surface and no user, which is exactly what a `BGProcessingTask` requires.

## Outstanding, and not blocking week 1b

- **The paid account and a TestFlight path**, before the app lives on the phone
  permanently. Then the ninety-day rule: upload every quarter, and **update in
  place — never delete and reinstall**, because deleting destroys the container
  and the whole log.
- **Measurements owed** under the standing evidence rules: cold launch to first
  frame, and full replay time, both on the actual phone. 400 ms and 250 ms are
  proposals and must not be written into a test as fact. Week 1b adds a third:
  the cost of the **first tap of a process that launched from the snapshot
  cache**, which recovers its resume under the `flock` and therefore decodes the
  log once. §4 wants that in microseconds; `EventLog.replay()` normally primes it
  first, but a tap can beat the replay and nothing has measured that race on a
  real device.
- **`PROJECT_CONSTITUTION.md` §14 is still unresolved** — wallet recovery versus
  the invisibility rule. It must be resolved before contract work begins, and it
  is a design blocker, not a product one. §3 settles that the chain ships; what
  ADR 0003 §2.5 refuses is its specific recovery ceremony.
- **The known-broken and known-untested list** is `memory/known-bugs.md`. Read
  it before touching `SettingsView` or `TodayView`.

## The standing constraint on everything

The failure mode is abandonment followed by a restart, not a bug. Evidence: 185
git repositories on this machine, ~78% near-copies, one lineage of 76 attempts
at the same idea between 2025-01-25 and 2025-03-24, of which 58 died on the day
they were created.

Every decision gets evaluated against: does this make the project more likely to
still be alive in six months? Prefer boring, incremental and additive over
correct-but-requires-a-rewrite.

## Do not

- **Do not rebuild anything.** `PROJECT_CONSTITUTION.md` §5: no rewrites, no
  restarts, no new repositories. If a document tells you nothing has been built,
  the document is wrong — run `swift test` and fix the document.
- **Do not write another governance document.** Governance is frozen —
  `PROJECT_CONSTITUTION.md` §11. Correcting a false sentence is not a new
  document; explaining an existing decision again is.
- Do not start the chain limb before §14 is resolved in writing, with a date, in
  `memory/decisions.md`.
- Do not add a fifth habit slot, a second tab, or a settings option.
- Do not add a surface. The v1 budget off the launch path is three, counted in
  `docs/product.md`. A fourth means editing that list first.
- Do not re-argue anything in `memory/decisions.md`. Overturn it in writing,
  with a date and a reason, or leave it alone.
- **Do not touch the canonical byte encoding.** `CompassDomain/CanonicalBytes.swift`
  is the only place it exists and `CanonicalBytesTests` pins it to a hex computed
  outside this project. If that test needs updating, something irreversible has
  happened — stop and find out what.
- **Do not re-run the `reproject` hatch to repair a chain that breaks later.** It
  has been used. A later break is damage to report under `docs/technical.md` §6,
  not a `prev` to recompute.
