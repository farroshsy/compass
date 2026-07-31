# Testing rules

Swift Testing (`@Test`, `#expect`). Around 80% of all tests live in
`CompassDomainTests`, are pure, and run in milliseconds. Write these:

- **Day and streak arithmetic, exhaustively.** 23:59 and 00:30 check-ins; the
  04:00 cutoff; DST both directions; travel Surabaya to anywhere and back; leap
  day; toggling twice in one day; a gap of exactly one day. A wrong answer here
  is what makes the user stop trusting the app.
- **Replay parity.** Replay twice, assert byte-identical serialised state.
- **Shard invariance.** Split by `habitID`, fold each shard, merge, assert equal
  to folding the whole. This mechanically forbids the global-accumulator bug.
  Highest-value single test in the project — write it first.
- **Incremental equals full replay** after a random event sequence.
- **Achievements fire exactly once, ever** — under full replay, after a crash,
  after a reinstall from the log.
- **Journal crash-safety.** Write a log, truncate at **every** byte offset,
  assert it opens with all complete lines intact and the partial tail dropped.
- **Canonical encoding stability.** Assert the digest of a fixed achievement
  equals a hardcoded hex string. If this test ever needs updating, something
  irreversible has happened — stop and find out what. Pin the **verification
  input** in the same test: a signature made over `canonicalBytes` verifies
  against `canonicalBytes` and **fails** against `digest`. That second assertion
  is what catches a future session reintroducing the inherited double hash.
- **Attestation failure** leaves the achievement earned and pending, and retries
  on **both** paths — when a `BGProcessingTask` fires, and opportunistically on
  next launch. Both, not either.
- **Two writers, one file.** Spawn two processes appending to one
  `events.jsonl`, interleave several thousand events, assert every line parses,
  no `(lamport, device)` pair repeats, and each writer's chain verifies unbroken.
  Write this before the widget ships, not after — every other test here uses
  synthesised in-process streams and would pass while real data corrupts.
- **Damaged-log recovery.** Inject a corrupted middle line, and separately a
  `prev` mismatch. Assert the damaged copy is written first, the longest valid
  prefix replays, other writers' chains are unaffected, and the app still
  launches. `docs/technical.md` §6.
- **The signing key survives relaunch.** Two `Signer` constructions across a
  simulated relaunch yield the same `publicKey`. The inherited code fails this.
- **Bundle restore round-trip.** A fresh install fed only the exported bundle
  reproduces every achievement bit-identically and verifies every OTS proof. An
  unexercised escape hatch is not an escape hatch.
- **Full replay and cold launch, each under a budget measured on the real phone
  first.** The replay one is the tripwire that triggers ADR 0002.

Do not write these. Say so out loud rather than feeling guilty:

- SwiftUI snapshot tests. They break on every point release and catch nothing a
  daily user would not notice within a day.
- A broad XCUITest suite. Slow, flaky, re-asserts the morning flow.
- Tests that an `@Observable` setter sets. That is testing the language.
- Mocked `URLSession` asserting a URL was assembled. Test the encoder.
- A coverage target. Domain coverage is high because Domain is pure; UI coverage
  is a vanity number.

Keep exactly **one** network test, hitting the real OpenTimestamps calendars.
The failure guarded against is building on an API nobody ever called.

Time enters tests through a fake `Clock`. Never `Date()` or `Calendar.current`.
