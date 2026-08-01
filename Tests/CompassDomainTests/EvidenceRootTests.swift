import CryptoKit
import Foundation
import Testing

@testable import CompassDomain

/// The Merkle construction, `docs/achievement-protocol.md` §4.1.
///
/// It is **frozen** by that document, so these tests pin the document rather
/// than the code: the two domain-separation prefixes, the promote-don't-duplicate
/// rule for odd levels, the single-leaf case, and the empty root. A verifier
/// written from §4.1 alone must reach the same root, and every one of these is a
/// place two reasonable implementations would otherwise differ.
@Suite("evidenceRoot — the Merkle construction that is frozen in the protocol")
struct EvidenceRootTests {

    private static func hash(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    @Test("An empty evidence set is 32 zero bytes")
    func emptyIsZeroes() {
        #expect(EvidenceRoot.root(ofLeaves: []) == Data(repeating: 0, count: 32))
        #expect(EvidenceRoot.empty.count == 32)
    }

    /// "For a single leaf, the root **is** that leaf." No further hashing, so a
    /// verifier does not have to guess whether a one-element tree gets a
    /// self-pairing round.
    @Test("A single leaf is the root, unhashed again")
    func singleLeafIsTheRoot() {
        let only = EvidenceRoot.leaf(EvidenceRootTests.hash(0xAA))
        #expect(EvidenceRoot.root(ofLeaves: [only]) == only)
    }

    /// **The rule that closes the classic forgery.** At an odd level the last
    /// node is promoted, never duplicated and paired with itself. Duplication is
    /// the construction that admits two distinct leaf sets with one root — so a
    /// three-leaf set and a four-leaf set whose last leaf repeats must not agree.
    @Test("An odd node is promoted, not duplicated — three leaves differ from four")
    func oddNodesArePromotedNotDuplicated() {
        let a = EvidenceRoot.leaf(EvidenceRootTests.hash(0x01))
        let b = EvidenceRoot.leaf(EvidenceRootTests.hash(0x02))
        let c = EvidenceRoot.leaf(EvidenceRootTests.hash(0x03))

        let three = EvidenceRoot.root(ofLeaves: [a, b, c])
        let duplicated = EvidenceRoot.root(ofLeaves: [a, b, c, c])

        #expect(three != duplicated)

        // And the promotion is exactly what §4.1 describes: `c` rides up
        // untouched and pairs with `node(a,b)` at the next level.
        #expect(three == EvidenceRoot.node(EvidenceRoot.node(a, b), c))
    }

    /// Domain separation is mandatory, "so a leaf can never be confused with an
    /// internal node". Without the prefixes, an attacker who can choose a leaf
    /// value can present an internal node as a whole subtree.
    @Test("A leaf and an internal node over the same bytes hash differently")
    func leavesAndNodesAreDomainSeparated() {
        let bytes = EvidenceRootTests.hash(0x5A)
        let asLeaf = EvidenceRoot.leaf(bytes)
        let asNode = Data(SHA256.hash(data: bytes))
        #expect(asLeaf != asNode)
        #expect(EvidenceRoot.leaf(bytes) != EvidenceRoot.node(bytes, bytes))
    }

    @Test("The prefixes are the ones the protocol names, 0x00 and 0x01")
    func prefixesArePinned() {
        let content = EvidenceRootTests.hash(0x7E)
        var leafInput = Data([0x00])
        leafInput.append(content)
        #expect(EvidenceRoot.leaf(content) == Data(SHA256.hash(data: leafInput)))

        var nodeInput = Data([0x01])
        nodeInput.append(content)
        nodeInput.append(content)
        #expect(EvidenceRoot.node(content, content) == Data(SHA256.hash(data: nodeInput)))
    }

    /// Order matters, and it is `(lamport, device)`. The root is computed over
    /// the sorted events rather than over the array it was handed, so the answer
    /// is a property of the evidence set and not of how the engine gathered it.
    @Test("The root sorts its events, so gathering order cannot change it")
    func rootIsIndependentOfGatheringOrder() throws {
        let events = try chained([
            event(.checkedIn, habit: habitA, on: day("2026-01-01"), lamport: 1, source: .tap),
            event(.checkedIn, habit: habitA, on: day("2026-01-02"), lamport: 2, source: .tap),
            event(.checkedIn, habit: habitA, on: day("2026-01-03"), lamport: 3, source: .tap),
        ])
        #expect(try EvidenceRoot.root(over: events) == EvidenceRoot.root(over: events.reversed()))
    }

    /// Changing a single counted event changes the root — which is what makes the
    /// evidence root evidence.
    @Test("Editing one counted event moves the root")
    func oneEditedEventMovesTheRoot() throws {
        let events = try chained([
            event(.checkedIn, habit: habitA, on: day("2026-01-01"), lamport: 1, source: .tap),
            event(.checkedIn, habit: habitA, on: day("2026-01-02"), lamport: 2, source: .tap),
        ])
        var tampered = events
        tampered[1] = tampered[1].with(payload: .habit(habitB))

        #expect(try EvidenceRoot.root(over: events) != EvidenceRoot.root(over: tampered))
    }

    /// A tree with a level of every parity, so the promotion path runs more than
    /// once in one call: 5 -> 3 -> 2 -> 1.
    @Test("A five-leaf tree reduces through two odd levels to one root")
    func reducesThroughRepeatedOddLevels() {
        let leaves = (1...5).map { EvidenceRoot.leaf(EvidenceRootTests.hash(UInt8($0))) }
        let expected = EvidenceRoot.node(
            EvidenceRoot.node(
                EvidenceRoot.node(leaves[0], leaves[1]),
                EvidenceRoot.node(leaves[2], leaves[3])
            ),
            leaves[4]
        )
        #expect(EvidenceRoot.root(ofLeaves: leaves) == expected)
    }
}
