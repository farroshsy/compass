# Open questions and rejected findings

Three adversarial reviews read this corpus against itself on 2026-07-31. Most of
what they found was correct and was applied — the deletions and corrections are
listed in `memory/decisions.md`.

This file holds what was **not** applied, in whole or in part, with the reasoning
and with **what evidence would change the answer.** It exists for the same reason
everything else here exists: a rejected finding with no recorded reasoning gets
re-raised by the next reviewer, and re-arguing settled questions is one of the
mechanisms by which this project gets restarted instead of continued.

A rejection here is not permanent. Each entry states its own falsifier.

---

## 1. "Move the canonical encoding and hash chaining to week 2"

**The finding.** Week 1 gated the first tappable checkbox behind the hand-written
canonical encoding, a hardcoded digest test and `prev` chaining, which for an
author with 58 repositories that died on their creation day is the highest-risk
possible ordering. Proposed fix: re-cut week 1 to a plain struct with
`JSONEncoder`, and move canonical encoding, `prev` and the stability test to a
week-2 block.

**Applied in part.** The diagnosis is right and it drove a real change: week 1 is
now split into 1a (tappable, on the phone, day one) and 1b (encoding, entry
condition "opened three days running"), and `docs/technical.md` §11 documents a
one-time `reproject` hatch which closes at the first signature. The overstated
irreversibility was corrected.

**Rejected: moving it out of week 1.** Two reasons.

The first is scope. `docs/product.md` states that "you do not strictly need this
for an MVP" is not a valid objection to infrastructure, and the encoding is the
infrastructure this project exists to build. Pushing it to week 2 optimises for
shipping a habit tracker, which is not what is being optimised for.

The second is the ratchet. Week 2 is the widget. The widget is the second writer,
and the second writer is what makes `device`, `lamport` and `prev` load-bearing
rather than decorative. Arriving at week 2 with an unchained log and a second
process appending to it is a worse position than arriving with a chained one,
because the reproject hatch would then have to run against a log two processes
are actively writing. The encoding is cheapest exactly where it now sits: after
the app is in use, before there is a second writer.

**What would change my mind.** Week 1a ships and 1b does not get done within two
weeks of it. That is direct evidence that the encoding block is too heavy to
follow a working app, and the correct response would be to move it behind the
widget and accept a reproject against two chains. Log the dates.

---

## 2. "Collapse ADR 0001 and ADR 0003 into ~40 lines"

**The finding.** The corpus is 2,572 lines of Markdown against zero lines of
Swift. ADRs 0001 and 0003 are 17% of it and are fully-argued decisions — twelve
chains evaluated, four wallet vendors compared — for a limb that ADR 0001 itself
says need never be built. Proposed fix: freeze the corpus, and collapse the two
ADRs into one ~40-line document holding only the conclusions plus the trigger,
dropping the comparative reasoning.

**Applied in part.** The freeze is right and is now at the top of
`memory/current-focus.md`: no document is edited until `swift test` passes on
`Day` and `project()`. The diagnosis that documentation became the work product
is correct and worth acting on.

**Rejected: the collapse.** The stated standard is that a document earns its
place if it stops a future session re-litigating a settled question. The
alternatives sections are the *only* part of these ADRs that does that. A
40-line document saying "Base 8453, non-upgradeable ERC-721, no proxy,
multi-owner smart account" stops nothing: the next session asks "why not
Arbitrum?", finds no answer, and spends an evening re-deriving that Arbitrum One
is a near coin flip and Base wins narrowly on the iOS ecosystem. That evening is
precisely the cost these documents were written to avoid, and the conclusions
alone cannot pay it.

The finding's own supporting argument also cuts the other way. It notes that the
comparative analysis will be stale by the time it is read, citing the document's
warning about Base client churn through 2026. If the analysis goes stale, the
*conclusion* built on it goes stale too — so keeping the conclusion and dropping
the reasoning preserves the part that expires and discards the part that lets
someone tell it has expired.

The review also somewhat overstated the corpus problem by counting these ADRs as
inert. ADR 0003's alternatives section is what produced this review round's
sharpest finding — that the identity limb cannot satisfy the invisibility rule —
because the argument against seed phrases was written down where it could be
checked against the design. That is the document doing its job.

**What would change my mind.** A future session actually re-litigates a chain
decision *despite* the ADRs, which would show they do not work as written; or
the freeze is broken specifically to edit ADR 0001 or 0003, which would show
they invite maintenance rather than settling anything. Either is a reason to cut.

