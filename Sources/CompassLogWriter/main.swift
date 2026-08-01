import CompassDomain
import CompassInfrastructure
import Foundation

// The second process in the two-writer test, and nothing else.
// `docs/technical.md` §4 and §9.10.
//
// §9.10 asks for two **processes** appending to one `events.jsonl`, and states
// the reason in the same breath: every other test in the suite uses synthesised
// in-process event streams and "would pass while real data corrupts". The
// property under test is a property of the operating system —
// `Synchronization.Mutex` does not span processes, `O_APPEND` writes do, and
// `flock` is the only thing holding the read-tail-then-append together. None of
// that can be observed from inside one process, however many tasks it runs.
//
// So this is a real executable, launched twice, writing through the **same**
// `EventJournal` the app and the widget write through. It is not a product,
// nothing links it, and it ships nowhere: it exists so that a test can make an
// assertion it could not otherwise make honestly.
//
//   CompassLogWriter <store-path> <writer-name> <event-count> [--cold]
//
// `--cold` opens a **fresh journal per event** and closes it again, which is what
// `WidgetStore.toggle` does on every press: unprimed, so the tail is recovered
// under the advisory `flock`, and single-use, so no cached resume can go stale.
// That is the shape that makes two processes sharing one writer name safe, and
// the shape a test must use to hammer the lock. Without it a journal writes its
// first event under the lock and every later one from memory, which is right for
// the app process and wrong as a model of the widget.
//
// It exits 0 on success and 1 with a message on stderr otherwise, because a
// silent failure here would look exactly like a passing test.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("CompassLogWriter: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard (4...5).contains(arguments.count),
      let count = Int(arguments[3]), count > 0,
      arguments.count == 4 || arguments[4] == "--cold"
else {
    fail("usage: CompassLogWriter <store-path> <writer-name> <event-count> [--cold]")
}

let layout = StoreLayout(storeURL: URL(fileURLWithPath: arguments[1], isDirectory: true))
let writerName = arguments[2]
let isCold = arguments.count == 5

do {
    // The identity is minted here, in this process, on this writer's name — one
    // random UUID, stored in the App Group. Two names, two UUIDs, two `lamport`
    // sequences, two `prev` chains. `docs/technical.md` §4.
    let identity = try WriterIdentity(layout: layout, writer: writerName).load()

    // **Handed no resume, deliberately.** This is the cold-start path §4
    // describes and the one the widget process is on every time it is invoked:
    // the first `record` reads the tail to recover `lamport` and the chain head
    // together, under the advisory `flock`, and appends inside it. Passing a
    // resume here would test the fast path and skip the lock, which is the half
    // that can actually corrupt.
    let warm: EventJournal? = isCold
        ? nil
        : try EventJournal(layout: layout, writer: identity)
    defer { warm?.close() }

    let habit = HabitID(rawValue: "habit-\(writerName)")
    let firstDay = Day(iso: "2020-01-01") ?? Day(ordinal: 0)

    for index in 0..<count {
        let journal = try warm ?? EventJournal(layout: layout, writer: identity)
        defer { if isCold { journal.close() } }

        // Alternating kinds so the `source` field is present on half the lines
        // and absent on the other half: an omitted optional is part of the
        // canonical form, so the interleaving exercises two line shapes rather
        // than one.
        let checkingIn = index.isMultiple(of: 2)
        try journal.record(
            kind: checkingIn ? .checkedIn : .checkInRevoked,
            day: firstDay.adding(index / 2),
            source: checkingIn ? .widget : nil,
            payload: .habit(habit)
        )
    }
} catch {
    fail("\(error)")
}
