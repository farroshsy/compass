# ADR 0003 — Identity and wallet

**Status:** Accepted as *the correct design if this limb is built*, not
scheduled, and conditional on ADR 0001 ever being built. If the token limb is
never built, none of this is needed. **v1 has no identity system of any kind.**

**Blocked, additionally, on an explicit overturn.** See "This limb cannot
satisfy the invisibility rule" below. No work starts on it until that is
recorded in `memory/decisions.md` with a date.

**Date:** 2026-07-31

---

## Context

The user must never see a wallet, an address, a seed phrase, gas, or a chain
name. That is a hard product constraint, not a preference. The question is what
identity mechanism can satisfy it and still survive losing a phone.

Two facts reframed the whole question during the investigation.

**First, cost is not a decision input.** At one user and roughly a dozen writes
a year, every candidate vendor is free and gas is about $2 a year. Longevity and
escape hatch are the only differentiators.

**Second, and decisively: because achievements are soulbound they cannot be
moved.** So the on-chain address must be permanent and the signing authority
must be replaceable. A plain externally-owned account fails this by
construction: the address is derived from the key, so losing the key loses the
address, and since the tokens cannot be transferred, every achievement is
orphaned forever with no recovery path from anyone. A smart contract account
passes: address and key are separate, so key loss is an owner rotation and the
tokens never move.

That is the strongest engineering claim this project has, and it is what makes
account abstraction *necessary* here rather than decorative.

---

## Decision

### 0. The governing rule, which comes before any of the mechanics

**The chain is a publication, not the system of record.** The local sealed log —
SHA-256, a Secure Enclave P-256 signature, an OpenTimestamps anchor — is the
record. A token is a public mirror of a fact the local log already proves.

This single decision converts key loss from catastrophic data loss into "you
lost a mirror, re-publish it", and it is also what makes the entire chain layer
deferrable. Which is the direct answer to the restart risk.

### 1. v1: no identity, no vendor, no account

One key exists: the Secure Enclave P-256 signing key, created on first launch,
non-extractable, used to sign achievement digests. It is never shown and never
named. This is the existing `Signer` from the Shipped app, reused unchanged.

The app is genuinely finished at this point. Everything below is additive.

### 2. If and when the chain limb is built: a multi-owner smart account

Create a passkey with Apple's own `ASAuthorizationPlatformPublicKeyCredentialProvider`.
No SDK, no wallet vendor, no account. This yields a secp256r1 public key.

Deploy a `CoinbaseSmartWallet` — the open-source, audited contract, with a
factory already on Base — with an owner set registered **at creation**:

- `owner[0]` — the iCloud-synced passkey. Survives a lost phone.
- `owner[1]` — the Secure Enclave P-256 key. Device-bound, Face ID gated,
  non-extractable.
- `owner[2]` — an offline recovery key, generated once, written on paper, stored
  physically, **outside Apple's trust domain**.

**Use the contract, not Coinbase's SDK.** That turns Coinbase from a vendor
dependency into a library dependency, which is the correct relationship, and it
sidesteps the fact that Base Account has no Swift SDK at all.

### 2.5 This limb cannot satisfy the invisibility rule, and saying otherwise was the error

`docs/product.md` bans "anything the user must understand about blockchains —
no wallet, no gas, no chain name, no address, no seed phrase" and calls that the
definition of done for the entire layer. This ADR was written as though the
passkey-plus-smart-account design satisfies it. **It does not**, and the ADR's
own text contains the refutation in three places:

1. `owner[2]` is "generated once, written on paper, stored physically". A
   hand-copied recovery key is a seed phrase in everything but encoding — and
   the alternatives section below rejects "any seed phrase or mnemonic in the
   UI" as violating the invisibility rule *outright*, while line 168's own
   assessment of the paper key is "the kind of chore that never gets done".
2. Passkey creation is a visible system sheet. That is a chain concept arriving
   as a modal.
3. Passkeys require a registered associated domain and a hosted
   `apple-app-site-association` file. `.claude/skills/architecture.md` says:
   "No server, no backend, no hosted service. Ever." A hosted AASA file is a
   hosted service, and a domain registrar is exactly the lapsing operational
   dependency `docs/product.md` refuses.

So building this limb means **overturning a `docs/product.md` non-goal in
writing**, not satisfying it. That is permitted — non-goals are overturned in
`memory/decisions.md` with a date and a reason — but it must be done knowingly,
by someone who has accepted the cost, rather than discovered halfway through by
an implementer who assumed the invisibility rule had been met.