---

## 3. "Never withdraw a certificate that has been shown"

**The finding.** The 72-hour provisional window and the five-state anchor
lifecycle push infrastructure concepts into the product: inside the window an
achievement is "quietly withdrawn" — a certificate the user was shown disappears
with no explanation — and after it, revocation is a visible greyed row requiring
the user to understand publication irreversibility. Proposed fix: never withdraw
a shown certificate; if a dependency is edited inside the window, keep the
certificate and simply do not submit it.

**Applied in part.** The deletion half is correct and was fixed: quiet withdrawal
contradicted Invariant 4 and the append-only property of `awards.jsonl`, and it
would have been implemented as a whole-file rewrite. Every revocation is now an
appended record in every state. `AnchorState` has no main-screen UI.

**Rejected: keeping a certificate whose underlying claim is now false.** An
achievement asserts that a named rule became true on a named day over a specific
evidence set. If the user revokes a check-in in that set, the assertion is false.
Keeping the certificate visible would mean the app knowingly displays a sealed
claim it knows to be wrong — in a project whose entire purpose is that a sealed
claim can be trusted. That is a worse failure than the confusion the finding is
trying to prevent.

The concept-count objection is also largely answered by other changes. There is
no achievement history list on the launch path, no certificate detail screen and
no "new" badge, so the surfaces on which revocation can confuse anyone have
already shrunk to one: the certificate list behind the settings glyph. And the
user does not need to understand publication irreversibility to read one line of
copy saying a day this depended on was edited.

**What would change my mind.** Anything demonstrating the revoked state is
actually confusing in use — the user encounters one and cannot tell what
happened. With one user, that is a single observation. Record it and revisit.

---

## 4. "Cut `source_backfill` and fix `source` to `.tap`/`.widget`"

**The finding.** Backfill is a shipped v1 capability with no design anywhere —
no screen, no gesture, no reach limit — and it is the only interaction in the app
needing a date, a scroll and a decision. Proposed fix: cut it from v1, fix
`source` to `.tap`/`.widget`, and **delete `source_backfill`**.

**Applied in part.** The product half is right and was applied in full. No
backfill surface ships in v1, `source` has three values, the 28-dot spine is
declared a display and never a control, `docs/product.md`'s non-goals say a
forgotten day stays forgotten, and it is deferred with a real trigger and written
scoping requirements in `docs/technical.md` §10.

**Rejected: deleting `source_backfill`.** `source_live` and `source_backfill`
live in `facts`, and `facts` is inside the canonical bytes. Unlike an event kind
— which is a `RawRepresentable` string precisely so it can be added later at no
cost — a digest field cannot be added additively. Deleting it now means that the
day backfill ships, either every prior achievement's digest shape differs from
every later one, or backfill ships without the honesty partition that
`memory/known-bugs.md` calls the thing standing between a certificate and an
overstatement.

The finding cites §10's rule that "a field that can hold exactly one value is a
comment". That rule is about fields with no possible second value — `owner` on a
one-user app, `transferability` on a non-transferable token. `source_backfill` is
`0` in v1 as a *measured fact about this history*, not as a structural constant,
and "no day was backfilled" is a different claim from "we did not record whether
any day was backfilled". Sealing the first is worth two bytes.

**What would change my mind.** A decision that backfill is refused outright
rather than deferred — recorded in `memory/decisions.md` with a date, deleting
the §10 trigger. At that point the field genuinely can hold only one value
forever and should go. Until then it is cheap insurance on an irreversible
surface.

---

## 5. "The milestone kind must be private" (the ADR 0001 / 0004 contradiction)

**The finding.** The two ADRs disagree about whether the milestone kind is
publicly readable on chain, and the privacy claim depends on which wins. Correct,
and it was fixed — but the finding left the direction open, and the direction is
a real decision worth recording.

**Chosen: the kind is public.** ADR 0004 now stores `milestoneKind` as a readable
field and its consequences state what leaks — the milestone class, its exact
date, and by arithmetic the habit's start date.

**Rejected: making the kind private and re-specifying the renderer to work from
public fields only.** If the kind is private there is nothing left for an
on-chain `data:` URI renderer to render except a date and an opaque hash. ADR
0001's honest accounting says rendering in wallets and explorers is one of only
two portfolio benefits the token buys, and the sole functional gain is a public
record that exists without holding a file. Strip the renderer and the chain limb
retains essentially nothing that OpenTimestamps does not already provide for
free — at which point the correct decision is not a private kind but no token.

