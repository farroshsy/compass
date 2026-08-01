# Compass Achievement Protocol, version 1

**Status:** normative for this repository.

**Scope, stated precisely because the loose version contradicted the mission.**
This is not a standard, not an SDK, not a platform, and it must not acquire a
second *implementer* — nobody else builds a product against it, and it never
acquires extensibility requirements, versioning politics or
backwards-compatibility debt on anyone else's behalf. See non-goals in
`docs/product.md`.

But §6 and §9 are **published verification procedure**, not private internals.
The mission sentence promises a record a stranger can check without trusting the
app or its author, and that is unachievable if the stranger must reimplement a
hand-written encoder from a document the project forbids them to consume. A
~200-line standalone verifier ships in this repository in week 4
(`docs/technical.md` §10), and it is the second *reader* of this format —
which is a different thing from a second implementer and is explicitly allowed.

The distinction that keeps both true: **anyone may check a Compass record;
nobody builds a Compass.**

The key words MUST, MUST NOT, SHOULD, SHOULD NOT and MAY are to be read as in
RFC 2119.

The purpose of this document is narrow and specific: **future code must not
invent fields.** Every field that exists is listed here with its type and its
semantics, and every field that was considered and deleted is listed in §10 with
the consumer that was missing. If a field is needed that is not here, this
document is amended first, in a commit of its own.

---

## 1. Definition

An **achievement** is an immutable, self-describing claim that a named rule
became true on a named civil day, carrying enough evidence for a stranger to
check it without the app.

It is not a badge, not a token, and not a row pointing at a live rules table.

---

## 2. Primitive types

### 2.1 `Day`

A civil date label. No instant, no timezone, no locale.

- Internal representation MAY be an integer ordinal (days since 2000-01-01,
  proleptic Gregorian).
- On-disk representation MUST be the string `"YYYY-MM-DD"`, zero-padded.
- Comparison and arithmetic MUST be integer operations on the ordinal.
- A `Day` MUST NOT be derived from a `Date` anywhere in `CompassDomain`. The
  conversion happens once, in `CompassInfrastructure`, at the moment of the tap,
  using a day-start hour of **04:00 local**, and is thereafter immutable.

### 2.2 Extensible identifiers

`AchievementID`, `RuleID`, `RuleKind`, `HabitID`, `EventKind` and `FactKey`
MUST be `RawRepresentable` structs over `String`, **never Swift enums.**

An unknown enum case is a decode crash and a `default:` branch to migrate
around. A `RawRepresentable` string decodes unknown values cleanly and preserves
them.

Enums are permitted **only** for closed sets defined by someone else, or by this
document as frozen: `JSONValue`, `AnchorState`, `SignerBacking`, `CheckInSource`.

### 2.3 `JSONValue`

A closed enum: `string`, `int`, `bool`, `array`, `object`, `null`.

**There is no floating-point case, and one MUST NOT be added.** Floating-point
formatting is not stable across platforms or releases, and these values are
inside a digest. Any quantity that seems to need a fraction MUST be expressed as
an integer in a stated unit.

---

## 3. `Achievement` — the record

Seven fields. No more.

```swift
struct Achievement: Codable, Sendable, Hashable, Identifiable {
    let id: AchievementID          // deterministic — §3.1
    let rule: RuleSpec             // FROZEN copy of the rule that fired — §3.2
    let earnedOn: Day              // the civil day it became true
    let detectedAt: Date           // the instant the engine noticed
    let facts: [FactKey: JSONValue]
    let witness: Witness           // §4
    let extra: [String: JSONValue] // forward-compat, round-tripped losslessly
}
```

### 3.1 `id` — deterministic, never a UUID

```
id = "<rule.id>@<earnedOn>"      e.g. "streak.meditate.100@2026-03-14"
```

A random UUID means replaying the log twice produces two awards for one fact,
and two devices produce duplicates. A deterministic ID makes the engine safely
re-runnable an unlimited number of times, which is the precondition for
retroactive edits and rule backfill.