**Until that overturn is recorded, this limb is refused, not deferred.** A
deferred item has a trigger that makes it worth building; this one has a
precondition that has not been met. ADR 0001 already says that if the chain limb
is never built, that is a successful outcome rather than a failure — that
sentence is now doing real work.

### 3. Why owner[2] is not optional

Ranked by what actually survives losing the phone:

| Owner | Survives lost phone | Survives lost or locked Apple ID |
|---|---|---|
| Secure Enclave key | No — non-extractable by design | No |
| iCloud-synced passkey | Yes | No |
| Offline paper key | Yes | Yes |

The precise failure mode to design against is: **phone lost AND Apple ID locked
or compromised.** In that single event the enclave key and the iCloud passkey die
together, because they share a trust root. **Two owners that fail together are
one owner.**

And it MUST be registered at creation, because adding an owner requires an
existing owner. The window to add a recovery key closes at exactly the moment
you need one.

#### 3.1 The owner[2] ceremony, written out because otherwise it will be skipped

As things stood, `owner[2]` was required by this section, forbidden by
`.claude/skills/blockchain.md` ("Never write a seed phrase, mnemonic, address or
gas figure into the UI"), rejected by this ADR's own alternatives section, and
predicted by its own line 168 not to happen — with no specified flow for
generating, displaying, confirming or re-verifying it anywhere. An implementer
following the skill file would skip it and ship exactly the enclave-plus-iCloud-
passkey pair that §3 identifies as the disqualifying failure mode: phone lost
and Apple ID locked, both owners dead together, every soulbound token orphaned
with no recovery path from anyone.

So the ceremony is a **first-class blocking step** in the chain-limb plan, ahead
of contract deployment, and `.claude/skills/blockchain.md` is amended so its
no-key-material rule reads "never in the daily loop; the one-time recovery
ceremony is the sole exception."

- **Generated** on-device from `SecRandomCopyBytes`, once, before the account is
  deployed.
- **Displayed** once, as text, on a screen that cannot be screenshotted or
  backgrounded without re-confirmation.
- **Confirmed** by transcription: the user re-enters a randomly chosen subset of
  the material. Deployment does not proceed until it matches.
- **Re-verified annually.** Line 155 already demands exactly this for
  vendor-held keys — "export it at setup, verify it controls the address, store
  it offline, and re-verify annually" — and there is no argument for holding the
  user's own recovery key to a weaker standard than a vendor's.
- **If the user declines**, the account is not deployed and no token is ever
  minted. There is no reduced two-owner mode, because two owners that fail
  together are one owner, and this document has already called that
  disqualifying.

If displaying a recovery key is genuinely unacceptable — which is a defensible
reading of the invisibility rule — then **the chain limb must not be built**,
and ADR 0001 should be amended to say so rather than leaving it deferred behind
a trigger that can never honestly fire.

### 4. Is the Secure Enclave key redundant? No — conditionally

It has a real role, and it is the same role it has today: proving an action came
from this specific physical device with a key nobody can extract, even holding
the unlocked phone. Passkeys are syncable, which is their value for recovery and
precisely why they are weaker as device attestation. The two are complementary.

But the answer is conditional: the enclave key has a role **if and only if** the
account is a multi-owner smart account whose owners the user controls. With a
vendor-managed embedded wallet, the SDK manages its own key material and will
not accept an external enclave key as a signer — there the enclave key genuinely
is redundant. That is a second, independent reason to prefer owner-set control
over a managed wallet.

Regardless of any chain, the enclave key keeps its v1 job: sealing the local log.
That never needs a chain.

### 5. ERC-4337 is a choice, not a necessity, and the README must say so

Applying the necessity discipline honestly: at a dozen transactions a year a
funded relayer key costs about $5 per decade and depends on nothing but an RPC
endpoint. **The minimum sufficient rung is a funded relayer, not ERC-4337.**

Take ERC-4337 anyway — the objective function explicitly permits infrastructure
over-engineering and this is the thing worth learning. But name it as
over-engineering. A portfolio artifact that identifies its own over-engineering
and shows the cheaper option it rejected reads far better than one pretending the
complexity was forced.

A paymaster is not needed for cost. It is needed only so the user never has to
hold ETH, which is a UX constraint with a simpler solution.

---

## Consequences

- **No third-party vendor is required for the app to keep working**, provided
  three things hold: the habit UI never blocks on a network call, the local
  sealed log is the system of record, and the smart account's owners are keys the
  user holds. Every vendor must be replaceable in a weekend.
- The design that fails that test is "vendor embedded wallet as identity, minted
  tokens as the record" — two single points of failure guarding data that by
  definition cannot be moved.
- **Hard invariant, with a test:** the habit UI never awaits a network call,
  ever. If sign-in ever gates the checkbox, a vendor outage breaks the one thing
  that must never break.
- Passkeys on iOS require a registered associated domain and a hosted
  `apple-app-site-association` file. Cheap and replaceable, but a real
  prerequisite that is easy to discover late, and it briefly makes a domain
  registrar a dependency. If there is no domain that will still be owned in five
  years, the passkey path should be **dropped rather than deferred**.
- The simulator has no Secure Enclave and falls back to a software key.
  Anything enclave-backed MUST be verified on physical hardware before being
  registered as an on-chain owner, or a key that does not exist on the phone gets
  registered as an owner.
- Consolidation is the base rate, not the exception: two of the four major
  embedded-wallet vendors were acquired within roughly a year, toward acquirers
  whose roadmaps have no room for a single-user habit tracker. Assume anything
  chosen today is repriced or deprecated within 24 months.
- An unexercised export is not an escape hatch. If any vendor-held key is ever
  used, export it at setup, verify it controls the address, store it offline, and
  re-verify annually.

---

## Alternatives, and why rejected

**A plain EOA with the key in the iCloud Keychain.** This is the simplest thing
that could work, and it was the recommendation of one investigation on grounds of
avoiding all account-abstraction complexity in v1. It is rejected because it
fails the disqualifying case rather than merely trading off: the address is
derived from the key, tokens cannot be transferred, so key loss orphans every
achievement permanently. A second immutable backup issuer address mitigates only
the ability to *mint*, and only if the paper key is genuinely written down before
launch — which is the kind of chore that never gets done. Recorded as a resolved
contradiction in `memory/decisions.md`.

**Privy.** Best native Swift developer experience of the four and free at this
scale. Rejected because the iOS SDK ships as a closed-source XCFramework and the
Swift 2.x SDK was documented as beta. A dependency that cannot be patched sitting
in the critical path of unmovable data, now reporting to a payments acquirer, is
the worst possible shape for a project whose primary risk is abandonment. It is
the correct choice for a startup optimising time to ship.

**Dynamic.** Free to 1,000 monthly actives, so cost is fine. Rejected on fit and
direction: web and React first, the weakest native iOS story of the four, and now
inside an institutional custody business.

**Turnkey.** The last independent of the four, with an open-source Swift SDK — so
a deprecation is a fork rather than a rewrite — and the only export design where
the vendor provably cannot decrypt what you extract, because the target encryption
key can be generated fully offline. If a vendor is ever wanted, this is the one,
and it should be `owner[2]` in place of the paper key, **never** the primary
identity. Not chosen for v1 because Apple's own passkey API has no vendor at all.

**Base Account / Coinbase SDK as the integration surface.** No native Swift SDK;
mobile support is React Native only via Mobile Wallet Protocol. Bridging React
Native into a Swift 6 SwiftUI app to obtain a wallet is disproportionate.
Rejected as an SDK, explicitly retained as a contract.

**Any seed phrase or mnemonic in the UI.** Violates the invisibility rule
outright, and the passkey plus enclave path gives strictly better recovery
properties with no user-visible key material.

**Minting in the user-facing path.** Violates the three-second rule and couples
the daily loop to bundler, paymaster and RPC liveness. The mint must be a
background job derived from local state — idempotent, retryable, and safely
deferrable by months.

**Treating the chain as the system of record.** Makes key loss catastrophic and
makes the chain layer non-deferrable, which directly worsens the restart risk.

**Registering recovery owners later, once the app is working.** Adding an owner
requires an existing owner, so the ability to add a recovery key disappears at
exactly the moment it becomes necessary. Recovery owners are a creation-time
decision or they do not exist.

---

## Open, and to be checked before any of this is built

- Is a P-256 verification precompile confirmed active on Base mainnet today, and
  what is the measured end-to-end gas for a WebAuthn user operation — not the
  precompile cost in isolation? The inheritance is an inference from the stack,
  not a verified fact.
- Does the on-chain WebAuthn verifier accept an assertion whose `clientDataJSON`
  was synthesised by a native client rather than a browser? This determines
  whether making the enclave key a working on-chain owner is feasible at all.
  It must stay off the critical path either way: synthesising WebAuthn-shaped
  assertions from an enclave key has no Swift library and is real work, and a
  stall there would stall the project.
