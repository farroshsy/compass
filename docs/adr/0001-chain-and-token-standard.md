# ADR 0001 — Chain and token standard

**Status:** Accepted, not scheduled. The decision is made so that it does not
have to be re-argued; the implementation is deferred behind the trigger in
`docs/technical.md` §10. No code in v1 depends on any of it.

**Additional precondition, added after review.** The trigger in §10 is necessary
but not sufficient. ADR 0003 §2.5 establishes that this limb cannot satisfy
`docs/product.md`'s invisibility rule — the recovery-key ceremony is a seed
phrase by another name, and passkeys require a hosted
`apple-app-site-association` file that `.claude/skills/architecture.md` forbids
outright. Building this therefore requires **overturning a `docs/product.md`
non-goal in writing, in `memory/decisions.md`, with a date**, by someone who has
accepted that cost. Until then this limb is refused rather than deferred.

The sentence below — "if the chain limb is never built, that is a successful
outcome, not a failure" — is now load-bearing rather than reassurance.

**Date:** 2026-07-31

---

## Context

Compass produces roughly a dozen milestone records a year. The stated objective
function ranks educational value and portfolio value above product necessity, so
"you do not need this" is explicitly not a valid objection. What *is* a valid
objection is anything that makes the project more likely to be abandoned.

Three questions had to be answered together, because the answers constrain each
other: which chain, which token standard, and what is mutable after deployment.

Two facts from the investigation changed the shape of the answer:

1. **EIP-4844 blobs are pruned after roughly 18 days.** Every rollup posts its
   data to blobs. So the common claim that an L2 record is "secured by Ethereum
   forever" is false in the reconstruct-from-L1 sense: after 18 days, recovering
   the chain's state depends on that chain's own nodes and third-party
   archivers, not on Ethereum. The KZG commitment persists; the data does not.
   This applies to every rollup, not just the speculative ones.
2. **Base announced on 2026-02-18 that it is migrating off the OP Stack** to its
   own unified client, with three planned hard forks. Deployed bytecode should
   be safe — this is not an EVM-compatibility risk — but RPC, indexer and SDK
   churn through 2026 should be expected.

---

## Decision

**Chain: Base mainnet (chainId 8453).**

**Standard: one non-upgradeable ERC-721 implementing ERC-5192 and ERC-5484
together.** They are orthogonal and each costs about ten lines. ERC-5192's
`locked()` is the signal wallets and marketplaces read to hide transfer and sell
UI, which is the only concrete interop payoff on offer. ERC-5484's `burnAuth()`
is an immutable on-chain declaration of who may destroy the token.

Interface IDs to register in `supportsInterface`: `0x80ac58cd` (721),
`0x5b5e139f` (721 Metadata), `0xb45a3c0e` (5192), `0x0489b56f` (5484).

**No proxy. Not UUPS, not transparent.** A proxy admin key can retroactively
rewrite what an achievement means, which destroys the exact property being
bought, and a proxy migration is precisely the big-bang event the restart risk
says to avoid. If the contract must change: deploy v2, mint new achievements
there, leave v1 tokens valid. Additive, never a rewrite.

**Immutable, no exceptions:** token ownership and the 721 core; `locked()`
returning true; `burnAuth()` returning `OwnerOnly`; the commitment, the
milestone kind, the attained date and the seal digest, all write-once at mint;
the issuer addresses.

**The milestone kind is a separate, publicly readable field.** The renderer
requirement below — that it "works from the commitment and the milestone kind" —
is only satisfiable by an on-chain `data:` URI renderer if the kind is readable,
because a renderer cannot open a hash. ADR 0004 records what that leaks and why
the alternative forfeits the display surface that is most of this ADR's payoff.

**Whether `sealDigest` belongs on chain at all is reopened by ADR 0004's
consequences**, which show it is a public linking key from any shared bundle to
every other token the address holds. One of the three responses listed there is
chosen and recorded before the first mint.

**Mutable, exactly one thing:** the `renderer` pointer behind `tokenURI`, so a
cosmetic SVG bug is not permanent. The renderer MUST emit a `data:` URI
generated on-chain — no IPFS, no HTTPS, because link rot is the most common way
an NFT dies. A one-way `sealRenderer()` gives up even that power once the art
settles.

**Burn: allowed, owner-only, and not sold as privacy.** A `burnWithSig`
(EIP-712) path matters, because without it burning requires the owner to hold
ETH, which breaks the "never see a wallet" rule at the worst possible moment.

**The OpenTimestamps layer stays and is load-bearing, not a fallback.** See
ADR 0004.

---

## The honest accounting

The brief asked for this plainly, so it is stated plainly rather than buried.

**What a token buys over the OpenTimestamps code that already exists and works:**

1. A public record that exists without the user holding a file. An OTS proof
   proves nothing to anyone unless you hand them the `.ots` file and the
   original bytes; an address on a block explorer is a link.
2. Free rendering in wallets, explorers and NFT viewers — a surface that can be
   put on a CV.
3. Binding to an owning identity rather than only to a timestamp.
4. Composability with other contracts, which is worth exactly zero for one user.

**What OpenTimestamps gives that the token does not:** no wallet, no gas, no
chain selection, no key custody, no contract to maintain, no Solidity toolchain,
no second language, no upgrade risk, anchoring in the most durable chain there
is, verification against a header set of roughly 55 MB — and it is already
written and tested in this user's own repository.

**Net:** for a single user, item 1 is the only functional gain, and it is a
display benefit rather than a capability. Items 2 and 3 are portfolio benefits.
If the goal were "Farros keeps his achievements", the correct answer is
OpenTimestamps and no chain at all.

