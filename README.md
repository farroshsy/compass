# Compass

A habit tracker that produces a record of what you actually did, which you can
hand to a stranger and they can check without trusting you or the app.

---

## What this is

One screen. Four checkboxes. Under three seconds from opening the app to closing
it. Roughly once a month a milestone falls out of the log and the app shows a
certificate, signed on the device immediately and submitted for Bitcoin
anchoring three days later. The certificate says "Sealed on this device" until a
proof actually comes back confirmed, and only then adds the anchor date — it
does not claim to be anchored before it is.

Four is the cap and the shipped seed: `AppComposition.seededHabits` is Move,
Read, Build, Reflect, and `Projection.habitCap` is 4. `docs/product.md` scopes
the launch path at "two to four", so two is the floor a user can reach by
removing rows, not what installs.

A standalone verifier ships in this repository, because "a stranger can check
it" is not true if the stranger has to reimplement a hand-written encoder from a
document. `verifier/compass-verify.py` — Python 3, standard library only, **no
code shared with the app** — recomputes the canonical bytes, the `content_hash`
chain, the achievement digests, the P-256 signatures and the OpenTimestamps
proofs, and re-derives each claim from the log rather than believing it. When it
agrees with `Sources/CompassDomain/CanonicalBytes.swift`, the agreement is
evidence rather than a tautology.

It has one user. It is a daily driver and a deliberate laboratory for
infrastructure that a habit tracker does not strictly need — event sourcing with
deterministic replay, hand-written canonical encoding, cryptographic sealing,
and public anchoring. That over-engineering is the point, and it is stated
plainly rather than dressed up as necessity. The product stays dead simple; the
infrastructure underneath does not.

There is no account, no server of ours, no sync, and nothing to sign in to. Two
honest qualifications: the log is covered by iCloud device backup, deliberately
and by decision, because until sync exists it is the only thing between a
dropped phone and total loss — so the data does leave the phone, to Apple. And
the OpenTimestamps calendars are third-party servers; that is the project's one
operational dependency and `docs/product.md` names it as an exception rather
than pretending it is not one.

The blockchain layer is a **mandatory deliverable** — `PROJECT_CONSTITUTION.md`
§3, settled on 2026-07-31 and not to be reopened — and it is meant to be
invisible: no wallet, no gas, no address, no seed phrase, never the word "mint".

What is refused is not the limb. It is **one specific design**: ADR 0003 §2.5
finds that the embedded-wallet recovery ceremony is a seed phrase by another
name, and passkeys need a hosted file the architecture rules forbid. So the
chain ships; it does not ship *that way*. §14 of the constitution records this
as a live design blocker that must be resolved before contract work begins, by
either designing a genuinely invisible recovery path or overturning the
invisibility non-goal in writing, dated, with the cost stated. Building anyway
without choosing is not available.

An earlier version of this section said the limb itself was "refused rather than
deferred". That contradicted the constitution, and the constitution wins.

## Status

**Weeks 1a, 1b, 2, 3 and 4 have shipped. The app builds, installs and runs, it
has an interactive Home Screen widget, it issues and signs certificates, and it
anchors them to Bitcoin through OpenTimestamps.**

Measured on 2026-08-01: `swift test` reports **482 tests in 46 suites passed**,
and the history is well past its first commit. A fresh install opens on Today
with four grey habit rows — Move, Read, Build, Reflect — a `0`, an empty 28-dot
spine, and a settings sheet behind the glyph that can add, remove, restore and
rename.

Week 1b added the part that cannot be changed later: the hand-written canonical
byte encoding, `content_hash` as SHA-256 over those bytes, per-writer `prev`
chaining, the App Group container, `actor EventLog` and the snapshot cache. The
existing log was replayed through the one-time `reproject` hatch and now carries
a real chain, with the original kept as `events.jsonl.pre-chain`. The encoding
was checked against a verifier written independently from `docs/technical.md` §3,
in another language, against the live simulator log — which is exactly the
property week 4's standalone verifier depends on.

Week 2 added the widget, and with it the **second writer**. The app process and
the widget process have two `device` UUIDs and two `prev` chains on one file, and
both record through one append API — `CheckIn.toggle` — because two writers
disagreeing about what a tap means is a fork with no lock to catch it. The
adversarial two-process test `docs/technical.md` §9.10 asks for shipped with it,
and earned its place immediately: it exposed an ordering defect in which a cold
second writer's un-check was silently discarded by the fold, permanently, with the
event sitting on disk. `memory/decisions.md` has it.

