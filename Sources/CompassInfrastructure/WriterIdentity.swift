import CompassDomain
import Foundation

/// Reads, and on first use creates, the ``DeviceID`` of one writer.
/// `docs/technical.md` §3, `.claude/skills/architecture.md`.
///
/// The value is a **randomly generated 128-bit UUID** and nothing else, ever. It
/// MUST NOT be `identifierForVendor`, a keychain-persisted hardware-adjacent
/// value, an Apple ID, the device name, or anything derived from any of those:
/// it is signed, anchored, and present inside every exported achievement handed
/// to a stranger via `witness.logHeads`. "Farros's iPhone" inside a signed record
/// handed to a recruiter is the failure being designed out. It is never
/// displayed in the UI.
///
/// **Device means writer, not phone.** The app process and the widget process on
/// one phone are two writers, so each gets its own identity file, its own
/// `lamport` sequence and its own `prev` chain. `docs/technical.md` §4.
public struct WriterIdentity: Sendable {

    /// The app process.
    public static let app = "app"

    /// **The widget process — the second writer, shipped with the widget in week
    /// 2 rather than after it.** `docs/technical.md` §4.
    ///
    /// It is a *name*, not an identity: the identity is the UUID minted behind
    /// it, in this store, on this writer's first write. Two names mean two files
    /// (``StoreLayout/writerIdentity(_:)``), two UUIDs, two `lamport` sequences
    /// and two `prev` chains — which is what `witness.logHeads` is shaped for and
    /// what ADR 0002 chose over one global chain, precisely because concurrent
    /// appenders fork a global one.
    ///
    /// The name must never be reused for a third writer and must never be
    /// changed: changing it mints a fresh UUID, which restarts a `lamport`
    /// sequence at 1 and a chain at genesis while the old chain's head is still
    /// under every `logHeads` ever written.
    public static let widget = "widget"

    private let layout: StoreLayout
    private let url: URL

    public init(layout: StoreLayout, writer: String = WriterIdentity.app) {
        self.layout = layout
        self.url = layout.writerIdentity(writer)
    }

    /// The stored identity, minting and persisting one on first use.
    ///
    /// A stored value is returned verbatim — never regenerated, never
    /// normalised. Regenerating it would fork this writer's `lamport` sequence
    /// and its chain, which is exactly what the per-writer design exists to
    /// prevent.
    ///
    /// The container is prepared before the mint is written. This is a writer's
    /// **first** touch of the store — earlier than the journal's, because the
    /// journal needs the identity to open — so it cannot assume someone else has
    /// already created the directory. On a genuinely fresh install nobody has,
    /// and the same is true of the widget process in week 2.
    ///
    /// ### The mint is taken under the advisory `flock`, and the read is not
    ///
    /// A writer *name* is not a process. The app has exactly one process, but iOS
    /// may run several widget extension instances at once, and every one of them
    /// is `WriterIdentity.widget` — so on the first press after an install, two
    /// processes can reach the mint together. Left unlocked they each generate a
    /// UUID, each write it, and one file survives: the loser then records under a
    /// `device` that no later launch will ever recover, so a phone grows a third
    /// writer that existed for one press and appears forever in the `logHeads` of
    /// every achievement sealed afterwards. Nothing is corrupted — per-writer
    /// chains verify independently, which is exactly why this is worth a lock
    /// rather than a panic — but a signed record should not carry a writer that
    /// was an accident.
    ///
    /// So the mint happens under the same cross-process lock
    /// `docs/technical.md` §4 already specifies for read-then-write, and the
    /// existence check is repeated inside it because another process may have
    /// minted between the two.
    ///
    /// The **fast path takes no lock at all**: once the file exists this is one
    /// read, which is what every launch after the first does.
    public func load() throws -> DeviceID {
        if let stored = stored() { return stored }

        try layout.prepare()
        return try EventJournal.withExclusiveLock(onFileAt: layout.events) {
            if let stored = stored() { return stored }
            let minted = UUID().uuidString
            try Data(minted.utf8).write(to: url, options: .atomic)
            return DeviceID(rawValue: minted)
        }
    }

    /// The identity already on disk, or `nil`. Returned verbatim — never
    /// regenerated, never normalised.
    private func stored() -> DeviceID? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : DeviceID(rawValue: trimmed)
    }
}