**Constraint on `RuleID`:** a rule ID MUST NOT change meaning. If what a rule
counts changes — a rest-day exemption is added, a streak is redefined — that is
a **new** `RuleID`, not a new version of an old one. Reusing an ID with new
semantics would allow the same underlying fact to hash to a different
achievement and be awarded twice.

`RuleSpec.version` exists for wording and threshold-presentation changes that do
**not** alter what is counted. It is not in the digest and not in the ID.

### 3.2 `rule` — the whole spec, copied in, frozen

Not a foreign key. An achievement earned in 2026 must still render and verify in
2029 after the rule has been reworded, retuned, or deleted entirely.

Storing a reference is what forces achievement-system migrations. Storing the
definition is what avoids them. Cost is roughly 200 bytes on about a dozen
records a year.

### 3.3 `earnedOn` and `detectedAt` — deliberately two fields

With retroactive edits and an app that was not opened for a week, "when it became
true" and "when we found out" genuinely differ, and a single field forces a lie
about one of them.

- `earnedOn` IS in the digest. It is the semantic claim.
- `detectedAt` is NOT in the digest. It is bookkeeping: it orders the
  certificate list and gates the 72-hour provisional window (§7.1). It does
  **not** drive a "new" indicator — that was cut, because a "new" badge is a
  re-engagement affordance in an app whose non-goals ban badges.

### 3.4 `facts`

The numbers that mattered, as an open map.

```json
{"streak": 100, "habitID": "h-7f3a9c21", "from": "2026-01-01",
 "source_live": 100, "source_backfill": 0}
```

#### The habit's display name MUST NOT appear in `facts`

`facts` is inside the canonical bytes (§6.1), which are hashed, signed and
anchored, and the resulting certificate is the artifact designed to be handed to
a stranger and shared through the single `ShareLink`. A name written in here can
never be taken back: `habitRenamed` is cosmetic and never affects the fold
(`docs/technical.md` §3), the record is immutable by Invariant 4, and the digest
is anchored to Bitcoin. There is no redaction path and there can never be one.

So a user who names a habit after a recovery programme, a medical routine or a
therapy task, earns a 30-day certificate, and later regrets the name would have
no remedy at all — while ADR 0004 goes to real effort to keep habit names off a
public chain. Keeping them off the chain and then freezing them into the record
people actually receive is not a coherent privacy model.

- `facts` carries `habitID`, a stable opaque identifier. **Never `habit`.**
- The human-readable name lives in a mutable local `habits.json`, resolved at
  render time — exactly the mechanism §5.2 already uses for titles, and for the
  same stated reason: it can be corrected forever without breaking a single
  anchor.
- The name is revealed by handing over `habits.json`, which travels in the
  export bundle. This is the same reveal-the-preimage control ADR 0004 uses
  on-chain.

#### `source_live` and `source_backfill`

**REQUIRED on every achievement derived from check-ins.** They partition
`witness.dayCount` and MUST sum to it. Without the partition, a certificate over
mostly backfilled days would be indistinguishable from one over live taps, and
the sealed claim would quietly overstate what happened — the one thing this
whole apparatus exists to prevent.

They are required **even though v1 ships no backfill surface** (see
`docs/technical.md` §10). These fields are inside the digest, so unlike an event
kind they cannot be added additively later. `source_backfill` is `0` on every v1
record, and that is a fact worth sealing rather than a field holding one value
by accident: it is the difference between "no day was backfilled" and "we did
not record whether any day was backfilled".

Values MUST be `string`, `int` or `bool`. See §2.3.

### 3.5 `extra`

A forward-compatibility bag. An older build reading a record written by a newer
build MUST preserve every key it does not understand and re-emit it unchanged.

**`extra` is NOT in the digest**, and the consequence MUST be understood:
anything that needs to be provable MUST go in `facts` or `witness`, never in
`extra`. An old build cannot compute a digest over fields it has never seen, and
the alternative — refusing to load unknown records — is the migration trap this
design exists to avoid.

---

## 4. `Witness` — the commitment to the underlying data

