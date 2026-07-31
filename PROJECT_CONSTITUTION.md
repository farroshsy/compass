# Project constitution

The controlling document. Where this disagrees with any other file in the
repository, this wins, and the other file is wrong and should be fixed.

**Established:** 2026-07-31

---

## 1. What this project is

Compass is a **flagship engineering project**: a habit tracker its author uses
every day, built as the reference implementation of an Achievement Protocol,
deliberately over-engineered in its infrastructure in order to learn modern
architecture end to end.

It is **not** a startup. It is not seeking users, revenue, funding, growth or
product-market fit. Objections of the form *"you do not need this to ship"* are
out of scope and must not be raised again.

## 2. Goals, in priority order

1. **Be alive in six months.** Everything else is subordinate. A brilliant
   architecture in an abandoned repository has taught nobody anything.
2. **Demonstrate mastery** of Swift 6, local-first architecture, event sourcing,
   cryptography, smart contracts, account abstraction, protocol design and
   verification.
3. **Be a daily driver.** The author opens it, taps, closes — every day.
4. **Be a portfolio artifact** an engineer would respect.

## 3. The blockchain is mandatory

Settled on 2026-07-31 and not to be reopened.

The blockchain subsystem — contracts, wallet, verification, issuer path — is a
**first-class deliverable**, equal in standing to the iOS client. It is not
optional, not a stretch goal, and not something that must justify itself in
product terms.

Its justification is recorded honestly and is sufficient: **it is a deliberate
learning objective.** The documentation must say exactly that, and must never
dress it up as a product necessity. ADR 0001's honest accounting — that for a
single user, OpenTimestamps alone would be the correct product answer — stays in
the repository. Both things are true at once.

What remains open is **sequencing**, never whether.

## 4. The sequencing constraint

> The application must be usable at the end of every milestone.

Blockchain work is scheduled, not deferred. But no milestone may leave the app
unusable in order to land infrastructure. Concretely: a working tap-and-close
loop exists in week one, before any contract, protocol or wallet work begins.

This is not blockchain-last. It is blockchain in an order that never breaks the
thing that keeps the project alive.

## 5. Rules that cannot be broken

- **No rewrites.** No restarts. No new repositories. This project is continued,
  never replaced.
- **No big-bang migrations.** Every change is additive. If a subsystem must
  change, the new one lands beside the old and the old is retired gradually.
- **Existing data survives every change.** Always.
- **Finish one subsystem before starting another.** Implementation, tests,
  documentation, review, then move on.
- **Technology is replaced only when it is newer *and* stable *and* simpler *and*
  documented *and* solves a problem that has actually arisen.** Never because it
  is trendy. Never because something newer exists.

### Why these rules exist

A scan of this machine on 2026-07-31 found 185 git repositories, 78% of them
near-copies of another, including one lineage of **76 attempts** at the same
project between 2025-01-25 and 2025-03-24, of which **58 died the day they were
born**. File counts across that run went 114, 95, 29, 20 — each restart was an
attempt to simplify by starting over rather than by deleting.

The documented failure mode of this author is not lack of ambition or ability.
It is restarting. Every rule in this section exists to make continuing cheaper
than starting again.

## 6. Authority

**The AI may decide:** implementation details, project structure, package
layout, Swift APIs, testing strategy, concurrency model, performance work,
dependency versions, refactoring, documentation updates.

**The AI may not change without an ADR and the human's agreement:** product
vision, the protocol, blockchain architecture, the achievement format, the
identity model, the trust model, security assumptions, the roadmap.

**If code and documentation disagree,** the documentation is correct until
implementation proves otherwise — and then the documentation is updated in the
same change, not later.

**Overturning a non-goal** requires an entry in `memory/decisions.md`, dated,
stating what was given up and who accepted the cost. Adopting a framing that
implies the reversal does not count.

## 7. Definition of done

A task is complete only when: the code compiles; tests pass; documentation is
updated; any affected ADR is updated; public APIs are documented; and no known
critical issue remains.

## 8. Standards

Deterministic. Testable. Documented. Modular. Strongly typed. Replayable where
applicable. No hidden global state. No abstraction with a single use site. No
premature optimisation.

The codebase should teach its reader *why* each decision exists.

## 9. Known unresolved conflict

**Wallet recovery versus the invisibility rule.** ADR 0003 §2.5 finds that the
recovery-key ceremony required by the embedded-wallet path is a seed phrase by
another name, which `docs/product.md` lists as a non-goal. ADR 0001 therefore
records the chain limb as *refused rather than deferred*.

Since §3 of this constitution makes the blockchain mandatory, this conflict must
be resolved before contract work begins. There are two honest resolutions:

1. Design a recovery path that genuinely stays invisible, and record how.
2. Accept a visible recovery step, overturn the non-goal in `memory/decisions.md`
   with a date, and state plainly in `product.md` that the invisibility rule has
   one exception and why.

Choosing neither, and building anyway, is not available.
