# Known bugs and hazards

**Compass has shipped code, and it has already shipped bugs.** This file opened
with "no application code exists yet, so nothing here is a bug *in Compass*"
until 2026-08-01, which was false by then and made the file read as a list of
things that could not yet happen. Two data bugs went out in `SettingsView` and
survived a suite of 206 tests — `memory/decisions.md`, 2026-07-31.

Four kinds of entry live here:

1. **Shipped and fixed** — what actually broke, kept so the shape is recognised
   next time.
2. **Known-untested** — code that is running with no test behind it, and the
   specific line where a regression would be silent.
3. **In code that will be reused** — hazards in the `before` repository, live
   the moment it is copied.
4. **Hazards in the design** — failure modes with no code yet.

Delete an entry when it is fixed or when it is proven not to apply. Do not
delete one because it has stopped being convenient.

---

## Shipped and fixed

### Two data bugs in `SettingsView`, both invisible to 206 tests

Fixed at `d17422e`. Recorded because the *shape* recurs, not because the bugs do.

- Done committed habit renames and returned, silently dropping a declared name
  typed and not submitted — the exact loss the handler's own comment said it
  existed to prevent, on the one field the sheet was added for.
- Done wrote a rename the user had cancelled by removing the habit. An in-flight
  edit was cleared only by committing it, and the sweep ran over active habits
  only, so Remove then Restore put a name on screen that the log did not have.

Both were ordinary logic. Both lived in `@State` inside a `View`, which no test
can construct or drive, and both passed `swift test` at `f2fd73e` — "206 tests
in 23 suites passed". The fix was extracting `SettingsEdits`, and the rule is
now in `.claude/skills/architecture.md`: **behaviour goes in a plain value
beside the `View`; the `View` keeps the layout.**

### The achievement pass failed silently, on both of its call sites

Fixed 2026-08-01. `Sources/CompassUI/TodayModel.swift`, the tap path and
`reconcile()`.

Both read `if let issued = try? await awarding.evaluate()`. `try?` discards the
error at the point it happens, so a pass that could not read the log, could not
reach the keychain or could not canonicalise a record left **no trace of any
kind** — no state, no file, no log line. A milestone that failed to issue looked
exactly like one that was never earned, and only one of those is a bug.

`.claude/skills/ui.md` forbidding a failure surface on Today is correct and was
not the cause; the file makes the same distinction for anchoring — "invisible on
the main screen does not mean unsayable anywhere". The two lines simply took the
first half and skipped the second.

The shape to recognise: **`try?` on a call whose failure has no other
observer.** It is indistinguishable from `try?` on a call whose failure is
genuinely uninteresting, and the two sit side by side in this file —
`TodayModel.append` uses `try?` correctly, because a failed write changes nothing
on screen *and the screen is the record of what happened*.

### A hardcoded `backing` would have passed 493 tests

Fixed 2026-08-01. The shape: **a value that is carried everywhere and required
nowhere.**

`Signer.swift`'s own doc comment promised that "on the simulator there is no
enclave and the key falls back to software; `backing` records that honestly" —
the first half of which was measured false later the same day, see the
simulator entry below — and every mechanism the promise needs was in place.
`Attestation.backing` was
encoded into `attestations.jsonl`, exported in the bundle, and printed by
`verifier/compass-verify.py`. Measured: replacing `backing: signer.backing` in
`AchievementIssuer.seal` with a hardcoded `.secureEnclave` left **all 493 tests
passing**. `SignerTests` pinned `Signer.backing` itself; nothing pinned whether
what the signer knew survived onto disk.

Two smaller defects came out of the same look:

- the verifier printed the backing **inside** the branch that runs only when the
  signature verifies, so a bundle whose signature failed said nothing about its
  provenance — which is exactly the bundle a reader wants it from;
- the run's conclusion — the line a reader actually stops on — was identical for
  a software-signed bundle and an enclave-signed one.

The rule this leaves: **a value whose whole purpose is honesty needs a test that
fails when it lies.** Carrying it, encoding it and printing it are not that test,
and all three can be present while the value is a constant.

### The verifier computed the evidence root over the wrong leaf order

Fixed on 2026-08-01, in `verifier/compass-verify.py`. Recorded because the shape
is the most dangerous one in this project: **a check that agrees only when the
data is tidy.**

