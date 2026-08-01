import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// `prev` chaining as the journal actually writes it, and the one-time
/// `reproject` hatch that gives a week-1a log a chain for the first time.
/// `docs/technical.md` §3, §4 and §11.
///
/// `CompassDomainTests/EventChainTests` pins what a chain *is*, against
/// synthesised events. This suite pins what lands on a real file.
@Suite("The chain on disk")
struct ChainTests {

    // MARK: Appending

    @Test("Every append links to the one before it")
    func appendsChain() throws {
        try withTemporaryStore { layout in
            let journal = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            var written: [Event] = []
            for offset in 0..<5 {
                written.append(
                    try journal.record(
                        kind: .checkedIn, day: day("2026-07-01").adding(offset),
                        source: .tap, payload: .habit(habitA)
                    )
                )
            }

            #expect(written[0].prev == EventChain.genesis)
            for (previous, next) in zip(written, written.dropFirst()) {
                #expect(try next.prev == previous.contentHash)
            }

            let read = try JournalReader(url: layout.events).read()
            #expect(read.chain.isIntact)
            let last = try #require(written.last)
            #expect(try read.chain.head(of: writerApp) == last.contentHash)
        }
    }

    @Test("The chain survives a cold start, with nothing handed to it")
    func chainSurvivesRestart() throws {
        // The widget's first launch in week 2, and the app's on any launch that
        // rendered from the snapshot cache. The journal is handed no resume and
        // recovers both halves — `lamport` and the head — under the advisory
        // `flock`. `docs/technical.md` §4.
        try withTemporaryStore { layout in
            let first = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            try first.record(kind: .checkedIn, day: day("2026-07-01"), source: .tap,
                             payload: .habit(habitA))
            let second = try first.record(kind: .checkedIn, day: day("2026-07-02"), source: .tap,
                                          payload: .habit(habitA))
            first.close()

            let restarted = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            let third = try restarted.record(kind: .checkedIn, day: day("2026-07-03"),
                                             source: .tap, payload: .habit(habitA))

            #expect(third.lamport == 3)
            #expect(try third.prev == second.contentHash)
            #expect(try JournalReader(url: layout.events).read().chain.isIntact)
        }
    }

    @Test("Two writers on one file never cross chains")
    func writersChainSeparately() throws {
        // ADR 0002 rejects a single global hash chain precisely because
        // concurrent appenders fork it. Two processes on one phone are the first
        // instance of that case, arriving in week 2 rather than at the second
        // device.
        try withTemporaryStore { layout in
            let app = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            let widget = try EventJournal(
                layout: layout, writer: writerWidget, clock: frozenClock()
            )

            for offset in 0..<20 {
                try app.record(kind: .checkedIn, day: day("2026-01-01").adding(offset),
                               source: .tap, payload: .habit(habitA))
                try widget.record(kind: .checkedIn, day: day("2026-01-01").adding(offset),
                                  source: .widget, payload: .habit(habitB))
            }

            let read = try JournalReader(url: layout.events).read()
            #expect(read.chain.isIntact)
            #expect(read.chain.heads.count == 2)
            #expect(read.chain.head(of: writerApp) != read.chain.head(of: writerWidget))

            // Interleaved on disk, and each writer's own first event is still
            // the genesis one.
            for writer in [writerApp, writerWidget] {
                let mine = read.events.filter { $0.device == writer }
                #expect(mine.first?.prev == EventChain.genesis)
                #expect(mine.dropFirst().allSatisfy { $0.prev != EventChain.genesis })
            }
        }
    }

