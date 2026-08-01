import CryptoKit
import Foundation

/// The OpenTimestamps proof format, read and written by hand.
/// `docs/adr/0004`, `docs/achievement-protocol.md` §7.1.
///
/// **Why this file exists at all.** ADR 0004 requires submitting every digest to
/// **all three** calendars rather than taking the first success, and requires
/// persisting every pending proof — and it is emphatic that a fresh submission
/// is not a proof: it is a promise that a calendar will aggregate the digest,
/// and it becomes worth something only after that calendar upgrades it with the
/// Bitcoin path. Both halves need the format itself: three responses have to be
/// held in one artifact, and an upgrade has to be asked for by the exact
/// intermediate value a calendar is waiting on.
///
/// The inherited `Calendars.anchor(_:)` returned "the first proof a calendar
/// returns" and threw the other two away, so none of that was reachable. See
/// ``Calendars`` for that fix.
///
/// ### The format, in one paragraph
///
/// A proof is a **tree**. The root is a message — for Compass, a SHA-256 digest.
/// Each edge is an operation (append these bytes, prepend those, hash the
/// result), and each leaf is an attestation about the message that the path of
/// operations produces. A `pending` attestation names a calendar that has
/// promised to include that value. A `bitcoin` attestation says that value is
/// the merkle root of a stated block. Verification is replaying the operations
/// and looking at what you arrive at — which is exactly what the standalone
/// verifier in `verifier/` does, independently, in Python.
///
/// ### One deliberate difference from the reference client
///
/// An upgraded branch is **grafted beside** its pending attestation rather than
/// replacing it. The reference client drops the pending attestation once the
/// Bitcoin path arrives. Keeping it costs a few dozen bytes and preserves which
/// calendar delivered the path, which is the operational fact ADR 0004's
/// "three independent chances" is about. Nothing reads a pending attestation as
/// evidence: `docs/achievement-protocol.md` §7.1 makes `confirmed` the only
/// state anchoring language may be rendered in, and only a Bitcoin attestation
/// produces it.
public enum OpenTimestamps {

    /// `\0OpenTimestamps\0\0Proof\0\xbf\x89\xe2\xe8\x84\xe8\x92\x94` — the 31
    /// magic bytes every detached `.ots` file starts with.
    static let magic = Data([
        0x00, 0x4F, 0x70, 0x65, 0x6E, 0x54, 0x69, 0x6D, 0x65, 0x73, 0x74, 0x61, 0x6D, 0x70,
        0x73, 0x00, 0x00, 0x50, 0x72, 0x6F, 0x6F, 0x66, 0x00, 0xBF, 0x89, 0xE2, 0xE8, 0x84,
        0xE8, 0x92, 0x94,
    ])

    static let majorVersion = 1

    /// The operation tag for "the file was hashed with SHA-256". Compass only
    /// ever stamps a SHA-256 digest, so it is the only one written.
    static let sha256Tag: UInt8 = 0x08

    /// Reads a detached proof file: magic, version, the file-hash operation and
    /// its digest, then the timestamp over that digest.
    public static func readDetached(_ data: Data) throws -> (digest: Data, timestamp: OTSTimestamp) {
        // The prefix is checked before the cursor is even built, so that a file
        // which is not a proof says so rather than reporting itself truncated.
        // "This is not an OpenTimestamps file" and "this proof is damaged" are
        // different sentences to the person holding the bundle.
        guard data.count >= magic.count, Data(data.prefix(magic.count)) == magic else {
            throw OTSError.notAProof
        }
        var reader = ByteReader(data)
        _ = try reader.take(magic.count)
        _ = try reader.varuint()
        guard try reader.byte() == sha256Tag else { throw OTSError.unsupportedFileHash }
        let digest = try reader.take(32)
        return (digest, try OTSTimestamp(reading: &reader))
    }

    /// Writes a detached proof file for `digest`.
    public static func writeDetached(digest: Data, timestamp: OTSTimestamp) throws -> Data {
        guard digest.count == 32 else { throw OTSError.badDigest }
        var out = magic
        ByteWriter.appendVaruint(majorVersion, to: &out)
        out.append(sha256Tag)
        out.append(digest)
        out.append(try timestamp.serialized())
        return out
    }
}

// MARK: - The tree

/// One node: what this message is attested by, and what it can be transformed
/// into.
public struct OTSTimestamp: Hashable, Sendable {

