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
