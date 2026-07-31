# ADR 0002 — Local-first storage and event sourcing

**Status:** Accepted. This is the one ADR that constrains code written in week
one, and the canonical encoding it fixes is the only genuinely irreversible
early decision in the project.

**Date:** 2026-07-31

---

## Context

The app must work fully offline, must be durable at the moment of a tap, and
must produce a record that can be sealed and checked by someone who was not
there. There is one user, one device, roughly two check-ins a day, and about a
dozen achievements a year — call it 750 records a year.

At that volume almost any storage choice works. So the decision is not made on
performance. It is made on two things: **what makes a rewrite non-destructive**,
and **what can be hashed**.

---

## Decision

### 1. Event sourcing, with an append-only log as the only truth

Justified on survival grounds first, not elegance:

- **It is the anti-restart mechanism.** Under CRUD, a Compass v2 starts at zero
  and the streak dies, which makes restarting cheap and continuing expensive.
  Under event sourcing the log is the asset and the app is a view over it: v2
  imports the log and the streak is intact. This does not prevent a rewrite. It
  makes a rewrite non-destructive, which removes most of what makes one appealing.
- **It is load-bearing for the sealed claim.** A "1000 days of meditation"
  certificate minted from a mutable `streak INTEGER` column attests to a number
  the user could have typed. Minted from a Merkle root over the actual
  check-in events, it attests to a history. This is product-critical, not
  infrastructure indulgence.
- **It makes eventual multi-device sync a set union** rather than a merge
  algorithm. See ADR-adjacent notes in `docs/technical.md` §7.

The known failure mode, stated so it can be watched for: in solo projects the
projection becomes the real code and the log becomes write-only ballast.
Mitigation is a small closed event set, versioned payloads that are never
reinterpreted, and making at least one user-visible feature (state as of any
past day) read the log directly so it stays load-bearing rather than ceremonial.

### 2. Storage format: append-only JSON Lines, in an App Group container

One event per line, appended to an open file descriptor.

```
Group/events.jsonl        the only truth
Group/awards.jsonl        immutable achievement and revocation records
Group/attestations.jsonl  mutable, last-write-wins per achievement ID
Group/snapshot.json       cache. Deletable. Never the source of anything.
```

**The App Group requirement, stated as what it actually is.** An earlier form of
this ADR said the App Group is required from the first commit and that
retrofitting it means reworking every path in the persistence layer. That is
overclaimed, and the overclaim was doing real damage: App Groups need an
entitlement, which needs a provisioning profile, which needs the paid developer
account — so this one sentence was what converted a purchase into a hard gate on
all storage code, in a project whose documented failure mode is that day one is
where projects die.

The container is a directory URL, and `.claude/skills/architecture.md` already
requires infrastructure to be constructed in exactly one file, the composition
root in `App/`. So the real requirement is:

> **Every path obtains its base URL from a single injected `storeURL`.** No file
> path is constructed anywhere else. Switching that URL from
> `.documentDirectory` to
> `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` is then one
> line plus a file move, and it MUST happen **before the widget ships in week
> 2** — because a widget cannot read a container it has no access to.

That keeps the genuine constraint, matches the architecture rule already
written, and removes a false dependency on a $99 purchase from the first line of
code.

**Hard invariant — three tiers, not two.** The earlier wording said
`events.jsonl` is the only file that is not rebuildable and everything else may
be deleted and recomputed at any time. That is wrong, and wrong in the direction
that licenses destroying the least protected data in the project.

| Tier | Files | Why |
|---|---|---|
| **Irreplaceable** | `events.jsonl`, `awards.jsonl` | Events are the only truth. Awards are recorded as facts with a frozen rule copy precisely so recomputation under changed rules cannot un-award something already anchored — so recomputing them is not the same operation as reading them. |
| **Irreplaceable in part** | `attestations.jsonl` | `otsProof`, `signature`, `publicKey` and `chain` are not recomputable. A deleted-and-resubmitted OTS proof yields a strictly *later* Bitcoin timestamp, destroying the "it is not backdated" property that ADR 0004 calls the entire argument for the pairing. The signature is unrecomputable once the enclave key is gone. `ChainRecord` is the only thing making ADR 0001's chain-death insurance work. Only `state` and the timestamps here are recomputable. |
| **Disposable** | `snapshot.json`, the projection, every derived table | Delete freely. |

The two consequences that motivated the original wording still hold — for the
disposable tier, which is where they were always true: a projection bug is never
data loss, and a change to how anything is computed costs zero migration by
construction.

### 3. Canonical encoding, frozen at first write