    public var attestations: [OTSAttestation]
    public var branches: [OTSBranch]

    public init(attestations: [OTSAttestation] = [], branches: [OTSBranch] = []) {
        self.attestations = attestations
        self.branches = branches
    }

    /// Every calendar still only *promising*, with the exact value it promised
    /// about. That value is what an upgrade request asks for, and it is why the
    /// operations have to be replayed rather than skipped.
    public func pending(from message: Data) -> [(calendar: String, commitment: Data)] {
        var out: [(String, Data)] = []
        walk(from: message) { node, value in
            for attestation in node.attestations {
                if case .pending(let uri) = attestation { out.append((uri, value)) }
            }
        }
        return out
    }

    /// Every Bitcoin attestation, with the merkle root the operations arrive at.
    ///
    /// **This is the only thing in the format that is a proof.** Everything else
    /// is a promise.
    public func bitcoin(from message: Data) -> [(height: Int, merkleRoot: Data)] {
        var out: [(Int, Data)] = []
        walk(from: message) { node, value in
            for attestation in node.attestations {
                if case .bitcoin(let height) = attestation { out.append((height, value)) }
            }
        }
        return out
    }

    /// Operations this build cannot compute, reported rather than skipped
    /// silently. A branch behind one of these is unverifiable here, and both
    /// this file and the standalone verifier say so out loud.
    public func unreplayable(from message: Data) -> [String] {
        var out: [String] = []
        collectUnreplayable(from: message, into: &out)
        return out
    }

    private func collectUnreplayable(from message: Data, into out: inout [String]) {
        for branch in branches {
            guard let next = branch.operation.apply(to: message) else {
                out.append(branch.operation.name)
                continue
            }
            branch.timestamp.collectUnreplayable(from: next, into: &out)
        }
    }

    private func walk(from message: Data, _ visit: (OTSTimestamp, Data) -> Void) {
        visit(self, message)
        for branch in branches {
            guard let next = branch.operation.apply(to: message) else { continue }
            branch.timestamp.walk(from: next, visit)
        }
    }

    /// Merges another timestamp over the same message into this one.
    ///
    /// This is how three calendars become one artifact, and how an upgrade is
    /// grafted onto the node the calendar was waiting on. It is a union: nothing
    /// a proof already carried is ever dropped, because a proof is the one thing
    /// in this system that cannot be recomputed — a resubmitted digest gets a
    /// strictly later Bitcoin timestamp, which destroys the "it is not
    /// backdated" property that is the entire argument for anchoring.
    /// `docs/technical.md` §6, tier "irreplaceable in part".
    public mutating func merge(_ other: OTSTimestamp) {
        for attestation in other.attestations where !attestations.contains(attestation) {
            attestations.append(attestation)
        }
        for branch in other.branches {
            if let index = branches.firstIndex(where: { $0.operation == branch.operation }) {
                branches[index].timestamp.merge(branch.timestamp)
            } else {
                branches.append(branch)
            }
        }
    }

    /// Merges `upgrade` into whichever node the operations from `message` reach
    /// the value `commitment`. Returns whether it found one.
    @discardableResult
    public mutating func graft(
        _ upgrade: OTSTimestamp, at commitment: Data, from message: Data
    ) -> Bool {
        if message == commitment {
            merge(upgrade)
            return true
        }
        var grafted = false
        for index in branches.indices {
            guard let next = branches[index].operation.apply(to: message) else { continue }
            if branches[index].timestamp.graft(upgrade, at: commitment, from: next) {
                grafted = true
            }
        }
        return grafted
    }
}

/// One operation and the node it leads to.
public struct OTSBranch: Hashable, Sendable {
    public let operation: OTSOperation
    public var timestamp: OTSTimestamp

    public init(operation: OTSOperation, timestamp: OTSTimestamp) {
        self.operation = operation
        self.timestamp = timestamp
    }
}

/// The transformations a proof is allowed to contain.
public enum OTSOperation: Hashable, Sendable {
    case append(Data)
    case prepend(Data)
    case reverse
    case hexlify
    case sha1
    case ripemd160
    case sha256
    case keccak256

    var name: String {
        switch self {
        case .append: "append"
        case .prepend: "prepend"
        case .reverse: "reverse"
        case .hexlify: "hexlify"
        case .sha1: "sha1"
        case .ripemd160: "ripemd160"
        case .sha256: "sha256"
        case .keccak256: "keccak256"
        }
    }

