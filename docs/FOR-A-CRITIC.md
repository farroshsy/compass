# Evaluating Compass

The main [README](../README.md) is written for whoever works on this next. This
document is for someone deciding whether the work is any good.

**Compass is an engineering artifact, not a consumer product.** It is a
single-user iOS habit tracker whose real subject is what it takes to produce a
personal record that a stranger can check without trusting the app or its
author. Judge it as you would a small systems project, not as a startup.

Its engineering claims are reproducible. Its product assumptions are largely
untested: there has been no sustained real-world use, and the Limitations
section below should be read before the rest.

---

## The engineering questions it answers

These are the questions the repository exists to answer. Each has a concrete,
inspectable answer in the code.

**Can a canonical serialisation be reimplemented from its specification alone,
in another language, with no shared code?**
Yes. `docs/technical.md` §3 freezes eleven values in a fixed order.
`verifier/compass-verify.py` was written from that section and reproduces every
`content_hash` and every chain link produced by the Swift implementation. Zero
lines are shared between them.

**Can two OS processes append to one log without corrupting its order?**
Yes, by refusing to pretend they are one writer. The app and the Home Screen
widget each carry their own device UUID, `lamport` counter and `prev` chain,
through a single append API. Total order is `(lamport, device)`, never
wall-clock. The two-writer test drives two real processes and found a defect on
the day it was written.

**Can cryptographic claims be prevented from overstating what was verified?**
The certificate reads *"Sealed on this device"* and gains an anchoring line only
when a proof confirms. The verifier prints its own limit on every run: checking
a Bitcoin header requires a chain it does not ship, so it reports the block
height and merkle root and states that it did not take the last step.

**Can an append-only event log stay simple enough for a single-user app?**
Open question, leaning yes. The whole store is JSON Lines, one `write(2)` per
event, no database, no third-party dependency. A five-year replay measures
193 ms. The cost shows up elsewhere: a projection bug silently rewrote history
across the whole log rather than one row.

**Can third-party anchoring be integrated while staying invisible?**
Yes so far. OpenTimestamps submission runs on `BGProcessingTask` with
exponential backoff — never a timer, never on the launch path — and the user
never sees a wallet, a chain name, a fee, or the word "mint".

**Can a documentation corpus stay true to code that changes daily?**
No, not without deliberate effort, and this is the most useful negative result
here. Four separate correction passes in one day were documents fixing
documents. Twice, a correction introduced a fresh overstatement in the opposite
direction. The rule that eventually worked: verify against the machine, never
against another document.

---

## What is checkable

| | |
|---|---|
| Lines shared between the app and its verifier | **0** |
| Independent implementations of the canonical form | **2** (Swift, Python) |
| Defects found by mutation testing that a green suite had missed | **4** |
| Third-party dependencies | **0** |
| Tests | **482** |

**The verifier is the load-bearing artefact.** A verifier that imported the
app's encoder would only prove the app agrees with itself. This one was written
from the specification in another language and disagreed with the app once —
over Merkle leaf ordering — which is the whole reason to build it that way.

**Mutation testing, not coverage.** Every fix in this repository was proved by
reintroducing the defect and confirming a test fails. That discipline caught
four high-severity bugs a 218-test green suite had missed. All four were the
same species: the app asserting on screen something that had not happened. None
crashed. None failed a test.

**Estimates are recorded when wrong.** The verifier was estimated at ~200 lines
and came out at 579, because re-deriving the claim from the log and implementing
P-256 by hand were not in the estimate.

**Failure paths are drawn, not implied.** The diagrams in [OVERVIEW.md](OVERVIEW.md)
show every FAIL exit from the verification flow. A diagram with only a happy
path is how a tool gets trusted for things it does not do.

---

## Limitations

**No sustained real-world use.** All work has been validated through tests and
simulator execution rather than daily use on a physical device. Every design
decision is untested against the only user the app has.

**Verification demand is unvalidated.** No evidence is offered that anyone wants
a cryptographically checkable habit record. The demand is assumed.

**Motivation is unaddressed.** Habit trackers fail because people stop opening
them, not because people falsify them. Compass has no answer beyond being fast
and refusing to nag, and that may not be enough.

**Documentation exceeds empirical evidence.** Every decision can be explained.
None has been tested against a person.

**The widget press is unverified.** No available simulator runtime could place a
widget on a Home Screen. The 0.7-second interaction — the most valuable one in
the product — has never been performed.

**The name overpromises.** A compass guides. This records. *Ledger* would be
accurate.

**The format is frozen early.** The canonical encoding was fixed and the
one-time re-projection hatch spent before the app had been used for a single
day. That was a deliberate choice by the owner, recorded with its cost in
`memory/decisions.md`.

---

## Non-goals and trade-offs

**The blockchain layer exists as a learning objective, not a product
requirement.** `docs/adr/0001` states the alternative plainly: for a single
user, OpenTimestamps alone is the correct answer and no chain is needed. The
limb is scheduled anyway, and labelled as a learning objective everywhere it
appears.

**Single user is a constraint, not modesty.** Accounts, permissions,
onboarding, migration windows, abuse and billing are all absent because there is
one user. Any solution reintroducing that difficulty has made the project worse.
The cost is that no external validation loop exists.

**Non-goals are binding and win over every other document.** Notifications,
gamification, streak headlines, social features and visible blockchain concepts
are refused with stated reasons in `docs/product.md`. Several are classified
permanent; a few are Phase 1 exclusions with triggers.

---

What Compass demonstrates is that a system of this integrity can be built and
kept honest by one person. It does not demonstrate that the problem was worth
solving.