Hand-written bytes, not `JSONEncoder`, for the reason already documented in the
existing Shipped code: key order is not a promise Swift makes across releases,
and a verifier recomputing a digest in three years must get identical output.

The fields `device`, `lamport` and `prev` are present from the very first event,
even though there is one device and no sync. They cost nothing now and cannot be
added later without invalidating every hash computed before the change.

### 4. Determinism rules

- `project(_ events: [Event]) -> Projection` is pure and total: no clock, no
  `Calendar.current`, no `TimeZone.current`, no locale, no I/O.
- Total order is `(lamport, device)`. **Never wall-clock** — clocks move
  backwards and an NTP correction would reorder history.
- No floating point in the fold. Streaks and counts are integers.
- Every accumulator is keyed by `habitID`. There are no global accumulators.

The last rule is not stylistic. A globally order-dependent accumulator is the
exact bug that destroyed replay determinism in this user's prior event-sourced
work, and it is mechanically forbidden by the shard-invariance test rather than
left to code review.

### 5. Measured basis, and the trigger to revisit

Benchmarked on this machine, Swift 6.2.4:

| | 5 yr × 5 habits (10,493 events) | 10 yr × 10 habits (41,975 events) |
|---|---|---|
| full projection rebuild | 193 ms | 865 ms |
| hash-chain every event | 60 ms | 261 ms |
| whole-array rewrite per tap | 145 ms / 1.9 MB | 644 ms / 7.7 MB |

Two conclusions. First, the whole-array rewrite pattern used by `Log.persist()`
in the existing Shipped app is disqualified — 145 ms and a 1.9 MB flash write
per checkbox at year five violates the three-second rule and wears flash for no
reason. That is a measured kill, not a stylistic objection; the pattern is
correct for one entry a day and wrong for a tap-driven tracker. Appending one
line to an open descriptor does not appear in that table because it is O(1).

Second, a from-zero rebuild at the worst realistic case is under a second, which
retires snapshots and compaction from the roadmap. They are not needed for the
life of this project.

**Trigger to revisit:** a test asserting full replay on the reference device
fails a 250 ms budget, or a feature genuinely needs a query rather than a fold.
The response, in order: (a) a snapshot with compaction — still a cache, still no
migration; then (b) GRDB. Do not build either before the assertion fails.

Caveat on the numbers, per standing evidence rules: they were measured on a Mac,
not on device. The conclusion rests on a ratio — a per-tap cost that grows
linearly with history — which holds regardless of absolute speed, so it is
robust even if the absolute figures shift.

---

## Consequences

- No schema, therefore no schema migration, therefore no migration-shaped wall.
  This is the single largest thing being bought.
- The log is greppable and diffable. `Day` is encoded as `"2026-07-31"` rather
  than an integer ordinal specifically to preserve this; the ordinal is an
  internal arithmetic detail.
- Export ships in week one and is a **bundle, not a log dump**: `events.jsonl` +
  `awards.jsonl` + `attestations.jsonl` + the frozen rule JSON + `habits.json` +
  the P-256 public keys + every `.ots` proof + a `manifest.json` of per-file
  digests. Stated in these words here, in `docs/product.md`,
  `docs/technical.md` §8 and `memory/next-tasks.md` so the four copies cannot
  drift. Exporting `events.jsonl` alone would omit both the achievement records
  and the Bitcoin proofs — the two things the export is claimed to preserve. It
  is what turns a future rewrite into a re-projection rather than a reset, and a
  test asserts a fresh install fed only the bundle reproduces every achievement.
- No queries. Correct at 750 records a year, wrong at 100,000. The tripwire is a
  measured assertion in the test suite, not a note in a document.
- Crash-safety has to be tested properly: write a log, truncate at every byte
  offset, assert it opens with all complete lines intact and the partial tail
  dropped. This is what makes the synchronous-append design honest.
- Two sources of truth are forbidden. If a snapshot ever disagrees with a
  replay, the replay wins and the snapshot is rewritten.

---

## Alternatives, and why rejected

**CRUD with an upsert on `(habitID, day, done)`.** Genuinely sufficient for
product correctness, and it should be said plainly that for "did I meditate
today?" this is all that is required. Rejected on three grounds: it makes a
rewrite destructive, which is the documented top risk; it reduces a sealed
certificate to an attestation over a mutable integer; and it forces hand-written
conflict resolution for anything concurrent, which the fold gets for free.

