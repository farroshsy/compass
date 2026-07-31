# Decisions log

A decision here is not re-argued. It is overturned in writing, with a date and a
reason, or it stands. Re-litigating settled questions is one of the mechanisms
by which this project gets restarted instead of continued.

Full reasoning lives in `docs/adr/`. This file is the index plus the decisions
that were too small for an ADR, plus — most usefully — the places where the five
design investigations **contradicted each other** and a choice had to be made.

---

## Settled before any code (2026-07-31)

- **Habits and check-ins never go on chain.** Only milestone achievements do,
  and only if the chain limb is ever built. ADR 0004.
- **Achievements are soulbound.** Buying a 1000-day meditation streak would
  destroy the meaning. ADR 0001.
- **Local-first.** The app is fully usable offline; sealing and anchoring are
  background work. ADR 0002.
- **Event-sourced, append-only JSON Lines.** ADR 0002.
- **iOS 18, Swift 6, SwiftUI, Observation, async/await.** No UIKit unless forced.
- **Day boundary at 04:00 local**, applied when the event is created, never in
  the fold. All three investigations that raised it independently chose 04:00.
  Not user-configurable in v1: past days are immutable, so changing it would
  create a visible one-day boundary discontinuity for no benefit.
- **`"v"` is 1 and is never bumped.** A version bump is a migration.
- **Sign immediately, publish after 72 hours.** See contradiction 6 below.
- **No rarity, computed or authored, in v1.** See contradiction 5 below.
- **Total days, not the current streak, is the headline number.** A number that
  resets to zero teaches you to start over, which is the exact behaviour this
  project defends against.
- **Four habits is a hard cap.** The one-handed layout stops holding past four.

---

## Settled by adversarial review of the corpus (2026-07-31)

Three reviews read the document set against itself. These are the decisions that
came out of it. Each is a **deletion or a correction, recorded so the deletion
itself is the settled thing** — otherwise the next session re-adds the field and
re-argues the point.

### Non-goals are the authority

`docs/product.md`'s non-goals section outranks `docs/technical.md`,
`docs/achievement-protocol.md`, `docs/adr/` and `.claude/skills/`. Where any of
those reserved a field or a UI element for something the non-goals ban, the
field is deleted rather than designed around. The set was supplying both sides
of six arguments with zero code written, which is the exact mechanism these
documents exist to prevent.

### Deleted because they instantiated a named non-goal

- **`habitCadenceChanged` and the `cadence` payload on `habitCreated`.**
  Schedules are banned. A cadence also implies settings UI and a third
  `DayStatus` for days that are neither done nor missed.
- **`dayNoteAttached`.** Notes are banned.
- **`Scope.tag`.** Tags and categories are banned.
- **The daily local notification** (was `.claude/skills/ui.md`). A reminder at a
  fixed hour cancelled when the day completes is a streak-defence notification
  by function, and `docs/product.md` says those do not exist. The week-2 widget
  is the reminder and costs no permission prompt. The "decide the notification
  hour" blocking task went with it.
- **The first-launch naming flow.** Habits are seeded in the bundle with names
  set; renaming lives in the settings sheet. Naming was blocking day one for a
  value `habitRenamed` makes cosmetic by construction.
- **The achievement "new" indicator.** A re-engagement affordance in an app whose
  non-goals ban badges.

Every one of these is cheap to reverse: `EventKind` and the identifiers are
`RawRepresentable` strings *specifically* so a kind can be added later with no
format change. That is the stated reason they are strings, and it is why
reserving them cost nothing to give up.

### Backfill: not in v1, but its honesty fields stay

No surface for editing a past day ships in v1. It is the only interaction
needing a date, a scroll and a decision, it was never scoped anywhere, and it
would turn the 28-dot spine from a display into a control. A forgotten day stays
forgotten. **But `source_live` and `source_backfill` remain REQUIRED**, because
they sit inside the digest and cannot be added additively later; `source_backfill`
is `0` on every v1 record. Deferred with a trigger, not refused.

### The MVP is one screen *on the launch path*, plus three counted surfaces

