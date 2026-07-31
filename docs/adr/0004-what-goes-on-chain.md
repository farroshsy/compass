# ADR 0004 — What goes on chain, and what does not

**Status:** Accepted. The exclusions are binding in v1; the inclusions are
conditional on ADR 0001 ever being built.

**Date:** 2026-07-31

---

## Context

A public chain is a permanent, world-readable, un-deletable append-only medium
with a per-write cost and a real chance of the operating chain not existing in
five years. Those four properties determine what may sensibly be written to it.

Meanwhile the app produces roughly 750 records a year, of which almost all are
"did a thing on a day". The question is where the line goes.

---

## Decision

### Never on chain

**Check-ins.** Roughly 730 a year, individually meaningless, and putting them on
a public ledger would publish a behavioural diary. They live locally, in
`events.jsonl`, and are committed to only through hashes.

**Habit names.** What the token records is
`keccak256(habitID ‖ milestoneKind ‖ salt)`. The human-readable meaning stays in
the local store, and the user can reveal it by handing over the preimage. This
is the actual privacy control in this design, and it is far stronger than
burning. A per-token random salt is used rather than one app-wide salt, because
the habit vocabulary is small and guessable, so revealing one preimage against a
shared salt would let an observer brute-force the rest.

**Notes, text, timestamps of individual taps, timezone, or device identifiers.**
None of these has an on-chain consumer, and each is a fact about a person's day.

**Anything mutable.** If a value could ever want correcting, it does not go into
an immutable record. This is why display titles are excluded from the digest as
well as from the chain.

### On chain, if and when the token limb is built

Per achievement, write-once at mint:

| Field | Why | Public? |
|---|---|---|
| `commitment` | `keccak256(habitID ‖ milestoneKind ‖ salt)` — proves *which* achievement without publishing which habit it was about | opaque |
| `milestoneKind` | The renderer needs it. See below. | **readable** |
| `attainedAt` | The civil day the milestone was reached | readable |
| `sealDigest` | The SHA-256 that OpenTimestamps anchored | readable |
| owner | The smart account address — see ADR 0003 | readable |

Roughly a dozen writes a year.

**`milestoneKind` is stored as a separate readable field, and this resolves a
contradiction that ran through two ADRs.** The alternatives section below and
ADR 0001 both require the on-chain renderer to work "from the commitment and the
milestone kind" — which an on-chain `data:` URI renderer can only do if the kind
is a readable field, since it cannot open a hash. Meanwhile the consequences
section claimed a verifier learns only that "some achievement of some kind" was
attained. Both could not be true. If the kind were private the renderer cannot
render, and display in wallets and explorers is ADR 0001's only concrete payoff.

So the kind is public, and the disclosure statement below is corrected to say
what that actually leaks rather than understating it.

**`salt`, specified here because it was required everywhere and defined
nowhere.** It is the only thing standing between a small, guessable habit
vocabulary and a trivially brute-forced commitment, and also the only thing that
lets the user ever open a commitment and prove what a token means.

- **32 bytes from `SecRandomCopyBytes`.** Fresh per token, never per app.
- Stored alongside the `ChainRecord` in `attestations.jsonl`.
- **In the export bundle**, and covered by the export manifest digest.
- **Losing the salt is terminal**: the on-chain token becomes a permanently
  unopenable hash — an achievement that exists forever and can never again be
  shown to mean anything. Recorded in `memory/known-bugs.md`.

### Anchored to Bitcoin via OpenTimestamps, always, chain or no chain

- Every achievement digest, after the 72-hour provisional window.
- **The event-log head, weekly, from week 4** — not "once that is triggered".
  See the corollary below; the trigger fires on the first run of the achievement
  engine, so this is scheduled work, not deferred work.

The marginal cost of a digest is zero — the calendars Merkle-aggregate
submissions — with no transaction, no gas and no wallet. The user never sees any
of it.

### The calendars are an operational dependency, and this document previously did not say so

"Costs nothing" was true about money and false about risk. The OpenTimestamps
calendars are third-party servers, and `docs/product.md` refuses "any service
that must be kept alive" on the grounds that an operational dependency that can
lapse, expire, get repriced or get shut down is a way for the app to stop
working. ADR 0001 calls this layer load-bearing rather than a fallback. So this
is the project's one real operational dependency and it is named as one.

