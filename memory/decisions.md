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

> *Superseded on the same day, kept as written.* "Create two habits" became
> **four, seeded in the bundle** — see the 2026-07-31 entry below. Nothing else
> in the sentence changed.

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

---

## 2026-07-31 — behaviour does not live in `@State`

**The rule.** A screen's behaviour — what a control commits, discards or refuses
— goes in a plain value beside the `View`, and the `View` keeps the layout. It is
now written down in `.claude/skills/architecture.md`, because until this entry
the lesson existed only as a paragraph inside the file it produced, and a lesson
with no rule behind it is one the next session re-learns.

**The evidence, and it is measured.** `SettingsView` held three `@State`
properties, and two data bugs lived in them:

- Done committed habit renames and returned, silently dropping a declared name
  typed and not submitted — the exact loss the handler's own comment said it
  existed to prevent, on the one field the sheet was added for;
- Done wrote a rename the user had cancelled by removing the habit, because an
  in-flight edit was cleared only by committing it and the sweep ran over active
  habits only. Remove then Restore put a name on screen that the log did not
  have.

Both are ordinary logic. Both were unreachable from a test, and **both survived a
suite of 206 tests** — verified by running `swift test` at `f2fd73e`, the commit
before the fix, which reports "206 tests in 23 suites passed". `@State` inside a
`View` is state no test can construct or drive, and
`.claude/skills/testing.md` refuses snapshot tests and a broad XCUITest suite out
loud — so "test it through the view" was never available, and pretending
otherwise is how these two lasted.

**It is the same move as the composition root**, one target down, and that move
landed a `PROJECT_CONSTITUTION.md` §2 update, an architecture rule and a dated
entry here. This one landed the extraction and none of the three. That asymmetry
is what this entry closes.

The extraction is `Sources/CompassUI/SettingsEdits.swift`; the tests that could
not exist before it are `Tests/CompassUITests/SettingsTests.swift`.

**What was given up.** One more file and one more indirection between reading
`SettingsView` and knowing what Done does. Paid down by the pointer at the
`@State` declaration and by `SettingsEdits` carrying the reasoning at the site.

**Under `PROJECT_CONSTITUTION.md` §12** the limb cited is maintainability, on the
same measured grounds as the composition-root entry above. No security limb is
claimed.

---

## 2026-07-31 — Done commits every edit and no creation

**The decision.** The settings sheet's Done button commits the habit renames and
the declared name, and deliberately does **not** commit the "New habit" field.
The field's text dies with the sheet.

**Why the asymmetry is the point.** Every other field on the sheet revises
something that already exists and is revisable: a rename is undone by another
rename, a declared name is withdrawn by declaring an empty one. Creating a habit
is neither. It mints a `HabitID` and appends a `habitCreated` to a log that is
append-only and has no tidying pass, so a habit minted from three abandoned
characters is on disk forever — inside `witness.logHeads` for every achievement
sealed afterwards — and Remove archives rather than deletes, so there is no way
back. It could also spend the last free slot under the four-habit cap without
the user asking for it.

It is the rule `SettingsEdits.remove(_:from:)` already keeps in the other
direction: **abandoning a field is not confirming it.** Dismissal is ambiguous,
and where it is ambiguous this sheet does the reversible thing.

**Correction, 2026-08-01.** This paragraph ended "Add is one visible, enabled tap
away on the same row", and so did the doc comment it was written from. It is
false on the install that ships. `AppComposition.seededHabits` seeds four and
`Projection.habitCap` is 4, so a fresh install sits at the cap: `canAdd(in:)`
requires `mayAddHabit`, which is false there, and the Add button is **disabled**.
A name typed into that field cannot be committed at all until a habit is
removed, which `SettingsCopy.addFooterAtCap` states in the footer.

The decision stands and the argument gets stronger, not weaker. Below the cap,
refusing to sweep the field costs the user one tap. At the cap, sweeping it
could only fail silently or spend a slot nobody asked for. So the field must not
be swept in either regime, and "one tap away" was never what carried the
reasoning — it was a consolation offered to the reader, and it happens not to
exist on day one.