"One screen and a file" was false against the rest of the corpus, which required
at least seven surfaces. The budget is now settings sheet, certificate,
certificate list — counted in `docs/product.md`. The certificate detail screen
and the history "new" badge are cut.

### Week 1 is split into 1a and 1b, and nothing blocks day one

The old list gated the first tappable checkbox behind the canonical encoding, a
hardcoded digest test, hash chaining, an App Group container and a purchase —
for an author with 58 repositories that died on their creation day. The
irreversibility was also overstated: a log written before anything is signed can
be replayed once into a chained log. So there is a **one-time `reproject`
hatch**, usable exactly once and closing permanently at the first signature.
The encoding still lands in week 1 and still precedes anything cryptographic;
only the ordering inside the week moved.

### The Apple Developer account blocks the phone, not the code

`swift test` on the domain suite needs no account, no profile and no device.
Enrolment runs in parallel. Week 1a may ship on a free seven-day profile: that
is fatal to a habit but not to a seven-day skeleton.

### The App Group is a `storeURL`, not a rewrite

"Retrofitting it is a rewrite" was the sentence that turned a $99 purchase into
a gate on all storage code. Every path takes its base URL from one injected
`storeURL`; switching it to the container is one line and must happen before the
widget ships in week 2.

### Corrections where the corpus asserted something untrue

- **Export is a bundle, not a log dump.** It previously omitted both the
  achievement records and the Bitcoin proofs it was claimed to preserve.
- **Three tiers of rebuildability, not two.** `attestations.jsonl` holds OTS
  proofs, signatures and chain records, none of which are recomputable.
- **The certificate says "Sealed on this device" until `confirmed`.** It never
  claims Bitcoin anchoring before a proof is upgraded.
- **The OpenTimestamps calendars are an operational dependency**, named as an
  explicit exception to the no-hosted-service rule. Submit to all three.
- **Anchoring retry is `BGProcessingTask` *and* a launch drain**, not either.
  Three files previously specified two incompatible behaviours.
- **Weekly log-head anchoring is week-4 work**, not deferred — its trigger fires
  on the first run of the week-3 engine.
- **Habit display names never enter a digest.** `facts` carries `habitID`.
- **`device` is a random 128-bit UUID**, never hardware-derived, never displayed.
- **`content_hash`, `canonical-scope`, the Merkle construction and the signature
  convention are now defined.** All four were referenced and undefined.
- **Revocation is always an appended record**, never a deletion, in any state.
- **BeforeKit code is copied in**, never referenced by filesystem path.
- **The identity limb (ADR 0003) is refused, not deferred**, until someone
  records a dated overturn of the invisibility non-goal. It cannot satisfy that
  rule: a paper recovery key is a seed phrase by another name, and passkeys need
  a hosted file `architecture.md` forbids outright.

---

## Contradictions between the five investigations, and how they were resolved

### 1. Storage: JSON Lines versus SQLite/GRDB

**Conflict.** The local-first investigation benchmarked plain files and rejected
them: 145 ms and a 1.9 MB flash write per tap at year five. The achievement-model
and iOS investigations both specified append-only JSON Lines.

**Resolution: JSON Lines.** The benchmark measured *rewriting the whole array*
— the pattern in the existing Shipped `Log.persist()` — not *appending a line*
to an open descriptor, which is O(1) and does not appear in that table. The
measurement kills whole-file rewriting, which is real and worth knowing, but it
does not touch the actual design.

The residual concern the benchmark does raise is full-replay cost (193 ms at
year five), and that is handled by never replaying on the launch path: read a
snapshot synchronously, replay in a `.task`, reconcile. GRDB is deferred behind
a measured trigger rather than rejected. ADR 0002.

### 2. Wallet: iCloud Keychain EOA versus multi-owner smart account

**Conflict, and the sharpest one.** The chain-and-contracts investigation
recommended a plain secp256k1 key in the iCloud Keychain, explicitly no smart
account and no ERC-4337 in v1, for simplicity. The identity investigation
rejected a plain EOA as *disqualifying rather than a tradeoff*.