```swift
struct Witness: Codable, Sendable, Hashable {
    let firstDay: Day
    let lastDay: Day            // == earnedOn for streak rules
    let dayCount: Int
    let evidenceRoot: Data      // 32 bytes: Merkle root over qualifying events
    let logHeads: [String: Data] // deviceID -> that device's chain head
}
```

`evidenceRoot` and `logHeads` are not redundant and do different jobs:

- `evidenceRoot` pins **exactly which events were counted**. It is what makes a
  post-hoc revocation honest — the claim can still be checked against the set it
  was actually made over.
- `logHeads` commits to the **whole history** as of detection. It is what links
  the achievement to a weekly log-head anchor, which is the only thing that makes
  a backfilled achievement genuinely provable about the past rather than about
  the day it was detected.

`logHeads` MUST be serialised with device keys sorted byte-wise in the canonical
form. `deviceID` is a random 128-bit UUID and is never derived from hardware,
the Apple ID or the device name — it ships to strangers inside every exported
achievement, so it is specified in `docs/technical.md` §3 rather than left to
whatever is convenient.

### 4.1 `evidenceRoot` — the Merkle construction, frozen here

This is fixed in this document, now, rather than at week 3, for a specific
reason: `content_hash` is produced by the **week-1** event encoding, and
`docs/technical.md` §3 says such a field cannot be added afterwards without
invalidating every hash computed before the change. A week-3 engine specified in
terms of a quantity the week-1 encoding does not produce is a
week-one-blocks-on-week-twelve defect, and it would sit inside the one document
whose stated purpose is that future code must not invent fields.

- **Leaves** are the qualifying events' `content_hash` values, in
  `(lamport, device)` order. `content_hash` is defined in `docs/technical.md`
  §3 as `SHA-256` over the event's canonical bytes, and that definition is
  normative here.
- **Domain separation is mandatory**, so a leaf can never be confused with an
  internal node:
  - `leaf(e)   = SHA-256(0x00 ‖ content_hash(e))`
  - `node(l,r) = SHA-256(0x01 ‖ l ‖ r)`
- **Odd-node rule:** at any level with an odd number of nodes, the last node is
  **promoted unchanged** to the next level. It is NOT duplicated and paired with
  itself — duplication is the classic construction that admits two distinct leaf
  sets with one root.
- **Empty set:** an `evidenceRoot` over zero events is 32 zero bytes. No rule in
  v1 can produce this, and stating it costs one line and removes an undefined
  case.
- `evidenceRoot` is the root of the tree built by repeated application of
  `node` until one node remains. For a single leaf, the root **is** that leaf.

**Explicitly not stored:** the list of qualifying days. A 1000-day streak would
carry 1000 `Day` values, all recomputable from a log head that already commits
to them.

---

## 5. `RuleSpec`

```swift
struct RuleSpec: Codable, Sendable, Hashable {
    let id: RuleID              // "streak.meditate.100"
    let version: Int            // presentation only; not in the digest
    let kind: RuleKind
    let scope: Scope
    let threshold: Int
    let window: Int?            // rate_in_window: window length in days
    let requires: Int?          // rate_in_window: n satisfied within the window
    let maxBackfillLagDays: Int? // nil = backfills always count
    let neutralDaysBridge: Bool  // reserved; false until neutral days ship
    let repeatPolicy: RepeatPolicy // once | everyOccurrence | cooldown(days)
    let members: [RuleID]?       // all_of
    let titleKey: String         // display only; NOT in the digest
    let fallbackTitle: String    // display only; NOT in the digest
    let extra: [String: JSONValue]
}

struct Scope: Codable, Sendable, Hashable {  // struct, not an enum with payloads
    let habit: HabitID?    // nil = any
    let requiresAll: Bool  // all active habits done that day
}
```