    /// The new message, or `nil` when this build cannot compute it.
    ///
    /// RIPEMD-160 and Keccak-256 are not in CryptoKit and are **not** hand-rolled
    /// here: `PROJECT_CONSTITUTION.md` §5 prefers mature technology over novelty,
    /// and a hand-written hash on the path that decides whether a record is
    /// anchored is exactly the wrong place to be original. Calendars aggregate
    /// with SHA-256, so no Compass proof has ever contained one — and if one ever
    /// does, that branch is reported unverifiable rather than assumed good.
    func apply(to message: Data) -> Data? {
        switch self {
        case .append(let suffix): message + suffix
        case .prepend(let prefix): prefix + message
        case .reverse: Data(message.reversed())
        case .hexlify: Data(message.map { String(format: "%02x", $0) }.joined().utf8)
        case .sha1: Data(Insecure.SHA1.hash(data: message))
        case .sha256: Data(SHA256.hash(data: message))
        case .ripemd160, .keccak256: nil
        }
    }
}

/// What a proof can say about a message.
public enum OTSAttestation: Hashable, Sendable {

    /// A calendar has promised to aggregate this value. **Not a proof.**
    case pending(String)

    /// This value is the merkle root of the block at this height. The only
    /// attestation `AnchorState.confirmed` may be derived from.
    case bitcoin(Int)

    /// An attestation type this build does not know. Kept verbatim and
    /// re-emitted, never dropped — the same rule the event log applies to
    /// unknown fields.
    case unknown(tag: Data, payload: Data)

    static let pendingTag = Data([0x83, 0xDF, 0xE3, 0x0D, 0x2E, 0xF9, 0x0C, 0x8E])
    static let bitcoinTag = Data([0x05, 0x88, 0x96, 0x0D, 0x73, 0xD7, 0x19, 0x01])
}

// MARK: - Serialisation

extension OTSTimestamp {

    /// The reference serialisation: `0xff` separates steps, `0x00` introduces an
    /// attestation, and the final step carries no separator.
    ///
    /// Attestations and branches are emitted in **byte order of their own
    /// encoding**, so two runs over one proof produce one file. The reference
    /// client sorts by its own object ordering; any deterministic order parses
    /// identically, and this one is a property of the bytes rather than of a
    /// language's collation.
    func serialized() throws -> Data {
        let sortedAttestations = try attestations
            .map { ($0, try $0.serialized()) }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
            .map(\.1)
        let sortedBranches = branches
            .map { ($0, $0.operation.serialized()) }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }

        guard !sortedAttestations.isEmpty || !sortedBranches.isEmpty else {
            throw OTSError.emptyTimestamp
        }

        var out = Data()
        for attestation in sortedAttestations.dropLast() {
            out.append(contentsOf: [0xFF, 0x00])
            out.append(attestation)
        }

        if sortedBranches.isEmpty {
            out.append(0x00)
            out.append(sortedAttestations[sortedAttestations.count - 1])
            return out
        }

        if let last = sortedAttestations.last {
            out.append(contentsOf: [0xFF, 0x00])
            out.append(last)
        }
        for (branch, encoded) in sortedBranches.dropLast() {
            out.append(0xFF)
            out.append(encoded)
            out.append(try branch.timestamp.serialized())
        }
        let (branch, encoded) = sortedBranches[sortedBranches.count - 1]
        out.append(encoded)
        out.append(try branch.timestamp.serialized())
        return out
    }

    /// The mirror. **Nothing is applied while parsing**, deliberately: a proof
    /// carrying an operation this build cannot compute is still read in full and
    /// re-emitted unchanged, rather than truncated at the first byte it does not
    /// like. Messages are computed later, by whoever needs them.
    public init(reading reader: inout ByteReader) throws {
        var attestations: [OTSAttestation] = []
        var branches: [OTSBranch] = []

        func step(_ tag: UInt8) throws {
            if tag == 0x00 {
                attestations.append(try OTSAttestation(reading: &reader))
            } else {
                let operation = try OTSOperation(tag: tag, reading: &reader)
                branches.append(
                    OTSBranch(operation: operation, timestamp: try OTSTimestamp(reading: &reader))
                )
            }
        }

        var tag = try reader.byte()
        while tag == 0xFF {
            try step(try reader.byte())
            tag = try reader.byte()
        }
        try step(tag)

        self.init(attestations: attestations, branches: branches)
    }
}

extension OTSOperation {

