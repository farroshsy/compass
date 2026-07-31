import Foundation

// The two types the ``Attestor`` port in `Ports.swift` is declared over.
//
// They live here now only because `docs/technical.md` §2 declares the port in
// terms of them, and a protocol cannot be declared over names that do not
// exist. The achievement engine that produces claims, and the attestor that
// consumes them, are week 3 and week 4 work per §11 build order — nothing here
// is implemented, wired, or read by Domain.
//
// `Attestation` is transcribed from `docs/achievement-protocol.md` §7, which
// specifies it field for field. `AchievementClaim` is named in
// `docs/technical.md` §2 and is defined nowhere in the corpus; per
// `PROJECT_CONSTITUTION.md` §9 that gap is reported rather than designed
// around. It carries the two quantities the corpus does pin down: which
// achievement (`Attestation.achievement`, §7) and the digest that is submitted
// to a calendar (§6.6, §7.1 step 3).

/// What is handed to an ``Attestor``.
public struct AchievementClaim: Hashable, Sendable {
    public let achievement: AchievementID
    /// `SHA-256(canonicalBytes)`. `docs/achievement-protocol.md` §6.6.
    public let digest: Data

    public init(achievement: AchievementID, digest: Data) {
        self.achievement = achievement
        self.digest = digest
    }
}

/// Mutable, and therefore stored in its own file — `attestations.jsonl`,
/// last-write-wins per achievement ID. Separating mutable from immutable is
/// what allows `awards.jsonl` to be strictly append-only.
/// `docs/achievement-protocol.md` §7.
public struct Attestation: Codable, Sendable {
    public let achievement: AchievementID
    public let publicKey: Data
    /// P-256 over `canonicalBytes`, never over `digest`. §6.7.
    public let signature: Data
    /// Recorded honestly: a simulator-made proof must never look as strong as a
    /// phone-made one.
    public let backing: SignerBacking
    public var state: AnchorState
    public var otsProof: Data?
    public var calendar: URL?
    public var submittedAt: Date?
    public var confirmedAt: Date?
    public var blockHeight: Int?
    /// Reserved; `nil` until a token is ever minted.
    public var chain: ChainRecord?

    public init(
        achievement: AchievementID,
        publicKey: Data,
        signature: Data,
        backing: SignerBacking,
        state: AnchorState,
        otsProof: Data? = nil,
        calendar: URL? = nil,
        submittedAt: Date? = nil,
        confirmedAt: Date? = nil,
        blockHeight: Int? = nil,
        chain: ChainRecord? = nil
    ) {
        self.achievement = achievement
        self.publicKey = publicKey
        self.signature = signature
        self.backing = backing
        self.state = state
        self.otsProof = otsProof
        self.calendar = calendar
        self.submittedAt = submittedAt
        self.confirmedAt = confirmedAt
        self.blockHeight = blockHeight
        self.chain = chain
    }
}

/// Frozen closed set, and therefore permitted to be an enum. §2.2, §7.1.
///
/// A fresh OpenTimestamps submission is an *incomplete* proof. Until a calendar
/// upgrades it with the Bitcoin path the achievement is sealed but not
/// anchored, and MUST NOT be described as anchored.
public enum AnchorState: String, Codable, Hashable, Sendable, CaseIterable {
    case provisional
    case sealed
    case submitted
    case confirmed
    case failed
}

/// Frozen closed set, and therefore permitted to be an enum. §2.2.
public enum SignerBacking: String, Codable, Hashable, Sendable, CaseIterable {
    case secureEnclave
    case software
}

/// Reserved so that adding it later is not a format change. §7.
public struct ChainRecord: Codable, Hashable, Sendable {
    public let chainId: Int
    public let contract: String
    public let tokenId: String
    public let txHash: String

    public init(chainId: Int, contract: String, tokenId: String, txHash: String) {
        self.chainId = chainId
        self.contract = contract
        self.tokenId = tokenId
        self.txHash = txHash
    }
}