    @Test("An event the canonical form refuses writes nothing and does not move the head")
    func refusedEventLeavesTheChainAlone() throws {
        // The write path canonicalises **before** it writes, so a name carrying
        // a control character — rejected at write time rather than escaped,
        // `docs/achievement-protocol.md` §6.3 — never reaches the file. If the
        // order were the other way round there would be a line on disk that
        // nothing could ever link to.
        try withTemporaryStore { layout in
            let journal = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            let good = try journal.record(
                kind: .habitCreated, day: day("2026-07-01"),
                payload: .habit(habitA, name: "Move")
            )

            let before = try rawLog(layout)
            #expect(throws: CanonicalEncodingError.self) {
                try journal.record(
                    kind: .habitCreated, day: day("2026-07-01"),
                    payload: .habit(habitB, name: "Re\u{7}ad")
                )
            }
            #expect(try rawLog(layout) == before, "a refused event reached the file")

            // And the sequence did not move: the next event is number two and
            // links to number one.
            let next = try journal.record(kind: .checkedIn, day: day("2026-07-01"),
                                          source: .tap, payload: .habit(habitA))
            #expect(next.lamport == 2)
            #expect(try next.prev == good.contentHash)
            #expect(try JournalReader(url: layout.events).read().chain.isIntact)
        }
    }

    // MARK: The one-time hatch

    @Test("A week-1a log is replayed into a chained one, and the original is kept")
    func reprojectChainsAWeek1aLog() throws {
        try withTemporaryStore { layout in
            let original = try writeUnchainedLog(layout)

            let outcome = try Reprojector(layout: layout).reprojectIfNeeded()
            #expect(outcome == .rechained(events: original.count))

            // Same events, same order — only the links are new.
            let read = try JournalReader(url: layout.events).read()
            #expect(read.chain.isIntact)
            #expect(read.events.count == original.count)
            #expect(read.events.map(\.id) == original.map(\.id))
            #expect(read.events.map(\.payload) == original.map(\.payload))
            #expect(read.events.map(\.recordedAt) == original.map(\.recordedAt))

            // The insurance: the pre-chain file is byte-for-byte what was there.
            let kept = try JournalReader(url: layout.preChainEvents).read()
            #expect(kept.events == original)
            #expect(kept.events.allSatisfy { $0.prev == EventChain.genesis })
        }
    }

    @Test("Running the hatch again does nothing, and never overwrites the original")
    func reprojectIsIdempotent() throws {
        try withTemporaryStore { layout in
            try writeUnchainedLog(layout)
            let reprojector = Reprojector(layout: layout)

            try reprojector.reprojectIfNeeded()
            let afterFirst = try rawLog(layout)
            let keptFirst = try Data(contentsOf: layout.preChainEvents)

            // "This hatch may be used **exactly once**" — and the mechanism is
            // not a flag that can be wrong, it is that a chained log needs
            // nothing. `docs/technical.md` §11.
            #expect(try reprojector.reprojectIfNeeded() == .notNeeded)
            #expect(try rawLog(layout) == afterFirst)
            #expect(try Data(contentsOf: layout.preChainEvents) == keptFirst)
        }
    }

    @Test("The hatch is used exactly once, and a later break never re-runs it")
    func hatchIsUsedExactlyOnce() throws {
        // `docs/technical.md` §11: "This hatch may be used **exactly once**."
        // An already-chained log makes it a no-op, which covers the ordinary
        // second launch. This is the case that a no-op does not cover: a log
        // whose chain breaks later — real damage, a foreign line, a truncated
        // middle — would otherwise walk back in and rewrite every `prev` in the
        // file, which is the hatch running a second time.
        try withTemporaryStore { layout in
            try writeUnchainedLog(layout)
            try Reprojector(layout: layout).reprojectIfNeeded()
            let firstOriginal = try Data(contentsOf: layout.preChainEvents)

            // Something breaks the chain afterwards.
            var lines = try rawLog(layout).split(separator: 0x0A).map { Data($0) }
            lines[1] = try JSONEncoder().encode(
                stamped(.checkedIn, device: writerApp, lamport: 2, on: "2026-07-30",
                        payload: .habit(habitB))
            )
            try Data(lines.map { $0 + Data([0x0A]) }.joined()).write(to: layout.events)
            let damaged = try rawLog(layout)

            let outcome = try Reprojector(layout: layout).reprojectIfNeeded()
            #expect(outcome == .refusedAlreadyUsed)
            #expect(try rawLog(layout) == damaged, "the hatch ran a second time")
            #expect(try Data(contentsOf: layout.preChainEvents) == firstOriginal)
        }
    }

    @Test("An attempt that died before the swap is finished, not refused")
    func interruptedHatchIsResumed() throws {
        // The crash window: the pre-chain copy is on disk and the log has not
        // been replaced yet, so the copy is byte-identical to the log. Nothing
        // was rewritten, so finishing is the *same* use of the hatch — refusing
        // here would leave a log permanently unchained because of one crash.
        try withTemporaryStore { layout in
            try writeUnchainedLog(layout)
            try FileManager.default.copyItem(at: layout.events, to: layout.preChainEvents)
            let original = try Data(contentsOf: layout.preChainEvents)

            let outcome = try Reprojector(layout: layout).reprojectIfNeeded()
            #expect(outcome == .rechained(events: 3))
            #expect(try JournalReader(url: layout.events).read().chain.isIntact)
            #expect(try Data(contentsOf: layout.preChainEvents) == original)
        }
    }

    @Test("A log holding a line this build cannot decode is refused, never rewritten")
    func reprojectRefusesDamage() throws {
        // A rewrite is the one operation in this codebase that can destroy data,
        // and `docs/technical.md` §3 makes `payload` closed — so an event from a
        // newer build is undecodable **by design**. Rewriting without it would
        // drop a real event a real writer really wrote.
        try withTemporaryStore { layout in
            try writeUnchainedLog(layout)
            let fromTheFuture = stamped(
                .checkedIn, device: writerApp, lamport: 9, on: "2026-07-31",
                payload: .habit(habitA)
            )
            try appendRawLine(
                try lineFromANewerBuild(fromTheFuture, payloadKey: "mood", value: "steady"),
                to: layout.events
            )
            let before = try rawLog(layout)

            #expect(try Reprojector(layout: layout).reprojectIfNeeded() == .refusedDamaged(lines: [4]))
            #expect(try rawLog(layout) == before, "a damaged log was rewritten")
            #expect(!FileManager.default.fileExists(atPath: layout.preChainEvents.path))
        }
    }

    @Test("The hatch closes permanently once anything is signed")
    func reprojectRefusesAfterASignature() throws {
        // `docs/technical.md` §11: it "closes permanently the moment anything is
        // signed". A `prev` recomputed after that would move a `content_hash`
        // that a signature — and possibly a Bitcoin anchor — already committed
        // to, and §6 puts a signature in the tier that cannot be recomputed at
        // all.
        try withTemporaryStore { layout in
            try writeUnchainedLog(layout)
            try Data(#"{"achievement":"streak.habit-a.7@2026-07-07"}"#.utf8)
                .write(to: layout.attestations)
            let before = try rawLog(layout)

            #expect(try Reprojector(layout: layout).reprojectIfNeeded() == .refusedSealed)
            #expect(try rawLog(layout) == before)
        }
    }

    @Test("An empty store needs nothing and writes nothing")
    func reprojectOnAnEmptyStore() throws {
        try withTemporaryStore { layout in
            let outcome = try Reprojector(layout: layout).reprojectIfNeeded()
            #expect(outcome == .notNeeded)
            #expect(!FileManager.default.fileExists(atPath: layout.preChainEvents.path))
        }
    }

    @Test("The exported bundle carries a verifiable chain, and restore keeps it")
    func bundleCarriesTheChain() throws {
        // `docs/technical.md` §8: "A test asserts that a fresh install fed only
        // the exported bundle reproduces every achievement bit-identically and
        // verifies every proof." Week 1b is the first half of that promise it
        // can actually keep — there are no achievements and no proofs yet, and
        // there *is* a chain, which is what every later proof is built on. A
        // bundle whose chain does not verify is a bundle whose achievements
        // could never be checked.
        try withTemporaryStore { source in
            let journal = try EventJournal(layout: source, writer: writerApp,
                                           clock: frozenClock())
            try journal.record(kind: .habitCreated, day: day("2026-07-01"),
                               payload: .habit(habitA, name: "Move"))
            for offset in 0..<4 {
                try journal.record(kind: .checkedIn, day: day("2026-07-01").adding(offset),
                                   source: .tap, payload: .habit(habitA))
            }
            journal.close()
            let head = try JournalReader(url: source.events).read().chain.head(of: writerApp)

            try withTemporaryStore { bundleRoot in
                let bundle = bundleRoot.storeURL.appendingPathComponent("bundle")
                try Exporter(layout: source).export(to: bundle, at: instant("2026-08-01T09:00:00+07:00"))

                try withTemporaryStore { fresh in
                    try Exporter(layout: fresh).restore(from: bundle)
                    let restored = try JournalReader(url: fresh.events).read()

                    #expect(restored.chain.isIntact)
                    #expect(restored.chain.head(of: writerApp) == head)
                    #expect(restored.events.count == 5)
                }
            }
        }
    }

    /// Writes a log the way week 1a wrote one: real events, correct `lamport`
    /// sequence, and `prev = genesis` on every line because the canonical
    /// encoding did not exist yet.
    @discardableResult
    private func writeUnchainedLog(_ layout: StoreLayout) throws -> [Event] {
        let events = (1...3).map { lamport in
            stamped(
                .checkedIn, device: writerApp, lamport: lamport,
                on: "2026-07-\(String(format: "%02d", 28 + lamport))",
                payload: .habit(habitA)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var body = Data()
        for event in events {
            body.append(try encoder.encode(event))
            body.append(0x0A)
        }
        try body.write(to: layout.events)
        return events
    }
}
