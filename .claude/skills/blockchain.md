# Blockchain rules

Read `docs/adr/0001`, `0003` and `0004` before writing any of this. None of it
is in v1. If you are here before the app is in daily use, stop.

**Also stop if `memory/decisions.md` does not contain a dated entry overturning
the `docs/product.md` invisibility non-goal.** ADR 0003 §2.5 establishes that
this limb cannot satisfy that rule — the recovery ceremony is a seed phrase by
another name, and passkeys need a hosted `apple-app-site-association` file that
the architecture rules forbid. Until someone accepts that cost in writing, **that
recovery ceremony** is refused, not deferred.

**What is refused is that design, not the subsystem.**
`PROJECT_CONSTITUTION.md` §3 makes the blockchain a mandatory deliverable —
settled 2026-07-31, not to be reopened — and §14 records this as a live *design*
blocker to resolve before contract work, by either designing a genuinely
invisible recovery path or overturning the non-goal in writing with the cost
stated. Choosing neither and building anyway is not available; neither is
choosing neither and never building. This paragraph read "this limb is refused"
until 2026-08-01, which a session could take as permission to drop it. The
constitution wins.

- The chain is a publication, not the system of record. The local sealed log is
  the record. Removing the chain layer must lose no user data and no verifiable
  claim.
- Do not start any chain work until: the app is in daily use, OpenTimestamps
  anchoring works, and the trigger in `docs/technical.md` §10 has fired.
- OpenTimestamps first, always. Free, walletless, already written in
  `BeforeKit`, and it is what makes an `attainedAt` date credible.
- Never on chain: check-ins, habit names, notes, tap timestamps, timezone,
  device IDs, or anything mutable.
- On chain per achievement, write-once: `commitment`, `milestoneKind`,
  `attainedAt`, `sealDigest`, owner. Nothing else.
- `commitment = keccak256(habitID ‖ milestoneKind ‖ salt)`, with a **fresh
  random salt per token**. The habit vocabulary is small and guessable.
- The salt is **32 bytes from `SecRandomCopyBytes`**, stored beside the
  `ChainRecord` in `attestations.jsonl`, included in the export bundle, and
  covered by its manifest digest. **Losing the salt is terminal** — the token
  becomes a permanently unopenable hash that can never again be shown to mean
  anything. `memory/known-bugs.md`.
- `milestoneKind` is **publicly readable**, because an on-chain renderer cannot
  open a hash. It leaks the milestone class and its exact date, from which the
  habit's start date is arithmetic. Say that. Do not repeat the older, softer
  claim that a verifier learns only "some achievement of some kind".
- `sealDigest` is a **public linking key**. From any shared bundle anyone can
  compute it, find the token, find the address, and enumerate every other token
  and every date that address holds. Sharing one certificate discloses the whole
  timeline. Pick one of ADR 0004's three responses and record it in
  `memory/decisions.md` before the first mint.
- Base mainnet, chainId 8453. One non-upgradeable ERC-721 implementing both
  ERC-5192 (`locked()`) and ERC-5484 (`burnAuth()`).
- No proxy. If the contract must change, deploy v2 and leave v1 tokens valid.
- Exactly one mutable thing: the renderer pointer behind `tokenURI`. The
  renderer emits an on-chain `data:` URI. No IPFS, no HTTPS.
- Enforce idempotency in the contract, not only the client. Key the token to the
  achievement ID and reject duplicates. A retry storm must not manufacture
  achievements.
- Minting is a background job derived from local state: idempotent, retryable,
  safely deferrable by months. Never in a user-facing path.
- No EOA as the owning account. Soulbound tokens cannot be moved, so key loss
  would orphan them permanently. Multi-owner smart account, three owners
  registered at creation, one of them outside Apple's trust domain.
- Never write a seed phrase, mnemonic, address or gas figure into the UI **in the
  daily loop. The one-time `owner[2]` recovery ceremony is the sole exception**,
  and it is a blocking, first-class step with a specified flow — generate,
  display once, confirm by transcription, re-verify annually, and do not deploy
  the account if the user declines. ADR 0003 §3.1. The old absolute form of this
  rule made an implementer skip `owner[2]` and ship the two-owners-that-fail-
  together design the ADR calls disqualifying.
- Do not claim a token is "secured by Ethereum forever". Blobs are pruned after
  roughly 18 days. Say what is true.
- Do not claim burning provides privacy. The mint transaction is permanent.
- Do not claim ERC-4337 was necessary. A funded relayer is the minimum
  sufficient rung. Say it is over-engineering chosen for learning.
- Keep the contract near 150 lines. Verify on the explorer and on Sourcify.
  Deploy bytecode and constructor arguments stay in this repository.
