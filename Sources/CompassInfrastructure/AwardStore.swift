import CompassDomain
import Darwin
import Foundation

/// `awards.jsonl` and `attestations.jsonl`. `docs/technical.md` §6,
/// `docs/achievement-protocol.md` §7 and §8.
///
/// **They are two files because one of them mutates and the other does not.**
/// An achievement is never mutated and never deleted (Invariant 4); an
/// attestation's `state`, `otsProof` and timestamps change as a proof is
/// submitted, upgraded and confirmed. Separating them is what lets `awards.jsonl`
/// be strictly append-only, which is what makes the tier-1 "irreplaceable"
/// classification in §6 mean something.
///
/// Both are append-only on disk. `attestations.jsonl` is **last-write-wins per
/// achievement ID on read** — a state change appends a new line and the fold
/// keeps the last one, so nothing is ever rewritten in place. That is the same
/// shape as the event log, for the same flash-write reason ADR 0002 gives.
public struct AwardStore: Sendable {

    public let layout: StoreLayout

    public init(layout: StoreLayout) {
        self.layout = layout
    }

    // MARK: awards.jsonl

    /// Every award record, in file order, plus the lines this build could not
    /// read.
    public func readAwards() throws -> AwardLedger {
        let lines = try AwardStore.lines(of: layout.awards)
        let decoder = JSONDecoder()

        var achievements: [Achievement] = []
        var revocations: [Revocation] = []
        var unreadableLines: [Int] = []

        for (index, line) in lines {
            // No discriminator field is invented — see ``AwardRecord``. The two
            // shapes are disjoint on their required keys, so decoding one and
            // then the other is total over the file, and a line that is neither
            // is **counted, never dropped and never rewritten.**
            if let achievement = try? decoder.decode(Achievement.self, from: line) {
                achievements.append(achievement)
            } else if let revocation = try? decoder.decode(Revocation.self, from: line) {
                revocations.append(revocation)
            } else {
                unreadableLines.append(index)
            }
        }

        return AwardLedger(
            achievements: achievements,
            revocations: revocations,
            unreadableLines: unreadableLines
        )
    }

    /// Appends one record. **There is no update and no delete on this file, in
    /// any state, for any reason** — `docs/achievement-protocol.md` §8. A
    /// documented deletion path inside a strictly append-only file gets
    /// implemented as a whole-file rewrite, which is the operation ADR 0002
    /// disqualifies on flash-write grounds and the one most likely to lose the
    /// file on a crash.
    public func append(_ record: AwardRecord) throws {
        switch record {
        case .achievement(let value): try append(encoded: try AwardStore.encoder.encode(value))
        case .revocation(let value): try append(encoded: try AwardStore.encoder.encode(value))
        }
    }

    private func append(encoded: Data) throws {
        try layout.prepare()
        let descriptor = try EventJournal.openForAppend(layout.awards)
        defer { Darwin.close(descriptor) }
        try EventJournal.writeLine(encoded, to: descriptor)
    }

    // MARK: attestations.jsonl

    /// The current attestation per achievement — last line wins.
    public func readAttestations() throws -> [AchievementID: Attestation] {
        let decoder = JSONDecoder()
        var current: [AchievementID: Attestation] = [:]
        for (_, line) in try AwardStore.lines(of: layout.attestations) {
            guard let attestation = try? decoder.decode(Attestation.self, from: line) else {
                continue
            }
            current[attestation.achievement] = attestation
        }
        return current
    }

    /// Appends the attestation's new state. Never rewrites an earlier line: the
    /// file is append-only on disk and last-write-wins on read.
    public func append(_ attestation: Attestation) throws {
        try layout.prepare()
        let descriptor = try EventJournal.openForAppend(layout.attestations)
        defer { Darwin.close(descriptor) }
        try EventJournal.writeLine(try AwardStore.encoder.encode(attestation), to: descriptor)
    }

    /// How many times anchoring this achievement has been recorded as failed.
    ///
    /// **The append-only file is the retry counter.** `docs/achievement-protocol.md`
    /// §7.1 requires exponential backoff and §7's `Attestation` has no field for
    /// an attempt count — and this build does not add fields the protocol does
    /// not have. It does not need one: every state change appends a line, so the
    /// failures are already on disk and counting them is the whole mechanism.
    /// See ``AnchorRetry``.
    public func failureCount(for achievement: AchievementID) throws -> Int {
        let decoder = JSONDecoder()
        return try AwardStore.lines(of: layout.attestations).reduce(into: 0) { count, line in
            guard let value = try? decoder.decode(Attestation.self, from: line.1),
                  value.achievement == achievement, value.state == .failed
            else { return }
            count += 1
        }
    }

    // MARK: anchors.jsonl