**What was given up, honestly.** A user who types a habit name and taps Done
loses the typing. That is accepted, and the alternative — a permanent record
nobody confirmed — is worse in a project whose whole premise is that the log can
be believed.

Recorded because the Done comment previously claimed it committed *every* field,
which was false, and because the next session to notice the asymmetry will read
it as an oversight and "fix" it. `SettingsTests.doneRefusesToCreateFromAHalfTypedName`
is what makes that fix fail out loud.

---

## 2026-08-01 — the three-day entry condition on week 1b is waived

**What was waived.** `docs/technical.md` §11 gates week 1b on an entry
condition: *the app has been opened three days running.* The owner has chosen to
proceed with weeks 1b, 2, 3 and 4 without meeting that condition.

**The condition is not partially met.** The app has never been opened on a
phone. `memory/next-tasks.md`'s only unticked week 1a item is **"Install on the
phone. Use it."**

§11 is left standing as written. The gate and the waiver are both on the record.

**What it costs, recorded so nobody has to reconstruct it later:**

- **Week 1b freezes the canonical byte encoding.** §11's one-time `reproject`
  escape hatch closes permanently at the first signature, which is week 3. So
  the format is being frozen against a loop nobody has lived with.
- **§11's stated reason for the gate** is that overstating the encoding as
  irreversible "put an irreversible cryptographic commitment at item three of
  day one for an author with 58 repositories that died on their creation day".
- **The four high-severity defects found on 2026-07-31** were all cases of the
  app asserting something untrue, and none was caught by a green test suite.
  Real use is the detector that was skipped.

**Who decided.** The owner, explicitly, on 2026-08-01.
`PROJECT_CONSTITUTION.md` §6 makes the roadmap his.

---

## 2026-08-01 — `CompassDomain` imports CryptoKit

**What changed.** `docs/technical.md` §2 and `.claude/skills/architecture.md`
both said `CompassDomain` imports "Foundation only". They now say Foundation and
**CryptoKit**.

**Why it was not worked around.** The corpus already requires SHA-256 in the pure
layer, twice. `content_hash` is defined in §3 as SHA-256 over canonical bytes,
and `docs/achievement-protocol.md` §4.1 builds `evidenceRoot` out of those hashes
inside an engine `docs/technical.md` §5 requires to be "a pure, idempotent,
re-runnable function". A design where the pure layer cannot hash is a design
where week 3's engine cannot be pure.

**The alternatives, and why both are worse and both are already forbidden:**

- **A hashing port in Domain.** One implementation, one call site.
  `PROJECT_CONSTITUTION.md` §8: "No abstraction with a single use site."
- **A hand-written SHA-256.** `PROJECT_CONSTITUTION.md` §5: prefer mature,
  well-supported technology; newness is never sufficient. Re-implementing a
  primitive that ships in the OS, on the path that a Bitcoin anchor will
  eventually depend on, is the opposite of that rule.
- **`content_hash` computed in Infrastructure.** Splits one concept across a
  boundary, leaves `Event` unable to verify its own chain, and forces week 3's
  pure engine to take an injected hasher — which is the first alternative again.

**What it does not change.** The boundary that is load-bearing is *Domain must
never learn Infrastructure exists*, and §2 says the enforcement mechanism is that
"a target that does not declare a dependency physically cannot import it".
CryptoKit is a platform framework, not a package target; it is not declared as a
dependency by anything and the compiler still refuses `import CompassInfrastructure`
inside Domain. The rule that a **third-party package** needs a fired trigger in
`docs/technical.md` §10 is untouched — third-party dependencies in v1 are still
none.

**Authority.** `PROJECT_CONSTITUTION.md` §6 gives the AI "project structure,
package layout, Swift APIs". This is that. It is recorded here because the
sentence it changed was quoted in two skills files and a doc, and a quiet edit to
a rule that three documents state is how a rule stops being a rule.

## 2026-08-01 — the canonical encoding, frozen

