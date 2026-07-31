# Known bugs and hazards

No application code exists yet, so nothing here is a bug *in Compass*. These are
hazards already identified — in code that will be reused, and in decisions that
have a known failure mode — recorded now so they are not rediscovered painfully
later.

Delete an entry when it is fixed or when it is proven not to apply. Do not
delete one because it has stopped being convenient.

---

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

**Resolved.** `docs/achievement-protocol.md` **§6.7** now states the convention
in code: Compass signs `canonicalBytes` directly with CryptoKit's `DataProtocol`
overload, so the signed message is `SHA-256(canonicalBytes)` and equals `digest`
with no second hash, and `Signer.sign(_ text:)` MUST NOT be called on the
achievement path. §6 previously had no slot that could receive this answer,
which is why this entry pointed at a section that could not hold it.

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

### Design risks with no code yet

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
  not an architectural problem. It does not block writing `Day`, `project()` or
  the domain test suite, which need no account at all — see
  `memory/next-tasks.md`.
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