**What would change my mind.** A decision that the start-date leak is
unacceptable. That is a coherent position, and its correct consequence is
recorded above: build no token limb rather than build one that renders nothing.
It is not a reason to keep a renderer that cannot render.

---

## 6. Still genuinely open, and not decided here

These were raised, are real, and are deliberately left open with the decision
point named rather than settled now.

- **Which of ADR 0004's three responses to the `sealDigest` correlation leak.**
  Drop `sealDigest` on-chain in favour of a blinded commitment, mint each
  achievement to a distinct address, or accept and warn at share time. All three
  are defensible; all three are cheap; none can be chosen sensibly before the
  chain limb is real. **Decision point:** before the first mint, recorded in
  `memory/decisions.md`. Doing none of them is refused.
- **Whether the identity limb is ever built at all.** ADR 0003 §2.5 now states
  that it cannot satisfy the invisibility rule and that building it requires
  overturning a `docs/product.md` non-goal in writing. Whether anyone wants to
  pay that is not a question this review can answer. **Decision point:** a dated
  entry in `memory/decisions.md`, or the limb stays refused indefinitely, which
  ADR 0001 already calls a successful outcome.
- **The value of N** in "surface a permanently failed anchor once after N days".
  Written as 30 in `docs/achievement-protocol.md` §7.2. That is a proposal, not
  a measured figure, and per the standing evidence rules it is labelled as one.
  **Decision point:** after the first real anchor failure, if there is one.

---

## The share artifact names nobody

**Raised:** 2026-07-31, by a design review of the certificate.
**Status: RESOLVED, 2026-07-31 — option (b).** The decision and its reasoning are
in `memory/decisions.md`, "the four habits, the sealed name, and one recorded
deviation". It is not re-argued here; it is overturned in writing, with a date
and a reason, or it stands.

The question is left in this file rather than deleted, because the alternative it
rejected is the part that stops it being re-raised.

`docs/product.md` justifies the certificate's `ShareLink` on the grounds that a
stranger — an employer, a coach — can verify a claim without trusting the app.
But the same document makes accounts and sign-in permanent non-goals, so there
is no subject in the record. The exported card states that *a device* recorded
100 consecutive days. It does not state whose device.

An unattributed record demonstrates nothing about a person. The design surfaced
this; it is a product gap, not a layout one.

### Candidate resolutions

**(a) Accept it. The record is meaningful only when handed over in context.**
You send the certificate yourself, in a conversation where you are already
identified. The artifact proves *the record was not fabricated afterwards*,
which is the honest and complete claim; it never claimed to prove identity.
Costs nothing, changes no code, and is the smallest answer.

**(b) An optional self-declared name, typed once, inside the digest.**
A string the user enters — not an account, no server, no verification of the
name itself. It is digested and sealed with everything else, so it cannot be
changed afterwards without breaking the seal. This does not prove the name is
true; it proves the name was committed to at the same instant as the record,
which is a weaker but real claim, and strictly stronger than nothing.
Costs: one field, one event kind, one line on the certificate, and a decision
about what an empty name renders as.

### What is NOT available

Anything that verifies the identity itself. That requires an issuer, which
requires a second party, which `product.md` bans as a permanent non-goal.

### Deciding

Owner: the human, per `PROJECT_CONSTITUTION.md` §6. Neither option overturns a
non-goal — (b) adds a field, it does not add an account — so this needs a
decision recorded in `memory/decisions.md`, not a non-goal overturn.

### Decided — (b), 2026-07-31

The owner chose (b). It ships as one optional text field in the settings sheet,
empty by default, recorded as the event kind `subjectNamed` with payload
`{"name":<string>}` — added additively per `docs/technical.md` §3, reusing a
payload key that was already frozen, so nothing about the closed-payload rule or
any existing kind's key order moves. It reaches the digest through the log, via
`docs/achievement-protocol.md` §4's `witness.logHeads`, rather than through
`facts`, because a digest field cannot be added additively and an event kind can.

The reasoning, including why (a) was rejected while remaining true, is in
`memory/decisions.md`. The claim the app is permitted to make is fixed there and
is repeated in the sheet's own copy: **it proves the name was committed to at the
time, not that the name is true.**