**What is frozen.** `CompassDomain/CanonicalBytes.swift` is the only place the
canonical form exists in code. It is the eleven values `docs/technical.md` §3
lists, in that order, UTF-8, no whitespace, `source` omitted when absent,
`payload` present always and closed per kind, `prev` as padded base64. Escaping is
`\\`, `\"`, `\n` and nothing else; every other control character is **refused at
write time**, which is why `EventJournal` canonicalises before it writes.

**How it was checked, and why the method matters more than the result.** The
expected byte string in `CanonicalBytesTests` is transcribed from §3 **by hand**
and its SHA-256 comes from two tools outside this project. A hex captured from a
run pins whatever the code happened to do, and the first session to reorder a key
re-records it and nothing fails. Independently, a ~40-line verifier written in
Python from §3 alone — sharing no code with the app — reproduced every
`content_hash` and every `prev` link in the **live simulator log**, including
after a real tap. That is the property week 4's standalone verifier needs and it
is now demonstrated rather than assumed.

**One rule reproduces the whole per-kind payload table:** emit the present fields
in the fixed order `habitID`, `name`, `achievementID`, `reason`. Every kind §3
lists is a subsequence of that order. It was chosen over a `switch` on `kind`
because `EventKind` is a `RawRepresentable` string precisely so a newer build can
add a kind — and a `switch` would have no branch for one, so two builds would
disagree about the bytes of one line.

## 2026-08-01 — the `reproject` hatch has been used, and "exactly once" is enforced in code

**It ran.** On 2026-08-01, against the real week-1a log in the App Group
container. Four `habitCreated` events that carried `prev = genesis` now carry a
chain; `events.jsonl.pre-chain` holds the original and is never overwritten.

**"Exactly once" is not a flag.** `docs/technical.md` §11 says the hatch may be
used exactly once. An already-chained log makes it a no-op, which covers the
ordinary second launch — but a chain that breaks *later*, for any reason, would
have walked straight back in and rewritten every `prev` in the file. That is a
second use.

The rule is now: `events.jsonl.pre-chain` is the record of the first use, and its
contents decide. Absent — first use, copy and rewrite. Identical to the live log —
a previous attempt died between the copy and the swap, so finishing it is the
*same* use. Different — the hatch has been used; refuse with
`.refusedAlreadyUsed`, and whatever broke the chain since is damage to report
under §6, not a `prev` to recompute.

**This was found by mutation, not by review.** Reintroducing "overwrite the
pre-chain original" left the whole suite green, because the only test that
exercised a second run hit the already-chained no-op first. The surviving mutant
was the finding.

## 2026-08-01 — the snapshot cache may never carry a `lamport` or a chain head

**The rule.** `snapshot.json` carries habit names, today's booleans, the totals
and the strip. It carries **no `lamport`, no chain head and no `device`**, and it
must never acquire one.

**Why it is worth a decision rather than a comment.** The cache exists because a
full rebuild is not free — 193 ms at five years, 865 ms at ten — and the obvious
next optimisation is to put the writer's resume in it too, so the first tap after
a cache launch does not have to read the log. That would make a file in
`docs/technical.md` §6's *disposable* tier load-bearing for the tier that cannot
be rebuilt: a stale cache handing a writer a `lamport` it has already used forks
that writer's chain, silently, on the one file the whole project rests on.

**What is done instead.** `EventLog.replay()` reads the log from the `.task` that
follows the first frame and hands the resume to `EventJournal.prime(_:)`, which
**never overwrites** one a tap already established. If a tap beats the replay the
journal recovers under the advisory `flock` — the cold-start path §4 already
describes. The cost is a latency claim nobody has measured on a device;
`memory/known-bugs.md` carries it.

**A second consequence, stated because it looks like a bug.** While the cache
stands in for the log, `TodayModel.totalDays` is computed as
`snapshot.daysRecorded − (snapshot.dayIsRecorded ? 1 : 0) + (recorded today ? 1 : 0)`.
That is exact, not approximate: today is the only day whose recorded-ness can
change before the replay lands. The largest number on the screen is the one thing
a person checks, and a cache that could only be roughly right about it would be
worse than no cache.