The specific mechanism, which is easy to miss: **a fresh submission is not a
proof.** It is a promise that a calendar will include the digest in an
aggregation. It becomes worth something only after that calendar upgrades it
with the Bitcoin path, and the upgrade must be fetched from that same server,
later. If the calendars are gone, repriced or firewalled during the window,
every un-upgraded proof is permanently worthless.

Required mitigations, all cheap:

- **Submit to all three calendars, not first-success-wins.** Three independent
  chances to upgrade, for the same zero marginal cost.
- **Persist every pending proof** in `attestations.jsonl`, which is in the
  irreplaceable-in-part tier per ADR 0002.
- **Upgrade aggressively and keep re-attempting over a long horizon** — months,
  not the length of one backoff schedule.
- **Store the upgraded proof in the export bundle**, as `.ots` files.
- Recorded in `memory/known-bugs.md`: a pending, un-upgraded OTS proof proves
  nothing, and the certificate must not say "anchored" until `confirmed`.

What keeps this an exception rather than a contradiction: total calendar failure
costs the *timestamp* claim and nothing else. The local signature still proves
the record came from this device unaltered, and the app keeps working.

---

## The point that makes the two layers worth having together

`attainedAt` is just a number the issuer typed in. The chain can prove a token
was minted at block N; it cannot prove the milestone was reached months earlier.

The OpenTimestamps seal is what makes that number credible: it proves the record
existed before a particular Bitcoin block, so it cannot have been fabricated
afterwards. Put `sealDigest` in the token and the two layers reinforce each
other — Base says "this is owned by this address", Bitcoin says "and it is not
backdated".

That is the entire argument for the pairing, and it is why the OpenTimestamps
layer is not the loser in ADR 0001. It is the foundation, and the token is a
display surface built on top of it.

**A corollary that must not be lost:** a rule shipped in June that backfills a
March achievement produces a June anchor, which alone proves nothing about
March. Only if the log head was already anchored weekly does the March data have
a March anchor, and only then does the achievement's `witness.logHeads` point at
something meaningful. Until weekly log-head anchoring exists, the UI MUST NOT
imply that a backfilled achievement is proven to have occurred when it says it
did.

**This corollary fires immediately, which is why weekly anchoring is week-4 work
and not a deferred item.** The engine backfills over existing history with
`earnedOn` set to the historical day, and the rule set starts at 7 consecutive
days. An app in daily use since week 1 therefore has historical 7-day and 30-day
awards backfilled the moment the engine first runs, in week 3. There is no
distant future in which this trigger fires; it fires on the first execution.

The unavoidable consequence, stated rather than papered over: **no achievement
covering days before the first weekly log-head anchor can ever be proven about
the past.** Anchoring cannot start before the anchoring code exists. So for that
first cohort of backfilled awards, and only that cohort, the certificate says
what is true — that the record was sealed on the device and anchored on the date
it was anchored — and claims nothing about when the days themselves were
recorded. Every award after the first log-head anchor is provable about its own
period. Shipping week 3 without this produces certificates that overstate, which
is the one failure this apparatus exists to prevent.

---

## Consequences

- The chain layer can be removed entirely without losing any user data or any
  verifiable claim. That is the property that makes it safe to defer indefinitely.
- Verification for someone handed the exported bundle: recompute the canonical
  bytes, check the SHA-256, check the P-256 signature, check the OpenTimestamps
  proof against Bitcoin headers. No chain access required, and no trust in the
  app or its author at any step. A ~200-line standalone verifier ships in the
  repository in week 4 so this procedure is runnable rather than merely
  described.
  - **What a verifier cannot conclude:** display text outside the digest —
    `titleKey`, `fallbackTitle`, `extra`, `detectedAt` — is attacker-controllable
    on a received bundle while the signature still verifies. Titles are rendered
    from digest-covered rule fields. See `docs/achievement-protocol.md` §9.8.
  - **Across a device replacement**, a bundle may span two unrelated public keys.
    With a forward-looking rotation authorisation signed by the older key,
    continuity is *proven*. With only a `keyRotated` event and its anchor, the
    *ordering* of the keys is proven and continuity is asserted, not proven. A
    verifier must report those two cases differently. See `docs/technical.md` §8.