**Resolution: the smart account argument wins.** Because achievements are
soulbound they cannot be moved, so losing the key orphans every achievement
permanently, with no recovery path from anyone. That is unrecoverable data loss,
not a simplicity tradeoff.

Note what this costs, because it strengthens a separate decision: the correct
identity design makes the chain limb *more* work, not less, which is one more
reason it is deferred rather than scheduled. The contract design from the
chain-and-contracts investigation survives intact — it is orthogonal to how
ownership is held. ADR 0003.

### 3. Is an award an event, or purely derived?

**Conflict.** The iOS investigation specified milestone identity as derived from
the log and not stored. The local-first investigation argued the opposite:
events that gate irreversible external side effects must be recorded as facts.

**Resolution: both, and there is no real tension once stated precisely.** The
engine *computes* eligibility as a pure function; a guarded step then *appends*
an immutable award record whose ID is deterministic. Deterministic IDs make the
append idempotent, so recording it does not cost re-runnability. Recording it is
necessary because a later rule change must not silently un-award something
already anchored to Bitcoin — which is also why each award carries a frozen copy
of the rule that fired.

### 4. Achievement identity — three different schemes

**Conflict.** `"<ruleID>@<earnedOn>"` versus `SHA256(kind ‖ habitID ‖ threshold)`
versus the tuple `(habitID, rule, firstReachedDay)`.

**Resolution: `"<ruleID>@<earnedOn>"`.** It is greppable in a text log, it
contains the day (the hash form does not, which its own author flagged as a
re-award risk), and it is human-readable in a file that exists partly to be read
by a human. The re-award risk is closed by a rule in the protocol: a `RuleID`
must never change meaning; a change to what is counted is a **new** `RuleID`, not
a new version.

### 5. Rarity

**Conflict.** The achievement-model investigation proposed a genuinely
interesting measured rarity — surprisal under a first-order Markov chain fitted
to the user's own history. The iOS investigation banned rarity tiers, points and
levels outright as converting a certificate into a token.

**Resolution: no rarity in v1 at all.** The certificate aesthetic wins, and the
measured version is deferred with a trigger (the detail screen feels thin) and a
condition (the model must be named inline, per standing evidence rules, or no
number is shown). Authored rarity tiers stay permanently refused.

### 6. When the achievement is signed

**Conflict.** The achievement-model investigation said an achievement is
provisional on earning and is signed and submitted only after a 72-hour window.
The iOS investigation said the certificate shows "Sealed on this device"
immediately.

**Resolution: sign immediately, submit after 72 hours.** Signing is local, free
and offline, and it makes the record tamper-evident from the first moment. Only
*publication* is irreversible, so only publication needs to wait. This gives both
properties and removes an entire reversal UI from v1.

### 7. Total ordering key

**Conflict.** One investigation sorted by `(recordedAt, device, seq)`; another
argued never to use wall-clock time and to use a Lamport counter.

**Resolution: `(lamport, device)`.** Clocks move backwards — NTP corrections,
manual changes — so `recordedAt` is not a safe sort key. `recordedAt` is kept as
metadata and is never read by the fold.

### 8. The `Day` type — name and encoding

**Conflict.** `DayKey {y,m,d}` encoded as a string; `LocalDay {y,m,d}` encoded
as a string; `Day { ordinal: Int }` encoded as an integer.

**Resolution: named `Day`, internally an ordinal, encoded as `"2026-07-31"`.**
The ordinal gives clean integer arithmetic; the string keeps the log greppable
and auditable by hand, which is a large part of why the log is text at all.

### 9. Weekly anchoring of the log head

**Not a contradiction so much as an undeclared deviation.** One investigation
proposed ~52 extra OpenTimestamps submissions a year on top of the ~14 already
written into the project's decisions, and flagged it as needing confirmation
rather than assumption.

**Original resolution: deferred, with a precise trigger** — the first time a
newly-shipped rule backfills a *historical* achievement.

