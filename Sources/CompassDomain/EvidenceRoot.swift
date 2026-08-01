import CryptoKit
import Foundation

/// `witness.evidenceRoot` — the Merkle root over the events that were actually
/// counted. **The construction is frozen in `docs/achievement-protocol.md` §4.1
/// and is implemented here, not designed here.**
///
/// It was frozen in that document at week 1 rather than at week 3 for a specific
/// reason: the leaves are `content_hash` values produced by the **week-1** event
/// encoding, and `docs/technical.md` §3 says such a field cannot be added
/// afterwards without invalidating every hash computed before the change. A
/// week-3 engine specified in terms of a quantity the week-1 encoding does not
/// produce would be a week-one-blocks-on-week-twelve defect.
///
/// What `evidenceRoot` buys, and why `logHeads` does not replace it: this pins
/// **exactly which events were counted**, which is what makes a post-hoc
/// revocation honest — the claim can still be checked against the set it was
/// actually made over. `logHeads` commits to the whole history instead.
public enum EvidenceRoot {

    /// A leaf and an internal node can never be confused, because the two hashes
    /// are domain-separated by a one-byte prefix. Without it, an attacker who can
    /// choose a "leaf" that is really an encoded internal node can present an
    /// internal node as a whole subtree.
    private static let leafPrefix: UInt8 = 0x00
    private static let nodePrefix: UInt8 = 0x01

    /// An `evidenceRoot` over zero events: 32 zero bytes.
    ///
    /// No rule in v1 can produce this — a threshold is at least 1 and a
    /// qualifying day has at least one event behind it — and stating it costs one
    /// line and removes an undefined case.
    public static let empty = Data(repeating: 0, count: 32)

    /// `leaf(e) = SHA-256(0x00 ‖ content_hash(e))`
    public static func leaf(_ contentHash: Data) -> Data {
        var input = Data([leafPrefix])
        input.append(contentHash)
        return Data(SHA256.hash(data: input))
    }

    /// `node(l,r) = SHA-256(0x01 ‖ l ‖ r)`
    public static func node(_ left: Data, _ right: Data) -> Data {
        var input = Data([nodePrefix])
        input.append(left)
        input.append(right)
        return Data(SHA256.hash(data: input))
    }

    /// The root of the tree built by repeated application of ``node(_:_:)`` until
    /// one node remains.
    ///
    /// **Odd-node rule: at any level with an odd number of nodes, the last node
    /// is promoted unchanged.** It is *not* duplicated and paired with itself —
    /// duplication is the classic construction (CVE-2012-2459 in Bitcoin's own
    /// tree) that admits two distinct leaf sets with one root, which would let a
    /// forged evidence set match a genuine anchor.
    ///
    /// **For a single leaf, the root is that leaf**, with no further hashing.
    public static func root(ofLeaves leaves: [Data]) -> Data {
        guard !leaves.isEmpty else { return empty }
        var level = leaves
        while level.count > 1 {
            var next: [Data] = []
            next.reserveCapacity(level.count / 2 + 1)
            var index = 0
            while index + 1 < level.count {
                next.append(node(level[index], level[index + 1]))
                index += 2
            }
            if index < level.count {
                // Promoted unchanged. Never paired with itself.
                next.append(level[index])
            }
            level = next
        }
        return level[0]
    }

    /// The root over the events that were counted.
    ///
    /// **Leaves are the qualifying events' `content_hash` values, in
    /// `(lamport, device)` order** — the same total order everything else in this
    /// system uses, and never wall-clock. Sorting here rather than trusting the
    /// caller is what makes the root a function of the *set* of events rather
    /// than of the order the engine happened to collect them in, which is what
    /// "the engine is a pure function; same inputs, bit-identical outputs"
    /// requires.
    ///
    /// It throws rather than substituting anything when an event cannot be
    /// canonicalised: an evidence root that silently skipped an event would
    /// commit to a smaller set than the claim was made over, which is the one
    /// thing this value exists to prevent.
    public static func root(over events: [Event]) throws -> Data {
        let ordered = events.sorted { $0.order < $1.order }
        return root(ofLeaves: try ordered.map { leaf(try $0.contentHash) })
    }
}