`evidence_for` collected the qualifying events by iterating `days` and handed the
result straight to `evidence_root`, so the Merkle leaves were in **day** order.
`docs/achievement-protocol.md` §4.1 freezes them in `(lamport, device)` order and
says nothing about days. `EvidenceRoot.root(over:)` on the Swift side was right
all along, so the spec and the app agreed and only the second reader was wrong.

**It passed every test the suite had, and could not have failed one.** Every
bundle `VerifierTests` produced was one writer's check-ins appended one day after
another, and on such a log day order *is* `(lamport, device)` order — the two
readings are indistinguishable. The defect only appears when one day holds
several events written out of sequence, which the widget and the app make routine
the moment both exist (`docs/technical.md` §4). On the fixture built to show it:

```
leaves in day order        a433e65b3ecfa118f24e9de7e0d358aa71ba10a02be819b9840b8761e52a4ebe
leaves in (lamport,device) fa44093f0a0375029ebefc102a5a9e8568db74678e7cc006527856b390c036b4  ← the app, and §4.1
```

The rule this leaves behind: **when an artefact exists to check another one, at
least one fixture must be built so that two plausible readings of the
specification give different answers.** A passing suite of tidy fixtures is
evidence about the fixtures. `VerifierTests.evidenceLeavesAreInTotalOrderNotDayOrder`
is that fixture, it asserts that the two candidate roots differ before it asserts
which one was reached, and with the fix reverted on either side it is the only
one of 483 tests that fails.

### The verifier asserted the one claim it could not check

Fixed 2026-08-01, in `verifier/compass-verify.py`. The shape: **the strongest
claim on the page rendered with the marker reserved for what was recomputed.**

`backing` is outside the digest — `docs/achievement-protocol.md` §6.1 freezes the
canonical form and does not list it, because no signature can prove what hardware
held a key. Three readings were possible and two hedged correctly: `software`
printed unmarked and attributed to the record, a missing field printed `unknown`.
`secureEnclave` printed `ok`, the same marker as the P-256 signature, the
manifest digests and the chain.

**Demonstrated.** Take a genuinely software-signed bundle, change one word in
`attestations.jsonl`, recompute every `manifest.json` digest as an honest
exporter would:

```
  ok         the key is Secure Enclave-backed, per the record
  ok       every signature here came from a Secure Enclave key
  Every check that could run, passed.                          exit 0
```

Nothing else notices, and nothing else should: the signature is genuine and the
log is untouched. The only thing standing between a forged provenance claim and a
clean run was how one line was printed — and it was printed as established.

The rule this leaves: **`ok` belongs to a check that recomputed something.** A
field that was read is reported as read, and the reading an attacker would choose
gets no more confidence than the one that says nothing. It is the mirror of the
entry above it: that one trusted tidy data, this one trusted undigested data, and
both were readable as passes.

---

## Known-untested, and running

`.claude/skills/testing.md` refuses SwiftUI snapshot tests and a broad XCUITest
suite, out loud and for good reasons. That is a deliberate decision, not an
oversight — but it leaves a region of live code with nothing behind it, and the
two `SettingsView` bugs above came out of exactly that region. So the region gets
named.

The first entry below is not untested code. It is a **limitation of the format**,
filed here because it is the section a future session reads before believing
something.

### `backing` cannot distinguish a simulator from a phone, and nothing else can

**A limitation of the format, recorded rather than fixed.** Measured 2026-08-01.
`docs/achievement-protocol.md` §7.0 bis is the full reasoning; this is the
operational version.

§7 says "a simulator-made proof must never look as strong as a phone-made one",
and five places in the repository explained how that was delivered: on the
simulator there is no enclave, so the key falls back to software and the record
says `software`.

**That premise is false on every Mac this project has run on.** This host is an
Intel Core i9 with an Apple T2 Security Chip. `SecureEnclave.isAvailable` is
`true` inside the iOS Simulator there, so the first launch mints an enclave key
in the *host Mac's* enclave, and the bundle exported from the simulator on
2026-08-01 — `.../Devices/4D361587…/…/Compass-2026-08-01 2/attestations.jsonl` —
carries `"backing":"secureEnclave"`. Apple Silicon behaves the same way. The
fallback happens only on a host with **no** enclave, which excludes every T2 and
Apple Silicon Mac. The enclave test even carried a `withKnownIssue` for hosts
*without* one, so the inverse case had been considered and the live one had not.