What (b) costs, from the list above, is now paid: one field, one event kind, and
a decision about what an empty name renders as — an empty name is no declaration
at all, and it is also how a declaration is withdrawn. The remaining item, the
line on the certificate, lands with `CertificateView` in week 3.

---

## The Today screen was built from the design, and three things were not

**Raised:** 2026-07-31, implementing the design document's turn-6 Today screen.
**Status:** open. Blocks nothing. Two of the three are unreachable in the app as
built.

The screen now matches the specification — 44pt number, the caption sentence,
the 9pt/2pt spine, deep-field checked rows with a rounded-square mark, and the
six Dynamic Type rules. Three points where the document could not be followed
literally are recorded here rather than absorbed silently.

### 1. The settings glyph is not on the screen — CLOSED, 2026-07-31

**The falsifier below fired.** The settings sheet exists, so the glyph shipped
with it, at the measured position, unchanged: SF Symbols `gearshape`, 17pt, 30%
ink, a 44 x 44 target centred at (371, 128), overhanging the margin by 11pt. The
geometry moved out of `TodayView`'s documentation and into `TodayMetrics`, where
`TodayMetricsTests` asserts every number of it — so "unchanged" is now checkable
rather than remembered. The original entry is kept below because it is the reason
the position was not re-invented.


The design adds one — SF Symbols `gearshape`, 17pt, 30% ink, a 44 x 44 target
centred at (371, 128) in the 402 x 874 frame, overhanging the margin by 11pt so
the glyph's trailing edge lands on the margin line and the target still reaches
44. It records this as a decision taken on the user's behalf: an addition to a
screen whose rule is that nothing may be added, "justified only because the
sheet is already budgeted and otherwise unreachable".

**Not built, because the sheet is not built.** The settings sheet is week 3.
`.claude/skills/ui.md` budgets three surfaces off the launch path and all three
are week 3 or later, so a glyph shipped now is a control that opens nothing.
The geometry above is recorded in `TodayView`'s documentation so that week 3
places it where it was measured rather than where it looks right.

**Falsifier:** the settings sheet exists. Then the glyph ships with it, at that
position, unchanged.

### 2. Six of the eight habit-row field colours are derived, not designed

The document gives the deep field for two habits in light appearance
(`teal #1B6B7A`, `orange #8A4E00`) and for one in dark (`teal`, "the same hue at
34% over black, i.e. rgb(22,68,76)"). The palette has four entries because four
habits is the hard cap, so six values were missing.

The dark rule was **recovered, not invented**: rgb(22,68,76) is iOS's
dark-appearance system teal `#40C8E0` multiplied by 0.34, exactly, to the byte.
The other three dark fields follow from that rule.

The light rule could not be recovered — in HSB the teal drops to 61% of the
system colour's brightness and the orange to 54%, so no single factor produces
both. What the two share is luminance, 0.1215 and 0.1085. So indigo and pink
keep their system hue and saturation and take the brightness that lands on the
mean of those, which reproduces the property the design actually argued from —
the contrast measurement — rather than a factor it never states.

This is low-stakes today: there is no surface for creating a third or fourth
habit, so those two rows cannot appear. It is recorded because the first time
they can appear, someone should look at them.

**Falsifier:** the designer supplies the four missing values. They replace these
with no other change — see `HabitTint`.

### 3. The design's AX5 metric table is one row off for two text styles

It gives `title3 20 -> 49` and `title2 22 -> 53`. Apple's published iOS table
gives 53 and 56; 49 is Apple's *subheadline* AX5 value. Every other row in the
design's table matches Apple exactly — body 53, footnote 44, caption2 42,
largeTitle 60, and subheadline-at-accessibility2 30 — so the two title rows are
a transcription slip, and the rest of the table cross-validates the corrected
one now in `TodayMetrics`.

**The load-bearing finding survives the correction**, which is the only reason
it was safe to make. The design's claim is that four habit rows still fit at AX5
and therefore the four-habit hard cap in `docs/product.md` survives the worst
case; it says this is "worth knowing, because it was the least certain of the
product's hard numbers". Recomputed with title3 at 53 and the caption counted at
the two lines it actually takes, four rows fit with **137 points to spare**
rather than the document's 165. `TodayMetricsTests` pins that number, so the
next change to any constant on the screen has to re-derive it.