**Overturned 2026-07-31, by adversarial review: it is week-4 work, not deferred
work.** The trigger reads as distant but is guaranteed to fire on the *first*
execution of the week-3 engine, which backfills 7-day and 30-day awards over the
history the app has been accumulating since week 1. Deferring it therefore meant
shipping week 3 with certificates that overstate. It is free (calendars
Merkle-aggregate; no gas, no wallet, no transaction), it needs only a digest and
`Calendars`, and it is what makes a backfilled achievement provable about the
past rather than about the day it was detected. ADR 0004 also now states the
unavoidable residue: awards covering days before the first log-head anchor can
never be proven about the past, and the certificate says so by claiming less.

### 10. Rule kinds — six or two

**Not a conflict, a scope call.** Six evaluator kinds were specified, with their
author noting that six is a bet. **v1 implements two** — `streak` and `total` —
with the other four named in the protocol so the format does not change when they
arrive. Tripwire recorded: wanting a kind with conditionals inside it means stop
and write Swift, because that is a DSL arriving by accident.

### 11. Neutral days for travel

**Resolution: deferred.** Its own author called it the piece they were least
confident earned its complexity — one event kind and one fold branch for an edge
case that fires perhaps twice a year. Trigger: an eastward flight actually costs
a day, or a rest day is genuinely wanted.

---

## 2026-07-31 — `content_hash` covers the payload

The canonical form did not digest `habitID`. Fixed in `technical.md` §3, ADR
0002 amended. Found before any code was written, so the §11 escape hatch was
still open and the fix cost nothing. See ADR 0002's amendment for the full
accounting.

## 2026-07-31 — "only implementation", not "reference implementation"

`PROJECT_CONSTITUTION.md` §1 said "reference implementation of the Achievement
Protocol". In standards work that implies other implementations are expected,
which `product.md` bans. Reworded to "the only implementation". No change of
substance — the protocol remains a constitution for this codebase alone.

## 2026-07-31 — the chain mandate and the refused wallet design are not in conflict

An audit read `PROJECT_CONSTITUTION.md` §3 ("the blockchain is mandatory")
against six files recording the chain limb as "refused" and called it a blocking
contradiction. It is not. §3 fixes the destination; the refusal is of ADR 0003's
specific embedded-wallet recovery ceremony, which breaks the invisibility
non-goal. Build the chain, not that design. Recorded here so the next reader
does not re-derive the alarm. The live decision remains §14 / ADR 0003 §2.5:
invisible recovery, or overturn the non-goal in writing.

## 2026-07-31 — evidence attachments: forward compatibility only

Recorded the invariants that keep a future photo/voice attachment additive:
evidence is optional and never required for a check-in; it lives in its own
top-level object, not in `payload` or the envelope; media is referenced by
content hash and never embedded, so it never enters canonical bytes, the chain,
or an anchor.

This is NOT a decision to build evidence capture. It is a constraint on how it
would be built, written down while the canonical form is still open, because
after the first signature it cannot be revised. See `technical.md` §3.

---

## 2026-07-31 — design mode ends, execution mode begins

**Frozen before the first line of code:**

- the canonical event form, including `payload` — irreversible after the first
  signature, verified by two mechanical sweeps
- the `payload` / `extra` boundary: what is proven versus what is metadata
- the evidence invariant: optional, hash-referenced, never in canonical bytes
- scheduled versus deferred versus refused, kept apart in `technical.md` §10
- non-goal classification, PROPOSED and awaiting confirmation

**Still flexible, deliberately:** UI detail, implementation choices, storage
optimisation, module boundaries below Domain⊥Infrastructure, future surfaces,
and the roadmap's route (never its destination — `PROJECT_CONSTITUTION.md` §11).

From here, `PROJECT_CONSTITUTION.md` §9 governs: assume the architecture is
correct and execute it. Documents change only when code reveals a real
contradiction, and then in the same change.

**First milestone, in full:** install the app, create two habits, tap, close,
open it tomorrow, and it still knows.

---

## 2026-07-31 — the composition root moved into the package