**So the guarantee §7's sentence describes has never been delivered, on any
machine, since the first build.** What survives is the writer obligation —
`backing` is the signer's own value, and `AchievementIssuerTests` fails when it
lies — and the reader obligation not to default a missing value upward.

**No mechanism was invented to close it, deliberately.** A device-class field
would be a format change needing an ADR, it would be self-asserted, and it would
sit outside the digest like `backing` does, so it would be attacker-controlled on
any received bundle. It would buy a stronger-looking record and no stronger
claim.

What this costs, concretely:

- Reading `secureEnclave` in a bundle tells you the key was enclave-backed. It
  does **not** tell you the enclave was a phone's.
- `docs/adr/0003`'s requirement to verify enclave-backed keys on physical
  hardware before registering an on-chain owner is now load-bearing rather than
  belt-and-braces: a simulator key looks identical to a phone key, so nothing
  downstream can catch the mistake.
- Anything that ever wants "this came from the phone" needs a mechanism that does
  not exist yet — App Attest or DeviceCheck are the candidates, both are network
  services, and neither is scheduled. Not a defect awaiting a fix; a gap awaiting
  a requirement.

### The line that decides whether the store notice is ever spoken

`Sources/CompassUI/TodayView.swift:132`:

```swift
.accessibilityLabel(model.spokenCaption)
```

**No test covers this line, and changing one word breaks accessibility in
silence.** The header's children are merged with
`.accessibilityElement(children: .combine)` and the merged label is then
replaced by this one, which discards every child's text — including the store
notice. Write `model.caption` here instead of `model.spokenCaption` and a
VoiceOver user on a launch that cannot open the store hears "0 days recorded"
and nothing about why, which reads as an app that forgot everything. That is the
precise misreading the notice exists to prevent, and it is what the code did
before `f2fd73e`.

What *is* tested is `TodayModel.spokenCaption` and `TodayCaption.spokenHeader`
(`TodayModelTests`, and `CompositionTests` for `isStoreAvailable == false`). All
of that keeps passing while the view ignores it. The test suite cannot see the
call site; only a reader can.

**Standing rule, since there is no test to enforce it:** anything added inside
that accessibility element must also be added to `TodayModel.spokenCaption`, or
it is written on the screen and unsayable.

### The `fileExporter` presentation itself

`Sources/CompassUI/SettingsView.swift`, the `.fileExporter` modifier and
`startExport()`.

**Nothing asserts that a folder ever lands on disk.** Every decision around it is
tested — `TodayModel.export()` returns the port's bundle or a sentence
(`ExportControlTests`), `BundleDocument.directoryWrapper()` reproduces the bundle
byte for byte including its nesting, `SettingsCopy.exportFilename` is a civil
date, and `ExportTests` pins that the port's bundle is the bundle
`Exporter.export(to:at:)` writes. What is not tested is the four lines between
them: the binding that presents the sheet, the `contentType: .folder`, the
`defaultFilename`, and the `onCompletion` that clears the document.

That is the same class as every other `View` line below and it has the same
cause: `.claude/skills/testing.md` refuses snapshot tests and a broad XCUITest
suite, so there is no mechanism here that can drive a system sheet.

**Standing rule, since there is no test to enforce it:** `directoryWrapper()` is
the only thing that decides bytes, and `fileWrapper(configuration:)` must stay
one line of forwarding — `FileDocumentWriteConfiguration` has no accessible
initialiser, so anything moved into it becomes untestable the moment it is
written.

### Everything else inside a `View` body

Same class, same absence of coverage. In particular:

- `SettingsView.addSection` — `.disabled(!edits.canAdd(in: model))` and the
  footer that switches on `model.mayAddHabit`. `SettingsEdits.canAdd` is tested;
  the wiring that reads it is not.
- `SettingsView.removedSection` — `.disabled(!model.mayAddHabit)` on Restore.
- `TodayView` — `if !model.isStoreAvailable { storeNotice }`.
- Every layout number in `TodayMetrics` is tested as arithmetic. **Nothing has
  been measured on a physical device.** The AX5 fit is a computation that
  passes, not an observation that four rows fit.

### Export exists, is tested, and has no way to reach it

`Sources/CompassInfrastructure/Export.swift` implements the bundle and
`ExportTests` covers it, but **no surface in the app calls it.** `CompassUI.swift`
says so at the site: export is budgeted to the settings sheet and not wired to
it. Until it is, the "insurance policy that turns a rewrite into a re-projection"
is code the user cannot run, and the phone-loss hazard below is unmitigated in
practice rather than in principle.