## 2026-08-01 — `spineLength` moved to `CompassDomain`

**What moved.** The literal `28`. `TodayMetrics.spineLength` now reads
`TodaySnapshot.spineLength`.

**Why.** The launch cache carries the strip and is written by
`CompassInfrastructure`, which cannot import `CompassUI`. The alternatives were a
second constant in Infrastructure — two things that can disagree, and the one
that is wrong is the one nobody is looking at — or passing the number down
through `AppComposition.compose`, which would have put a forwarded argument in
`App/`, where `.claude/skills/architecture.md` forbids one because no test can see
it.

**Precedent, not a new idea.** `Projection.habitCap` already lives beside the
fold rather than beside the layout, for the same stated reason. `TodayMetrics`
remains the only place the *layout* asks the question.

---

## 2026-08-01 — `lamport` is a Lamport clock, and week 1b implemented a serial number

**Found by the two-writer test, on the day it was written, exactly as
`docs/technical.md` §4 predicted a cross-process defect would have to be found.**

`JournalRead.resume(for:)` recovered `highWaterMarks[writer]` — the writer's own
highest `lamport`. §3 has always said "Lamport first so causality holds", and a
per-writer serial number carries no causality. With one writer the two are the
same number and nothing in a suite of 287 tests could distinguish them.

What the second writer made observable:

> The app seeds four habits and records a check-in, reaching `lamport 5`. The
> widget process, which has never written, starts at **1**. The user presses the
> widget to un-check that habit and the revocation lands at `(1, widget)`. The
> fold resolves the cell last-writer-wins under `(lamport, device)`, so
> `(5, app)` wins and the un-check is **discarded** — not delayed, discarded, for
> as long as the log exists, with the event sitting on disk the whole time.

**Decision: the clock resumes from the highest `lamport` in the whole log; the
chain head stays this writer's own.** Recovered together, updated apart. This is
implementing what the document says, not redesigning it — `PROJECT_CONSTITUTION.md`
§9. Per-writer monotonicity and `(lamport, device)` uniqueness both survive: a
maximum over a set containing this writer's mark cannot be below it, and the
`device` half is what two writers landing on one number have always had.

Two consequences, both implemented:

- `EventJournal.prime` now **raises** a clock it already has, where it used to
  refuse any second value. It still never moves the head — a value read before a
  write that already happened would fork the chain. The head is the thing that
  must not move backwards; the clock is the thing that must not stand still.
- `TodayView` reconciles on `.task(id: scenePhase)`, so an app returning from the
  background re-reads the log and re-primes. Without it, a tap made a second ago
  ties with a widget press from ten minutes ago and the tie is decided by which
  random UUID is larger.

Four tests fail without this: `theClockCarriesCausality`,
`primingRaisesTheClockButNeverMovesTheHead`, `theLaterPressWins`, and
`thetwoWritersShareOneTruth`.

---

## 2026-08-01 — `CompassInfrastructure` imports `CompassApplication`

`docs/technical.md` §11 requires the widget to use "the same append API" as the
app, and §4 says why: two writers disagreeing about what a tap means is a fork
with no lock to catch it. That decision is `CheckIn` and it lives in
`CompassApplication`; the widget's path into the store is Infrastructure, because
it reads the log, takes the `flock` and writes the disposable cache.

So one of three things had to be true, and the third was chosen:

1. duplicate the decision in the widget path — the fork itself;
2. move `CheckIn` into `CompassDomain`, reversing a written decision and emptying
   `CompassApplication` for no gain;
3. **add the edge Infrastructure → Application → Domain.**

No cycle, and the one load-bearing boundary — Domain must never learn
Infrastructure exists — is untouched. `PROJECT_CONSTITUTION.md` §6 puts package
layout squarely in the AI's authority; recorded here because §2's dependency list
is documentation and changed with the code.

