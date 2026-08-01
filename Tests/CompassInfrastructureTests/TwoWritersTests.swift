import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// **Two writers, one file — with two real processes.** `docs/technical.md` §4
/// and §9.10, `.claude/skills/testing.md`.
///
/// This is the test the corpus asks for by name, and it says why in the same
/// breath: *"every other test here uses synthesised in-process streams and would
/// pass while real data corrupts."* `ChainTests` already builds two
/// `EventJournal`s over one file and interleaves them, and it passes — but both
/// of them are in one process, where `Synchronization.Mutex` serialises every
/// write and no `flock` is ever contended. None of the three things §4 actually
/// relies on is exercised by that:
///
/// - `O_APPEND` making one `write(2)` atomic **against another process**;
/// - the advisory `flock` holding a read-tail-then-append together **across**
///   processes;
/// - two writer identities never sharing a `lamport` sequence or a `prev` chain,
///   when neither process can see the other's memory.
///
/// So this suite launches `CompassLogWriter` twice, concurrently, against one
/// store, and then asserts exactly what §9.10 lists: every line parses, no
/// `(lamport, device)` pair appears twice, and each writer's chain verifies
/// unbroken from its first event to its head.
///
/// It ships **with** the widget, not after it, because the widget is the second
/// writer and the failure it guards against is silent.
@Suite("Two writers, one file, two processes")
struct TwoWritersTests {

    /// Several thousand appends, per §9.10, split between the two processes.
    private static let eventsPerWriter = 1_500

    @Test("Several thousand interleaved appends leave one intact log")
    func twoProcessesInterleave() throws {
        try withTemporaryStore { layout in
            try runBothWriters(in: layout, each: TwoWritersTests.eventsPerWriter)

            let read = try JournalReader(url: layout.events).read()

            // §9.10, assertion 1: every line parses. Nothing torn, nothing
            // half-written, and no partial tail — two processes appending to one
            // descriptor must not be able to land a line inside another's.
            #expect(read.damagedLines.isEmpty, "a line was torn: \(read.damagedLines)")
            #expect(!read.droppedPartialTail)
            #expect(read.events.count == TwoWritersTests.eventsPerWriter * 2)
            #expect(lineCount(try rawLog(layout)) == read.events.count)

            // §9.10, assertion 2: no `(lamport, device)` pair appears twice. This
            // is what makes `EventOrder` a *total* order — two events sharing one
            // pair are two events the fold cannot put in an order, on a log the
            // whole system claims is deterministically replayable.
            let stamps = try stampsOnDisk(layout)
            #expect(stamps.count == read.events.count)
            #expect(Set(stamps).count == stamps.count, "a (lamport, device) pair was reissued")

            // §9.10, assertion 3: each writer's chain verifies unbroken from its
            // first event to its head.
            #expect(read.chain.isIntact, "a chain broke: \(read.chain.breaks)")
            #expect(read.chain.heads.count == 2, "expected exactly two writer heads")

            for events in byWriter(read.events).values {
                #expect(events.count == TwoWritersTests.eventsPerWriter)
                #expect(events.first?.prev == EventChain.genesis)

                // One strictly increasing sequence per writer, never restarting
                // and never repeating. It is deliberately **not** `1...N`: the
                // clock is a Lamport clock, so each cold start advances past
                // whatever the other process has written by then. A writer whose
                // sequence were exactly `1...N` would be one that never read the
                // other's marks — see `EventJournalTests.theClockCarriesCausality`
                // for the un-check that costs.
                let lamports = events.map(\.lamport)
                #expect(zip(lamports, lamports.dropFirst()).allSatisfy { $0 < $1 })
                #expect(lamports.first ?? 0 >= 1)
            }
        }
    }

