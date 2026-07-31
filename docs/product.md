# Compass — product

## Mission

A habit tracker that produces a record of what you actually did, which you can
hand to a stranger and they can check without trusting you or the app.

Two things follow from that sentence and nothing else does. First, the app must
be opened every day, or there is no record. Second, the record must be sealed in
a way that a person who was not there can verify, or it is just a database with
your own numbers in it.

**What "they can check" costs, stated because otherwise the sentence
overstates.** A stranger recomputes the canonical bytes, checks the SHA-256,
checks the P-256 signature, and checks the OpenTimestamps proof against Bitcoin
headers — the procedure is in `docs/adr/0004`. That is only actually achievable
if there is something to run. So a **~200-line standalone verifier ships in this
repository in week 4**, and `docs/achievement-protocol.md` §6 and §9 are
published verification procedure rather than private internals.

This does not reopen the non-goal below. The protocol acquires no second
*implementer* — nobody builds a product against it. It gains a second *reader*,
which is the entire point of sealing anything. **Anyone may check a Compass
record; nobody builds a Compass.** Without the verifier, the mission sentence
would be describing something the project does not ship.

## The single user

Farros Hilmi Syafei. One person. Surabaya, UTC+7. ITS Informatics, graduating
around September 2026. Solo engineer, iPhone, no team, no customers, no
investors, and none of those are arriving.

This is not modesty about ambition. It is a load-bearing constraint. Every
design question that would be hard for a thousand users — accounts, permissions,
onboarding, migration windows, support, abuse, moderation, billing — is not hard
here, and any solution that reintroduces that difficulty has made the project
worse. When a decision is genuinely ambiguous, the tiebreak is: what does one
person need.

## The daily loop

Open the app. Tap two checkboxes. Close the app. Under three seconds, cold.

That is the entire product. Everything else in this repository exists to support
that loop or to seal what it produces. There is no second screen you are meant
to visit, no feed, no streak-defence notification, no weekly review. If a change
adds a step to that loop, the change is wrong regardless of what it enables.

"No second screen you are meant to visit" is a claim about the launch path, and
it is kept true by the surface budget in the MVP scope below — three surfaces,
all of them reachable only by a deliberate detour, none of them ever presented
to the user unprompted. It is not a claim that the app has literally one view;
that version was false against the rest of these documents, and a false rule is
one a future session correctly ignores.

The measurable form of that promise: no `await` between the finger and the
pixel, no network call on the launch path, and a launch-to-first-frame budget
that a test asserts on the real device. See `docs/technical.md`.

Roughly once a month, a milestone falls out of the log — a hundred consecutive
days, a thousand days in total. The app shows a certificate. The certificate is
signed locally on the spot and never asks the user to wait for anything.

It is then **submitted** for Bitcoin anchoring three days later, and it says
"Sealed on this device" until a proof actually comes back confirmed, at which
point it reads "Sealed on this device · Anchored 2026-03-17". It does not claim
to be anchored before it is. Anchoring can fail — the OpenTimestamps calendars
are somebody else's servers — and a certificate that asserted permanence the
project could not deliver, in an app whose rules forbid ever correcting it,
would be worse than one that claims less.

## Two objective functions, in this order

This project is optimised for:

1. **Being opened every day.** An app that is not used produces no record and
   the whole thing is theatre.
2. **Educational value from modern infrastructure.** Event sourcing,
   deterministic replay, cryptographic sealing, public anchoring, and eventually
   account abstraction and a soulbound token contract.
3. **Being a portfolio artifact.** A thing that can be shown and explained.

It is **not** optimised for revenue, users, adoption, or product-market fit.
There is no market. This has a specific consequence that governs how objections
are weighed:

> "You do not strictly need this for an MVP" is **not** a valid objection to
> infrastructure. It **is** a valid objection to product features.

Over-engineer the infrastructure. Keep the product dead simple. When those two
pull against each other, the loop wins, because objective 1 outranks objective 2.