### Damage is detected and nothing says so

Week 1b made the damaged-log condition **detectable**: `JournalRead.chain` walks
every writer's chain and lists each break, `JournalRead.damagedLines` lists every
line that would not decode, and `Reprojector` returns `.refusedDamaged`,
`.refusedSealed` or `.refusedAlreadyUsed` rather than rewriting a log it cannot
read. Every one of those values is discarded by `AppComposition.compose`.

So `docs/technical.md` §6's policy is half implemented, and the missing half is
the visible one:

- nothing copies the file to `events.jsonl.damaged-<timestamp>` before touching
  anything;
- nothing surfaces the **one notice** saying how many days were recovered and
  where the damaged copy is.

The app does still launch, and no line is ever silently dropped from the file —
which are the two properties §6 cares most about. But a user whose log breaks
today is told nothing, and the corpus says they should be told once. Same missing
surface as the export button below, and probably the same piece of work.

Week 1b added a second value with the same shape as the unreachable export
above: `Reprojector.reprojectIfNeeded()` returns an outcome, and the composition
root throws it away. Not a correctness bug — every refusal leaves the log exactly
as it was, and the journal chains forward from the last event it can read — but
a permanently unchained log currently looks identical to a healthy one.

### The first tap after a cache launch may decode the whole log

A launch that renders from `snapshot.json` does not decode the log, so the
journal starts with no resume and recovers `lamport` and its chain head under the
advisory `flock` on its first write. `EventLog.replay()` normally primes it from
the `.task` that follows the first frame, well before a tap — but a tap **can**
beat the replay, and then the recovery lands on the main actor inside the
synchronous steps `docs/technical.md` §4 requires to be microseconds. §6 measures
a full decode at 193 ms at five years and 865 ms at ten, on a Mac.

Not a correctness bug: `EventJournal.prime` never overwrites the **head** a tap
already established, so the chain cannot fork either way. It is an unmeasured
latency claim, and it belongs with the other measurements owed below.

**Week 2 adds a second, larger instance of the same shape.** `WidgetStore.toggle`
decodes the log **twice** on every press: once unlocked to decide which event to
write, and once inside `EventJournal.record` under the `flock` to recover the
clock and the head. That is deliberate — passing a resume is what makes `record`
skip the lock, and several widget extension instances share one writer name — but
it doubles the cost of the press on a log that §6 measures at 193 ms at five years.
Nobody has measured it on a phone. If it bites, the fix is a locked read-and-record
in one call, not a resume passed in from outside the lock.

### The widget's *press* has never been verified on a device or simulator

Verified: the extension is embedded, carries the same App Group as the app,
registers with WidgetKit, and its timeline provider renders the four real habits
read from the shared `events.jsonl` — the cross-process read path, end to end,
seen in the widget gallery preview on 2026-08-01.

Not verified: pressing a row. Placing a widget on the iOS 18.4 simulator segfaults
SpringBoard inside `-[SBHRippleSimulation clear]`, which is Apple's Home Screen
wallpaper code and has nothing to do with Compass, so the widget could not be
placed to press. Every layer beneath `Button(intent:)` is under test —
`WidgetStoreTests` and `TwoWritersTests` — and the plumbing above it is Apple's.
What is genuinely unexercised is the two-line `ToggleHabitIntent.perform()` and
the `Button(intent:)` binding.

**Clear it the first time the app is on the phone**, which is the same trip that
clears the entry below: add the widget, press a row, and confirm
`writer-widget.id` appears in the container beside `writer-app.id` with a second
chain in `events.jsonl`.

### The app has never been verified on a phone

Every verification to date is `swift test` plus a simulator install. No entry in
`memory/decisions.md` records the app running on a physical device, and week
1b's entry condition — opened three days running — depends on it.
`memory/current-focus.md`.

---

### `BGTaskScheduler` registration is untested, and it throws when it is wrong

`AnchorScheduler.register()` is the `BGProcessingTask` half of §9.8, and it is
the half no test watches — deliberately, because the scheduler decides when it
runs and a test cannot make it. Every line that can be wrong is in
`AnchorPipeline`, which `swift test` compiles.

**Registration and submission are verified on the simulator**, from the device
log on 2026-08-01 rather than from the build settings that were meant to produce
them:

```
[com.apple.BackgroundTasks:Framework] submitTaskRequest:
  <BGProcessingTaskRequest: dev.farros.compass.anchor,
   earliestBeginDate: 2026-08-01 04:36:32 +0000,
   requiresExternalPower=0, requiresNetworkConnectivity=1>
```

So `register` did not throw and the system accepted the request. That is the
failure that was nearly shipped: the identifier was first written as an
`INFOPLIST_KEY_` build setting and **silently dropped** from the built product
with no warning at any stage, and `BGTaskScheduler.register` throws when its
identifier is missing from `BGTaskSchedulerPermittedIdentifiers`.

What is still unexercised is the only part that matters and the only part nobody
controls: **whether a task ever actually fires.** `BGProcessingTask` carries no
execution guarantee, which is precisely why the launch drain exists and why
`docs/technical.md` §9.8 insists on both paths. There is nothing to fix here and
nothing to test; it is named so that nobody later mistakes "registered" for
"runs".

### The AX5 seal size has been looked at, and still not measured

`Assets/seal/README.md` carries the finding "holds to 160pt, merges at 120pt"
forward from turn 3d and then prescribes 120pt at AX5. **3d measured the
superseded 4 x 7 twenty-eight-cell device.** The shipped device is an 8 x 8
sixty-four-cell matrix — more than twice as dense — and at 120pt its cell falls to
**6.14pt** with a 1pt shadow and a 1pt highlight on it, so a third of every cell
is edge treatment. The README prescribes exactly the size already known to merge
on a strictly sparser device.

**Week 3 rendered it and looked at it, which is more than had been done and less
than a measurement.** On the iPhone 17 Pro simulator at
`accessibility-extra-extra-extra-large`, the cells stay individually separated —
they do not merge into a solid block — but at actual size the field reads as
texture rather than as data. `CertificateMetricsTests.cellPitchAtTheAccessibilitySize`
pins 6.14pt and says in its own comment that nobody has measured it, so a change
to either the AX5 size or the matrix ratio has to come and read that paragraph.

The design's 120pt is implemented, because `PROJECT_CONSTITUTION.md` §9 says to
implement the documented design and report. What is owed is a look on a physical
phone at arm's length, and then a decision: keep 120, raise the floor to 168 —
which costs nothing, because at AX5 the screen scrolls and the attestation has
already unstacked — or drop the die at that size. It is a design change either
way and it is the owner's call.

### A habit added in the settings sheet can never earn a streak certificate

`docs/technical.md` §5 says "per habit at 7, 30, 100, 365 and 1000 consecutive
days". A rule is **static data** and `Scope.habit` is a `HabitID`, so the shipped
rows name the four seeded identifiers — and a habit created in the sheet has an
identifier minted at runtime that no shipped rule names. The all-habit `total`
rows still cover it, since they are scoped to any habit; the streak rows do not.

Nothing in the corpus reconciles "rules are data shipped in the bundle" with "a
habit can be added at runtime", and week 3 did not invent a reconciliation. The
mechanism to close it needs no new concept — `RuleStore` already reads the store's
own `rules/` directory, so writing a per-habit row there at `habitCreated` is the
whole fix. What it needs is a decision about whether a habit added on day 300
should be able to earn a 7-day certificate on day 307, and that is a product
question rather than an engineering one.

### The declared-name footer is now understating rather than overstating

`SettingsCopy.nameFooter` was written in week 1a, when there was no chain and no
signature, and it deliberately claims nothing: "Optional, and nobody checks it."
Its own doc comment says "When the seal actually exists, this is the sentence that
earns the stronger claim."

The seal exists as of week 3. The footer is still **true** — nothing verifies the
name, and there is no second party that could — so it has not become dishonest,
and understating is the safe direction. What it no longer says is the thing that
is now real: a name declared before a record is sealed is inside
`witness.logHeads` and cannot be restated afterwards without breaking that seal.
`SettingsTests.theSheetClaimsNoCryptographyItDoesNotHave` still asserts the old,
weaker bound, and its premise — a `FakeRecorder` whose events all carry
`prev == genesis` — is no longer a description of the app.

Left alone deliberately: it is a copy change with a real claim inside it, and a
claim about what a seal proves should be written once, carefully, rather than
folded into the week that first made it true.

### "Three independent chances to upgrade" is two