**What moved.** The composition root was `CompassApp.compose()` in
`App/CompassApp.swift`. It is now `AppComposition.compose()` in
`Sources/CompassInfrastructure/Composition.swift`. `App/` is a thin shell that
constructs the composed value and hands it to the SwiftUI scene, and holds no
branch, no `catch` and no forwarded argument. **The "exactly one place"
rule is unchanged** — infrastructure is still constructed in exactly one file.
Only its location changed. `docs/technical.md` §2 and
`.claude/skills/architecture.md` are updated to match, in this change.

**The evidence, under `PROJECT_CONSTITUTION.md` §12.** The limb cited is
**maintainability** — "a newer mature technology provides a measurable
improvement in correctness, maintainability, interoperability or developer
experience", read here as the maintainability improvement, not a technology
adoption. The **"a security issue has been identified" limb does not apply** and
is not claimed; nothing here is a security finding.

The evidence is a measurement, not a preference. `App/` is not compiled by
`swift test` and has no test target, so mutation testing was run against the
wiring as it stood: restoring the `preconditionFailure` on the store-open
failure path (a crash on every launch), and separately deleting the argument
that hands the journal its already-known high-water mark (a full log decode on
the tap path), each left **111 of 111 tests passing**. Two fixes for two real
bugs had no test at their fix site, and either could have been deleted by a
future session in silence. After the move both are ordinary unit tests in
`Tests/CompassInfrastructureTests/CompositionTests.swift`, verified by
re-running the same two mutations on a copy: the crash now aborts the run, and
the missing prime fails at `CompositionTests.swift:120`.

It is in `CompassInfrastructure` rather than `CompassApplication` for a
mechanical reason: `CompassUI` imports `CompassApplication`, so composing
something the UI consumes cannot live there without the import running
backwards.

**What was given up.** The composition root is no longer visible in `App/`,
which is the first place a reader opening this repository would look for it —
"where does the app start, and what does it build?" is answered one directory
further in than convention suggests. That cost is accepted, and it is paid down
only by the pointers: `App/CompassApp.swift` says where the wiring went and why,
`docs/technical.md` §2 shows it in the module tree, and this entry is the record.
The alternative was keeping the root where a reader expects it and leaving the
lines that can be wrong where no test can see them.

Accepted by the human on 2026-07-31.

---

## 2026-07-31 — the four habits, the sealed name, and one recorded deviation

Three decisions taken by the owner on the same day, recorded together because
each was a choice a future session would otherwise re-argue. All three landed
with the code in the same change.

### The four seeded habits: Move, Read, Build, Reflect

The placeholders `habit-a` and `habit-b` are gone. `memory/current-focus.md`
called naming them "by construction the cheapest thing in the project to change"
and told a session to ship the placeholders rather than block on the question;
this is that question answered, not overturned.

**One per domain, and the domains are the point:** health, learning, deep work,
reflection. They are chosen to be mutually exclusive and jointly close to
exhaustive for one person's day, so that no day's effort has nowhere to land and
no two rows compete for the same tap.

**Relationship and character are folded into Reflect rather than becoming two
more booleans.** They are real and they were considered. They lose to the cap:
`docs/product.md` makes four a hard cap on the grounds that the one-handed
bottom-anchored layout stops holding past four rows, "at which point the
three-second promise quietly becomes false" — and objective 1 outranks
everything. A sixth row would be a better taxonomy attached to a worse loop.
Reflect is where they are recorded, in the person's own head, which is where the
app has always kept everything that is not a boolean: there are no notes, no
tags and no moods here by permanent non-goal.

**This seeds at the cap, deliberately.** That is only safe because the AX5
finding holds: four rows still fit at accessibility 5 with 137 points to spare,
and `TodayMetricsTests` pins that number so a future change to any constant on
the screen has to re-derive it. It also means first launch opens with no free
slot — the settings sheet refuses a fifth until one is removed, and says so.

**The identifiers stay opaque** — `habit-a` through `habit-d`, carrying no part
of the names. `docs/achievement-protocol.md` §3.4 keeps display names out of
anything digested because there is no redaction path and can never be one, and a
`HabitID` is precisely what `facts` carries into a signed, anchored record. An ID
of `"move"` would have put the name inside the digest for the sake of a log that
reads nicely. A test asserts no seed's ID contains its name.

