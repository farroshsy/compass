# The standalone verifier

```
python3 verifier/compass-verify.py <bundle-directory>
```

Exit code 0 if every check that could run passed, 1 otherwise. Python 3, standard
library only — no `pip install`, no Xcode, no Swift.

---

## Why this exists

`docs/product.md` opens with a promise:

> A habit tracker that produces a record of what you actually did, which you can
> hand to a stranger and they can check without trusting you or the app.

That sentence is false unless there is something to run. A stranger handed an
export bundle and a specification would have to reimplement a hand-written byte
encoder from a document before they could check anything, and almost nobody
does that — so without this file the mission sentence describes something the
project does not ship. `docs/technical.md` §10a scheduled it for week 4;
`docs/adr/0004` and `docs/achievement-protocol.md` §6 and §9 are the procedure it
implements.

**It shares no code with the application, on purpose.** A checker that links the
app's own encoder has established only that the app agrees with itself. This one
rebuilds the event canonical form from `docs/technical.md` §3, the achievement
canonical form from `docs/achievement-protocol.md` §6, the Merkle evidence root
from §4.1, and does P-256 signature verification by hand. When it and
`Sources/CompassDomain/CanonicalBytes.swift` produce the same bytes, that
agreement is evidence.

`Tests/CompassInfrastructureTests/VerifierTests.swift` runs it against a bundle
the Swift suite produces, so the two implementations cannot drift apart in
silence.

## What it checks

| | |
|---|---|
| `manifest.json` | every file's SHA-256 |
| `events.jsonl` | canonical bytes, `content_hash`, and each writer's `prev` chain from genesis to its head |
| `awards.jsonl` | the achievement canonical form and its digest; **that the log still supports the claim** — the qualifying days are re-derived and the Merkle evidence root recomputed from the events that were counted, with the leaves in `(lamport, device)` order per §4.1; and that each `witness.logHeads` entry is a point that exists on that writer's chain |
| `attestations.jsonl` | the P-256 signature over the canonical bytes, verified against the public key in the bundle; and **what backed the key**, Secure Enclave or software, printed per record and again for the bundle as a whole |
| `anchors.jsonl`, `proofs/*.ots` | that the anchored digest is the digest of those heads, and that the heads are this log's; then every OpenTimestamps operation replayed from the digest, reporting each attestation it reaches as a pending calendar promise or a Bitcoin block commitment |

Re-deriving the claim is the part that separates *this record is signed* from
*this record is true*. A verifier that checked only signatures would pass a
bundle whose log says one thing and whose certificate says another.

**The evidence leaves are sorted, and the order is `(lamport, device)`, never
day.** `docs/achievement-protocol.md` §4.1 freezes it and says nothing about
days. This file iterated `days` until 2026-08-01, which is the same answer on
any log appended one day after another and a *different root* on a log where one
day holds several events written out of sequence — the ordinary shape once two
writers exist, since the widget and the app interleave. It agreed with the app on
every bundle the suite had, because every one of them was tidy. A verifier that
agrees only when the data is tidy is worse than none, because it is believed.
`VerifierTests.evidenceLeavesAreInTotalOrderNotDayOrder` is the fixture that can
tell the two apart.

## What it does not check, and says so on every run

- **Bitcoin headers.** A Bitcoin attestation commits a merkle root at a stated
  height. Confirming that root really is that block's needs a Bitcoin node or a
  header chain, and shipping either inside a script whose whole purpose is to
  reduce what you have to trust would be self-defeating. It prints the height and
  the root so the last step can be taken by hand, and it states that it did not
  take it.
- **Who the record is about.** The declared name in Compass is self-declared and
  unverified by construction — `memory/decisions.md`, 2026-07-31 — and nothing
  in the app ever claimed otherwise.
- **Which hardware held the signing key.** `backing` is the issuer's own claim
  about its own key and no signature can prove it, so this file reports what the
  record says and never treats it as verified. A record that omits it is reported
  as not saying rather than assumed to be enclave-backed — the strongest reading
  is the one an attacker would pick. A software-backed bundle is *not* a failed
  bundle: the signature is perfectly valid, and what it cannot support is the
  claim that one particular device made it. `docs/technical.md` §8.
- **RIPEMD-160 and Keccak-256 operations** inside a proof, if one ever appears.
  Calendars aggregate with SHA-256 and no Compass proof has contained one. A
  branch behind an operation it cannot compute is reported as unchecked, never
  assumed good.

## An honest note about its size

`docs/technical.md` §10a estimated ~200 lines. It is 579 lines of code, 868 with
its comments. The difference is not padding: re-deriving the claim from the log
and implementing P-256 arithmetic by hand were both absent from the estimate. The
estimate is left standing in that document rather than edited to match, because
the plan is evidence about what was expected.