`docs/adr/0004` requires submitting every digest to all three OpenTimestamps
calendars rather than taking the first success, and gives the reason as "three
independent chances to upgrade". The code does exactly that. **The first real
submission, on 2026-08-01, showed the redundancy it buys is smaller than the
sentence implies.**

The proof came back carrying two pending attestations naming
`alice.btc.calendar.opentimestamps.org` and one naming `bob` — because
`a.pool.opentimestamps.org` is a **pool**, and it routed the submission to alice.
So three requests reached **two** operators.

Not a bug in Compass, and nothing to change in the submission path: asking all
three is still strictly better than asking one, and which servers a pool fronts
is not this project's to decide. It is recorded because the number in the ADR was
an assumption nobody had checked, and because the fix — if it is ever wanted — is
a one-line change to `Calendars.defaults`, naming a third independent operator
instead of a pool. Whether a third independent operator exists and is worth
depending on is a question this project has not asked.

### The app's own proof has not reached a Bitcoin block yet

**The digest has.** `33a6fc1429640437cf9711e800e9a3fe46c873407eaa8f53f44c2b4e2361d106`
— the log-head digest the app computed and submitted — is committed by **Bitcoin
block 960500**, merkle root
`f8c42e4dc3667ca33c0170f9f0ab935df23c5b91ee45cb2752926a3b19b2f045`. That is a
real, upgraded OpenTimestamps proof of the real value, and the standalone
verifier reads it and reports exactly that.

What it is **not** is the proof sitting in the app's store. The confirmed one
came from a submission made by hand thirty-three minutes earlier, while the
canonical form was being pinned; the app's own submission went out at 10:36 and
landed in a later aggregation round, which had not made it into a block by the
end of the session. Same digest, different path, and only the app's path is in
`anchors.jsonl`.

So what is genuinely unexercised is one inch: `AnchorPipeline.upgradeAll`
receiving a real Bitcoin attestation from a real `/timestamp/<commitment>` call
and writing `confirmed` to disk. Everything on either side of it is exercised —
the parser against genuine upgraded bytes, the pipeline against a scripted one,
the verifier against both.

**Clear it by opening the app again.** The drain runs on every foreground, the
proof is already in `anchors.jsonl`, and the pass is idempotent. Then read
`anchors.jsonl` and expect `confirmed` with a `blockHeight`.

### The four real achievements are still inside their 72-hour window

`docs/achievement-protocol.md` §7.1 forbids submitting before 72 hours after
`detectedAt`, and the real store's four awards were detected on 2026-08-01. So
the only thing anchored for real so far is the **log head**, and the achievement
submission path has been exercised only against a scripted calendar. Re-open the
app after 2026-08-04.

### Export still has no surface — and week 4 made that cost more

The entry above stands unchanged, and it now costs two things instead of one:
`memory/next-tasks.md`'s scheduled iCloud Drive backup cannot be built on top of
an export the user has never been able to run, and **the standalone verifier
takes a bundle** — so the one artifact that makes the mission sentence true is,
today, reachable only by someone with a Mac and this repository.

The week-4 proof of the verifier was produced by running `Exporter` over the
simulator's real container from a throwaway harness, precisely because there is
no button. That is honest about what was demonstrated and it is not a substitute
for the button.

## In code that will be reused

### `Signer.sign` double-hashes

`~/Downloads/before/Sources/BeforeKit/Seal.swift`:

```swift
public func sign(_ text: String) throws -> Data {
    let hash = Data(SHA256.hash(data: Data(text.utf8)))
    if let enclaveKey {
        return try enclaveKey.signature(for: hash).rawRepresentation
    }
    ...
}
```

It computes `SHA256(text)` and hands the resulting `Data` to CryptoKit's
`DataProtocol` overload, which hashes again. So it signs `SHA256(SHA256(text))`.

`signatureIsValid()` verifies the same way, so the existing app is
self-consistent and correct. Nothing is broken today.

**It matters** the moment anything outside that app has to verify a signature —
an external verifier, or an on-chain WebAuthn verifier, which requires signing
the SHA-256 of a raw concatenation and would reject a double-hashed signature.
Copying `sign()` verbatim into that path will produce signatures that fail.

**Resolved in the document, then in the code.**
`docs/achievement-protocol.md` **§6.7** states the convention: Compass signs
`canonicalBytes` directly with CryptoKit's `DataProtocol` overload, so the signed
message is `SHA-256(canonicalBytes)` and equals `digest` with no second hash.