The shared call is `CheckIn.toggle(_:on:in:from:using:)`. `TodayModel.toggle`
passes `.tap`, the widget passes `.widget`, and nothing else differs. Mutation:
give the widget its own `record` call and `sourceIsTheWidgetsOwn` fails.

---

## 2026-08-01 — one App Intent ships, not two

`memory/next-tasks.md` listed `ToggleHabitIntent` **and** `CheckInIntent`. Only
the first is written.

`.claude/skills/ios.md` says to "build App Intents first, as substrate — but ship
**only the widget** on top of them in v1", and `docs/technical.md` §10b defers
`AppShortcutsProvider` phrases, the Control Center control and the Action Button
behind triggers that have not fired. A second intent with no caller is an entry
point with no user, and the same skill file states the cost: "every extra entry
point is another place the tap path must stay correct and another place a wrong
day boundary or a lost write can hide."

The deferral is enforced rather than remembered: `isDiscoverable = false` keeps
the intent out of Shortcuts and Siri. Overturn by writing the phrases when a
Shortcuts automation is actually wanted.

---

## 2026-08-01 — the widget writes the disposable cache, and reads the log

Two decisions about `snapshot.json` that pull in opposite directions, and both
follow from the same rule: a cache is a claim, the log is the fact.

**It writes the cache after a press.** Not doing so leaves the app's next launch
rendering a first frame that contradicts a press the user just made and watched
land. The cache carries no `lamport`, no head and no `device`, so a second process
writing it cannot fork anything — which is precisely why
`.claude/skills/architecture.md` requires it to stay that way.

**It never reads the cache.** In the app a stale cache costs one wrong frame and
the replay fixes it; here the read decides *which event gets written*, and a stale
"unchecked" appends a second `checkedIn` for a day that already has one.

Also decided here: a press for a habit that is archived or absent is **refused**,
writing nothing. A rendered widget outlives the row it was drawn from, and the app
cannot reach this state because its rows come from the live projection.

---

## 2026-08-01 — week 3: five design assertions adjudicated against the frozen docs

The design bundle for the certificate and the seal is five turns deep and
contradicts itself and `.claude/skills/ui.md` in five places. Each is settled
here so it is not re-argued, and each is a **refusal recorded as the decision**
rather than a silence.

### 1. The attestation copy is `ui.md`'s, verbatim

`ui.md` lines 48–50 fix the literal strings: **"Sealed on this device"**,
upgrading on confirmation to **"Sealed on this device · Anchored <date>"** — one
line, a middot, no full stops. The design bundle renders three different
treatments across three turns: two sentences with full stops, two separate lines,
and one continuous sentence. None of them is `ui.md`'s, and `ui.md` is frozen.

`ui.md` wins. If the two-line notary stack is ever wanted, it is a copy change and
it needs a line here first — which is what this entry is the precedent for.

### 2. The seal's press-and-settle animation does not ship

`ui.md` line 46 enumerates exactly one certificate animation — "fades up 12pt over
220ms" — and adds "It does not pop, bounce, fly, or spin." The design adds a
second: the seal scaling 1.035 → 1.0 over 180ms from t=60ms. It is inside the
300ms budget and has no overshoot, so it is not literally a bounce; a scale-in is
nonetheless the nearest thing on that list, and `ui.md` authorises no second
animation.

The design concedes it itself: "the certificate would lose nothing by being still,
and stillness is more in character for a document. If the 180ms ever looks like
flourish on the device, delete it — the layout does not depend on it." So it is
still. Overturn by writing the line here, not by re-reading the design bundle.

### 3. There is no haptic on issue

Turn 6f states flatly "The haptic ships." Nothing authorises it: `ui.md`'s only
haptic rule is about the daily tap, and the non-goals do not cover haptics either
way — so this is not a non-goal violation, it is an unrecorded product decision
taken inside a design bundle. `docs/product.md` is explicit that decisions are
made in writing here and never by a field quietly appearing in a spec. It is
dropped. 6f itself says reversing it costs one line.

### 4. A rule ID names the opaque `HabitID`, never a display name

