# Architecture rules

Read `docs/technical.md` before changing structure. Read `docs/adr/` before
overturning a decision.

- One repository, named `compass`. Never fork it. If you want `compass-v2`,
  delete a file inside `compass` instead.
- **Three tiers of rebuildability, not two.** Irreplaceable: `events.jsonl` and
  `awards.jsonl`. Irreplaceable *in part*: `attestations.jsonl` — its
  `otsProof`, `signature`, `publicKey` and `chain` cannot be recomputed (a
  resubmitted OTS proof gets a strictly later Bitcoin timestamp; a signature is
  gone with the key), while only its `state` and timestamps can. Disposable:
  `snapshot.json`, the projection, any derived file. ADR 0002.
- Every path gets its base URL from a **single injected `storeURL`**. Construct a
  file path nowhere else. That is what makes moving to the App Group container a
  one-line change, and it must move before the widget ships in week 2.
- `docs/product.md`'s **non-goals are the authority.** If anything in `docs/` or
  in these skills reserves a field, an event kind or a UI element for something
  listed there, delete it rather than designing around it. Overturn a non-goal in
  `memory/decisions.md` with a date and a reason, or leave it alone.
- `CompassDomain` imports Foundation and nothing else. It must never learn that
  Infrastructure exists. This is the only load-bearing boundary; if
  Application-vs-Domain starts costing edits in four targets for one field,
  collapse Application into Domain.
- Infrastructure is constructed in exactly one file, the composition root in
  `App/`. Nowhere else.
- New capability goes behind an existing port if one fits. New ports are added
  in `CompassDomain/Ports.swift` and nowhere else.
- Never mutate or delete an event. Un-checking appends `checkInRevoked`.
- Never sort by wall-clock time. Total order is `(lamport, device)`.
- `device` is a **random 128-bit UUID** generated at first write and stored
  locally. Never `identifierForVendor`, never the device name, never anything
  derived from hardware or the Apple ID, and never displayed. It is signed,
  anchored and shipped to strangers inside every exported achievement.
- `device` means **writer, not phone.** The app and the widget are two writers
  with two UUIDs, two `lamport` sequences and two `prev` chains. One event per
  `write(2)` to an `O_APPEND` descriptor; take an advisory `flock` around any
  read-tail-then-append. `docs/technical.md` §4.
- Habit display names never enter a digest. `facts` carries `habitID`; the name
  lives in a mutable local `habits.json` resolved at render time.
- Never use `Calendar.current`, `TimeZone.current`, `Date()` or a locale inside
  `CompassDomain`. Time enters through the injected `Clock` port.
- No global accumulators in the fold. Every accumulator is keyed by `habitID`.
- No floating point anywhere in the fold or in any digested value.
- Additive changes only. Do not bump `"v"`. Do not rename a field. Do not remove
  a field. Add an optional one, or use `extra`.
- Preserve unknown fields and unknown event kinds on read and re-emit them
  unchanged. Never drop data you do not understand.
- Every taxonomy this project owns is a `RawRepresentable` struct over `String`,
  never a Swift enum. Enums only for closed sets someone else defined.
- No third-party dependency without a written trigger in `docs/technical.md`
  §10 that has actually fired. Code reused from the `before` repository is
  **copied in** with an attribution header — never an SPM path dependency, never
  a submodule. A build that breaks because an unrelated folder was tidied is a
  restart trigger.
- No server, no backend, no hosted service. Ever. Two named consequences: the
  OpenTimestamps calendars are the one operational dependency the project does
  take, and it is declared as an exception in `docs/product.md`; and a hosted
  `apple-app-site-association` file would violate this rule, which is part of
  why the identity limb in ADR 0003 is refused rather than deferred.
- Before adding a file, check whether the change belongs in an existing one.
  This codebase should stay small enough to read in an afternoon.
