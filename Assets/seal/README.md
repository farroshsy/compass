# Seal assets

Vendored from the design handoff (`compass-habit-tracker-design/`, which is
gitignored — it is a zip, not source). **Nothing here is wired into the build
yet.** `CertificateView` is week 3, per `docs/technical.md` §11, and cannot be
built meaningfully before it: there is no rule engine, nothing sealed, and no
`evidenceRoot` to derive the impression from.

## What ships

```
die-light-2x.png  die-light-3x.png
die-dark-2x.png   die-dark-3x.png
```

The die frame with **no matrix in it**. The app strikes the 64 cells over it at
issue time — per set bit, a rounded rect filled in the paper colour, with a 1pt
inner top-left shadow at 22% and a 1pt bottom-right highlight at 55%. About
twenty lines of SwiftUI.

The design withdrew the in-app height-field renderer it had proposed, and
recorded why in the same words this repository uses: "The constitution says
architecture is never added because it feels cleaner, and §12 wants a citation.
I had none — it was an aesthetic preference wearing infrastructure's clothes."
The cost of the two-layer strike is recorded rather than hidden: it is flatter
than the render, the walls do not curve, there is no displaced lip around each
cell, and beside the reference stills it is visibly cheaper. That is the right
trade.

Shipping size is 168pt — validated as holding down to 160pt and merging at
120pt. At AX5 it drops to 120pt, because it is a graphic and not text.

## What the cells encode

The **first 64 bits of `witness.evidenceRoot`** — the Merkle root over the
events that were actually counted — as an 8 x 8 field of pressed cells, MSB
first, one byte per row, 8.6pt per cell at a 168pt die.

So the impression is a property of *this* record and no other. Two certificates
can never carry the same one, and forging it would mean colliding the Merkle
root. Sixty-four bits in a die is a hallmark, never the thing you check: the
thing you check is the full digest printed underneath, and the export bundle.

## `reference/` — not runtime assets

Record-specific renders of one particular die, straight-on only. They exist so
the two-layer strike can be compared against what it is approximating.
`matrix-light-alt-3x.png` is a *different* record, i.e. a different die.

There is a tension in the design document worth knowing about before anyone
reaches for these: one line says "Shipping assets are the full-size PNGs", and
a later line in the same turn, titled "The renderer is withdrawn", says the die
frames ship and the app strikes the cells itself. **The later line governs** —
a fixed matrix PNG cannot be correct for an arbitrary record, so the earlier
line cannot be the instruction.

Three-quarter views are explicitly not a shipping state; the certificate uses
the straight-on render. They are not vendored.

## Deliberately not vendored

- `seal-*` — the turn-3 device, a 4 x 7 grid of the last twenty-eight days.
  Superseded, because a 28-day window is not a property of the specific record.
- `matrix-*-quarter-*` — not a shipping state.
- `*-view.jpg` — 400px document copies.

## The certificate itself has no image assets

It is all type and colour: paper `#F2EFE8` / `#1C1C20`, ink `#191917` /
`#EDEAE2`, New York for the claim, SF Mono for the identifier block, and **no
colour anywhere** — no gold, no accent, no tint. The spec is in the design
document; see `memory/next-tasks.md` under week 3.