`Scope.tag` was removed. Tags and categories are a named non-goal in
`docs/product.md`, and reserving a field for a banned feature is what keeps the
feature alive — a future session reads `tag: String?`, concludes tags were
planned, and builds them. `RuleKind` and the identifiers are `RawRepresentable`
strings so that additions cost no format change; the same argument applies here
in reverse, which is why giving the field up costs nothing. If tags are ever
genuinely wanted, the non-goal is overturned in writing in `memory/decisions.md`
first, and this document is amended in a commit of its own, per the rule at the
top of this file.

### 5.1 `RuleKind` — six named, two implemented

| kind | v1 | meaning |
|---|---|---|
| `streak` | yes | `threshold` consecutive qualifying days |
| `total` | yes | `threshold` qualifying days in total, not necessarily consecutive |
| `rate_in_window` | reserved | `requires` of `window` days |
| `first_ever` | reserved | the first qualifying day of all time |
| `distinct_weekdays` | reserved | `threshold` distinct weekdays covered |
| `all_of` | reserved | every rule in `members` earned |

An evaluator MUST skip an unknown `RuleKind` with a warning and MUST leave the
rule file on disk untouched. An older build never destroys rules it does not
understand.

**Tripwire:** if a seventh kind is wanted and it needs conditionals *inside*
itself, stop and write Swift. That is a DSL arriving by accident, and it is the
shape of scope creep that has killed prior attempts.

### 5.2 Title rendering

Titles are **derived, never stored on the achievement**. `titleKey` plus
`fallbackTitle` plus `facts` renders the display string.

Because display text is excluded from the digest, a typo can be corrected
forever without breaking a single anchor. `fallbackTitle` is frozen at earn time
so a typo is permanent on the fallback path only; this is accepted deliberately,
because the localisation-key path fixes it.

---

## 6. Canonical bytes and the digest

The digest is what gets signed and anchored. It MUST be computed over
hand-written bytes, not `JSONEncoder`. Dictionary ordering is not a promise
Swift makes across releases, and a verifier recomputing this in three years must
get byte-identical output.

### 6.1 Achievement canonical form

Exact key order, no whitespace, UTF-8:

```
{"v":1,"id":<string>,"rule":<rule-digest-form>,"earnedOn":<string>,
 "facts":<canonical-map>,"witness":<canonical-witness>}
```

### 6.2 `rule-digest-form`

Exact key order. **Display fields are omitted.** Optional fields that are `nil`
are omitted entirely, never emitted as `null`.

```
{"id":<string>,"kind":<string>,"scope":<canonical-scope>,"threshold":<int>,
 "window":<int>?,"requires":<int>?,"maxBackfillLagDays":<int>?,
 "neutralDaysBridge":<bool>,"repeatPolicy":<string>,"members":[<string>…]?}
```

Omitted from the digest, and therefore freely correctable forever: `version`,
`titleKey`, `fallbackTitle`, `extra`.

### 6.3 `canonical-map`

Keys sorted by UTF-8 byte value, ascending. Values emitted per §2.3. Strings
escaped as `\\`, `\"`, `\n` and nothing else — any other control character MUST
be rejected at write time rather than escaped, so the escaping rules can never
drift.

### 6.4 `canonical-scope`

Referenced by §6.2, so it is spelled out rather than implied. Exact key order.
Optional fields that are `nil` are omitted entirely, never emitted as `null`.

```
{"habit":<string>?,"requiresAll":<bool>}
```

### 6.5 `canonical-witness`

```
{"firstDay":<string>,"lastDay":<string>,"dayCount":<int>,
 "evidenceRoot":<base64>,"logHeads":<canonical-map of deviceID -> base64>}
```

Base64 is standard, with padding, per RFC 4648 §4.

### 6.6 Digest

```
digest = SHA-256(canonicalBytes)
```

### 6.7 Signature — the convention, stated in code terms

`memory/known-bugs.md` requires this to be decided before the first achievement
is signed and written into this section. It is stated here in code, because the
ambiguity being closed is one that already produced a real defect in the code
being copied in, and prose is not precise enough to close it.

```swift
// CORRECT. The DataProtocol overload hashes its argument once.
let signature = try privateKey.signature(for: canonicalBytes).rawRepresentation
```