    /// Every log-head anchor, folded last-write-wins per digest.
    ///
    /// Same shape and same reason as ``readAttestations()``: an anchor mutates as
    /// its proof is submitted and upgraded, and a state change appends rather
    /// than rewriting.
    public func readAnchors() throws -> [LogAnchor] {
        let decoder = JSONDecoder()
        var current: [Data: LogAnchor] = [:]
        var order: [Data] = []
        for (_, line) in try AwardStore.lines(of: layout.anchors) {
            guard let anchor = try? decoder.decode(LogAnchor.self, from: line) else { continue }
            if current[anchor.digest] == nil { order.append(anchor.digest) }
            current[anchor.digest] = anchor
        }
        return order.compactMap { current[$0] }
    }

    /// The most recently created anchor, or `nil` before anything is anchored.
    /// ``LogAnchorSchedule`` compares against this to decide whether a week is up.
    public func latestAnchor() throws -> LogAnchor? {
        try readAnchors().max { $0.createdAt < $1.createdAt }
    }

    public func append(_ anchor: LogAnchor) throws {
        try layout.prepare()
        let descriptor = try EventJournal.openForAppend(layout.anchors)
        defer { Darwin.close(descriptor) }
        try EventJournal.writeLine(try AwardStore.encoder.encode(anchor), to: descriptor)
    }

    /// How many times this anchor has been recorded as failed. Same counter, same
    /// file discipline, same reason as ``failureCount(for:)``.
    public func failureCount(forAnchor digest: Data) throws -> Int {
        let decoder = JSONDecoder()
        return try AwardStore.lines(of: layout.anchors).reduce(into: 0) { count, line in
            guard let value = try? decoder.decode(LogAnchor.self, from: line.1),
                  value.digest == digest, value.state == .failed
            else { return }
            count += 1
        }
    }

    // MARK: Reading lines

    /// Non-empty lines with their 1-based numbers. A file that is not there yet
    /// is empty, not an error — no award has ever been written on a fresh
    /// install, and that is the normal case rather than a failure.
    private static func lines(of url: URL) throws -> [(Int, Data)] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A, omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { $0.element.isEmpty ? nil : ($0.offset + 1, Data($0.element)) }
    }

    /// `withoutEscapingSlashes` only, exactly as the event log's encoder is. The
    /// on-disk line is **not** the canonical form: the canonical bytes are
    /// hand-written in `CompassDomain/CanonicalBytes.swift`, derived from the
    /// decoded record, and nothing may be inferred from this file's byte layout.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

/// The fold of `awards.jsonl`. `docs/achievement-protocol.md` §8.
///
/// A revoked achievement is **still here**, and that is the point. §8: "the
/// record still survives on disk". What revocation changes is what the
/// certificate list says about it, never whether it exists.
public struct AwardLedger: Sendable, Hashable {

    public let achievements: [Achievement]
    public let revocations: [Revocation]

    /// 1-based line numbers this build could not decode as either record type.
    /// Reported, never dropped and never rewritten — the same contract
    /// `JournalRead.damagedLines` has.
    public let unreadableLines: [Int]

    public init(
        achievements: [Achievement], revocations: [Revocation], unreadableLines: [Int] = []
    ) {
        self.achievements = achievements
        self.revocations = revocations
        self.unreadableLines = unreadableLines
    }

    /// Every ID that has ever been awarded, including revoked ones.
    ///
    /// **This is the set the engine filters against**, deliberately: a revoked
    /// achievement must not be re-awarded on the next pass, which is what
    /// filtering on the *live* set would do.
    public var recordedIDs: Set<AchievementID> {
        Set(achievements.map(\.id))
    }

    public var revokedIDs: Set<AchievementID> {
        Set(revocations.map(\.achievement))
    }

    /// Reverse-chronological. §3.3 gives `detectedAt` exactly two jobs and this
    /// is one of them: it "orders the certificate list".
    ///
    /// **`earnedOn` breaks the tie, and that is not decoration.** A first run
    /// over accumulated history detects every backfilled award at the *same
    /// instant*, so on the run that produces the longest list `detectedAt` orders
    /// nothing at all. Measured on the simulator on 2026-08-01: four awards
    /// issued in one pass listed as 7 days, 30 days, 7 days, 30 days — a
    /// "reverse-chronological" list in which the older record sat above the newer
    /// one. Falling back to the day the claim became true is the reading a person
    /// means by chronological, and it is a digested field.
    ///
    /// The `id` is the last resort, so two records earned on one day still have
    /// one order and two runs over one file agree.
    public var newestFirst: [Achievement] {
        achievements.sorted {
            if $0.detectedAt != $1.detectedAt { return $0.detectedAt > $1.detectedAt }
            if $0.earnedOn != $1.earnedOn { return $0.earnedOn > $1.earnedOn }
            return $0.id > $1.id
        }
    }

    public func isRevoked(_ id: AchievementID) -> Bool {
        revokedIDs.contains(id)
    }
}
