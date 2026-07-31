# Current focus

**As of 2026-08-01.**

> ## Week 1a shipped. The app builds, installs and runs.
>
> **If you are a new session: do not start anything from scratch.** There is a
> Swift package, an Xcode project, an app that launches, and a test suite that
> passes. Every previous version of this file said the opposite, and a session
> that believed it would have rebuilt what already exists — which is the exact
> failure `PROJECT_CONSTITUTION.md` §5 exists to prevent, invited by the corpus
> itself.

## Where the project actually is

Measured on this machine on 2026-08-01, by running the commands, not by reading
another document.

```
swift test          -> 218 tests in 23 suites passed
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
  `Attestation`, `ComposedStore`.
- **Infrastructure:** `EventJournal` appending JSON Lines to an open
  `FileHandle`, `StoreLayout`, `SystemClock` with the 04:00 boundary,
  `WriterIdentity`, `Export`, and `AppComposition` — which seeds the four habits
  as `habitCreated` events on a first launch and, when the store cannot be
  opened, returns an `UnavailableStore` rather than refusing to launch.
- **UI:** `TodayView`, `HabitRow`, `SpineView`, `TodayModel`, `TodayMetrics`,
  `TodayCaption`, `HabitTint`, and the settings sheet — `SettingsView`,
  `SettingsEdits`, `SettingsCopy`.
- **The settings sheet arrived in week 1a, ahead of the plan**: add, remove
  (archives, never deletes), restore, rename in place, and the optional declared
  name on the record. `docs/technical.md` §11 now records that it landed early.
- The Record app icon, and the week-3 seal assets vendored in `Assets/seal/`.

### What does not exist yet

No canonical byte encoding, no `content_hash`, no `prev` chaining, no App Group,
no `actor EventLog`, no snapshot cache, no widget, no rule specs, no achievement
engine, no `CertificateView`, no signing, no anchoring, no standalone verifier.
All of that is week 1b and later, and all of it is listed in
`memory/next-tasks.md`.

## What the next session should do

**Week 1b — the canonical encoding and the hash chain.** `docs/technical.md` §11
and `memory/next-tasks.md`.

> **Entry condition, verbatim from `docs/technical.md` §11: the app has been
> opened three days running.** Not before.

**That condition is not met, and nothing in this repository says it is.** Week 1a
ends with *"Install on the phone. Use it."* — that item is unticked, and no
entry in `memory/decisions.md` records the app ever being on a phone. What has
been demonstrated is a simulator install, which is a build check, not three days
of use. So the honest next action is not code:

1. **Put the app on the phone and open it for three days.** A free provisioning
   profile is acceptable for this — it expires after seven days, which is fatal
   to a habit but not to a three-day entry condition.
2. **Start the paid Apple Developer enrolment in parallel** if it has not been
   started. Individual verification takes days and it blocks nothing until the
   app goes on the phone to stay.

If week 1b is started before the app is in daily use, the ordering rule in
`docs/technical.md` §11 — *the daily loop must be in daily use before anything
cryptographic is built* — has been broken, and the thing that keeps the project
alive was skipped for the thing that is more interesting to build. That is the
whole reason the split exists.

**The one-time `reproject` hatch is still open** and is what makes waiting safe:
the week-1a log can be replayed once into a freshly chained log. It closes the
moment anything is signed, which cannot happen before week 3.

## Outstanding, and not blocking week 1b

- **The paid account and a TestFlight path**, before the app lives on the phone
  permanently. Then the ninety-day rule: upload every quarter, and **update in
  place — never delete and reinstall**, because deleting destroys the container
  and the whole log.
- **Measurements owed** under the standing evidence rules: cold launch to first
  frame, and full replay time, both on the actual phone. 400 ms and 250 ms are
  proposals and must not be written into a test as fact.
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