- The signed message is therefore **`SHA-256(canonicalBytes)`**, which is
  exactly `digest` as defined in §6.6. There is no second hash.
- **`Signer.sign(_ text:)` as inherited from `BeforeKit` MUST NOT be called on
  this path.** It computes `SHA-256(text)` itself and then hands the resulting
  `Data` to the same `DataProtocol` overload, which hashes again — so it signs
  `SHA-256(SHA-256(text))`. The originating app verifies the same way and is
  self-consistent, but Compass promises an external verifier, and an on-chain
  WebAuthn verifier would reject a double-hashed signature outright.
- Verification is the mirror:
  `publicKey.isValidSignature(sig, for: canonicalBytes)`.

**Verification input, stated once so it cannot drift:** a verifier recomputes
`canonicalBytes` per §6.1, and that same byte string is both what is hashed to
`digest` and what is passed to the signature check. A verifier never signs or
verifies over `digest` itself.

The encoding-stability test in §9 pins **both**: the hardcoded digest hex, and
that a signature produced over `canonicalBytes` verifies against
`canonicalBytes` and fails against `digest`. The second half is what catches a
future session reintroducing the double hash.

### 6.8 Version policy

**`"v"` is `1` and MUST NOT be bumped.** A version bump is a migration, and a
migration is the documented death mechanism for this codebase. Forward
compatibility is delivered by additive optional fields, `RawRepresentable`
identifiers, and the lossless `extra` bag — not by versioning.

If a change genuinely cannot be made additively, that is a signal the change is
wrong, not a signal to bump the version.

---

## 7. `Attestation` — mutable, separate file

Attestations live in `attestations.jsonl`, last-write-wins per achievement ID,
**because they mutate while the achievement does not**. Separating mutable from
immutable is what allows `awards.jsonl` to be strictly append-only.

```swift
struct Attestation: Codable, Sendable {
    let achievement: AchievementID
    let publicKey: Data
    let signature: Data         // P-256 over the achievement digest
    let backing: SignerBacking  // .secureEnclave | .software
    var state: AnchorState
    var otsProof: Data?
    var calendar: URL?
    var submittedAt: Date?
    var confirmedAt: Date?
    var blockHeight: Int?
    var chain: ChainRecord?     // reserved; nil until a token is ever minted
}

enum AnchorState: String { case provisional, sealed, submitted, confirmed, failed }
enum SignerBacking: String { case secureEnclave, software }
```

`backing` MUST be recorded honestly. A simulator-made proof must never look as
strong as a phone-made one.

`ChainRecord`, if it ever exists, holds `chainId`, `contract`, `tokenId` and
`txHash`. It is reserved here so that adding it later is not a format change.

### 7.0 Two things week 4 found, reported rather than amended

Both are recorded here rather than fixed, because this document is the one place
a field may be added and `PROJECT_CONSTITUTION.md` §6 puts the achievement format
outside what may change without an ADR and the human's agreement. Neither is
blocking; both are things a reader of `attestations.jsonl` would otherwise
misread.

- **`calendar` is singular and `docs/adr/0004` requires three submissions.** The
  implementation leaves it `nil` while `submitted` — there is no single calendar
  to name, and the three pending attestations live inside `otsProof`, which is
  the format's own way of holding them — and fills it in on `confirmed` with the
  calendar whose branch delivered the Bitcoin path. That is the only moment the
  field has one answer. The weekly log-head record, which this document does not
  specify, carries `calendars` plural.
- **`AchievementClaim` cannot produce an `Attestation`.** The `Attestor` port in
  `docs/technical.md` §2 takes a claim — an ID and a digest — and returns an
  `Attestation`, which requires `publicKey`, `signature` and `backing`. A
  calendar supplies none of those. The implementation reads the sealed record it
  is anchoring and returns it with the anchor added, which is what §7.1's
  ordering already implies: `sealed` happens immediately and offline, and
  `submitted` happens to a record that is already signed.

### 7.1 bis — the weekly log-head anchor is not an achievement