## MVP scope

**One screen on the launch path, and a file.** The launch path is the whole
product. Everything else is deliberately off it — but the count is stated
honestly here, because "the MVP is one screen" was being contradicted by
surfaces that existed only in the technical documents and were never scoped,
designed, or counted. A screen that is never counted is a screen nobody budgeted.

**The launch path — one screen, and nothing may be added to it:**

- Two to four habits, **seeded in the bundle with their names already set**, so
  first launch opens directly on Today with the rows there. No naming flow, no
  keyboard, no permission prompt, nothing between install and the first tap.
  Renaming lives in the settings sheet, where it already belongs.
- One tap toggles a habit for today. A second tap untoggles it. No confirmation.
- The day boundary is 04:00 local, so a check-in at 01:30 counts for the day you
  were awake for.
- A 28-day dot strip showing gaps honestly, with no colour and no alarm. It is a
  **display, never a control** — nothing may be tapped on it.
- The largest number on the screen is **total days**, not the current streak.

**Off the launch path — three surfaces, and that is the budget:**

1. **A settings sheet** behind a deliberately hard-to-reach glyph. Rename,
   archive, export.
2. **A certificate**, shown once when a milestone fires. Signed with a Secure
   Enclave P-256 key, shown immediately, never waiting on a network. Carries the
   single `ShareLink`.
3. **A certificate list** inside the settings sheet, so a certificate can be
   re-opened and shared after it is dismissed. Plain reverse-chronological rows.
   **No "new" indicator** — a "new" badge is a re-engagement affordance and
   badges are banned four sections below. Revoked entries render as revoked; see
   `docs/achievement-protocol.md` §8.

**Underneath, not a surface:**

- An append-only event log on disk, durable at the moment of the tap.
- Milestone rules evaluated as a pure function of that log.
- OpenTimestamps anchoring in the background, with no main-screen UI at all.
  Anchor state appears only on the certificate itself, which states honestly
  whether it is sealed or anchored.
- **Export as a bundle** — see below. Not the log alone.

**Cut from v1, so they are not smuggled back in as "already designed":** a
first-launch naming flow, a separate certificate detail screen, a "new"
indicator, a daily notification, and retroactive backfill of a past day.

That is the whole of v1. It is a complete, honest, finished app, and it contains
no chain, no wallet, no account, and no server of ours.

## Non-goals

This is the most important section in this file. Everything below is a thing
Compass will not do, with the reason, because a non-goal without a reason gets
quietly overturned six weeks later by someone who has forgotten the argument.

> **This section is the authority.** Where any other document in this repository
> — `docs/technical.md`, `docs/achievement-protocol.md`, `docs/adr/`, or
> `.claude/skills/` — contains a field, an event kind, a rule, or a UI element
> that instantiates something listed here, **the non-goal wins and the other
> document is wrong.** Delete the field, do not design around it.

That rule exists because the document set's stated function is to stop a future
session re-litigating a settled question, and with zero code written the set was
already supplying both sides of six arguments: the daily notification, schedules,
notes, tags, "one screen", and hosted services. A session that reads a rule and
its contradiction re-argues it — which is the exact mechanism these documents
exist to prevent. Each deletion made under this rule is recorded as a line in
`memory/decisions.md`, so the deletion itself becomes the settled decision.

A non-goal is overturned the same way any decision is: **in writing, in
`memory/decisions.md`, with a date and a reason.** Never by a field quietly
appearing in a spec.

**An achievement protocol for other companies, or for anyone else at all.**
Not a standard, not an SDK, not a spec others implement, not a platform. The
achievement format in `docs/achievement-protocol.md` is a constitution for *this
codebase* so future sessions stop inventing fields. The moment it is designed for
a second consumer it acquires extensibility requirements, versioning politics and
backwards-compatibility debt that a one-user app has no reason to pay.