The chain is justified by the learning-and-portfolio half of the objective
function, not by the product. **The README must say so** rather than dressing it
up as necessity.

A second thing worth not over-claiming: **"soulbound" is close to decorative
here.** Non-transferability protects against a market that does not exist —
nobody wants to buy this meditation streak, and the user has no wallet UI to
transfer from. `locked()` is doing UX work and semantic work, not security work.

---

## Consequences

- A second language, a second toolchain (Foundry), a second test suite and a
  second CI pipeline enter a solo project. That is real ongoing drag, and it is
  the sort of thing that makes opening the repository feel like work. Mitigation:
  keep the contract around 150 lines, no proxy, no dependencies beyond
  OpenZeppelin's ERC721.
- Habit names MUST NOT go on-chain. Store
  `keccak256(habitID ‖ milestoneKind ‖ salt)`. The human-readable meaning stays
  local and can be revealed by handing over the preimage. This is the actual
  privacy control, and it is far stronger than burning.
- Burning does not deliver the privacy it appears to. The mint transaction, the
  commitment and any metadata remain visible in archives and indexers regardless
  of burn state. Do not let the presence of a burn function license putting
  anything sensitive on-chain.
- Idempotency MUST be enforced on-chain, not only in the client. The contract
  keys the token to the achievement ID and rejects duplicates, or a retry storm
  silently manufactures duplicate achievements — which destroys the meaning as
  effectively as making them purchasable would.
- **Chain-death insurance, concretely:** the local sealed record includes
  `chainId`, contract address, token ID and mint transaction hash, and that whole
  record is OTS-anchored. Deploy bytecode and constructor arguments stay in the
  repository. If Base dies, the achievements survive in the Bitcoin layer and the
  contract can be redeployed on any EVM chain with history replayed from local
  data. This is what makes the chain choice reversible, and reversibility is the
  only real answer to "what if the chain dies".
- Expect tooling breakage through 2026 from the Base client migration. Pin
  dependency versions.

---

## Alternatives, and why rejected

**No chain at all — OpenTimestamps only.** Genuinely competitive, and on product
merits it wins outright. See the honest accounting above. Rejected only because
the objective function explicitly ranks learning and portfolio value above
product necessity. Nothing is lost by the recommendation, because OTS is kept as
the foundation rather than replaced. If the chain limb is never built, that is a
successful outcome, not a failure.

**Ethereum Attestation Service.** The better engineering fit on the merits —
attestations are designed for exactly this, are revocable, are cheaper than
minting, and are already deployed on Base. Rejected because it is a third-party
protocol dependency rather than an EIP anyone can reimplement, it does not render
in wallets, and writing a minimal contract is the actual educational payload. If
the objective function were "correct" rather than "educational plus portfolio",
EAS wins. Stated here so the tradeoff is not forgotten.

**ERC-6551 token bound accounts.** Wrong problem, and still in peer review
rather than Final. It gives an NFT its own smart-contract account so it can hold
assets; a meditation streak does not need a bank account.

**ERC-5192 alone.** Deliberately silent on burning. Since burn is a real
question here, leaving the policy implicit in the bytecode is worse than
declaring it on-chain for ten extra lines.

**ERC-5484 alone.** Does not implement `locked()`, forfeiting the single
concrete interop benefit of being on-chain. Worth naming honestly: ERC-5484's
"consensual" framing assumes issuer and receiver are different parties
negotiating burn rights. Here they are the same person, so that half of the
standard is ceremonial — `burnAuth` is still useful as an immutable public
declaration, but nobody is consenting to anything.

**ERC-4973 account-bound tokens.** Does not implement the canonical ERC-721
transfer interface, so wallets and explorers largely do not render it. That
loses the display surface, which is most of the point.

**ERC-6239 semantic soulbound tokens.** Metadata ornamentation on top of 5192.
Buys nothing for one user, and works against keeping habit meanings off-chain.

**Abstract.** Roughly $47M TVS, Stage 0, a state-update pause in May 2026, and
activity down sharply from its early-2025 peak. Built on a stack whose roadmap
risk it inherits, with cultural relevance coupled to a single NFT brand. This is
the exact chain the brief worries about — trendy now, plausibly gone in five
years, and it would take the achievements with it.

**zkSync Era.** Around $203M TVS and still Stage 0 in 2026 despite years of head
start. More decisive: Matter Labs is sunsetting zkSync Lite in 2026 and has
pivoted toward institutional and privacy infrastructure. A company that retires a
chain when strategy changes is direct evidence against the five-year test.

**Arbitrum Orbit, or any dedicated chain.** Running a chain for a dozen
transactions a year is a permanent operational obligation with no counterparty.
It is a chain guaranteed to die, on a schedule set by getting bored.

**OP Mainnet.** Perfectly respectable — Stage 1, fault proofs, roughly $1.46B
TVS. Rejected only on relative momentum, at about an eighth of Base's TVS.

**Arbitrum One.** The genuine runner-up, close enough to be nearly a coin flip:
around $10.22B TVS, Stage 1, excellent tooling, arguably a better decentralisation
track record. Base is picked narrowly for the consumer and iOS ecosystem, which
matters for the identity work in ADR 0003. If Arbitrum tooling is already
familiar, switching is fine and the contract is identical.

**Ethereum L1.** Maximum durability and no chain-selection risk, but roughly $5
to $50 per mint and it teaches nothing about the modern L2 stack the project
exists to learn. The durability it offers is bought more cheaply — free — with
OpenTimestamps.