ADR 0004 requires the event-log head to be anchored weekly, and **that record is
deliberately not specified in this document.** It is not an achievement: it has
no rule, no `earnedOn`, no witness and no claim about a person. Filing it in
`attestations.jsonl` would have meant minting a fake `AchievementID` to key it
under, which is exactly the kind of invention this document exists to prevent.

It lives in `anchors.jsonl` and its shape and canonical form are fixed in
`docs/technical.md` §6.

### 7.1 Lifecycle

1. **`provisional`** — the achievement is computed, recorded, and shown to the
   user. The certificate appears immediately.
2. **`sealed`** — signed with the P-256 key. This happens **immediately**, in
   the same pass, offline. The signature costs nothing and makes the local
   record tamper-evident from the first moment.
3. **`submitted`** — the digest has been sent to an OpenTimestamps calendar.
   This MUST NOT happen until **72 hours after `detectedAt`**.
4. **`confirmed`** — an upgraded proof has landed in a Bitcoin block. A fresh
   OTS submission is an **incomplete proof**; it is worth something only after a
   calendar has upgraded it with the Bitcoin path, and that upgrade must be
   fetched from a calendar server later. Until then the achievement is sealed
   but not anchored, and MUST NOT be described as anchored. See ADR 0004.
5. **`failed`** — retried with exponential backoff via `BGProcessingTask`
   **and** drained opportunistically on next launch. Both, because
   `BGProcessingTask` carries no execution guarantee. MUST be invisible on the
   main screen.

The 72-hour gap between step 2 and step 3 is the provisional window. Signing
immediately and publishing late gives both properties that matter: the local
record cannot be silently altered, and nothing irreversible has been published
that the user might immediately want to take back.

### 7.2 The certificate MUST state its own state honestly

`AnchorState` has **no main-screen UI** — no spinner, no pending badge, no
failure state, per `.claude/skills/ui.md`. That rule stands. But invisibility on
the main screen was being read as invisibility everywhere, and the result is a
guarantee the app is instructed never to correct:

> If all three calendars are unreachable through the retry window, or the
> submission silently 4xxs, the user holds what they believe is a
> Bitcoin-anchored record and actually holds a local signature — and no surface
> is permitted to say so.

An overstated permanence guarantee that cannot be corrected is worse than no
guarantee. So:

- The certificate reads **"Sealed on this device"** until `AnchorState` is
  `confirmed`, and **"Sealed on this device · Anchored <date>"** after.
- **Anchoring language MUST NOT be rendered before `confirmed`.** Not on
  `submitted`, which only means bytes were sent.
- If any achievement has been `failed` for more than **30 days**, that fact is
  surfaced **once**, in the certificate's own detail area — not on the main
  screen, not as a badge, not repeatedly. This is the single escalation that
  makes permanent failure discoverable rather than structurally unsayable.

The main screen stays clean; the artifact stops overstating.

---

## 8. `Revocation`

```swift
struct Revocation: Codable, Sendable {
    let achievement: AchievementID
    let reason: String
    let at: Date
    let newLogHeads: [String: Data]
}
```

Appended to `awards.jsonl`. **Every** revocation is an appended record. There is
no deletion path in this file, in any state, for any reason.

An earlier form of this section said a revocation while `provisional` removes
the record quietly. That contradicted Invariant 4 below, and it contradicted the
append-only property of `awards.jsonl` that the mutable/immutable file split in
§7 exists to preserve. A documented deletion path inside a strictly append-only
file gets implemented as a rewrite of that file — which is the operation ADR
0002 disqualifies on flash-write grounds and the one most likely to lose the
file on a crash.

Rules:

- Revocation while `provisional` — a `Revocation` is appended and the projection
  filters the achievement out of the certificate list. Nothing was published, so
  nothing needs reversing on the outside, and the user does not need to be told
  anything. **The record still survives on disk.**
