import CompassDomain
import Foundation

/// The one-time `reproject` hatch. `docs/technical.md` §11.
///
/// > **Before the first signature is ever computed, the log may be replayed once
/// > into a freshly chained log — same events, same order, `content_hash` and
/// > `prev` computed for the first time. The old file is kept as
/// > `events.jsonl.pre-chain`.**
///
/// This exists because week 1a shipped a working tap loop before the canonical
/// encoding existed, so every event it wrote carries `prev = genesis`. §11 is
/// explicit about why that ordering was chosen and what it costs: putting an
/// irreversible cryptographic commitment at item three of day one, for an author
/// with 58 repositories that died on their creation day, is the highest-risk
/// possible ordering. The hatch is what makes the split safe.
///
/// **It closes permanently the moment anything is signed**, which cannot happen
/// before week 3. After that the encoding is irreversible in the full sense and
/// `docs/technical.md` §3 governs without exception — so the check for a
/// signature is here, in code, rather than left as a sentence in a document
/// somebody has to remember to read.
///
/// ### What it refuses to do
///
/// It never touches a line it cannot decode. A rewrite is the one operation in
/// this codebase that can destroy data, `docs/technical.md` §3 makes `payload`
/// closed so an event from a newer build is undecodable **by design**, and
/// rewriting the file without it would drop a real event that a real writer
/// really wrote. So a damaged log is reported and left exactly as it is, which
/// leaves the app in the week-1a state it was already in rather than in a
/// smaller one.
public struct Reprojector: Sendable {

    public let layout: StoreLayout

    public init(layout: StoreLayout) {
        self.layout = layout
    }

    /// Replays the log into a freshly chained one, if it needs it and is allowed
    /// to.
    ///
    /// Idempotent by construction rather than by a flag: once it has run, the
    /// chain verifies, and a log whose chain verifies is ``ReprojectOutcome/notNeeded``.
    /// There is no "have I done this" bit to get wrong, and no state that can
    /// disagree with the file.
    @discardableResult
    public func reprojectIfNeeded() throws -> ReprojectOutcome {
        try EventJournal.withExclusiveLock(onFileAt: layout.events) {
            let read = try JournalReader(url: layout.events).read()

            // An empty log and an already-chained log are the same answer.
            guard !read.chain.isIntact else { return .notNeeded }

            guard read.damagedLines.isEmpty else {
                return .refusedDamaged(lines: read.damagedLines)
            }
            guard !hasBeenSealed else { return .refusedSealed }

            // **Exactly once**, and this is where that is enforced rather than
            // asserted. `docs/technical.md` §11: "This hatch may be used exactly
            // once." An already-chained log makes it a no-op, which covers the
            // ordinary second launch — but a log whose chain breaks *later*, for
            // any reason, would otherwise walk straight back in here and rewrite
            // every `prev` in the file. That is the hatch running a second time,
            // and it is not what the escape clause bought.
            //
            // The pre-chain file is the record of the first use, and its
            // contents distinguish the only two cases that matter:
            //
            // - identical to the live log — a previous attempt died between the
            //   copy and the swap. Nothing has been rewritten yet, so finishing
            //   it is the *same* use, not a second one.
            // - different — the hatch has been used. Refuse.
            //
            // The insurance therefore goes down **before** anything is replaced,
            // and this is the one decision rather than two:
            switch try? Data(contentsOf: layout.preChainEvents) {
            case .none:
                try FileManager.default.copyItem(at: layout.events, to: layout.preChainEvents)
            case .some(let copy) where copy == (try Data(contentsOf: layout.events)):
                break
            case .some:
                return .refusedAlreadyUsed
            }

            let rechained = try chain(read.events)
            var body = Data()
            for event in rechained {
                body.append(try Reprojector.line(event))
            }

            let staging = layout.storeURL.appendingPathComponent("events.jsonl.rechaining")
            try body.write(to: staging, options: .atomic)
            _ = try FileManager.default.replaceItemAt(layout.events, withItemAt: staging)

            return .rechained(events: rechained.count)
        }
    }

    /// Whether anything has been signed. The hatch closes here, permanently.
    ///
    /// `attestations.jsonl` is where signatures live
    /// (`docs/achievement-protocol.md` §7) and it is
    /// `docs/technical.md` §6's "irreplaceable in part" tier — a signature is
    /// unrecomputable once the enclave key is gone. If one exists, a `prev` this
    /// code recomputed would move a `content_hash` that a signature and possibly
    /// a Bitcoin anchor already committed to.
    private var hasBeenSealed: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: layout.attestations.path
        ) else { return false }
        return (attributes[.size] as? Int ?? 0) > 0
    }

    /// Links the events into per-writer chains, in their existing order.
    ///
    /// **Same events, same order.** The only field that changes is `prev`, and
    /// on a week-1a log every one of them is genesis — so this is the first time
    /// a link is computed, not a second time.
    private func chain(_ events: [Event]) throws -> [Event] {
        var heads: [DeviceID: Data] = [:]
        var result: [Event] = []
        result.reserveCapacity(events.count)

        // The total order, not the file order. A log written by two writers
        // interleaves them, and each chain is that writer's own sequence.
        for event in events.sorted(by: { $0.order < $1.order }) {
            let linked = event.chained(to: heads[event.device] ?? EventChain.genesis)
            heads[linked.device] = try linked.contentHash
            result.append(linked)
        }
        return result
    }

    /// One JSON Lines record, terminated. The same encoder the journal appends
    /// with, for the same reason: the stored line is not the canonical form and
    /// nothing may be derived from its byte layout.
    private static func line(_ event: Event) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var line = try encoder.encode(event)
        guard !line.contains(0x0A) else { throw JournalError.embeddedNewline }
        line.append(0x0A)
        return line
    }
}

/// What the hatch did, said out loud rather than returned as a `Bool`.
///
/// The two refusals are the interesting values and they are different
/// conditions: one is recoverable and one is permanent. Collapsing them into
/// "did not run" is how a permanently unchained log gets mistaken for a
/// transient failure.
public enum ReprojectOutcome: Hashable, Sendable {

    /// The chain already verifies. An empty log, or one that has already been
    /// through here.
    case notNeeded

    /// The log was replayed into a freshly chained one, and the original is at
    /// `events.jsonl.pre-chain`.
    case rechained(events: Int)

    /// The log holds lines this build cannot decode, so rewriting it would drop
    /// a real event. Recoverable: fix or remove the lines and the hatch is still
    /// open.
    case refusedDamaged(lines: [Int])

    /// Something has been signed. The hatch is closed and stays closed.
    /// `docs/technical.md` §11.
    case refusedSealed

    /// The hatch has already been used: `events.jsonl.pre-chain` records a
    /// different log from the one on disk. Whatever broke the chain since then
    /// is real damage to be reported, not a second `prev` computation to be run.
    /// `docs/technical.md` §11: "exactly once".
    case refusedAlreadyUsed
}
