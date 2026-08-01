import CompassDomain
import CompassInfrastructure
import CryptoKit
import Foundation
import Testing

/// The OpenTimestamps proof format. `docs/adr/0004`,
/// `docs/achievement-protocol.md` §7.1.
///
/// **The central fixture is a real calendar response**, captured from
/// `https://a.pool.opentimestamps.org/digest` on 2026-08-01 and pasted in as
/// bytes. `.claude/skills/testing.md` keeps exactly one live network test and
/// says why — "the failure mode being guarded against is building on an API
/// nobody ever called" — but that test cannot assert anything about *shape*
/// without pinning a known answer, and a live server cannot be a fixture. So the
/// live test proves the API is still there, and this one proves the parser reads
/// what it actually sends.
struct OpenTimestampsTests {

    /// The digest that was submitted to produce ``calendarResponse``: the bytes
    /// `0x00` through `0x1f`. Chosen so it can be written out rather than
    /// remembered.
    private var submittedDigest: Data { Data((0..<32).map { UInt8($0) }) }

    /// 207 bytes, exactly as `a.pool.opentimestamps.org` returned them. It is a
    /// serialised timestamp with no file header — that framing belongs to the
    /// `.ots` file, not to the wire.
    private var calendarResponse: Data {
        Data(
            hexEncoded: "f0083b69c973505a157708f010d19b58809a88843bef68f8071dcfd0f708f020"
                + "0133e689a7eb36762c87ee3a146a1c6a5b2b74357e4957cf2d0991fb20ab96e4"
                + "08f1205285247785d6dabb7ffb5e843a5d51e30e2d42f82fc48a6db9d1a8f4fe"
                + "cc0e7208f020417a362156465713fcdede6b0137e5c2488732bb7b51c0aeb401"
                + "17dca9d0d7fd08f1046a6d6054f0087dde3846a3845e9d0083dfe30d2ef90c8e"
                + "2e2d68747470733a2f2f616c6963652e6274632e63616c656e6461722e6f7065"
                + "6e74696d657374616d70732e6f7267"
        )
    }

    private func parse(_ data: Data) throws -> OTSTimestamp {
        var reader = ByteReader(data)
        return try OTSTimestamp(reading: &reader)
    }

    // MARK: Reading what a calendar actually sends

    /// The whole point of replaying the operations: the pending attestation is
    /// about a value several hashes away from the digest, and that value is what
    /// an upgrade request has to name. A parser that skipped the operations
    /// would have nothing to ask for.
    @Test("A real calendar response parses into one pending attestation")
    func aRealResponseParses() throws {
        let timestamp = try parse(calendarResponse)
        let pending = timestamp.pending(from: submittedDigest)

        #expect(pending.count == 1)
        #expect(pending.first?.calendar == "https://alice.btc.calendar.opentimestamps.org")
        #expect(pending.first?.commitment.count == 44)
        #expect(timestamp.bitcoin(from: submittedDigest).isEmpty)
        #expect(timestamp.unreplayable(from: submittedDigest).isEmpty)
    }

    /// A promise is not a proof, and this is where that distinction is made
    /// mechanical: nothing in a freshly submitted response can produce
    /// `AnchorState.confirmed`, because there is no Bitcoin attestation in it.
    @Test("A fresh submission carries no Bitcoin attestation")
    func aFreshSubmissionIsNotAProof() throws {
        #expect(try parse(calendarResponse).bitcoin(from: submittedDigest).isEmpty)
    }

    @Test("A real calendar response survives a serialise / parse round trip")
    func realBytesRoundTrip() throws {
        let timestamp = try parse(calendarResponse)
        let written = try OpenTimestamps.writeDetached(
            digest: submittedDigest, timestamp: timestamp
        )
        let read = try OpenTimestamps.readDetached(written)

        #expect(read.digest == submittedDigest)
        #expect(read.timestamp == timestamp)
        #expect(read.timestamp.pending(from: submittedDigest).count == 1)
    }