    func serialized() -> Data {
        switch self {
        case .append(let argument): Data([0xF0]) + OTSOperation.varbytes(argument)
        case .prepend(let argument): Data([0xF1]) + OTSOperation.varbytes(argument)
        case .reverse: Data([0xF2])
        case .hexlify: Data([0xF3])
        case .sha1: Data([0x02])
        case .ripemd160: Data([0x03])
        case .sha256: Data([0x08])
        case .keccak256: Data([0x67])
        }
    }

    init(tag: UInt8, reading reader: inout ByteReader) throws {
        switch tag {
        case 0xF0: self = .append(try reader.varbytes())
        case 0xF1: self = .prepend(try reader.varbytes())
        case 0xF2: self = .reverse
        case 0xF3: self = .hexlify
        case 0x02: self = .sha1
        case 0x03: self = .ripemd160
        case 0x08: self = .sha256
        case 0x67: self = .keccak256
        default: throw OTSError.unknownOperation(tag: tag)
        }
    }

    private static func varbytes(_ data: Data) -> Data {
        var out = Data()
        ByteWriter.appendVaruint(data.count, to: &out)
        out.append(data)
        return out
    }
}

extension OTSAttestation {

    func serialized() throws -> Data {
        var payload = Data()
        var tag: Data
        switch self {
        case .pending(let uri):
            tag = OTSAttestation.pendingTag
            let encoded = Data(uri.utf8)
            ByteWriter.appendVaruint(encoded.count, to: &payload)
            payload.append(encoded)
        case .bitcoin(let height):
            tag = OTSAttestation.bitcoinTag
            ByteWriter.appendVaruint(height, to: &payload)
        case .unknown(let unknownTag, let unknownPayload):
            tag = unknownTag
            payload = unknownPayload
        }
        var out = tag
        ByteWriter.appendVaruint(payload.count, to: &out)
        out.append(payload)
        return out
    }

    init(reading reader: inout ByteReader) throws {
        let tag = try reader.take(8)
        let payload = try reader.varbytes()
        var inner = ByteReader(payload)
        switch tag {
        case OTSAttestation.pendingTag:
            let uri = try inner.varbytes()
            self = .pending(String(decoding: uri, as: UTF8.self))
        case OTSAttestation.bitcoinTag:
            self = .bitcoin(try inner.varuint())
        default:
            self = .unknown(tag: tag, payload: payload)
        }
    }
}

// MARK: - Bytes

/// A cursor over a proof. It throws rather than trapping on a short read: a
/// proof can arrive from a calendar, and a calendar is somebody else's server.
public struct ByteReader {
    private let data: Data
    private var index: Data.Index

    public init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func byte() throws -> UInt8 {
        guard index < data.endIndex else { throw OTSError.truncated }
        defer { index = data.index(after: index) }
        return data[index]
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else {
            throw OTSError.truncated
        }
        let end = data.index(index, offsetBy: count)
        defer { index = end }
        return Data(data[index..<end])
    }

    /// Base-128, least significant group first, high bit as the continuation
    /// flag. The bound stops a hostile proof from asking for a 2 GB allocation.
    mutating func varuint() throws -> Int {
        var value = 0
        var shift = 0
        while true {
            let byte = try self.byte()
            guard shift < 56 else { throw OTSError.malformedVaruint }
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    mutating func varbytes() throws -> Data {
        try take(try varuint())
    }
}

enum ByteWriter {
    /// Base-128, least significant group first. **Non-negative only**, and the
    /// clamp is not defensive politeness: `>>=` on a negative `Int` is an
    /// arithmetic shift that never reaches zero, so a negative value here would
    /// be an infinite loop rather than a wrong byte. Nothing can produce one —
    /// every value written is a length or a block height, and a parsed varuint is
    /// non-negative by construction — which is exactly why a future change that
    /// did would be hard to see.
    static func appendVaruint(_ value: Int, to out: inout Data) {
        var remaining = max(0, value)
        if remaining == 0 {
            out.append(0)
            return
        }
        while remaining != 0 {
            var byte = UInt8(remaining & 0x7F)
            if remaining > 0x7F { byte |= 0x80 }
            out.append(byte)
            remaining >>= 7
        }
    }
}

public enum OTSError: Error, Hashable, Sendable {
    case notAProof
    case unsupportedFileHash
    case badDigest
    case truncated
    case malformedVaruint
    case emptyTimestamp
    case unknownOperation(tag: UInt8)
}
