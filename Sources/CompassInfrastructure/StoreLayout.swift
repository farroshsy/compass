import Foundation

/// The single place in the codebase where a file path is constructed.
/// `docs/technical.md` §6, ADR 0002 §2, `.claude/skills/architecture.md`.
///
/// Every path obtains its base URL from one injected `storeURL`. That is the
/// whole requirement, and it is what makes switching from `.documentDirectory`
/// to `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` one
/// line plus a file move — which MUST happen before the widget ships in week 2,
/// because a widget cannot read a container it has no access to.
///
/// The layout mirrors `docs/technical.md` §6 exactly:
///
/// ```
/// Group/
///   events.jsonl        append-only, per-writer chained — the only truth
///   awards.jsonl        append-only: achievement and revocation records
///   attestations.jsonl  append-only, last-write-wins per achievement ID
///   rules/*.json        bundle + user directory, hot-reloadable
///   snapshot.json       cache. Deletable. Never the source of anything.
/// ```
///
/// Only ``events`` is written in week 1; the rest are named here so that the one
/// place paths are built stays the one place when weeks 3 and 4 arrive.
public struct StoreLayout: Hashable, Sendable {

    /// The injected base. Nothing below is constructed from anything else.
    public let storeURL: URL

    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    /// Irreplaceable, tier 1. The only truth. `docs/technical.md` §6.
    public var events: URL { storeURL.appendingPathComponent("events.jsonl") }

    /// Irreplaceable, tier 1. Written from week 3.
    public var awards: URL { storeURL.appendingPathComponent("awards.jsonl") }

    /// Irreplaceable in part — `otsProof`, `signature`, `publicKey` and `chain`
    /// are not recomputable. Written from week 4.
    public var attestations: URL { storeURL.appendingPathComponent("attestations.jsonl") }

    /// The weekly log-head anchors. `docs/adr/0004`, week 4.
    ///
    /// Irreplaceable in part, on exactly the same grounds as ``attestations``:
    /// the heads are recomputable from the log, and the **proof over them is
    /// not**. Re-submitting a discarded anchor gets a strictly later Bitcoin
    /// timestamp, which destroys the one property the anchor exists to provide.
    ///
    /// It is its own file rather than a shape inside `attestations.jsonl`
    /// because that file is keyed by `AchievementID` and a log head is not an
    /// achievement — putting one in there would mint a fake achievement
    /// identifier to file it under.
    public var anchors: URL { storeURL.appendingPathComponent("anchors.jsonl") }

    /// Rule JSON, hot-reloadable. Written from week 3.
    public var rules: URL { storeURL.appendingPathComponent("rules", isDirectory: true) }

    /// Disposable. Delete freely; the replay always wins.
    public var snapshot: URL { storeURL.appendingPathComponent("snapshot.json") }

    /// The log as it stood before the one-time `reproject` hatch computed
    /// `content_hash` and `prev` for the first time. `docs/technical.md` §11.
    ///
    /// Irreplaceable while it exists, and never overwritten once written: it is
    /// the only copy of what week 1a actually recorded, and the hatch that
    /// creates it is the single operation in this codebase that rewrites the
    /// only truth.
    public var preChainEvents: URL {
        storeURL.appendingPathComponent("events.jsonl.pre-chain")
    }

    /// Where one writer's `DeviceID` is remembered.
    ///
    /// **Device means writer, not phone.** The app process and the widget
    /// process are two writers with two UUIDs, two `lamport` sequences and two
    /// `prev` chains, so the identity file is per writer name.
    /// `docs/technical.md` §3 and §4.
    public func writerIdentity(_ writer: String) -> URL {
        storeURL.appendingPathComponent("writer-\(writer).id")
    }

    /// Creates the container if it is not there yet, and applies the data
    /// protection class from `docs/technical.md` §6.
    ///
    /// `NSFileProtectionCompleteUntilFirstUserAuthentication` is the strongest
    /// class compatible with a widget that renders on a locked screen. The
    /// consequence is stated rather than hidden: after the first unlock
    /// following a reboot, anyone holding the unlocked phone gets the whole
    /// diary in plain text.
    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: storeURL, withIntermediateDirectories: true
        )

        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: storeURL.path
        )
        #endif
    }
}