    @Test("A detached file starts with the OpenTimestamps magic and the SHA-256 tag")
    func theFileHeaderIsTheStandardOne() throws {
        let written = try OpenTimestamps.writeDetached(
            digest: submittedDigest, timestamp: try parse(calendarResponse)
        )
        // `\0OpenTimestamps\0\0Proof\0` — the header every other OpenTimestamps
        // client in the world looks for. A bundle whose proofs only this project
        // can open would still require trusting this project.
        #expect(written.starts(with: Data("\0OpenTimestamps\0\0Proof\0".utf8)))
        #expect(written[31] == 0x01)  // major version
        #expect(written[32] == 0x08)  // SHA-256
        #expect(Data(written[33..<65]) == submittedDigest)
    }

    @Test("A file that is not a proof is refused rather than half-read")
    func rubbishIsRefused() {
        #expect(throws: OTSError.notAProof) {
            try OpenTimestamps.readDetached(Data("not a proof".utf8))
        }
        // The magic alone: a header with nothing after it is truncated, not
        // valid-and-empty.
        #expect(throws: (any Error).self) {
            try OpenTimestamps.readDetached(Data("\0OpenTimestamps\0\0Proof\0".utf8)
                + Data([0xBF, 0x89, 0xE2, 0xE8, 0x84, 0xE8, 0x92, 0x94]))
        }
    }

    // MARK: Three calendars, one artifact

    /// **This is the assertion ADR 0004's first mitigation rests on.** Three
    /// responses about one digest have to survive as three, in one file, or
    /// "three independent chances to upgrade" is a sentence with nothing behind
    /// it.
    @Test("Three calendars' responses merge into one proof carrying all three")
    func threeCalendarsMergeIntoOne() throws {
        var merged = OTSTimestamp()
        for host in ["alice", "bob", "finney"] {
            merged.merge(
                OTSTimestamp(
                    branches: [
                        OTSBranch(
                            operation: .append(Data([0x01])),
                            timestamp: OTSTimestamp(
                                branches: [
                                    OTSBranch(
                                        operation: .sha256,
                                        timestamp: OTSTimestamp(
                                            attestations: [.pending("https://\(host).example")]
                                        )
                                    )
                                ]
                            )
                        )
                    ]
                )
            )
        }

        let digest = Data(SHA256.hash(data: Data("anything".utf8)))
        let calendars = merged.pending(from: digest).map(\.calendar).sorted()
        #expect(
            calendars == [
                "https://alice.example", "https://bob.example", "https://finney.example",
            ]
        )

        // And they survive the file, which is where they actually have to live.
        let file = try OpenTimestamps.writeDetached(digest: digest, timestamp: merged)
        #expect(try OpenTimestamps.readDetached(file).timestamp.pending(from: digest).count == 3)
    }

    /// Merging is a union and never a replacement. A proof is the one thing in
    /// this system that cannot be recomputed: resubmitting a discarded digest
    /// gets a strictly later Bitcoin timestamp, which destroys the "it is not
    /// backdated" property that is the whole argument for anchoring.
    @Test("Merging the same response twice changes nothing")
    func mergingIsIdempotent() throws {
        var once = try parse(calendarResponse)
        let before = try OpenTimestamps.writeDetached(digest: submittedDigest, timestamp: once)
        once.merge(try parse(calendarResponse))
        let after = try OpenTimestamps.writeDetached(digest: submittedDigest, timestamp: once)
        #expect(before == after)
    }

    // MARK: The upgrade

    /// The Bitcoin attestation as the format actually spells it — tag
    /// `0588960d73d71901`, then a varint block height — written out by hand from
    /// the specification rather than produced by this file's own encoder, so the
    /// test is about the format and not about a round trip with itself.
    private func bitcoinAttestationBytes(height: Int) -> Data {
        var payload = Data()
        var remaining = height
        if remaining == 0 {
            payload.append(0)
        }
        while remaining != 0 {
            var byte = UInt8(remaining & 0x7F)
            if remaining > 0x7F { byte |= 0x80 }
            payload.append(byte)
            remaining >>= 7
        }
        return Data([0x00, 0x05, 0x88, 0x96, 0x0D, 0x73, 0xD7, 0x19, 0x01])
            + Data([UInt8(payload.count)]) + payload
    }

    /// The upgrade path, end to end and offline: a pending branch is grafted with
    /// the rest of the path, and the proof gains a Bitcoin attestation over a
    /// value the operations actually arrive at.
    @Test("Grafting an upgrade onto a pending commitment produces a Bitcoin attestation")
    func anUpgradeGraftsOntoThePendingCommitment() throws {
        var proof = try parse(calendarResponse)
        let pending = try #require(proof.pending(from: submittedDigest).first)

        // What a calendar returns for `/timestamp/<commitment>`: more operations,
        // ending in the block that committed them.
        let upgrade = try parse(
            Data([0xF0, 0x02, 0xAB, 0xCD, 0x08]) + bitcoinAttestationBytes(height: 912_345)
        )

        // Computed outside the expectation: `graft` mutates, and the macro's
        // expansion would capture `proof` immutably.
        let grafted = proof.graft(upgrade, at: pending.commitment, from: submittedDigest)
        #expect(grafted)

        let confirmed = proof.bitcoin(from: submittedDigest)
        #expect(confirmed.count == 1)
        #expect(confirmed.first?.height == 912_345)
        // The merkle root is the value the operations arrive at — append 0xabcd,
        // then SHA-256 — and not something the record asserted.
        #expect(
            confirmed.first?.merkleRoot
                == Data(SHA256.hash(data: pending.commitment + Data([0xAB, 0xCD])))
        )

        // The pending attestation is kept beside it: which calendar delivered the
        // path is the operational fact ADR 0004's three-chances argument is about.
        #expect(proof.pending(from: submittedDigest).count == 1)

        // And it all survives the file.
        let file = try OpenTimestamps.writeDetached(digest: submittedDigest, timestamp: proof)
        #expect(try OpenTimestamps.readDetached(file).timestamp.bitcoin(from: submittedDigest)
            .first?.height == 912_345)
    }

    @Test("Grafting at a value the proof never reaches changes nothing")
    func aGraftMustFindItsCommitment() throws {
        var proof = try parse(calendarResponse)
        let before = proof
        let grafted = proof.graft(
            OTSTimestamp(attestations: [.bitcoin(1)]),
            at: Data(repeating: 0xEE, count: 32),
            from: submittedDigest
        )
        #expect(!grafted)
        #expect(proof == before)
    }

    // MARK: What it refuses to guess at

    /// RIPEMD-160 and Keccak-256 are not in CryptoKit and are deliberately not
    /// hand-rolled — a hand-written hash on the path that decides whether a
    /// record is anchored is the wrong place to be original. A branch behind one
    /// is **reported**, never assumed good, and the proof is still read in full
    /// and re-emitted unchanged.
    @Test("An operation this build cannot compute is reported, and the proof survives it")
    func anUnknownOperationIsReportedRatherThanGuessed() throws {
        let bytes = Data([0x03]) + bitcoinAttestationBytes(height: 700_000)
        let proof = try parse(bytes)
        let digest = Data(repeating: 0x01, count: 32)

        #expect(proof.unreplayable(from: digest) == ["ripemd160"])
        #expect(proof.bitcoin(from: digest).isEmpty)

        // Lossless: the bytes come back out, so a proof written by a newer or
        // different client is never destroyed by this one reading it.
        let file = try OpenTimestamps.writeDetached(digest: digest, timestamp: proof)
        #expect(try OpenTimestamps.readDetached(file).timestamp == proof)
    }

    @Test("A truncated proof throws rather than trapping")
    func aTruncatedProofThrows() {
        var reader = ByteReader(Data(calendarResponse.prefix(40)))
        #expect(throws: OTSError.truncated) { _ = try OTSTimestamp(reading: &reader) }
    }
}

extension Data {
    /// A fixture written as hex, because a captured wire response is bytes and
    /// pasting it as anything else would be pasting an interpretation of it.
    fileprivate init(hexEncoded hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                fatalError("test fixture is not hex")
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
