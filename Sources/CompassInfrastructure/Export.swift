import CompassDomain
import CryptoKit
import Foundation

/// Export, and the import that makes it worth having. `docs/technical.md` §8 and
/// §10a, `docs/product.md`, ADR 0002. Scheduled for **week 1**: it is the
/// insurance policy that turns any future rewrite into a re-projection instead
/// of a reset.
///
/// **Export is a bundle, not a log dump.** An earlier form of the corpus defined
/// it as "newline-delimited canonical JSON of the whole log" while
/// simultaneously claiming it preserved achievements and Bitcoin proofs — which
/// live in `awards.jsonl` and `attestations.jsonl` and were therefore in neither
/// the definition nor the file. Someone who followed the documents exactly,
/// exported weekly, and then dropped their phone in a river lost every signature
/// and every proof.
///
/// The documented bundle is:
///
/// ```
/// events.jsonl              the whole log, one event per line
/// awards.jsonl              every achievement and revocation record
/// attestations.jsonl        signatures, OTS proofs, anchor state, chain records
/// rules/*.json              the rule JSON frozen into each award
/// habits.json               HabitID -> display name, so a name can be revealed
/// publickey.pem             the P-256 public key(s), including rotated ones
/// proofs/*.ots              every OTS proof file, upgraded where available
/// salts.json                per-token commitment salts, if any token was minted
/// manifest.json             per-file SHA-256 digests, plus the export timestamp
/// ```
///
/// **What a bundle actually contains, and why anything is missing.** Only
/// artifacts belonging to features that exist are written. `events.jsonl`,
/// `habits.json` and `manifest.json` always. `awards.jsonl`,
/// `attestations.jsonl`, `anchors.jsonl` and `rules/` are copied **if present**,
/// so the day a week writes one it is in the bundle with no change here.
///
/// `publickey.pem` and `proofs/*.ots` landed in **week 4** and are *derived*
/// rather than copied: the key and the proof bytes live inside
/// `attestations.jsonl` and `anchors.jsonl`, and are written out again in the
/// forms the rest of the world reads. Only `salts.json` is still absent, because
/// no token has ever been minted; writing an empty placeholder would be worse
/// than omitting it, since a placeholder is indistinguishable from a real file
/// that lost its contents.
///
/// **This is what the standalone verifier in `verifier/` is handed.** It shares
/// no code with this file — every byte string it checks is rebuilt from the
/// documents — so the bundle has to be complete rather than merely
/// self-consistent.
public struct Exporter: Sendable {

    public let layout: StoreLayout

    public init(layout: StoreLayout) {
        self.layout = layout
    }

    // MARK: Export

    /// Writes the bundle into `destination`, creating it if needed, and returns
    /// the manifest that was written.
    @discardableResult
    public func export(to destination: URL, at instant: Date) throws -> ExportManifest {
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )

        var digests: [String: String] = [:]

        // The only truth, byte for byte. Always present, even when empty: a
        // bundle whose shape depends on whether anything has been tapped yet is
        // a bundle whose restore path is untested on day one.
        let events = try Data(contentsOfIfExists: layout.events) ?? Data()
        digests[BundleFile.events] = try write(events, to: destination, named: BundleFile.events)

        // Copied if present. `awards.jsonl` and `attestations.jsonl` arrived in
        // week 3, `anchors.jsonl` in week 4.
        for (name, source) in [
            (BundleFile.awards, layout.awards),
            (BundleFile.attestations, layout.attestations),
            (BundleFile.anchors, layout.anchors),
        ] {
            guard let data = try Data(contentsOfIfExists: source) else { continue }
            digests[name] = try write(data, to: destination, named: name)
        }
        for (name, data) in try filesInDirectory(layout.rules, prefixedWith: BundleFile.rules) {
            digests[name] = try write(data, to: destination, named: name)
        }

        // Week 4. Both are **derived** from the two files above rather than
        // copied from the store: a proof lives inside its attestation as bytes,
        // and the public key lives inside it as an X9.63 blob. They are written
        // out separately because §8 lists them separately, and it lists them
        // separately because a `.ots` file is the thing every other
        // OpenTimestamps tool in the world can read, and a `.pem` is the thing
        // every other verifier can read. A bundle whose proofs can only be
        // extracted by code that already understands Compass would be a bundle
        // that still requires trusting Compass.
        for (name, data) in try proofFiles() {
            digests[name] = try write(data, to: destination, named: name)
        }
        if let pem = try publicKeysPEM() {
            digests[BundleFile.publicKey] = try write(
                pem, to: destination, named: BundleFile.publicKey
            )
        }