- A verifier handed only a token ID learns the **milestone kind**, the date, and
  the owning address — not which habit it was about, until a preimage is
  revealed. That is the intended level of disclosure, and it is weaker than the
  earlier claim of "some achievement of some kind", which was inconsistent with
  the renderer requirement.
  - **What the kind being public leaks:** the milestone class and its exact date,
    from which the habit's start date is arithmetic. A 1000-day streak attained
    on 2026-03-14 says the habit began on 2023-06-18.
- **`sealDigest` is a public linking key, and the disclosure does not run only
  one way.** The earlier consequence considered only "token ID → what can be
  learned". The reverse direction is the one that matters, because the reverse
  direction is the one the product actually performs:

  > The exported bundle contains the achievement. From it, anyone computes
  > `sealDigest`, finds the token, and therefore the smart account address —
  > and from that address, **every other token it holds and every `attainedAt`
  > on them.**

  So handing one certificate to one recruiter discloses the full timeline of
  every milestone the user has ever earned. The per-token salt does nothing
  about this: the linking key is the digest, not the commitment.

  Three responses, in preference order. **(a)** Drop `sealDigest` from the
  on-chain record and store a per-token *blinded* commitment to it instead — the
  OTS proof in the bundle already carries the timestamp claim, so the on-chain
  copy buys linkage rather than proof. **(b)** Mint each achievement to a
  distinct address. **(c)** Accept it explicitly and warn at `ShareLink` time
  that sharing links the sharer to every other milestone. Whichever is chosen is
  recorded in `memory/decisions.md` before the first mint. Doing none of them
  and leaving the privacy model stated as stronger than the delivered one is the
  option that is refused.
- The local sealed record must include `chainId`, contract address, token ID and
  transaction hash once a token exists, and that record is itself anchored. This
  is what makes redeploying on another chain possible if Base disappears.
- Burning removes current state; it does not remove the mint transaction, which
  remains in explorers and indexers permanently. Burn-for-privacy is a promise
  the chain cannot keep. The commitment-hash design is what delivers privacy
  here; the burn is a courtesy.
- **The honest limit on durability, stated because it is usually misstated:**
  rollup data is posted to blobs, which are pruned after roughly 18 days. After
  that, reconstructing the L2's state depends on that chain's own nodes and
  third-party archivers, not on Ethereum. So a token is *not* "secured by
  Ethereum forever" in the reconstruct-from-L1 sense. This is the precise form of
  "the chain dies and takes the achievements with it", it applies to every
  rollup, and it is the strongest argument for keeping OpenTimestamps as the
  durability floor.

---

## Alternatives, and why rejected

**Every check-in on chain.** Roughly 730 writes a year, a public behavioural
diary, and no consumer for any individual record. Even if free, it would be
wrong.

**A daily or weekly Merkle root of check-ins on chain.** Better than every
check-in, and it is genuinely what the OpenTimestamps layer already does — for
free, without a wallet, anchored to a more durable chain, using code that is
already written and tested. Paying an L2 to do a strictly worse version of this
has no argument behind it.

**Habit names in `tokenURI` metadata so the token renders nicely.** This is the
tempting one, because it is what would make the token look good in a wallet, and
that display surface is most of what the token buys. Rejected: it publishes what
the person is trying to do with their life, permanently, to satisfy an aesthetic
preference. The renderer works from the commitment and the readable
`milestoneKind` field, and the result is deliberately austere. Note what that
costs, stated in the consequences above rather than hidden here: the milestone
kind and its date are public, and the habit's start date follows by arithmetic.

**Storing the streak count as a plain integer on chain, with no seal.** An
attestation over a number the issuer typed. It proves the issuer said something,
which is what a signature already does, more cheaply.

**One evolving token whose metadata updates as milestones accrue.** Fewer writes
and a smaller contract, and it was a real candidate. Rejected because a mutable
token is a token whose meaning can be rewritten, which removes the only property
worth paying for; and because it breaks the collection-of-certificates mental
model that makes the feature feel worth having at all.

**Off-chain metadata on IPFS or HTTPS.** Link rot is the most common way an NFT
dies. The renderer emits an on-chain `data:` URI or the token has no metadata.

**No anchoring at all — just a local signature.** A local signature proves the
record came from this device and has not been edited. It does not prove *when*,
which means a log written honestly over two years and one written the week before
an interview remain indistinguishable. Anchoring is the only layer that fixes
that, it is free, and the code already exists.