`docs/achievement-protocol.md` §3.1's example is `"streak.meditate.100"`. Taken
literally that is the failure §3.4 exists to prevent, one field over: `rule.id` is
inside the digest (§6.2), it is printed verbatim in the certificate's identifier
block, and the certificate is the artifact designed to be handed to a stranger. A
record named after a recovery programme, a medical routine or a therapy task would
be unredactable forever — which is §3.4's own argument about `facts`.

**The shipped rows read `streak.habit-a.100`.** The rendering rule that follows,
which had to be decided before the first certificate was signed:

> The habit's **display name** is resolved at render time from the mutable local
> mapping, keyed by the `habitID` in `facts`. **Nothing frozen into the record
> ever carries a display name, including `rule.id`.**

So after a rename the claim line changes and the identifier line does not — and
they **cannot** disagree, because the identifier line names no habit at all.
`CertificateCopyTests.aRenameCannotMakeTheDocumentContradictItself` is the
mutation target; `AchievementIssuerTests.ruleIdentifiersAreOpaque` is the guard on
the shipped rows.

### 5. A pre-baked matrix render never ships, and the guard reads the source tree

One line of turn 5c says "Shipping assets are the full-size PNGs", and every
certificate drawing in turn 5 displays a rendered matrix as the seal. A pre-baked
matrix prints an **identical** 64-bit hallmark on every certificate — destroying
the exact property 5c claims for it and putting a false statement on a signed,
anchored, shareable document. Turn 5d, later in the same turn, withdraws it. The
later line governs and `Assets/seal/README.md` had already adjudicated it.

Two consequences that are decisions rather than restatements:

- **The die frames ship as four loose PNGs, not as an asset catalogue.**
  `swift build` does not run `actool`, so a catalogue is copied verbatim into the
  resource bundle and every lookup inside it fails.
- **The guard reads `Sources/`, not the built bundle.** Copying a matrix render
  into `Sources/CompassUI/SealFrames/` was tried on 2026-08-01: SwiftPM did not
  notice, did not re-copy, and the bundle-only assertion **passed with the render
  sitting in the repository**. A guard a stale build can defeat is not a guard.

---

## 2026-08-01 — the certificate list falls back to `earnedOn`

`docs/achievement-protocol.md` §3.3 gives `detectedAt` exactly two jobs, one of
which is ordering the certificate list. On the run that produces the *longest*
list — the first pass, which backfills every historical award — every record is
detected at the same instant, so `detectedAt` orders nothing at all.

Measured on the simulator: four awards issued in one pass rendered as 7 days,
30 days, 7 days, 30 days. Reverse-chronological in name only.

So the order is `detectedAt`, then `earnedOn`, then `id`. `earnedOn` is a digested
field and it is what a person means by chronological. The `id` stays as the last
resort so two records earned on one day still have one order.

---

## 2026-08-01 — the achievement engine takes the log, not a projection

`docs/technical.md` §4's tap-path sketch reads
`Task { await achievements.evaluate(projection) }`, and that signature cannot be
implemented: `docs/achievement-protocol.md` §4.1 builds `evidenceRoot` out of the
qualifying events' `content_hash`, and `witness.logHeads` needs every writer's
chain head. A `Projection` carries neither — it folds check-ins into booleans and
drops the events that produced them.

Teaching `Projection` to carry the winning `Event` per cell was considered and
rejected: the projection is also rehydrated from the disposable launch cache,
which has no events in it, so half of every restored projection would carry a
field it structurally cannot fill.

So the `Awarding` port takes nothing and the adapter reads the log. `QualifyingLog`
re-derives the `(habit, day)` cell in the same last-writer-wins order `Projection`
uses, and `AchievementEngineTests.theEngineAndTheFoldAgree` is what holds the two
together rather than review.

---

## 2026-08-01 — week 4: three decisions the documents did not make

All three arose because ADR 0004 mandates weekly log-head anchoring and
`docs/achievement-protocol.md` specifies only the *achievement* record. They are
recorded rather than left implicit, because each is a place a future session
would otherwise re-derive an answer and pick a different one.

