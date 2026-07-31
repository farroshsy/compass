# Current focus

**As of 2026-07-31.**

> ## The corpus is frozen
>
> **No document in this repository is to be edited until `swift test` passes on
> `Day` and `project()`.**
>
> There are ~2,600 lines of Markdown here against zero lines of Swift and zero
> commits. Documentation has become the work product, which is a comfortable
> way to feel productive without taking the risk that the project is actually
> about. `README.md` sets the standard itself — a document earns its place if it
> stops a future session re-litigating a settled question — and that standard is
> now met. Adding more cannot make it more met.
>
> The one exception: `docs/open-questions.md` and `memory/` may be appended to
> when a *decision changes*, because that is the mechanism that stops
> re-litigation. Writing more explanation of an existing decision is not that.

## Where the project actually is

Documentation only. **No application code exists.** No `Package.swift`, no
`project.yml`, no targets, no Xcode project. The repository contains this
documentation set and nothing else, and it has no commits yet.

Five design investigations were completed before any code was written:
achievement model, local-first storage, chain and contracts, identity and
wallet, and iOS structure and UX. Their conclusions are compressed into
`docs/` and `docs/adr/`. The investigations themselves are not in this
repository; what survived them is.

## What the next session should do

**Write `Day` and `project()` and run `swift test`.** That is the entire
instruction. It needs no developer account, no provisioning profile, no device
and no product decision — the domain suite is pure and is where roughly eighty
per cent of the tests live.

Then week 1a in `memory/next-tasks.md`: a tappable checkbox on the phone,
installed and used. Then, and only after the app has been opened three days
running, week 1b: the canonical encoding and the hash chain.
`docs/technical.md` §11 has the ordering and the reasoning for the split.

**Nothing blocks the first line of code.** The previous version of this file
gated everything on a $99 purchase with an individual-verification wait, and on
naming two habits. Both were wrong:

1. **The paid Apple Developer account** blocks the app living on the phone
   permanently, not writing code. A free profile expires after seven days, which
   is fatal to a habit but not to a seven-day skeleton. Start the enrolment in
   parallel; it blocks nothing until week 1a is installed to stay.
2. **Which habits** was never a specification problem. There is no notification
   any more, and `habitRenamed` is cosmetic and never affects the fold — so this
   is by construction the cheapest thing in the project to change. **Settled on
   2026-07-31:** four, seeded in the bundle with their names already set — Move,
   Read, Build, Reflect, one per domain. `AppComposition.seededHabits`. The
   placeholders `habit-a` and `habit-b` are gone, and the settings sheet can
   rename, add and remove, so none of it is load-bearing.

## The standing constraint on everything

The failure mode is abandonment followed by a restart, not a bug. Evidence: 185
git repositories on this machine, ~78% near-copies, one lineage of 76 attempts
at the same idea between 2025-01-25 and 2025-03-24, of which 58 died on the day
they were created.

Every decision gets evaluated against: does this make the project more likely to
still be alive in six months? Prefer boring, incremental and additive over
correct-but-requires-a-rewrite.

## Do not

- **Do not write another document.** See the freeze at the top. The next
  artifact this project needs is a passing test, not a better explanation.
- Do not start the chain limb. It is now **refused, not deferred**, until a
  dated entry in `memory/decisions.md` overturns the invisibility non-goal —
  ADR 0003 §2.5 explains why the limb cannot satisfy it as designed.
- Do not add a fifth habit slot, a second tab, or a settings option.
- Do not add a surface. The v1 budget off the launch path is three, counted in
  `docs/product.md`. A fourth means editing that list first.
- Do not re-argue anything in `memory/decisions.md`. Overturn it in writing,
  with a date and a reason, or leave it alone.