**Week 3 copied `Signer` in and did not copy `sign(_ text:)` at all** —
`Sources/CompassInfrastructure/Signer.swift` has `signature(over canonicalBytes:)`
and nothing else, and the parameter is named so that a call site reading
`signature(over: digest)` looks wrong. Two tests hold it, at two levels:
`AchievementBytesTests.signsCanonicalBytesAndNotTheDigest` against a bare
CryptoKit key, and `SignerTests.signsTheBytesAndNotTheDigest` against the type
the application actually calls. Both assert the second half `.claude/skills/testing.md`
asks for: a signature over `canonicalBytes` **fails** against `digest`.
Reintroducing the double hash was tried on 2026-08-01 and both fail.

### `Signer` cannot restore a Secure Enclave key across launches

Same file. `Signer` has exactly two initialisers: `init(preferEnclave:)`, which
unconditionally calls `SecureEnclave.P256.Signing.PrivateKey()` and mints a
**brand-new key every time**, and `init(softwareKeyData:)`, which restores
software keys only. The comment claiming "enclave keys are restored from their
own data representation instead" describes an initialiser that does not exist,
and `exportableKey` returns nil for enclave keys.

Copied verbatim, **every Compass launch produces a different public key.**
Achievements signed in different sessions would carry different signers and the
"this came from one device" claim collapses. The entry below records only that
the key does not survive *device replacement*; this is worse — it does not
survive *relaunch*.

Fix while copying, before the first achievement is signed:

- Persist `SecureEnclave.P256.Signing.PrivateKey.dataRepresentation` to the
  keychain on first launch with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — after first unlock so the
  widget process can construct the signer, this-device-only because a key that
  syncs is not a device attestation.
- Add `init(enclaveKeyData:)` restoring via
  `SecureEnclave.P256.Signing.PrivateKey(dataRepresentation:)`.
- Test that two successive `Signer` constructions, and two across a simulated
  relaunch, yield the same `publicKey`.

**Fixed in week 3, with all three.** `KeychainStore` writes the enclave key's
`dataRepresentation` under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
`Signer.init(store:)` restores it, and `SignerTests` drives the **real** keychain
under a service name of its own and deletes what it wrote — a fake behind a
protocol would have made the assertion pass while the two `SecItem` calls that
decide whether the key survives went unexercised. Mutation, 2026-08-01: making
`init` ignore the stored key fails three tests, starting with
`theKeySurvivesRelaunch`.

**One clause of §8's reasoning is not yet delivered:** the accessibility class is
"after first unlock, because the widget process must be able to construct the
signer". The class is right, but the item has no keychain access group, so the
widget could not read it. Nothing in v1 signs from the widget — it only records
check-ins — so this costs nothing today. It becomes a real gap the day anything
outside the app process has to seal something.

### `Log.persist()` rewrites the whole array

Same repository, `Calendar.swift`. Correct for one entry a day; measured at
145 ms and a 1.9 MB flash write per append at a 5-year Compass workload. Do not
reuse. ADR 0002.

### The Secure Enclave key does not survive device replacement

Non-extractable by design. Records and proofs survive because they are in the
exported bundle; the ability to extend that key's chain does not. Re-keying must
be an additive event, never a reason to reset history.

---

## Hazards in the design, not yet realised

### Unverified claims that must be measured before being asserted

Per standing evidence rules, these numbers are proposals and must not be written
into a test or a README as fact until measured on the actual phone:

- Cold launch to first frame under 400 ms.
- Full replay under 250 ms.
- All storage benchmarks in ADR 0002 were run on a Mac, not on device. The
  conclusion rests on a ratio that holds regardless of absolute speed, but the
  absolute figures should not be quoted as device figures.

### Unverified external facts

- Whether a P-256 verification precompile is active on Base mainnet is an
  inference from the stack, not a confirmed fact. Confirm before any gas budget
  depends on it.
- Whether an on-chain WebAuthn verifier accepts an assertion whose
  `clientDataJSON` was synthesised by a native client rather than a browser is
  unknown. It determines whether the enclave key can be an on-chain owner at all.
- Whether `Button` is genuinely interactive in Lock Screen accessory widget
  families on the target OS. Treat as read-only until confirmed on device.

### Design risks ahead of the code that would realise them

