# Read this if you are evaluating Compass

The main [README](../README.md) is written for whoever works on this next. This
one is for someone deciding whether it is any good.

Short version: **Compass is an engineering artifact, not a consumer product,
and it was built that way on purpose.** If you evaluate it as a startup you
will find it wanting, and you will be right.

---

## What a critic said, and what is true

A detailed critique landed on 2026-08-01. Most of it is correct. Rather than
answer it in a thread, it is recorded here.

### Conceded, without qualification

**"You built infrastructure in search of a product."** Yes. Event sourcing,
canonical bytes, an independent verifier, Merkle commitments and OpenTimestamps
are invisible to someone tapping four boxes. Ninety percent of the work does not
touch the experience.

**"You never prove verification is valuable."** Also yes. Nobody has ever asked
to check anyone's Duolingo streak. The demand for verified personal habit data
is asserted here, not evidenced, and `docs/open-questions.md` had already
recorded that the share artefact names nobody — the gap was known before it was
pointed out, which is not the same as solved.

**"You solved trust before motivation."** Correct, and it is the sharpest point
made. Habit trackers fail because people stop opening them, not because people
falsify them. Compass has no answer to *how do you get someone to open this
tomorrow* beyond making it fast and refusing to nag. That may not be enough.

**"Documentation has become a substitute for validation."** Fair. Every decision
here can be explained; none has been tested against a person. Four separate
passes on 2026-08-01 were documents correcting documents.

**"Ledger describes it better than Compass."** A compass guides. This records.
The name is aspirational in a way nothing in the product supports.

**"'We deliberately' appears everywhere."** It does. A document that defends
each choice reads as anxious rather than confident, and length is itself a
defect — which is why this file is short.

### Where the critique misfires

**Product-market fit is scored 2/10 against a project that names it a non-goal.**
`docs/product.md` states, in writing that predates the critique: *"It is not
optimised for revenue, users, adoption, or product-market fit. There is no
market."* Scoring an explicit non-goal is a category error. The valid version of
the point is narrower and does land: even a single-user tool needs its single
user to open it, and that has not happened yet.

**"Your own docs admit blockchain isn't needed — that's almost a confession."**
It is a disclosure, not a confession. ADR 0001 was written before any critique
existed and states plainly: *"If the goal were 'Farros keeps his achievements',
the correct answer is OpenTimestamps and no chain at all."* Volunteering the
strongest argument against your own decision is the opposite of a confession
being extracted. The chain is justified as a learning objective and labelled as
one everywhere it appears.

### Conceded, and it changes the roadmap

**"The certificate is your strongest feature, not the blockchain."** Probably
right, and it is the most useful sentence in the critique. The certificate has
emotional weight; a Merkle root does not. That is worth acting on.

---

## The one number that matters

**Days of real use: zero.**

482 tests. Four weeks shipped. A working app on a simulator. Nobody has opened
it on a phone, once.

`docs/technical.md` §11 gated the cryptography on *"the app has been opened
three days running"*, precisely so the format could not be frozen before the
loop was lived with. That gate was waived by the owner on 2026-08-01 and the
cost is recorded, dated, in `memory/decisions.md`.

So the critique's harshest reading is the correct one: this is rigorous
engineering answering a question nobody has yet been shown to ask.

---

## What is actually checkable here

If you are evaluating the engineering rather than the product, these are the
parts that hold up to inspection:

**An independent verifier.** `verifier/compass-verify.py` — Python 3, standard
library only, sharing no code with the app. It reproduces every `content_hash`
and every chain link from the specification alone. A verifier that imported the
app's encoder would only prove the app agrees with itself.

**It states its own limit on every run.** Checking a Bitcoin *header* needs a
chain the script does not ship, so it reports the height and merkle root and
says it did not take the last step.

**Mutation testing, not coverage theatre.** Every fix in this repository was
proved by reintroducing the bug and confirming a test fails. That discipline
found four high-severity defects on 2026-07-31 that a green 218-test suite had
missed — every one of them the app asserting something that had not happened.

**Estimates are recorded when wrong.** The verifier was estimated at ~200 lines
and came out at 579. That is in `product.md`, not quietly rounded away.

**Failure branches are drawn.** See [OVERVIEW.md](OVERVIEW.md) — the verifier
diagram shows every FAIL exit, because a diagram with only a happy path is how
a tool gets trusted for things it does not do.

---

## The honest summary

The critique's scoreboard was: engineering 10, documentation 10, honesty 10,
evidence of anyone wanting this 2.

That is roughly right, and the project's own documents said so first. What
Compass demonstrates is that a system of this integrity can be built and kept
honest by one person. What it does not demonstrate is that the problem was worth
solving.

Those are different claims, and only the first one is being made.