        // The name is resolved at render time from a mutable local mapping,
        // never from a digest: a habit named after a recovery programme, a
        // medical routine or a therapy task must stay revealable rather than
        // frozen into a signed, anchored, shareable record.
        // `docs/technical.md` §5.
        //
        // Folded out of the *copy just written*, not out of the live store, so a
        // tap landing mid-export cannot put a habit in `habits.json` that is not
        // in the `events.jsonl` beside it.
        let names = try habitNames(loggedAt: destination.appendingPathComponent(BundleFile.events))
        digests[BundleFile.habits] = try write(
            try Exporter.canonicalJSON(names), to: destination, named: BundleFile.habits
        )

        let manifest = ExportManifest(
            exportedAt: Int((instant.timeIntervalSince1970 * 1_000).rounded()), files: digests
        )
        try Exporter.canonicalJSON(manifest).write(
            to: destination.appendingPathComponent(BundleFile.manifest), options: .atomic
        )
        return manifest
    }

    // MARK: Import

    /// Reads a bundle's manifest and checks every digest in it.
    ///
    /// An unexercised escape hatch is not an escape hatch, so the bundle is
    /// verified before it is trusted, not after it has overwritten something.
    @discardableResult
    public func verify(bundleAt bundle: URL) throws -> ExportManifest {
        let manifestURL = bundle.appendingPathComponent(BundleFile.manifest)
        guard let manifestData = try Data(contentsOfIfExists: manifestURL) else {
            throw ExportError.missingManifest
        }
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: manifestData)

        for (name, expected) in manifest.files {
            guard let data = try Data(
                contentsOfIfExists: bundle.appendingPathComponent(name)
            ) else {
                throw ExportError.missingFile(name)
            }
            let actual = Exporter.sha256Hex(data)
            guard actual == expected else {
                throw ExportError.digestMismatch(file: name, expected: expected, actual: actual)
            }
        }
        return manifest
    }

    /// Installs a verified bundle into an **empty** store — a fresh install fed
    /// only the exported bundle.
    ///
    /// Restoring over an existing log is refused rather than merged. Merging two
    /// logs is a set union under `(lamport, device)` and is exactly what sync
    /// will do when a second device exists (`docs/technical.md` §7); doing it
    /// here, silently, on the one path whose job is to rescue data, is how the
    /// rescue destroys what it was called to save.
    public func restore(from bundle: URL) throws {
        let manifest = try verify(bundleAt: bundle)
        try layout.prepare()

        if let existing = try Data(contentsOfIfExists: layout.events), !existing.isEmpty {
            throw ExportError.storeNotEmpty
        }

        for name in manifest.files.keys.sorted() {
            // `habits.json` is a rendering aid derived from the log, so it is
            // not installed as store state; everything else is copied verbatim.
            guard name != BundleFile.habits else { continue }

            let destination = try storePath(forBundleMember: name)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard let data = try Data(
                contentsOfIfExists: bundle.appendingPathComponent(name)
            ) else { continue }
            try data.write(to: destination, options: .atomic)
        }
    }

    /// Where a bundle member lands in the store.
    ///
    /// Known members go through ``StoreLayout``, which is the one place a path
    /// is built. An **unknown** member is still installed, under its own name,
    /// because a bundle written by a newer build may carry files this one has
    /// never heard of and dropping them would be exactly the "never destroy data
    /// you do not understand" failure. A name that tries to leave the store is
    /// refused: a bundle can arrive from a stranger.
    private func storePath(forBundleMember name: String) throws -> URL {
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              !components.contains(".."),
              !components.contains(".")
        else { throw ExportError.unsafeFileName(name) }

        switch name {
        case BundleFile.events: return layout.events
        case BundleFile.awards: return layout.awards
        case BundleFile.attestations: return layout.attestations
        case BundleFile.anchors: return layout.anchors
        default:
            if components.count == 2, components[0] == BundleFile.rules {
                return layout.rules.appendingPathComponent(String(components[1]))
            }
            return layout.storeURL.appendingPathComponent(name)
        }
    }

    // MARK: Pieces

    /// `HabitID` -> display name, folded out of the log. Archived habits are
    /// included: a name must stay resolvable for every ID that ever appears in a
    /// record, and archival does not remove the ID from history.
    private func habitNames(loggedAt url: URL) throws -> [String: String] {
        let projection = project(try JournalReader(url: url).read().events)
        var names: [String: String] = [:]
        for (id, habit) in projection.habits {
            names[id.rawValue] = habit.name
        }
        return names
    }

    /// `proofs/*.ots` — every OpenTimestamps proof, as the detached files the
    /// reference client reads. `docs/technical.md` §8, ADR 0004's fourth
    /// mitigation: "store the upgraded proof in the export bundle".
    ///
    /// Names are the achievement's own identifier, and for a log-head anchor the
    /// first sixteen hex characters of its digest. Both are already opaque —
    /// `docs/achievement-protocol.md` §3.4 keeps display names out of every
    /// identifier for exactly this reason, and a filename travels further than
    /// most fields do.
    private func proofFiles() throws -> [(String, Data)] {
        let store = AwardStore(layout: layout)
        var files: [(String, Data)] = []

        for (id, attestation) in try store.readAttestations().sorted(by: { $0.key < $1.key }) {
            guard let proof = attestation.otsProof, !proof.isEmpty else { continue }
            files.append(("\(BundleFile.proofs)/\(id.rawValue).ots", proof))
        }
        for anchor in try store.readAnchors() {
            guard let proof = anchor.otsProof, !proof.isEmpty else { continue }
            let name = anchor.digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            files.append(("\(BundleFile.proofs)/log-heads-\(name).ots", proof))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    /// `publickey.pem` — the P-256 public key(s), **including rotated ones**.
    ///
    /// Every distinct key that has ever signed something in this store, in the
    /// order it first appears, as SPKI PEM. Plural is not decoration: the enclave
    /// key does not survive device replacement, so a bundle spanning one carries
    /// two unrelated keys — and `docs/technical.md` §8 requires a verifier to
    /// report that case differently rather than to assume continuity.
    private func publicKeysPEM() throws -> Data? {
        var seen: [Data] = []
        for (_, attestation) in try AwardStore(layout: layout)
            .readAttestations()
            .sorted(by: { $0.key < $1.key })
        where !seen.contains(attestation.publicKey) {
            seen.append(attestation.publicKey)
        }
        guard !seen.isEmpty else { return nil }

        let pems = seen.compactMap {
            try? P256.Signing.PublicKey(x963Representation: $0).pemRepresentation
        }
        guard !pems.isEmpty else { return nil }
        return Data(pems.joined(separator: "\n").utf8)
    }

    private func filesInDirectory(
        _ directory: URL, prefixedWith prefix: String
    ) throws -> [(String, Data)] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        return try contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try Data(contentsOfIfExists: url) else { return nil }
                return ("\(prefix)/\(url.lastPathComponent)", data)
            }
    }

    private func write(_ data: Data, to destination: URL, named name: String) throws -> String {
        let url = destination.appendingPathComponent(name)
        if name.contains("/") {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        try data.write(to: url, options: .atomic)
        return Exporter.sha256Hex(data)
    }

    /// Lowercase hex of a file's SHA-256, the form `manifest.json` carries.
    ///
    /// `public` so a test can rebuild a manifest by hand — which is what
    /// `VerifierTests` needs in order to prove that the manifest is **not** the
    /// defence: a forger who rewrites it still fails on the chain and on the
    /// claim.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Sorted keys, no whitespace, no escaped slashes — so two exports of the
    /// same state produce the same bytes and therefore the same digest.
    public static func canonicalJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// The file names in a bundle, in one place, spelled once.
public enum BundleFile {
    public static let events = "events.jsonl"
    public static let awards = "awards.jsonl"
    public static let attestations = "attestations.jsonl"
    /// Week 4. The weekly log-head anchors — ADR 0004.
    public static let anchors = "anchors.jsonl"
    public static let rules = "rules"
    public static let habits = "habits.json"
    /// Week 4. `proofs/*.ots` — detached OpenTimestamps proofs, readable by any
    /// OpenTimestamps client and not only by this one.
    public static let proofs = "proofs"
    /// Week 4. The P-256 public key(s), including rotated ones.
    public static let publicKey = "publickey.pem"
    public static let manifest = "manifest.json"
}

/// `manifest.json`: per-file SHA-256 digests, plus the export timestamp.
/// `docs/technical.md` §8.
///
/// The manifest does not digest itself. `exportedAt` is an integer count of
/// milliseconds since the Unix epoch, for the same reason `Event.recordedAt` is:
/// there is no floating point in a value this project writes down.
public struct ExportManifest: Codable, Hashable, Sendable {
    public let exportedAt: Int
    /// Bundle-relative path -> SHA-256, lowercase hex.
    public let files: [String: String]

    public init(exportedAt: Int, files: [String: String]) {
        self.exportedAt = exportedAt
        self.files = files
    }
}

public enum ExportError: Error, Hashable, Sendable {
    case missingManifest
    case missingFile(String)
    case digestMismatch(file: String, expected: String, actual: String)
    /// Restore targets a fresh install. Merging is sync's job, not rescue's.
    case storeNotEmpty
    /// A manifest entry that would write outside the store.
    case unsafeFileName(String)
}

extension Data {
    /// `nil` when the file is absent, rather than an error. A missing
    /// `awards.jsonl` in week 1 is the normal case, not a failure.
    fileprivate init?(contentsOfIfExists url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self = try Data(contentsOf: url)
    }
}