- Revocation after `submitted` — the identical appended `Revocation`, and the
  certificate list renders it as a revoked entry reading that the user edited a
  day it depended on. **You never erase a published entry; you post a
  reversal.** This is the accounting model and it is deliberate: the whole point
  of anchoring is that you do not get to quietly rewrite your own record.
- The difference between the two cases is what the outside world saw, and
  therefore what the UI says. It is never whether the record is deleted.
- An achievement is **never** silently recomputed away because a rule changed.
  The frozen `rule` copy is what guarantees this.

---

## 9. Invariants

1. The engine is a pure function. Same inputs, bit-identical outputs.
2. The engine is idempotent. Deterministic IDs filtered against the set already
   recorded.
3. The engine is re-runnable over all history at any time. Shipping a
   hundred-day rule to someone already at day 150 awards it immediately with
   `earnedOn` set to the historical day.
4. An achievement, once recorded, is never mutated and never deleted.
5. Unknown fields and unknown rule kinds are preserved, never dropped.
6. No floating point anywhere in this document's data.
7. Display text is never in a digest.
8. **Undigested fields are never rendered as part of a verified claim.**

Invariant 8 needs its reasoning stated, because it closes a real forgery path
rather than a stylistic one. §3.5 correctly says anything provable must live in
`facts` or `witness` — but stops one step short of the consequence. On a bundle
received **from someone else**, every field outside the digest is
attacker-controllable while the signature still verifies: `extra`,
`version`, `detectedAt`, and — decisively — `titleKey` and `fallbackTitle`,
which §5.2 makes the source of the displayed title. A forged bundle could
therefore render an arbitrary achievement title under a valid signature and a
genuine Bitcoin anchor.

So:

- A verifier, and the certificate view when showing a record it did not itself
  produce, MUST draw display text only from **digest-covered** fields —
  `rule.id`, `rule.kind`, `rule.threshold`, `rule.scope`, `earnedOn`, `facts`
  and `witness`. A title is rendered *from the rule*, not from `titleKey`.
- Where undigested text is shown at all, it MUST be visibly marked as
  unverified.
- `titleKey` and `fallbackTitle` stay **out** of the digest. Putting them in
  would buy forgery resistance at the cost of §5.2's actual benefit — a typo
  correctable forever without breaking a single anchor — and the rule fields
  above already carry everything needed to render an honest title.

---

## 10. Fields considered and deleted

Each with the consumer that was missing. They are listed so they are not
reinvented.

| Field | Why deleted |
|---|---|
| `issuer` | Redundant with `attestation.publicKey`. One app, self-issued. If someone else ever awards something, that is a new record type, not a field on every historical row. |
| `owner` | One human, forever. A field that can hold exactly one value is a comment. |
| `transferability` | Constant `false`. Enforced by there being no transfer function, not by a boolean on a dozen rows a year. |
| `visibility` | No feed, no audience, no sharing surface. If sharing ever ships, it is a decision made at share time, not persisted per achievement. |
| `title` | Stored display text becomes a permanent typo or a data migration. Derived from `titleKey` + `fallbackTitle` + `facts` instead. |
| `rarity` | Authored rarity is manufactured by definition — someone typed the word. Computed rarity is a measurement and must never be persisted, because a persisted measurement goes stale. |
| `witness.qualifyingDays` | 1000 `Day` values for a 1000-day streak, all recomputable from a log head that already commits to them. |
| `earnedAt: Date` (single field) | Would force a lie about either when it became true or when it was detected. Split into `earnedOn` and `detectedAt`. |
| `facts["habit"]` (display name) | Frozen into a signed, anchored, shareable record with no redaction path, forever. Replaced by `facts["habitID"]` plus a mutable local `habits.json` resolved at render time. §3.4. |
| `Scope.tag` | Reserved a named non-goal. Tags and categories are banned in `docs/product.md`; a reserved field is how a banned feature stays alive. §5. |
| `RuleSpec.cadence` / schedule fields | Same class as `Scope.tag`. Schedules are a named non-goal, and a cadence implies settings UI plus a third `DayStatus` for days that are neither done nor missed. `docs/technical.md` §3. |