    @Test("The later press wins, whichever process made it")
    func theLaterPressWins() throws {
        // §9.10's three assertions are about the file. This is about what the
        // file *means*: `docs/technical.md` §3 resolves the `(habit, day)` cell
        // last-writer-wins under `(lamport, device)`, so a second writer whose
        // clock started at 1 would have every one of its revocations silently
        // outranked by the first writer's check-ins. Across two real processes,
        // with two real identity files, the most recent press must win.
        try withTemporaryStore { layout in
            try run(writer: "app", in: layout, count: 40)
            try run(writer: "widget", in: layout, count: 1)

            let read = try JournalReader(url: layout.events).read()
            let last = try #require(read.events.last)
            let earlier = read.events.dropLast()

            #expect(earlier.allSatisfy { $0.order < last.order }, "the last press sorted first")
            #expect(read.chain.isIntact)
        }
    }

    @Test("The two processes really did interleave on disk")
    func theInterleavingIsReal() throws {
        // Without this the suite above passes just as happily when one process
        // finishes before the other starts — which is a sequential test wearing
        // the costume of a concurrent one, and it would assert nothing about the
        // thing §4 is worried about. The number is deliberately far below what
        // two genuinely concurrent writers produce and far above what two
        // sequential ones do, which is exactly one.
        try withTemporaryStore { layout in
            try runBothWriters(in: layout, each: TwoWritersTests.eventsPerWriter)

            let devices = try JournalReader(url: layout.events).read().events.map(\.device)
            let switches = zip(devices, devices.dropFirst()).count { $0 != $1 }
            #expect(switches > 10, "the writers did not interleave: \(switches) switches")
        }
    }

