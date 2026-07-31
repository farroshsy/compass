# Compass

A habit tracker that produces a record of what you actually did, which you can
hand to a stranger and they can check without trusting you or the app.

---

## What this is

One screen. Two checkboxes. Under three seconds from opening the app to closing
it. Roughly once a month a milestone falls out of the log and the app shows a
certificate, signed on the device immediately and submitted for Bitcoin
anchoring three days later. The certificate says "Sealed on this device" until a
proof actually comes back confirmed, and only then adds the anchor date — it
does not claim to be anchored before it is.

A ~200-line standalone verifier ships in this repository, because "a stranger
can check it" is not true if the stranger has to reimplement a hand-written
encoder from a document.

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

The blockchain layer, if it is ever built, would be invisible: no wallet, no
gas, no address, no seed phrase, never the word "mint". `docs/adr/0003` now
records that this is **not achievable** as designed — a paper recovery key is a
seed phrase by another name, and passkeys need a hosted file the architecture
rules forbid — so that limb is refused rather than deferred until someone
accepts the cost in writing.

## Status

**Documentation only. There is no code yet.**

Five design investigations completed in July 2026. What survived them is in
`docs/`. The first target is a walking skeleton on a real phone, in daily use,
before anything cryptographic is written.

## Where things are

| Path | What it holds |
|---|---|
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

There is nothing to run yet.

Once there is, it will be: one Swift package plus a thin app target, generated
with `xcodegen`, opened in Xcode, and installed on the phone via TestFlight —
not a free development build, which expires after seven days and takes the daily
habit with it.

**TestFlight substitutes a ninety-day expiry for the seven-day one; it does not
remove the problem.** A build stops launching 90 days after upload, so a build
gets uploaded every quarter as a standing obligation. When one does expire,
**update in place — never delete and reinstall.** Deleting the app destroys the
App Group container and with it the entire log. `memory/known-bugs.md`.

`swift test` runs the domain suite, which is pure, has no simulator dependency,
and is where roughly eighty per cent of the tests live. **It needs no developer
account, no provisioning profile and no device** — which is why the first
session writes `Day` and `project()` and runs `swift test` on them, rather than
waiting on a purchase.
