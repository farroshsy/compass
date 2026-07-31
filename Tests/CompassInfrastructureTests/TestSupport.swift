import CompassDomain
import CompassInfrastructure
import Foundation
import Testing

// Fixtures for the impure suite. These tests touch a real filesystem and a real
// timezone database, which is the point: everything they exercise is the part of
// the system that `CompassDomainTests` deliberately cannot reach.

let habitA = HabitID(rawValue: "habit-a")
let habitB = HabitID(rawValue: "habit-b")

/// Two writers on one phone: the app process and the widget process.
/// `docs/technical.md` §4.
let writerApp = DeviceID(rawValue: "11111111-1111-4111-8111-111111111111")
let writerWidget = DeviceID(rawValue: "22222222-2222-4222-8222-222222222222")

/// Surabaya, UTC+7 — the single user's timezone. `docs/product.md`.
let surabaya = TimeZone(secondsFromGMT: 7 * 3_600)!

/// A `Day` from an ISO literal. Traps on a malformed literal, which is a test
/// authoring error rather than a runtime condition.
func day(_ iso: String) -> Day {
    guard let day = Day(iso: iso) else {
        fatalError("test fixture is not an ISO civil date: \(iso)")
    }
    return day
}

/// An absolute instant, written with its offset so the fixture is unambiguous
/// about which moment it means.
func instant(_ iso8601: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: iso8601) else {
        fatalError("test fixture is not an ISO 8601 instant: \(iso8601)")
    }
    return date
}

/// A clock frozen at one instant, in one zone.
func frozenClock(
    at iso8601: String = "2026-07-31T09:00:00+07:00", in zone: TimeZone = surabaya
) -> SystemClock {
    let date = instant(iso8601)
    return SystemClock(timeZone: zone, now: { date })
}

/// A unique empty store, deleted when `body` returns.
@discardableResult
func withTemporaryStore<T>(_ body: (StoreLayout) throws -> T) throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("compass-tests-\(UUID().uuidString)", isDirectory: true)
    let layout = StoreLayout(storeURL: root)
    try layout.prepare()
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(layout)
}

/// The raw bytes of the log, for the tests that care about lines rather than
/// events.
func rawLog(_ layout: StoreLayout) throws -> Data {
    try Data(contentsOf: layout.events)
}

func lineCount(_ data: Data) -> Int {
    data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
}

/// One line as a **newer build** would have written it: an extra key inside
/// `payload`, which `docs/technical.md` §3 makes a closed structure — so this
/// build cannot decode the line at all.
///
/// This is the undecodable line that is reachable **by design** rather than by
/// corruption, and it is the one that matters: it is a real event, written by a
/// real writer, and it consumed a `lamport` on that writer's sequence.
func lineFromANewerBuild(_ event: Event, payloadKey: String, value: String) throws -> Data {
    let encoded = try JSONEncoder().encode(event)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
          var payload = object["payload"] as? [String: Any]
    else {
        fatalError("fixture: an encoded event is a JSON object carrying a payload object")
    }
    payload[payloadKey] = value
    object["payload"] = payload
    return try JSONSerialization.data(withJSONObject: object)
}

/// Appends one raw line to the log, the way another writer's process would.
func appendRawLine(_ line: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line + Data([0x0A]))
}

/// Every `(device, lamport)` pair on disk, read from the **raw lines** rather
/// than from decoded events — so a line this build cannot decode still counts.
/// Reading them any other way is the bug these fixtures exist to catch.
func stampsOnDisk(_ layout: StoreLayout) throws -> [String] {
    try rawLog(layout).split(separator: 0x0A).compactMap { line in
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let device = object["device"] as? String,
              let lamport = object["lamport"] as? Int
        else { return nil }
        return "\(device)#\(lamport)"
    }
}

/// An event stamped by hand, for the fixtures that need a specific `lamport`.
func stamped(
    _ kind: EventKind,
    device: DeviceID,
    lamport: Int,
    on civilDay: String,
    payload: EventPayload
) -> Event {
    Event(
        id: UUID(),
        device: device,
        lamport: lamport,
        kind: kind,
        day: day(civilDay),
        recordedAt: 1_784_000_000_000,
        zoneOffset: 420,
        source: kind == .checkedIn ? .tap : nil,
        payload: payload
    )
}