**SwiftData.** An ORM over a private, undocumented SQLite schema. Event sourcing
requires hashing exact bytes, and you cannot commit to bytes a framework
reserves the right to change. Its CloudKit path also forbids unique constraints
and requires properties to be optional or defaulted, which collides directly
with the two constraints that make idempotent sync work. The decisive factor is
survivability: a plain SQLite file stays readable via the C API forever, whereas
a SwiftData store is readable only through the framework version that wrote it.
Honest counterweight: SwiftData is genuinely better for CRUD apps with evolving
object graphs, and it would hand over CloudKit sync for free. Compass is not
that app at the storage layer.

**Core Data.** Same objection with more ceremony.

**GRDB / SQLite now.** The strongest alternative, and it is deferred rather than
rejected. GRDB gives an explicit forward-only migrator, `ValueObservation` feeding
SwiftUI, WAL mode, and an in-memory queue that makes the fold testable with
`swift test`. It loses today only because it is a dependency solving a problem
the measurements say does not exist yet. The trigger above is the condition
under which it wins.

**SQLite.swift.** Weaker migration and observation stories than GRDB and less
maintenance activity, with no compensating advantage for this workload.

**Extending the existing Shipped `Log` actor.** Measured kill. See the table.

**Automerge.** A general-purpose JSON CRDT for concurrent editing of rich nested
documents. Compass has no such document — it has an append-only set of immutable
facts. Cost would be a Rust binary dependency, a document format not under our
control, growing in-document history metadata, and a transport still to be
built. Solves a problem this app does not have.

**Yjs.** JavaScript ecosystem, no native Swift story. Rejected on platform
grounds before any design consideration.

**ElectricSQL, PowerSync, Replicache, Zero.** All require a hosted service, a
Postgres, or both, to synchronise a few megabytes for one person. PowerSync in
particular is good and has a real Swift SDK, so this is not a quality judgement.
The objection is structural: a permanent operational dependency is itself a
project-death risk, because the day a container dies or a free tier lapses, the
app breaks, and a broken app is a restart trigger.

**Snapshots and log compaction now.** Measured out. Building them today would
add a second source of truth and a class of snapshot-versus-replay divergence
bugs to save under a second, once a decade.

**A single global hash chain across devices.** Two devices appending
concurrently fork the chain, and reconciling that requires consensus, which is
precisely the coordination this design exists to avoid. Per-device chains, with
the anchor covering the sorted set of heads, give the same guarantee with none
of the coordination.

---

## Amendment — 2026-07-31: `content_hash` must cover the payload

**Status:** Accepted. Applied to `docs/technical.md` §3 the same day.

**Evidence** (per `PROJECT_CONSTITUTION.md` §12): a security issue was
identified. This is the "security issue has been identified" limb, not the "it
feels cleaner" non-limb.

**The defect.** The canonical form frozen in `technical.md` §3 listed
`v, id, device, lamport, kind, day, recordedAt, zoneOffset, source, prev` and
nothing else. Every event kind carries a `habitID` or `achievementID`, and none
of them were digested. Consequently `habitID` could be edited on any line
without changing that event's `content_hash`, without breaking the `prev` chain,
and without invalidating the `evidenceRoot` in `docs/achievement-protocol.md`
§4. A hundred-day meditation streak could be restated as a hundred-day reading
streak with every proof intact, including the OpenTimestamps anchor.

`technical.md` L240 asserted "altering any earlier event changes every later
`content_hash`". True of the nine listed fields; false of the field carrying the
event's meaning.

**Decision.** A REQUIRED `payload` object joins the canonical form, positioned
between `source` and `prev`, with a frozen per-kind key order. Always present;
`{}` when a kind has no fields of its own. `day` and `source` stay at the top
level.

**Consequences.** None negative, because the fix landed before any code existed
and therefore before anything was signed — §11's escape hatch closes permanently
at the first signature, and it was still open. Had this been found after week 4,
the choice would have been between abandoning every existing proof and shipping
a chain that does not bind what it claims to bind.

**Alternatives rejected.**
- *Hash the whole on-disk line.* Rejected: the line carries `extra`, which an
  older build cannot hash, and key order on disk is not fixed.
- *Add `habitID` as a top-level digested field instead of a nested object.*
  Rejected: `achievementAwarded` and `achievementRevoked` carry different
  identifiers, so a single top-level field would be either wrongly named or
  absent for half the kinds, and absent-means-omitted would then make two
  different events digest identically.
- *Leave it and document the limitation.* Rejected: the guarantee is the product.

**How this was found.** Seven parallel agents read the corpus and cross-checked
it; the finding was then verified by reading the canonical form directly rather
than trusting the audit summary. Both steps mattered — the audit also produced
two claimed contradictions that did not survive that check.