### The share subject: option (b), an optional self-declared name

`docs/open-questions.md` asked what the certificate is a record *of*: the
exported card states that a device recorded 100 consecutive days, and never
whose device. Two candidate answers were written down. **(b) is chosen.**

What ships: one optional text field in the settings sheet, empty by default. No
account, no sign-in, no server, no verification of any kind. It is recorded as a
new event kind, `subjectNamed`, payload `{"name":<string>}`.

**Why (b) over (a).** (a) — accept it, the record is meaningful only when handed
over in context — costs nothing and is honest, and it remains true: you send the
certificate yourself, in a conversation where you are already identified. It was
rejected because it leaves the artifact unable to say anything at all about its
subject even when the holder wants it to, and the thing that would fix that is
one string. (b) is strictly stronger than (a) and weaker than an identity claim,
which is the correct position given that the identity claim is unavailable.

**The claim is deliberately weak, and the interface must state it weakly.**
Nothing proves the name is true; `docs/product.md` makes the second party that
could check it a permanent non-goal, and that is not being overturned here.
What is proven is narrower and real: the declaration is an event in the log, and
`docs/achievement-protocol.md` §4's `witness.logHeads` commits to the whole
history as of detection — so a name declared before a record is sealed cannot be
restated afterwards without breaking that seal. **It proves the name was
committed to at the time, never that it is true.** The settings sheet says
exactly that, in those terms.

**Why it is a kind and not a field in `facts`.** `facts` is inside the canonical
bytes, and a digested field cannot be added additively — the same argument that
kept `source_backfill` in the digest keeps this out of it. `EventKind` is a
`RawRepresentable` string precisely so a kind can be added later without a format
change (`docs/technical.md` §3), and this is the first use of that affordance.
It costs nothing: `subjectNamed` reuses `name`, a key `payload` had already
frozen, so the closed-payload rule does not move, no existing kind's key order
moves, and a build predating the kind decodes the line, ignores it in the fold,
and re-emits it unchanged.

Withdrawing a name is declaring an empty one, appended. **Nothing is deleted**,
and a record sealed while a name stood keeps that name.

No non-goal is overturned by this. (b) adds a field; it does not add an account.

### The unchecked mark is 45% ink, not 25%, and that is a deviation

Recorded because the design document explicitly asked for it to be, and because
an unrecorded deviation is one a future session "fixes" back.

The unchecked habit mark is a rounded-square stroke at **45% ink**, not the
`opacity(0.25)` the design document cites as the UI rule. The grounds are
measured contrast: **1.82:1 at 25%, 3.3:1 at 45%.** The lower value is not
legible as a control, and the mark is the only thing on an unchecked row that
says the row is a thing you press.

Two honest notes on the citation. `.claude/skills/ui.md` **as it now stands
states no opacity for the mark at all**, so the deviation is from the value the
design document quotes, not from a line a reader will find in the skills file
today. And the accompanying stroke widths — 1.7 at 20pt, 2.4 at the 48pt drawn
at AX5 — are deliberately not proportional: the mark grows 2.4x and the stroke
1.4x, because a proportionally scaled stroke on a 48pt square reads as a filled
square, which is the checked state.

`Sources/CompassUI/TodayMetrics.swift` carries the numbers and the reasoning at
the site.

### What landed with these decisions

Habit management in the settings sheet — add one, remove one — plus the settings
glyph the design specified and an earlier session deliberately held back because
the sheet did not exist yet. **Removing a habit appends `habitArchived` and never
deletes anything**, the habit keeps every day it recorded, and the four-habit cap
counts active habits only. The sheet says both of those out loud rather than
leaving them to the documentation.

Habit rows are now ordered by **creation order** rather than by identifier byte
order. That was invisible while every ID was a seed constant and became wrong the
moment the sheet could mint one: identifiers are opaque on purpose, so ordering
by them would have put a habit added this afternoon wherever random hex landed.
The register keeps the earliest creation, per habit, so it is order-independent
like every other register in the fold.

Accepted by the human on 2026-07-31.
