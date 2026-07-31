import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

/// The append-only journal: one `write(2)` of one complete line to an `O_APPEND`
/// descriptor. `docs/technical.md` §4 and §6, ADR 0002.
@Suite("EventJournal — append-only JSON Lines")
struct EventJournalTests {

    // MARK: Durability

    @Test("a written event survives a process restart")
    func survivesRestart() throws {
        try withTemporaryStore { layout in
            // The writing process.
            let journal = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            try journal.record(
                kind: .habitCreated, day: day("2026-07-31"), payload: .habit(habitA, name: "Meditate")
            )
            try journal.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitA)
            )
            journal.close()

            // A different process: a fresh reader over the same path, nothing
            // shared in memory.
            let restarted = JournalReader(url: layout.events)
            let read = try restarted.read()

            #expect(read.isIntact)
            #expect(read.events.count == 2)

            let projection = project(read.events)
            #expect(projection.isChecked(habitA, on: day("2026-07-31")))
            #expect(projection.habit(habitA)?.name == "Meditate")
            #expect(projection.totalCheckedDays == 1)
        }
    }

    @Test("the tap is durable before the next line is written")
    func durableAtTheMomentOfTheTap() throws {
        try withTemporaryStore { layout in
            let journal = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            let event = try journal.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitA)
            )

            // Kill the app here: the descriptor is never closed, and the line is
            // already on disk because the write was a syscall, not a buffer.
            let read = try JournalReader(url: layout.events).read()
            #expect(read.events.map(\.id) == [event.id])
        }
    }

    // MARK: Appending twice

    @Test("appending twice does not corrupt the first line")
    func secondAppendLeavesTheFirstLineAlone() throws {
        try withTemporaryStore { layout in
            let journal = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )

            let first = try journal.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitA)
            )
            let afterFirst = try rawLog(layout)

            let second = try journal.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitB)
            )
            let afterSecond = try rawLog(layout)

            // The first line is byte-identical and still the prefix. Nothing was
            // rewritten, re-encoded, or moved — the disqualified pattern from the
            // `before` repository would have replaced the whole file here.
            #expect(afterSecond.starts(with: afterFirst))
            #expect(lineCount(afterFirst) == 1)
            #expect(lineCount(afterSecond) == 2)
            #expect(afterSecond.last == 0x0A)

            let read = try JournalReader(url: layout.events).read()
            #expect(read.isIntact)
            #expect(read.events.map(\.id) == [first.id, second.id])
            #expect(read.events.map(\.lamport) == [1, 2])
            #expect(read.events[0].payload.habitID == habitA)
            #expect(read.events[1].payload.habitID == habitB)
        }
    }

    @Test("two hundred appends stay two hundred parseable lines")
    func manyAppends() throws {
        try withTemporaryStore { layout in
            let journal = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            for offset in 0..<200 {
                try journal.record(
                    kind: .checkedIn, day: day("2026-01-01").adding(offset), source: .tap,
                    payload: .habit(habitA)
                )
            }

            let read = try JournalReader(url: layout.events).read()
            #expect(read.isIntact)
            #expect(read.events.count == 200)
            #expect(read.events.map(\.lamport) == Array(1...200))
            #expect(project(read.events).totalCheckedDays == 200)
        }
    }

    // MARK: The writer's sequence

    @Test("lamport resumes after a restart, never repeats")
    func lamportRecoversFromTheTail() throws {
        try withTemporaryStore { layout in
            let first = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            try first.record(kind: .checkedIn, day: day("2026-07-30"), source: .tap,
                             payload: .habit(habitA))
            try first.record(kind: .checkedIn, day: day("2026-07-31"), source: .tap,
                             payload: .habit(habitA))
            first.close()

            // Cold start: the tail is read under an advisory `flock`, and the
            // sequence continues rather than starting again at 1.
            let second = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            let resumed = try second.record(
                kind: .checkedIn, day: day("2026-08-01"), source: .tap, payload: .habit(habitA)
            )
            #expect(resumed.lamport == 3)

            let events = try JournalReader(url: layout.events).read().events
            let pairs = events.map { EventOrder(lamport: $0.lamport, device: $0.device) }
            #expect(Set(pairs).count == pairs.count)
        }
    }

    @Test("a line this build cannot decode still holds its lamport")
    func undecodableLineKeepsItsPlaceInTheSequence() throws {
        // `docs/technical.md` §3 makes `payload` closed, so an event from a
        // newer build is undecodable *by design*. Recovering the high-water mark
        // from decoded events alone skips it, and the next write reuses a
        // `lamport` — breaking the `(lamport, device)` uniqueness §9.10 requires
        // and the total order in §3 depends on.
        try withTemporaryStore { layout in
            let first = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            try first.record(kind: .checkedIn, day: day("2026-07-30"), source: .tap,
                             payload: .habit(habitA))
            first.close()

            // The same writer's next event, written by a build this one has
            // never met. It is the last line in the file.
            let fromTheFuture = stamped(
                .checkedIn, device: writerApp, lamport: 2, on: "2026-07-31",
                payload: .habit(habitA)
            )
            try appendRawLine(
                try lineFromANewerBuild(fromTheFuture, payloadKey: "mood", value: "steady"),
                to: layout.events
            )

            // The mark counts it even though the event cannot be read.
            let read = try JournalReader(url: layout.events).read()
            #expect(read.events.count == 1, "the line genuinely does not decode")
            #expect(read.damagedLines == [2])
            #expect(read.highWaterMarks[writerApp] == 2)

            // Cold start, and the sequence resumes past the line it cannot read.
            let restarted = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            let resumed = try restarted.record(
                kind: .checkedIn, day: day("2026-08-01"), source: .tap, payload: .habit(habitA)
            )
            #expect(resumed.lamport == 3)

            let stamps = try stampsOnDisk(layout)
            #expect(stamps.count == 3)
            #expect(Set(stamps).count == stamps.count, "a (lamport, device) pair was reused")
        }
    }

    @Test("an undecodable line never moves another writer's sequence")
    func marksArePerWriter() throws {
        try withTemporaryStore { layout in
            let app = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            try app.record(kind: .checkedIn, day: day("2026-07-30"), source: .tap,
                           payload: .habit(habitA))
            app.close()

            let widgetLine = stamped(
                .checkedIn, device: writerWidget, lamport: 9, on: "2026-07-31",
                payload: .habit(habitB)
            )
            try appendRawLine(
                try lineFromANewerBuild(widgetLine, payloadKey: "mood", value: "steady"),
                to: layout.events
            )

            let read = try JournalReader(url: layout.events).read()
            #expect(read.highWaterMarks[writerApp] == 1)
            #expect(read.highWaterMarks[writerWidget] == 9)

            // Per-writer chains fail independently: the widget's unreadable line
            // does not push the app's counter forward.
            let restarted = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            let resumed = try restarted.record(
                kind: .checkedIn, day: day("2026-08-01"), source: .tap, payload: .habit(habitA)
            )
            #expect(resumed.lamport == 2)
        }
    }

    // MARK: Keeping the decode off the tap path

    @Test("a primed journal continues the sequence without reading the log")
    func primedJournalDoesNotDecodeOnTheFirstWrite() throws {
        // `docs/technical.md` §4 requires the synchronous tap steps to be
        // microseconds; §6 measures a full decode at 193 ms at five years and
        // 865 ms at ten. The composition root already read the log to render the
        // first frame, so it supplies the mark and the first tap decodes nothing.
        try withTemporaryStore { layout in
            let seed = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            for offset in 0..<3 {
                try seed.record(kind: .checkedIn, day: day("2026-07-01").adding(offset),
                                source: .tap, payload: .habit(habitA))
            }
            seed.close()

            // Exactly what `App/CompassApp.swift` does: one read, two results.
            let read = try JournalReader(url: layout.events).read()
            let primed = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock(),
                highWaterMark: read.highWaterMarks[writerApp] ?? 0
            )
            #expect(try primed.record(kind: .checkedIn, day: day("2026-07-04"),
                                      source: .tap, payload: .habit(habitA)).lamport == 4)

            let stamps = try stampsOnDisk(layout)
            #expect(Set(stamps).count == stamps.count)
        }

        // The proof that nothing was read: prime with a mark the file disagrees
        // with, and the primed value is what the first write uses. Only a
        // journal that never opened the log can behave this way.
        try withTemporaryStore { layout in
            let seed = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            try seed.record(kind: .checkedIn, day: day("2026-07-01"), source: .tap,
                            payload: .habit(habitA))
            seed.close()

            let primed = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock(), highWaterMark: 40
            )
            #expect(try primed.record(kind: .checkedIn, day: day("2026-07-02"),
                                      source: .tap, payload: .habit(habitA)).lamport == 41)
        }
    }

    @Test("an unprimed journal still recovers the mark by itself")
    func unprimedJournalStillRecovers() throws {
        // Priming is an optimisation the composition root can make, never a
        // requirement. A writer that is handed nothing — the week-2 widget
        // process on its first launch — still reads the tail under the `flock`.
        try withTemporaryStore { layout in
            let seed = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            try seed.record(kind: .checkedIn, day: day("2026-07-01"), source: .tap,
                            payload: .habit(habitA))
            seed.close()

            let cold = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            #expect(try cold.record(kind: .checkedIn, day: day("2026-07-02"),
                                    source: .tap, payload: .habit(habitA)).lamport == 2)
        }
    }

    @Test("two writers on one file keep separate sequences")
    func twoWritersDoNotShareACounter() throws {
        // The in-process half of `docs/technical.md` §9.10. The adversarial
        // two-*process* version ships with the widget in week 2, per §4 — not
        // here, and this test does not stand in for it.
        try withTemporaryStore { layout in
            let app = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
            let widget = try EventJournal(
                layout: layout, writer: writerWidget, clock: frozenClock()
            )

            for offset in 0..<50 {
                try app.record(kind: .checkedIn, day: day("2026-01-01").adding(offset),
                               source: .tap, payload: .habit(habitA))
                try widget.record(kind: .checkedIn, day: day("2026-01-01").adding(offset),
                                  source: .widget, payload: .habit(habitB))
            }

            let read = try JournalReader(url: layout.events).read()
            #expect(read.isIntact)
            #expect(read.events.count == 100)

            let pairs = read.events.map { EventOrder(lamport: $0.lamport, device: $0.device) }
            #expect(Set(pairs).count == pairs.count)

            for writer in [writerApp, writerWidget] {
                let mine = read.events.filter { $0.device == writer }.map(\.lamport)
                #expect(mine == Array(1...50))
            }

            let projection = project(read.events)
            #expect(projection.habit(habitA)?.checkedDays.count == 50)
            #expect(projection.habit(habitB)?.checkedDays.count == 50)
        }
    }

    @Test("the writer identity is a random UUID, stable across launches")
    func writerIdentityIsStable() throws {
        try withTemporaryStore { layout in
            let identity = WriterIdentity(layout: layout)
            let first = try identity.load()
            let second = try WriterIdentity(layout: layout).load()

            #expect(first == second)
            #expect(UUID(uuidString: first.rawValue) != nil)

            // The widget is a different writer, with a different chain.
            let widget = try WriterIdentity(layout: layout, writer: "widget").load()
            #expect(widget != first)
        }
    }

    // MARK: The port

    @Test("append writes a foreign event verbatim")
    func appendIsVerbatim() throws {
        try withTemporaryStore { layout in
            let journal = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            let imported = Event(
                id: UUID(),
                device: writerWidget,
                lamport: 41,
                kind: .checkedIn,
                day: day("2026-07-31"),
                recordedAt: 1_784_000_000_000,
                zoneOffset: 420,
                source: .widget,
                payload: .habit(habitB),
                extra: ["seenByANewerBuild": .string("kept")]
            )
            try journal.appendSync(imported)

            let read = try JournalReader(url: layout.events).read()
            #expect(read.events == [imported])
            // Unknown fields are preserved, never dropped.
            #expect(read.events.first?.extra["seenByANewerBuild"] == .string("kept"))
        }
    }

    // MARK: Damage

    @Test("truncating at every byte offset drops only the partial tail")
    func truncationAtEveryOffset() throws {
        let complete: Data = try withTemporaryStore { layout in
            let journal = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            for offset in 0..<6 {
                try journal.record(
                    kind: .checkedIn, day: day("2026-07-01").adding(offset), source: .tap,
                    payload: .habit(habitA)
                )
            }
            journal.close()
            return try rawLog(layout)
        }

        let whole = try withTemporaryStore { layout -> [Event] in
            try complete.write(to: layout.events)
            return try JournalReader(url: layout.events).read().events
        }
        #expect(whole.count == 6)

        // Every prefix of a crashed append: all complete lines intact, the
        // partial tail dropped, nothing else lost. `docs/technical.md` §9.6.
        for cut in 0...complete.count {
            let prefix = complete.prefix(cut)
            let expected = lineCount(Data(prefix))

            try withTemporaryStore { layout in
                try Data(prefix).write(to: layout.events)
                let read = try JournalReader(url: layout.events).read()

                #expect(read.damagedLines.isEmpty, "offset \(cut) lost a complete line")
                #expect(read.events.count == expected, "offset \(cut) recovered the wrong count")
                #expect(read.events == Array(whole.prefix(expected)), "offset \(cut) reordered")
                #expect(read.droppedPartialTail == (cut > 0 && prefix.last != 0x0A))
            }
        }
    }

    @Test("a damaged line is reported, never silently dropped")
    func damageIsReported() throws {
        try withTemporaryStore { layout in
            let journal = try EventJournal(
                layout: layout, writer: writerApp, clock: frozenClock()
            )
            try journal.record(kind: .checkedIn, day: day("2026-07-30"), source: .tap,
                               payload: .habit(habitA))
            try journal.record(kind: .checkedIn, day: day("2026-07-31"), source: .tap,
                               payload: .habit(habitA))
            journal.close()

            // Corrupt the middle of the file rather than its tail.
            let pieces: [Data.SubSequence] = try rawLog(layout).split(separator: 0x0A)
            var lines = pieces.map { Data($0) }
            lines.insert(Data(#"{"v":1,"kind":"checkedIn","#.utf8), at: 1)
            try Data(lines.map { $0 + Data([0x0A]) }.joined()).write(to: layout.events)

            let read = try JournalReader(url: layout.events).read()
            #expect(read.damagedLines == [2])
            #expect(read.isIntact == false)
            // The app still launches and the surviving days still count.
            #expect(read.events.count == 2)
            #expect(project(read.events).habit(habitA)?.checkedDays.count == 2)
        }
    }

    // MARK: A store that cannot be opened at all

    @Test("an unopenable store throws rather than trapping")
    func unopenableStoreThrows() throws {
        // The condition the composition root has to survive. `docs/technical.md`
        // §6: never refuse to launch — and a `preconditionFailure` at this point
        // refuses on every launch, for a condition that is usually transient,
        // with the log intact on disk the whole time.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("compass-tests-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = StoreLayout(storeURL: root)
        #expect(throws: (any Error).self) {
            try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
        }
    }

    @Test("the unavailable store refuses every call instead of losing a tap")
    func unavailableStoreThrowsOnBothPaths() async throws {
        let store = UnavailableStore(reason: "the sandbox is gone")

        #expect(throws: JournalError.storeUnavailable(reason: "the sandbox is gone")) {
            try store.record(
                kind: .checkedIn, day: day("2026-07-31"), source: .tap, payload: .habit(habitA)
            )
        }

        await #expect(throws: JournalError.storeUnavailable(reason: "the sandbox is gone")) {
            try await store.replay()
        }
    }
}
