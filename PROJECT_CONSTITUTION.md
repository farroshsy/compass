# Project constitution

The controlling document. Where this disagrees with any other file in the
repository, this wins, and the other file is wrong and should be fixed.

**Established:** 2026-07-31

---

## 1. What this project is

Compass is a **personal daily-use application and the reference implementation
of the Achievement Protocol.** Its purpose is to demonstrate modern software
engineering through a complete vertical slice: product, protocol, cryptography,
blockchain, verification, and client applications.

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

**The blockchain subsystem, the protocol, and the iOS application are all
mandatory deliverables. Their implementation order is determined by engineering
dependencies, not by their relative importance.** None is optional, a stretch
goal, or required to justify itself in product terms.

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
- **Prefer mature, well-supported technology over novelty.** New technologies may
  be adopted only if they materially improve correctness, security,
  maintainability, interoperability or developer experience. **Newness alone is
  never sufficient justification.** This clause is deliberately written to permit
  adopting something released in 2027 that is genuinely better, and to forbid
  adopting something released next week that merely exists.

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

## 9. Engineering mode

**The research phase is complete.** Do not continue exploring alternative
architectures unless implementation reveals a concrete deficiency. Assume the
architecture recorded in the ADRs is correct. The task is to execute it
faithfully.

When a genuine problem is found:

1. Explain it.
2. Propose the alternatives.
3. Recommend one.
4. **If it changes architecture, stop and wait for approval.**

Do not silently redesign the system. The failure mode this prevents is real and
has already happened in this project's history: an assistant that "discovers" a
better architecture every few sessions and gradually replaces the one that took
weeks to design. Ideas are cheap here and always available; a system that
survives contact with six months of implementation is not.

## 10. Architecture review

**After completing every milestone, perform an architecture review before
beginning the next one.** Evaluate:

- unnecessary complexity
- duplicated abstractions
- dead code
- performance
- protocol consistency
- security
- test coverage and test value
- documentation drift
- dependency updates
- ADR consistency with the code as built

**Resolve what is found before starting the next milestone.** Debt deferred to
"later" in a project like this is debt deferred to phase ten, where it arrives
all at once and looks like a reason to start over.

## 11. Governance is frozen

The governance layer — this constitution, the ADR structure, the product vision,
the technical vision, the authority split, the definition of done — is **frozen
as of 2026-07-31.**

No further edits unless implementation uncovers a real problem. Refining
governance documents is not progress, and it is a particularly seductive way to
feel productive without building anything.

From here, every working session answers exactly one question:

> **What is the next smallest complete subsystem that moves Compass toward the
> reference implementation?**

## 12. Known unresolved conflict

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