**Multiple users, accounts, sign-in, or a social layer.** No sharing feed, no
friends, no leaderboards, no comparison, no "3 of your friends meditated today".
Every one of those converts a private record into a performance, and a
performance is a thing you fake.

**A server, a backend, or any service that must be kept alive.** An operational
dependency that can lapse, expire, get repriced or get shut down is a way for
this app to stop working on a Tuesday for reasons unrelated to the app. Sync, if
it ever happens, uses CloudKit — the user's own iCloud, no operator. Scheduled
backup writes to the user's own iCloud Drive, on the same basis.

> **The one operational dependency this project does take, named rather than
> hidden:** the OpenTimestamps calendars. They are third-party servers. A fresh
> submission is an *incomplete* proof — it is worth something only after a
> calendar upgrades it with the Bitcoin path, and that upgrade must be fetched
> from that same server, later. If the calendars are gone, repriced or firewalled
> during the window, every pending proof is permanently worthless. The anchoring
> layer is described in `docs/adr/0001` as load-bearing rather than a fallback,
> so this is a real exception to the rule above and it is stated as one.
>
> Mitigations, all in `docs/adr/0004`: submit to all three calendars rather than
> first-success-wins, persist every pending proof, upgrade aggressively over a
> long horizon, and put the upgraded proof in the export bundle. Even fully
> failed, the local signature survives and the app keeps working — which is what
> keeps this an exception rather than a contradiction.

**Gamification.** No points, levels, XP, coins, badges, rarity tiers, loot,
random rewards, progress bars toward the next tier, confetti, or particles. The
milestone is a certificate, not a payout. Every item on that list converts a
document into a token, and a token is something you want to farm.

**Making the streak the headline number.** Streaks exist and drive milestones,
but a number that resets to zero on one missed day teaches the user to start
over, and starting over is the specific behaviour this project is defending
against. See the restart risk below.

**Timed habits, sub-tasks, quantities, notes, moods, tags, categories,
schedules, or habit templates.** Each is individually reasonable and each adds a
decision to a loop whose entire purpose is having no decisions in it. A habit is
a name and a boolean per day.

Under the authority rule above, this deleted three things that had been reserved
for them in the specs: the `cadence` payload and the `habitCadenceChanged` event
kind, the `dayNoteAttached` event kind, and `Scope.tag`. Reserving a field for a
banned feature is how the feature stays alive — a future session reads
`tag: String?`, concludes tags were planned, and builds them.

**Editing a past day.** A forgotten day stays forgotten. The app must not punish
a missed tap — that is what the greyless, alarmless 28-dot spine is for — and
not letting you rewrite it is the honest version of that, not a limitation.
It is also, in interface terms, the only thing in the app that would need a
date, a scroll and a decision, which is more complexity than every other screen
combined, and it would land on the one display element on the launch screen and
turn it into a control. Deferred with a real trigger in `docs/technical.md` §10
rather than refused outright, because the honesty machinery for it
(`source_live` / `source_backfill`) is inside the digest and already exists.

**A daily reminder notification.** Cancelled-when-complete or not, a reminder at
a fixed hour is a streak-defence notification by function whatever it is called,
and it costs a permission prompt on first launch plus a product decision nobody
needs to make. The week-2 home-screen widget is the reminder: it is already the
highest-value item in the plan, it sits where the thumb already is, and it costs
no prompt and no contradiction.

**More than four habits.** The one-handed bottom-anchored layout stops holding
past four rows, at which point the three-second promise quietly becomes false.
This is a hard cap, not a default.

**Live Activities and the Dynamic Island.** They exist for state that changes
over minutes to hours. A daily habit is a boolean with no in-flight state, so
this would hold the Dynamic Island all day to render a constant.

**An Android version, a web version, a watchOS app in v1, or a CLI.** The watch
is the only one of these with a real argument (a wrist tap is the true
one-second interaction) and it is deferred rather than refused — see
`docs/technical.md`.