### The log-head anchor is a new record type, in its own file

`anchors.jsonl`, with its canonical form fixed in `docs/technical.md` §6.

**Why not in `attestations.jsonl`.** That file is keyed by `AchievementID` and a
log head is not an achievement. Filing one there would have meant minting a fake
achievement identifier to key it under — the exact kind of invention
`docs/achievement-protocol.md` exists to prevent, performed inside the file that
document specifies.

**Why the canonical form carries no timestamp.** ADR 0004's own argument against
putting `attainedAt` on a chain is that a self-asserted instant is "just a number
the issuer typed in". The calendar is what supplies the time; a claimed one
inside the digest would be claiming the thing being proved. The consequence is
deliberate and load-bearing: two anchors over the same heads have the same
digest, so **unchanged heads are never re-anchored** — a second submission would
buy a strictly later Bitcoin timestamp for a value that already has an earlier
one.

**What was given up.** A fourth file in the store, and a fourth entry in the
export list that is stated identically in four documents. Both were paid in the
same change.

### The retry counter is the append-only file, not a new field

`docs/achievement-protocol.md` §7.1 requires exponential backoff and §7's
`Attestation` has no field for an attempt count. **No field was added.** Both
anchor files are append-only and every state change appends a line, so the number
of `failed` lines for a record *is* the attempt count, and the next attempt is
`firstAttempt + Σ delays`. Deterministic, needs nothing the protocol lacks, and
it uses the property the storage design already had rather than adding one.

The schedule doubles from one hour, stops widening at one week, and **never gives
up** — ADR 0004 asks for re-attempts "over a long horizon, months, not the length
of one backoff schedule", so there is no attempt limit and there must not be one.

### `Attestation.calendar` stays singular, and is filled in only on confirmation

ADR 0004 requires three submissions; §7 gives one `calendar` field. The field is
left `nil` while `submitted` — there is no single calendar to name, and the three
pending attestations live inside `otsProof`, which is the OpenTimestamps format's
own way of holding them — and is filled in on `confirmed` with the calendar whose
branch delivered the Bitcoin path. That is the only moment the question has one
answer.

**The alternative was amending the protocol document to make it plural**, which
`PROJECT_CONSTITUTION.md` §6 puts outside what may change without an ADR and the
human's agreement, for a field that is presentational and that nothing renders.
Reported in `docs/achievement-protocol.md` §7.0 instead. The log-head record,
which no document freezes, has `calendars` plural.

---

## 2026-08-01 — the verifier is Python, and it re-derives the claim

**Language.** Python 3, standard library only. The competing option was a Swift
executable in this package, which would have had CryptoKit for free. It loses on
the one thing the verifier is for: `docs/product.md` promises a stranger can
check the record, and a stranger with a Linux box and no Xcode is the ordinary
case. Week 1b already set this precedent — the event encoding was checked against
a Python verifier written from `docs/technical.md` §3 alone — and this is that
same instrument, finished.

**Scope, and why it is 579 lines and not ~200.** The brief in `technical.md` §10a
asks for the canonical bytes, the chain, the signature and the proof. It also
**re-derives the claim from the log**: the qualifying days for both shipped rule
kinds, and the Merkle evidence root over the events that were counted. That was
not in the estimate and it is the difference between checking that a record is
signed and checking that it is *true*. A verifier that only checked signatures
would pass a bundle in which the log says one thing and the certificate says
another, which is precisely the forgery the whole apparatus exists to prevent.

**What it refuses to do**, printed on every run rather than left to be assumed:
it does not fetch Bitcoin headers. A Bitcoin attestation commits a merkle root at
a stated height; confirming that root is that block's needs a node or a header
chain, and shipping either inside the script would be a bigger act of trust than
the one it removes. It prints the height and the root, and says it did not take
the last step.

Accepted as an implementation decision under `PROJECT_CONSTITUTION.md` §6, which
gives the AI implementation details and testing strategy. Nothing in the product
vision, the protocol or the trust model moved.
