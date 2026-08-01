import CompassDomain
import CompassInfrastructure
import Foundation
import Synchronization
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

/// A unique empty store for a test that has to `await`, deleted when `body`
/// returns. Same contract as ``withTemporaryStore(_:)``; `async` closures cannot
/// be passed to a synchronous one.
@discardableResult
func withTemporaryStoreAsync<T>(_ body: (StoreLayout) async throws -> T) async throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("compass-tests-\(UUID().uuidString)", isDirectory: true)
    let layout = StoreLayout(storeURL: root)
    try layout.prepare()
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(layout)
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

/// Lowercase hex, for comparing two digests as the values they are rather than
/// as opaque `Data`. `docs/technical.md` §9.7 and §9.13.
func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Week 4: a calendar that answers from a script

/// A `URLSession` that answers from a table instead of from the internet.
///
/// `.claude/skills/testing.md` refuses "mocked `URLSession` asserting a URL was
/// assembled" and keeps exactly **one** live network test. Neither rule is
/// broken here, because what these tests assert is not a URL: it is that
/// `Calendars` talks to **all three** calendars rather than stopping at the
/// first success, which is ADR 0004's first required mitigation and the one
/// thing about this subsystem that would regress in total silence. The live test
/// proves the API exists; this proves the fan-out does.
///
/// A stub at the `URLProtocol` seam rather than a protocol with a fake behind it
/// keeps the real `Calendars` — its concurrency, its status handling, its
/// parsing — inside the test. A fake would have moved exactly the code under
/// suspicion outside it.
///
/// **Every script is keyed to the session that owns it**, and that is not
/// decoration: `URLProtocol` registration is process-wide, `.serialized` only
/// orders tests *within* one suite, and two suites using one global table
/// produced a genuinely flaky assertion — a request counter reset by a test in
/// another file. The token travels as a header on every request the session
/// makes, so two suites can hold two scripts at once and neither can see the
/// other's.
final class StubCalendarProtocol: URLProtocol, @unchecked Sendable {

    static let tokenHeader = "X-Compass-Test-Script"

    struct Reply: Sendable {
        let status: Int
        let body: Data
        init(status: Int = 200, body: Data = Data()) {
            self.status = status
            self.body = body
        }
    }

    fileprivate struct Script {
        var replies: [String: Reply] = [:]
        /// Answered for any URL containing this fragment when no exact match
        /// exists. The upgrade endpoint names a commitment the test cannot know
        /// in advance — it is a hash of a hash of the digest — so the script has
        /// to be able to say "whatever it asks for".
        var wildcard: (fragment: String, reply: Reply)?
        var requests: [String] = []
        var bodies: [Data] = []
    }

    fileprivate static let scripts = Mutex([String: Script]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let token = request.value(forHTTPHeaderField: StubCalendarProtocol.tokenHeader) ?? ""

        // `URLSession` turns an upload body into a stream before a protocol sees
        // it, so the digest is read from whichever of the two is populated.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(contentsOf: buffer[0..<read])
            }
            body = collected
        }

        let reply = StubCalendarProtocol.scripts.withLock { scripts -> Reply in
            scripts[token, default: Script()].requests.append(url)
            if let body { scripts[token, default: Script()].bodies.append(body) }
            let script = scripts[token] ?? Script()
            if let exact = script.replies[url] { return exact }
            if let wildcard = script.wildcard, url.contains(wildcard.fragment) {
                return wildcard.reply
            }
            // The calendars' own sentence for a proof that is not in a block
            // yet. It is the ordinary answer for hours after a submission, and a
            // stub that returned something friendlier would be testing a server
            // that does not exist.
            return Reply(status: 404, body: Data("Pending confirmation in Bitcoin blockchain".utf8))
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One test's scripted calendar: the session to hand `Calendars`, and the script
/// only that session can see.
struct StubCalendars {

    let session: URLSession
    private let token: String

    init() {
        token = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubCalendarProtocol.self]
        configuration.httpAdditionalHeaders = [StubCalendarProtocol.tokenHeader: token]
        session = URLSession(configuration: configuration)
    }

    /// `Calendars` wired to this script, with a short timeout because nothing
    /// here reaches a network.
    var calendars: Calendars { Calendars(session: session, timeout: 5) }

    func answer(_ url: String, with reply: StubCalendarProtocol.Reply) {
        StubCalendarProtocol.scripts.withLock { $0[token, default: .init()].replies[url] = reply }
    }

    /// Every calendar accepts, each returning a response naming itself — so three
    /// answers are three *distinct* pending attestations and a merge that lost
    /// two of them would be visible.
    func acceptEverySubmission() {
        for host in calendarHosts {
            answer("\(host)/digest", with: .init(body: pendingResponse(from: host)))
        }
    }

    /// Answers every `/timestamp/<commitment>` request with the same body.
    func answerEveryUpgrade(with body: Data) {
        StubCalendarProtocol.scripts.withLock {
            $0[token, default: .init()].wildcard = (fragment: "/timestamp/", reply: .init(body: body))
        }
    }

    /// Every URL this session asked for, in order.
    var requests: [String] {
        StubCalendarProtocol.scripts.withLock { $0[token]?.requests ?? [] }
    }

    /// Every request body, for asserting that the digest itself was posted.
    var bodies: [Data] {
        StubCalendarProtocol.scripts.withLock { $0[token]?.bodies ?? [] }
    }
}

/// A serialised timestamp with one pending attestation, written by hand from the
/// format rather than by this project's encoder — `0x08` is "SHA-256 the
/// message", `0x00` introduces an attestation, then the pending tag, then the
/// calendar URI as varbytes.
func pendingResponse(from calendar: String) -> Data {
    let uri = Data(calendar.utf8)
    var payload = Data([UInt8(uri.count)])
    payload.append(uri)
    var out = Data([0x08, 0x00, 0x83, 0xDF, 0xE3, 0x0D, 0x2E, 0xF9, 0x0C, 0x8E])
    out.append(UInt8(payload.count))
    out.append(payload)
    return out
}

/// The same, but the path ends in a Bitcoin block rather than a promise — the
/// only thing in the format that is a proof. Tag `0588960d73d71901`, then the
/// height as a varint.
func bitcoinResponse(height: Int) -> Data {
    var payload = Data()
    var remaining = height
    if remaining == 0 { payload.append(0) }
    while remaining != 0 {
        var byte = UInt8(remaining & 0x7F)
        if remaining > 0x7F { byte |= 0x80 }
        payload.append(byte)
        remaining >>= 7
    }
    var out = Data([0x08, 0x00, 0x05, 0x88, 0x96, 0x0D, 0x73, 0xD7, 0x19, 0x01])
    out.append(UInt8(payload.count))
    out.append(payload)
    return out
}

/// The three calendars, spelled once, in the order `Calendars.defaults` holds
/// them.
let calendarHosts = [
    "https://a.pool.opentimestamps.org",
    "https://alice.btc.calendar.opentimestamps.org",
    "https://bob.btc.calendar.opentimestamps.org",
]