Most of these still have no code. Two now do: the provisioning bullet is live
today, and the phone-loss bullet is live the moment the log has anything in it,
which is now.

- **Per-device chains and the merge tiebreak are designed for but untested**,
  because there is one device. Without a shuffle-invariance test, two devices
  will diverge silently and surface months later as a phantom or missing
  achievement. Write the test before the second device, not after.
- **Backfill is the honesty hole, and v1 closes it by not having backfill.**
  A `.backfill` source would let the user mark days they did not do, and a
  certificate over mostly-backfilled days must be distinguishable from one over
  live taps. No backfill surface ships in v1 — a forgotten day stays forgotten —
  but `source_live` and `source_backfill` remain **required** fields, because
  they are inside the digest and cannot be added later. If that requirement is
  ever quietly dropped, or a backfill surface ships without it, the sealed claim
  starts overstating.
- **`fallbackTitle` is frozen at earn time**, so a typo is permanent on the
  fallback path. Accepted deliberately, because the localisation-key path fixes
  it. Worth knowing before the first typo.
- **The event log becoming write-only ballast** while the projection becomes the
  real code is the standard way solo event-sourcing projects rot. Mitigation:
  keep the event set small, and make at least one user-visible feature read the
  log directly so it stays load-bearing.
- **Free provisioning profiles expire after seven days.** The app stops
  launching. This is the largest practical threat to the *daily habit* and it is
  not an architectural problem. It blocked nothing in week 1a — that shipped
  against `swift test` and a simulator, neither of which needs an account — and
  it is now the live constraint, because the next thing the project needs is the
  app on a phone for three days. Seven days is enough for that and not enough
  for a habit. See `memory/next-tasks.md`.
- **TestFlight builds expire after ninety days.** TestFlight is the fix for the
  seven-day problem, but it substitutes a ninety-day one rather than removing
  it, and the number "90" appeared nowhere in this corpus. When a build expires
  the installed app refuses to launch until a new build is pushed. **Standing
  obligation: upload a build every quarter.**
  - **Compounding risk, and the more dangerous half:** if an expired build is
    resolved by deleting and reinstalling rather than updating in place, the App
    Group container goes with it and the entire log is destroyed. Update in
    place. Verify a recent off-device export exists before touching the
    installation.
- **Phone lost before any export exists — total, permanent loss.** Named because
  it is the single largest data-loss vector in the design and no document
  previously listed it. There is no server, sync is deferred until a second
  device exists, and the whole record lives in one container on one phone. Lost,
  stolen, bricked or wiped in week three means the streak, every achievement and
  every anchor are gone. Mitigations, all specified in `docs/technical.md` §8:
  iCloud device backup deliberately enabled for the container, a scheduled
  background export of the full bundle to iCloud Drive, and a first-launch check
  that the last successful export has not aged out.
- **A pending, un-upgraded OpenTimestamps proof proves nothing.** A fresh
  submission is only a promise that a calendar will aggregate the digest; it
  becomes a proof after the calendar upgrades it with the Bitcoin path, and that
  upgrade must be fetched from that same third-party server later. If the
  calendars are gone, repriced or firewalled during the window, every pending
  proof is permanently worthless. The certificate must not say "anchored" before
  `AnchorState` is `confirmed`. ADR 0004.
- **Salt loss makes a minted token permanently unopenable.** The per-token
  commitment salt is the only thing that lets the user ever open the commitment
  and prove what the token means — an achievement that exists forever and can
  never again be shown to mean anything. 32 bytes from `SecRandomCopyBytes`,
  stored beside the `ChainRecord`, in the export bundle, covered by the manifest.
- **`extra` and every other undigested field are attacker-controllable** on a
  bundle received from someone else, while the signature still verifies. That
  includes `titleKey` and `fallbackTitle`, which drive the displayed title — so
  a forged bundle could render an arbitrary achievement title under a valid
  signature and a genuine Bitcoin anchor. Invariant 8 in the protocol forbids
  rendering undigested text as part of a verified claim.
- **A bundle spanning a device replacement has two unrelated public keys.** The
  old key cannot sign the new one, because by the time the new phone exists the
  old key is unreachable. Without a forward-looking rotation authorisation
  signed during normal operation, a stranger must simply *trust* that the two
  keys belong to one person — which is the trust the mission sentence promises
  to eliminate. `docs/technical.md` §8.
