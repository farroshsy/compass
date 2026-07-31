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

    /// The app process. The widget adds a second name in week 2.
    public static let app = "app"

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
    public func load() throws -> DeviceID {
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return DeviceID(rawValue: trimmed) }
        }

        try layout.prepare()
        let minted = UUID().uuidString
        try Data(minted.utf8).write(to: url, options: .atomic)
        return DeviceID(rawValue: minted)
    }
}