    @Test("A cold second writer chains onto its own head, never the app's")
    func secondWriterStartsItsOwnChain() throws {
        // The real week-2 sequence: the app has been recording for a while, and
        // then a widget process is invoked for the first time. It has never
        // written, so it recovers `lamport 0` and a genesis head **for itself**
        // while the app's chain is many events deep in the same file.
        try withTemporaryStore { layout in
            let app = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            for offset in 0..<12 {
                try app.record(
                    kind: .checkedIn, day: day("2026-06-01").adding(offset),
                    source: .tap, payload: .habit(habitA)
                )
            }
            let appHead = try JournalReader(url: layout.events).read().chain.head(of: writerApp)

            try run(writer: "widget", in: layout, count: 40)

            let read = try JournalReader(url: layout.events).read()
            #expect(read.chain.isIntact)
            #expect(read.chain.head(of: writerApp) == appHead, "the app's head moved")

            let widget = try #require(
                read.chain.heads.keys.first { $0 != writerApp }
            )
            let theirs = read.events.filter { $0.device == widget }
            #expect(theirs.count == 40)

            // Its own chain starts at genesis — the chain is per writer.
            #expect(theirs.first?.prev == EventChain.genesis)

            // Its clock does **not** start at 1 — the clock is not. It resumes
            // past everything already in the log, so the first press a user ever
            // makes in the widget sorts after every tap they have made in the app.
            #expect(theirs.first?.lamport == 13)

            // The two chains never cross: no event of one writer carries the
            // other's `content_hash` as `prev`.
            let appHashes = Set(try read.events.filter { $0.device == writerApp }
                .map { try $0.contentHash })
            #expect(theirs.allSatisfy { !appHashes.contains($0.prev) })
        }
    }

    @Test("Two processes of the SAME writer stay one writer, and one chain")
    func oneWriterNameSurvivesTwoProcesses() throws {
        // `docs/technical.md` §4 says "no two processes share a writer identity",
        // and for the app that is simply true — there is one app process. For the
        // widget it is a **requirement the code has to keep**, because iOS may run
        // several extension instances at once and every one of them is
        // `WriterIdentity.widget`.
        //
        // Two things make that safe and both are exercised here. The identity is
        // minted under the advisory `flock`, so two processes reaching a fresh
        // store together agree on one UUID rather than each keeping its own. And
        // the widget's journal is **single-use** — `WidgetStore.toggle` opens one,
        // records one event under the lock, and closes it — so no cached resume
        // can go stale behind another process's append. `--cold` is that shape.
        try withTemporaryStore { layout in
            let processes = try (0..<2).map { _ in
                try launch(writer: "widget", in: layout, count: 60, cold: true)
            }
            for process in processes {
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
            }

            let read = try JournalReader(url: layout.events).read()
            #expect(read.damagedLines.isEmpty)
            #expect(read.events.count == 120)

            // One writer, one identity, one chain — not two, and not three.
            #expect(read.chain.heads.count == 1, "one writer name produced two identities")
            #expect(read.chain.isIntact, "the shared chain forked: \(read.chain.breaks)")

            let stamps = try stampsOnDisk(layout)
            #expect(Set(stamps).count == stamps.count, "a (lamport, device) pair was reissued")

            let lamports = read.events.map(\.lamport).sorted()
            #expect(lamports == Array(1...120))
        }
    }

    @Test("Each writer name mints its own identity, and keeps it across processes")
    func identitiesArePerWriterAndStable() throws {
        // `device` means writer, not phone. Two names, two files, two UUIDs —
        // and the same name must recover the same UUID on a later process, or a
        // `lamport` sequence restarts at 1 while the old chain's head is still
        // under every `logHeads` ever written.
        try withTemporaryStore { layout in
            try run(writer: "app", in: layout, count: 5)
            try run(writer: "widget", in: layout, count: 5)
            try run(writer: "app", in: layout, count: 5)

            let read = try JournalReader(url: layout.events).read()
            #expect(read.chain.heads.count == 2, "a writer name minted a second identity")
            #expect(read.chain.isIntact)

            let counts = byWriter(read.events).mapValues(\.count)
            #expect(counts.values.sorted() == [5, 10])
        }
    }

    // MARK: Running the processes

    /// Launches both writers at once and waits for both.
    ///
    /// They are started before either is waited on, which is the whole point:
    /// waiting on the first before starting the second would produce a
    /// sequential log and assert nothing.
    private func runBothWriters(in layout: StoreLayout, each count: Int) throws {
        let processes = try ["app", "widget"].map { writer in
            try launch(writer: writer, in: layout, count: count)
        }
        for process in processes {
            process.waitUntilExit()
            #expect(
                process.terminationStatus == 0,
                "CompassLogWriter exited \(process.terminationStatus)"
            )
        }
    }

    private func run(writer: String, in layout: StoreLayout, count: Int) throws {
        let process = try launch(writer: writer, in: layout, count: count)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func launch(
        writer: String, in layout: StoreLayout, count: Int, cold: Bool = false
    ) throws -> Process {
        let process = Process()
        process.executableURL = try TwoWritersTests.logWriter()
        process.arguments = [layout.storeURL.path, writer, String(count)] + (cold ? ["--cold"] : [])
        try process.run()
        return process
    }

    private func byWriter(_ events: [Event]) -> [DeviceID: [Event]] {
        Dictionary(grouping: events, by: \.device)
    }

    /// The helper executable, found from this source file rather than from
    /// `CommandLine.arguments[0]` — under `swift test` on macOS that is the
    /// `xctest` tool inside Xcode, which is nowhere near the build directory.
    ///
    /// **It throws rather than skipping when the binary is missing.** A skipped
    /// adversarial test is the exact failure §9.10 exists to prevent: the suite
    /// goes green, nobody reads the reason, and the one test that could have
    /// caught real cross-process corruption quietly stops running.
    private static func logWriter() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CompassInfrastructureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the package
        let build = packageRoot.appendingPathComponent(".build", isDirectory: true)

        var candidates = [build.appendingPathComponent("debug/CompassLogWriter")]
        // `.build/debug` is a symlink SPM maintains; the arch-specific directory
        // is the thing that always exists.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: build, includingPropertiesForKeys: nil
        )) ?? []
        candidates += contents.map { $0.appendingPathComponent("debug/CompassLogWriter") }

        guard let found = candidates.first(
            where: { FileManager.default.isExecutableFile(atPath: $0.path) }
        ) else {
            throw TwoWriterTestError.helperMissing(searched: candidates.map(\.path))
        }
        return found
    }
}

enum TwoWriterTestError: Error, CustomStringConvertible {
    case helperMissing(searched: [String])

    var description: String {
        switch self {
        case .helperMissing(let searched):
            return """
                CompassLogWriter was not built, so the two-writer test cannot spawn a second \
                process — run `swift build` or `swift test`, which builds it as a dependency \
                of this target. Searched: \(searched.joined(separator: ", "))
                """
        }
    }
}