**Anything the user must understand about blockchains.** No wallet, no gas, no
chain name, no address, no seed phrase, no network selector, no transaction
status, and never the word "mint". If a chain feature cannot be made invisible,
it does not ship. This is not a UX preference; it is the definition of done for
that entire layer.

**Selling this, open-sourcing it as a product, or writing a launch post.**
Publishing the repository is fine. Acquiring users is not, because users create
obligations, and obligations create the pressure to rewrite.

## The restart risk

This project's main failure mode is not a bug, a wrong architecture, or a
technical wall. It is abandonment followed by a fresh start under a new name.

The evidence is specific and it is about this machine. A scan found 185 git
repositories, of which around 78% are near-copies of one another. One lineage
contains 76 attempts at the same project between 2025-01-25 and 2025-03-24. Of
those 76, 58 died on the day they were created.

The pattern is not lack of skill or lack of effort. It is that starting over
felt cheaper than continuing — because continuing meant re-deriving decisions
that were never written down, and because hitting any wall made the existing
code feel like the problem.

**These documents exist to make continuation cheaper than restarting.** That is
their function, and it is the standard by which they should be judged. A
document here earns its place if it stops a future session from re-litigating a
settled question or from concluding that a rewrite is the only way forward.

The concrete mechanics, each of which appears again in the technical documents:

- **One repository, named `compass`, never forked.** If the impulse is to create
  `compass-v2`, the correct action is to delete a file inside `compass`.
- **The event log is the asset; the app is a view over it.** A rewrite that
  imports the log keeps the streak. This does not prevent a rewrite — it makes a
  rewrite non-destructive, which removes most of what makes one appealing.
- **No step in the plan is a big-bang migration.** Every stage is additive.
  Nothing that ships in week one has to be undone in week four.
- **Unknown fields and unknown event kinds are preserved, never dropped.** An
  older build reading a newer file does not destroy data it does not understand,
  so there is never a version at which you are trapped.
- **A decision recorded in `memory/decisions.md` is not re-argued.** It is
  overturned in writing, with a date and a reason, or it stands.
- **Export exists from the first week, and it is a *bundle*, not a log dump.**
  `events.jsonl` + `awards.jsonl` + `attestations.jsonl` + the rule JSON frozen
  into each award + `habits.json` + the P-256 public keys + every `.ots` proof +
  a `manifest.json` of per-file digests. The exact list is in
  `docs/technical.md` §8 and it is stated identically there, in
  `docs/adr/0002` and in `memory/next-tasks.md` so the copies cannot drift.

  This was previously defined as "newline-delimited canonical JSON of the whole
  log" — that is `events.jsonl` alone, which contains neither the achievement
  records nor the Bitcoin proofs it was simultaneously claimed to preserve.
  Someone who followed these documents exactly, exported weekly, and then
  dropped their phone in a river would have lost every signature and every
  proof. A test asserts a fresh install fed only the bundle reproduces every
  achievement and verifies every proof, because an unexercised escape hatch is
  not an escape hatch.

- **There is a backup path, and it is deliberate rather than inherited.** Until
  CloudKit sync exists there is one copy of everything, on one phone. So: iCloud
  device backup is deliberately left enabled for the container, a scheduled
  background task writes the export bundle to the user's iCloud Drive, and a
  first-launch check surfaces once if the last successful export has aged out.
  `docs/technical.md` §8. The honest consequence of enabling device backup is
  that the log is stored with Apple, which is why the framing above is "no
  server of ours and nothing to sign in to" rather than "nothing ever leaves the
  phone".

The largest practical threat to the daily loop is not any of the above: it is a
free-tier development certificate expiring after seven days and the app
silently refusing to launch. An app that uninstalls itself every week cannot
become a habit. This must be resolved before week one, not during it. See
`memory/next-tasks.md`.
