# Testing rules

Swift Testing (`@Test`, `#expect`). `CompassDomainTests` is the largest suite and
the only one with no filesystem in it — **170 of 482 tests, counted 2026-08-01
after week 4** — and it runs in milliseconds. A new test goes there unless it
cannot. ("Around 80%" stood here until someone counted; it was never true.)
Write these:

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
  - **Written in week 3.** `AchievementEngineTests` also pins the three
    invariants the "exactly once" one rests on: the engine is bit-identical
    across runs (asserted on the **digest**, not on the day — two runs that
    agreed about the day and disagreed about the evidence root would pass a
    weaker test and produce two different signatures), a shuffled log gives the
    identical record, and a rule shipped late lands on the **historical** day.
  - **One test holds the engine and the fold together.** `QualifyingLog`
    re-derives the `(habit, day)` cell in the same last-writer-wins order
    `Projection` uses — one rule written twice — so `theEngineAndTheFoldAgree`
    asserts they are the same set. Without it a certificate could commit to
    evidence the screen never showed.
- **Journal crash-safety.** Write a log, truncate at **every** byte offset,
  assert it opens with all complete lines intact and the partial tail dropped.
- **Canonical encoding stability.** Assert the digest of a fixed achievement
  equals a hardcoded hex string. If this test ever needs updating, something
  irreversible has happened — stop and find out what. Pin the **verification
  input** in the same test: a signature made over `canonicalBytes` verifies
  against `canonicalBytes` and **fails** against `digest`. That second assertion
  is what catches a future session reintroducing the inherited double hash.
  - **The event half of this landed in week 1b** and is the pattern to copy for
    the achievement half in week 3. `CanonicalBytesTests` writes the expected
    byte string out by hand, transcribed from `docs/technical.md` §3 rather than
    captured from a run, and pins its SHA-256 to a hex computed by two tools
    outside this project. A hex captured from the code pins whatever the code
    happens to do, and the first session to reorder a key simply re-records it.
  - **Assert the digest covers every semantic field**, one mutation per field,
    and that no two mutations collapse onto one digest. The field that matters
    most is `payload.habitID`: it was outside the digest once.
- **Attestation failure** leaves the achievement earned and pending, and retries
  on **both** paths — when a `BGProcessingTask` fires, and opportunistically on
  next launch. Both, not either.
  - **Written in week 4.** The network seam is a stubbed `URLProtocol`, not a
    fake `Calendars`. This file refuses "mocked `URLSession` asserting a URL was
    assembled" and that refusal stands — what is asserted here is not a URL, it
    is that the digest goes to **all three** calendars rather than stopping at
    the first success, which is ADR 0004's first mitigation and the one thing in
    this subsystem that would regress in total silence. A fake behind a protocol
    would have moved exactly the code under suspicion outside the test.
  - **Assert what a pass costs when there is nothing to do.** The launch drain
    runs on every foreground, so "no request at all when nothing is due" is what
    makes it compatible with "no network call on the launch path". A test that
    only checks the happy path leaves that free to become false.
- **Run the standalone verifier from the suite, on a bundle the suite produced.**
  `VerifierTests` shells out to `verifier/compass-verify.py`. Two independent
  implementations agreeing is the only evidence available about a byte format —
  one implementation can only ever agree with itself. Two of its cases are
  **negative**: an edited event is caught, and an edited event with the manifest
  rewritten to match is still caught, by the chain and by the claim. A verifier
  that has only ever passed is not a verifier.
- **Two writers, one file.** Spawn two processes appending to one
  `events.jsonl`, interleave several thousand events, assert every line parses,
  no `(lamport, device)` pair repeats, and each writer's chain verifies unbroken.
  Write this before the widget ships, not after — every other test here uses
  synthesised in-process streams and would pass while real data corrupts.
  - **Written in week 2, and it paid for itself the same day**, exposing a
    `lamport` ordering defect that made a widget un-check vanish into a green
    suite. `CompassLogWriter` is the second process; it exists for this test and
    nothing else, because a test cannot spawn a process that does not exist.
  - **Assert what the file means, not only what is in it.** The three assertions
    above are all about bytes. Two more are about the record: that the processes
    genuinely interleaved (otherwise it is a sequential test in a concurrent
    costume), and that the later press wins whichever process made it.
  - **Never let it skip.** If the helper binary is missing the test fails and says
    how to build it. A skipped adversarial test is the exact failure it exists to
    prevent: the suite goes green and nobody reads the reason.
  - Cover the case the design forbids but the OS permits: **two processes sharing
    one writer name**, which is what several widget extension instances are.
- **Damaged-log recovery.** Inject a corrupted middle line, and separately a
  `prev` mismatch. Assert the damaged copy is written first, the longest valid
  prefix replays, other writers' chains are unaffected, and the app still
  launches. `docs/technical.md` §6.
- **The signing key survives relaunch.** Two `Signer` constructions across a
  simulated relaunch yield the same `publicKey`. The inherited code fails this.
  - **Drive the real keychain**, under a service name the test owns and deletes.
    A fake behind a protocol makes this pass while the two `SecItem` calls that
    actually decide whether the key survives go unexercised — and those two calls
    *are* the claim.
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

**Written in week 4** as `CalendarNetworkTests`, and it is tagged `network` so a
run without the internet skips it **explicitly** — `swift test --skip-tag
network` — rather than silently. It really submits a digest: the SHA-256 of a
fixed sentence about the test, which is not a record, not a log head, and says
nothing about anybody's day. A captured real calendar response is pinned as a
fixture in `OpenTimestampsTests`, because a live server cannot be one; the live
test proves the API is still there, and the fixture proves the parser reads what
it sends.

- **What the certificate says is a test, not a screenshot.** Every string is a
  claim about what the record proves, and this file refuses the snapshot tests
  that would otherwise be the only thing looking at it. So the copy is a plain
  value — `CertificateCopy` — and `CertificateCopyTests` asserts the honesty
  rules directly: no anchoring language in any state but `confirmed`, permanent
  failure sayable exactly once, the **whole** digest printed, a forged
  undigested title unable to reach the page, and nothing in the register that
  congratulates or invites a return.
- **A guard over shipped assets reads the source tree, not the built bundle.**
  Copying a forbidden render into `Sources/` and re-running was tried on
  2026-08-01: SwiftPM did not re-copy the resource and the bundle-only assertion
  **passed with the render sitting in the repository**. A guard a stale build can
  defeat is not a guard.

Time enters tests through a fake `Clock`. Never `Date()` or `Calendar.current`.
