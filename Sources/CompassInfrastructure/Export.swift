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
/// **What a week-1 bundle actually contains, and why the rest is missing.** Only
/// artifacts belonging to features that exist are written. `events.jsonl`,
/// `habits.json` and `manifest.json` always. `awards.jsonl`,
/// `attestations.jsonl` and `rules/` are copied **if present**, so the day the
/// week-3 engine writes them they are in the bundle with no change here.
/// `publickey.pem`, `proofs/*.ots` and `salts.json` are derived from a signer, a
/// calendar and a token that do not exist before weeks 3, 4 and the chain limb
/// respectively; writing empty placeholders for them would be worse than
/// omitting them, because a placeholder is indistinguishable from a real file
/// that lost its contents.
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

        // Copied if present. Nothing here writes them yet — weeks 3 and 4 do.
        for (name, source) in [
            (BundleFile.awards, layout.awards),
            (BundleFile.attestations, layout.attestations),
        ] {
            guard let data = try Data(contentsOfIfExists: source) else { continue }
            digests[name] = try write(data, to: destination, named: name)
        }
        for (name, data) in try filesInDirectory(layout.rules, prefixedWith: BundleFile.rules) {
            digests[name] = try write(data, to: destination, named: name)
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

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Sorted keys, no whitespace, no escaped slashes — so two exports of the
    /// same state produce the same bytes and therefore the same digest.
    static func canonicalJSON(_ value: some Encodable) throws -> Data {
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
    public static let rules = "rules"
    public static let habits = "habits.json"
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
