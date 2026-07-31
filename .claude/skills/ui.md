# UI rules

The whole product is: open, tap two checkboxes, close, under three seconds.
Anything that adds a step to that is wrong regardless of what it enables.

- One screen **on the launch path**. No `TabView`. No `NavigationStack` on the
  launch path. Everything else is a `.sheet` or `.fullScreenCover` presented
  over Today. The v1 budget off that path is exactly three surfaces — settings
  sheet, certificate, certificate list — and it is counted in
  `docs/product.md`'s MVP scope. Adding a fourth means editing that list first.
- **No first-launch flow of any kind.** The two habits are seeded in the bundle
  with names already set, so first launch opens straight onto Today with the
  rows there. No naming screen, no keyboard, no permission prompt. Renaming
  lives in the settings sheet.
- Information at the top, out of thumb reach. Actions at the bottom, in the
  thumb arc. This inverts the normal habit-app layout on purpose.
- Habit rows: 76pt tall, full width minus 20pt margins, 12pt apart, corner
  radius 16. The **whole row** is the hit target, not the glyph.
- The last row sits 24pt above the home indicator. Tuned for 2–4 habits. Four
  is a hard cap, not a default.
- Tap toggles, tap again untoggles. Never a confirmation dialog.
- Haptic fires synchronously with the tap, before any write completes.
- The largest number on screen is **total days**, never the current streak.
- A missed day is a plain gap in the 28-dot spine. No red, no warning, no
  "streak at risk", no guilt copy anywhere in the app.
- The 28-dot spine is a **display, never a control.** Nothing on it is tappable.
  A forgotten day stays forgotten; there is no editing of a past day in v1.
- Finishing all habits does not change the layout. No takeover celebration. The
  rows just sit there filled.
- No "+" button on Today. Adding, renaming and deleting habits live behind the
  settings glyph, which is deliberately hard to reach.
- Two habits get two colours. Everything else is greyscale.
- Milestone certificate: fades up 12pt over 220ms. It does not pop, bounce, fly,
  or spin. Readable and dismissable by 300ms. No single animation over 300ms.
- The certificate never waits for a network. It shows **"Sealed on this device"**
  immediately, and keeps saying exactly that until `AnchorState` is `confirmed`,
  at which point it reads **"Sealed on this device · Anchored <date>"**.
- **Never render anchoring language before `confirmed`.** `submitted` only means
  bytes were sent, and an un-upgraded OTS proof proves nothing. A certificate
  that claims Bitcoin permanence it does not have, in an app forbidden to
  correct it, is worse than one that claims less.
- The card is not re-shown unprompted. It **is** re-openable from the
  certificate list in the settings sheet, which is where the `ShareLink` stays
  reachable after the card is dismissed. Plain reverse-chronological rows, and
  **no "new" indicator** — a "new" badge is a re-engagement affordance and
  badges are banned below.
- Banned outright: confetti, particles, sparkles, coins, points, levels, XP,
  rarity tiers, progress bars toward the next milestone.
- The certificate uses a serif face (`.system(.largeTitle, design: .serif)`).
  It is doing the entire visual argument for "document" rather than "token".
- Exactly one `ShareLink`, on the certificate, rendered via `ImageRenderer`.
- Never show a spinner, a pending badge, or a failure state for anchoring **on
  the main screen**. Anchor state lives on the certificate itself and nowhere
  else. "Invisible on the main screen" does not mean unsayable anywhere: if an
  achievement has been `failed` for more than 30 days, say so **once**, in the
  certificate, so permanent failure is discoverable rather than structurally
  unsayable. Once — not a badge, not a nag, not on Today.
- Never show a wallet, address, gas, chain name, seed phrase, or the word
  "mint". If a feature cannot be made invisible, it does not ship.
- **No notifications. None.** The earlier rule here mandated one local
  notification at a fixed hour, cancelled when the day completes — which is a
  streak-defence notification by function, and `docs/product.md` lists
  "no streak-defence notification" among the things that do not exist. The
  week-2 home-screen widget is the reminder: it costs no permission prompt, no
  fixed-hour decision, and no contradiction. Recorded in `memory/decisions.md`.
