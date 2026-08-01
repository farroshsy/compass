//  Calendars — copied in from the `before` repository,
//  `Sources/BeforeKit/Calendar.swift`, on 2026-08-01. `docs/technical.md` §1:
//  the consumption mechanism is copying the source in, never an SPM path
//  dependency, a submodule or a symlink.
//
//  **Two things were fixed while copying, not copied verbatim.**
//
//  1. `anchor(_:)` returned "the first proof a calendar returns" and discarded
//     the other two. `docs/adr/0004` and `docs/product.md` both require the
//     opposite, in those words: "Submit to all three calendars, not
//     first-success-wins. Three independent chances to upgrade, for the same
//     zero marginal cost." The inherited signature could not express three
//     answers, so it is gone; ``submit(_:)`` returns one result per calendar and
//     the caller keeps all of them.
//  2. `actor Log` is not copied at all. Its `persist()` re-encodes and rewrites
//     the whole array on every append — 145 ms and a 1.9 MB flash write per tap
//     at a five-year Compass workload. `docs/technical.md` §1, ADR 0002.
//
//  The comment in the original said "Two calendars are used, not one", above a
//  list of three. The list was right.

import Foundation

/// Submitting a digest to the OpenTimestamps calendars, and asking them later
/// whether it has made it into Bitcoin.
///
/// Free, and it needs no wallet, no gas and no account: the calendars aggregate
/// everyone's digests into one Merkle tree and commit the root in a Bitcoin
/// transaction, so an entry inherits the security of a block without its owner
/// ever touching a coin. That is why this app can anchor to Bitcoin while its
/// user owns none.
///
/// **These are somebody else's servers, and that is stated rather than hidden.**
/// `docs/product.md` refuses "any service that must be kept alive" and then
/// names this as the one exception the project does take. The specific
/// mechanism, which is easy to miss: a fresh submission is *not* a proof. It is
/// a promise that a calendar will include the digest in an aggregation, and it
/// becomes worth something only after that calendar upgrades it with the Bitcoin
/// path — an upgrade that must be fetched from that same server, later. If the
/// calendars are gone, repriced or firewalled during the window, every
/// un-upgraded proof is permanently worthless.
///
/// What keeps that an exception rather than a contradiction: total calendar
/// failure costs the *timestamp* claim and nothing else. The local signature
/// still proves the record came from this device unaltered, and the app keeps
/// working.
///
/// It is a plain `Sendable` struct and not an actor. `URLSession` is already
/// concurrency-safe, and wrapping it would only serialise three calls that
/// specifically must not be serialised. `docs/technical.md` §4.
public struct Calendars: Sendable {

    /// All three, and the count is load-bearing. ADR 0004's first required
    /// mitigation is submitting to every one of them.
    public static let defaults = [
        URL(string: "https://a.pool.opentimestamps.org")!,
        URL(string: "https://alice.btc.calendar.opentimestamps.org")!,
        URL(string: "https://bob.btc.calendar.opentimestamps.org")!,
    ]

    public let urls: [URL]
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        urls: [URL] = Calendars.defaults,
        session: URLSession = .shared,
        timeout: TimeInterval = 20
    ) {
        self.urls = urls
        self.session = session
        self.timeout = timeout
    }

    /// What one calendar said.
    public struct Response: Sendable {
        public let calendar: URL
        /// The serialised timestamp the calendar returned, or `nil` when it
        /// refused, timed out or was unreachable.
        public let timestamp: OTSTimestamp?
        /// Why not, in a form fit for a log line and nothing else.
        public let failure: String?

        public var succeeded: Bool { timestamp != nil }
    }

    // MARK: Submission

    /// Submits a 32-byte digest to **every** calendar and returns every answer.
    ///
    /// **Not first-success-wins**, and the difference is the whole point: three
    /// pending attestations are three independent chances that one of these
    /// servers is still answering in six months. They are submitted
    /// concurrently rather than in sequence because three 20-second timeouts in
    /// a row is a minute of a background task's budget spent waiting.
    ///
    /// It does not throw. A calendar that is down is an ordinary Tuesday, and
    /// the caller needs to know which of the three it was.
    public func submit(_ digest: Data) async -> [Response] {
        guard digest.count == 32 else {
            return urls.map {
                Response(calendar: $0, timestamp: nil, failure: "digest is not 32 bytes")
            }
        }

        let request = { (url: URL) -> URLRequest in
            var request = URLRequest(url: url.appendingPathComponent("digest"))
            request.httpMethod = "POST"
            request.httpBody = digest
            request.timeoutInterval = timeout
            request.setValue(
                "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
            )
            return request
        }

        let session = self.session
        return await withTaskGroup(of: Response.self) { group in
            for url in urls {
                let built = request(url)
                group.addTask { await Calendars.fetch(built, from: url, using: session) }
            }
            var responses: [Response] = []
            for await response in group { responses.append(response) }
            // A deterministic order, so two runs over the same failure report it
            // the same way.
            return responses.sorted { $0.calendar.absoluteString < $1.calendar.absoluteString }
        }
    }

    // MARK: Upgrade

    /// Asks one calendar for the rest of the path from `commitment` to Bitcoin.
    ///
    /// A 404 here is the **normal** case, not an error: it means "pending
    /// confirmation in the Bitcoin blockchain", which is where every fresh
    /// submission sits for hours. ADR 0004 asks for this to be re-attempted "over
    /// a long horizon — months, not the length of one backoff schedule", so a
    /// not-yet is reported as a failure string and never as a reason to stop.
    public func upgrade(commitment: Data, from calendar: URL) async -> Response {
        let hex = commitment.map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(
            url: calendar.appendingPathComponent("timestamp").appendingPathComponent(hex)
        )
        request.timeoutInterval = timeout
        return await Calendars.fetch(request, from: calendar, using: session)
    }

    private static func fetch(
        _ request: URLRequest, from calendar: URL, using session: URLSession
    ) async -> Response {
        let host = calendar.host ?? "calendar"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Response(calendar: calendar, timestamp: nil, failure: "\(host): no response")
            }
            guard http.statusCode == 200 else {
                // The body of a 404 is the calendar's own sentence about why —
                // "Pending confirmation in Bitcoin blockchain" — and it is worth
                // more in a log than the number is.
                let reason = String(decoding: data.prefix(120), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Response(
                    calendar: calendar, timestamp: nil,
                    failure: "\(host): \(http.statusCode)\(reason.isEmpty ? "" : " — \(reason)")"
                )
            }
            guard !data.isEmpty else {
                return Response(
                    calendar: calendar, timestamp: nil, failure: "\(host): empty proof"
                )
            }
            var reader = ByteReader(data)
            let timestamp = try OTSTimestamp(reading: &reader)
            return Response(calendar: calendar, timestamp: timestamp, failure: nil)
        } catch {
            return Response(
                calendar: calendar, timestamp: nil,
                failure: "\(host): \(error.localizedDescription)"
            )
        }
    }
}