Week 3 added the achievement engine and the certificate. Rules ship as JSON rows
and the evaluators are Swift; the engine is a pure, idempotent, re-runnable
function of the log, so a rule shipped today backfills over existing history with
`earnedOn` set to the day the claim actually became true. Each award carries a
frozen copy of the rule that fired and a `Witness` committing to the events that
were counted, is signed on the spot with a Secure Enclave P-256 key, and is
recorded as a fact rather than left as a derivation. Verified on the simulator
against a real 32-day history: four awards backfilled, signed and verifying, each
saying **"Sealed on this device"** and nothing about anchoring, because nothing
has been anchored.

The certificate is a document rather than a payout: full-bleed paper, no colour
anywhere, a serif claim, and the **whole** 64-hex digest printed underneath —
because sixteen hex characters verify nothing. The seal is a blind deboss whose
64 struck cells are the first 64 bits of that record's Merkle root, so two
certificates can never carry the same impression.

Week 4 added anchoring and the verifier. A digest goes to **all three**
OpenTimestamps calendars rather than the first one that answers, every pending
proof is kept, and the event-log head is anchored weekly — without which an award
the engine backfilled onto a day in the past would have an anchor proving only
the day it was submitted. The certificate gains exactly one line of text when a
proof confirms, and nothing else in the app changes.

Verified against the real calendars on 2026-08-01: the app computed its log head,
digested it, and submitted that digest to all three. **The same digest had
already been produced hours earlier by the Python verifier reading `events.jsonl`
alone** — two programs, no shared code, one answer. The bundle exported from that
store passes every check the verifier can run.

What does not exist yet: a proof that has actually reached a Bitcoin block — the
first submission is hours old and a calendar aggregates on its own schedule — and
a button that runs the export. `docs/technical.md` §11 has the build order,
`memory/current-focus.md` has the current position, and `memory/known-bugs.md`
has both gaps.

Five design investigations completed in July 2026. What survived them is in
`docs/`. **Still owed from week 1a:** the walking skeleton on a real phone, in
daily use. That was week 1b's stated entry condition; it was waived deliberately
on 2026-08-01, with the cost written down at the time in `memory/decisions.md`,
and `docs/technical.md` §11 keeps the gate as written rather than editing it to
match the outcome.

## Where things are

| Path | What it holds |
|---|---|
| `Sources/CompassDomain` | `Day`, `Event`, `project()`, `Projection`, `CanonicalBytes` — both canonical forms — `EventChain`, `TodaySnapshot`, `RuleSpec`, `Achievement`, `EvidenceRoot`, `AchievementEngine`, the ports. Imports Foundation and CryptoKit |
| `Sources/CompassApplication` | `CheckIn` — the tap-path decision **and the one append API both writers call** |
| `Sources/CompassInfrastructure` | `EventJournal`, `EventLog`, `Reproject`, `SystemClock`, `StoreLayout`, `Export`, `WidgetStore` — the second writer's path into the store — `RuleStore`, `AwardStore`, `Signer`, `AchievementIssuer`, `Calendars`, `OpenTimestamps`, `Anchoring`, `AnchorScheduler`, and `AppComposition`, the composition root, which seeds the four habits |
| `Sources/CompassUI` | `TodayView`, `HabitRow`, `SpineView`, `TodayModel`, `TodayMetrics`, the settings sheet, and the certificate — `CertificateView`, `SealView`, `CertificateCopy`, `CertificateMetrics` |
| `App/` | The thin app target. Composition only; no product code |
| `Widget/` | The thin widget extension. An `AppIntent`, a timeline provider and a view; no product code |
| `Sources/CompassLogWriter` | An executable built only so the two-process test in §9.10 has a second process. Not a product |
| `Tests/` | 482 tests in 46 suites — 170 domain, 145 UI, 159 infrastructure, 8 application. Exactly one of them touches the network, and it is tagged `network` |
| `verifier/` | The standalone verifier. Python 3, standard library only, no dependency on anything above it and no shared code with it |
| `Assets/seal/` | The seal's provenance and specification. The four die frames the app actually links are copied into `Sources/CompassUI/SealFrames/`; `reference/matrix-*` are one record's render and must never be linked |
| `docs/product.md` | Mission, the single user, the daily loop, MVP scope, and the non-goals — which are the most load-bearing part of the whole set |
| `docs/technical.md` | Stack, data model, event flow, storage, sync, auth, testing, and every deferred item with the trigger that would make it worth building |
| `docs/achievement-protocol.md` | The constitution for the achievement record. Exact fields, exact types, exact canonical bytes, so future code never invents a field |
| `docs/adr/0001` | Chain and token standard — Base, ERC-5192 + ERC-5484, no proxy |
| `docs/adr/0002` | Local-first storage and event sourcing — the only ADR that constrains week one |
| `docs/adr/0003` | Identity and wallet — why a plain EOA is disqualifying for soulbound records |
| `docs/adr/0004` | What goes on chain, and what never does |
| `.claude/skills/` | Short imperative rules read by coding sessions: architecture, ui, blockchain, ios, testing |
| `docs/open-questions.md` | Review findings that were rejected, with the reasoning and what evidence would reopen them |
| `memory/` | Current focus, next tasks, the decisions log, and known hazards |

Start with `docs/product.md`, then `docs/technical.md`. If you are about to
overturn something, `memory/decisions.md` records why it was decided and — for
the places where the five investigations disagreed with each other — which
argument won and what it cost.

## The honest version of the pitch

For one person keeping their own record, OpenTimestamps alone is sufficient. It
is free, needs no wallet, anchors to the most durable chain there is, and the
code already exists in a working app. A soulbound token buys one functional
thing over that — a public record that exists without you holding a file — and
two portfolio things: it renders in wallets and explorers, and it binds the
record to an identity rather than only to a timestamp.

The chain layer is therefore justified by the learning-and-portfolio half of the
goal, not by the product, and the documents say so throughout rather than
pretending the complexity was forced. `docs/adr/0001` has the full accounting,
including the alternative that wins on engineering merit and was rejected for
reasons that are not engineering reasons.

## Why the documents exist

This project's most likely failure is not a bug or a wrong architecture. It is
abandonment followed by a fresh start under a new name. The evidence is specific
and it is about this machine: 185 git repositories, around 78% near-copies of
one another, and one lineage of 76 attempts at the same idea inside two months,
of which 58 died on the day they were created.

The pattern is not lack of skill. It is that continuing meant re-deriving
decisions that were never written down, so starting over felt cheaper.

**These documents exist to make continuation cheaper than restarting.** That is
the standard by which they should be judged, and it is why every deferred thing
here carries the trigger that would revive it, every rejected thing carries the
reason it lost, and nothing in the plan requires a big-bang migration.

## Running it

The tests, which need no simulator, no developer account and no device:

```sh
swift test
```

The app. Both commands below were run on this machine on 2026-08-01 and the
build reported `** BUILD SUCCEEDED **`:

```sh
xcodegen && xcodebuild -project Compass.xcodeproj -scheme Compass \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug \
  CONFIGURATION_BUILD_DIR=$PWD/.build/products build

# `booted` resolves to a running simulator, so boot one first — with several
# booted it picks one of them, not necessarily the one named above.
xcrun simctl boot 'iPhone 17' 2>/dev/null || true
xcrun simctl install booted .build/products/Compass.app
xcrun simctl launch  booted dev.farros.compass
```

Or `xcodegen && open Compass.xcodeproj` and press Run.

**Never pass `ASSETCATALOG_COMPILER_APPICON_NAME=""`** to work around a missing
simulator runtime; it ships an iconless app. `project.yml` carries the full
reasoning and the re-measurement.

On the phone it goes via TestFlight — not a free development build, which
expires after seven days and takes the daily habit with it. A free profile is
fine for the first few days of use, and that is all week 1b's entry condition
needs.

**TestFlight substitutes a ninety-day expiry for the seven-day one; it does not
remove the problem.** A build stops launching 90 days after upload, so a build
gets uploaded every quarter as a standing obligation. When one does expire,
**update in place — never delete and reinstall.** Deleting the app destroys the
App Group container and with it the entire log. `memory/known-bugs.md`.

`swift test` runs the whole package suite — pure domain, the journal against a
real filesystem, and `TodayModel` against fake ports. **It needs no developer
account, no provisioning profile and no device**, which is why the first session
wrote `Day` and `project()` and ran `swift test` on them rather than waiting on
a purchase. It is still the fastest way to tell whether this repository is in a
working state.
