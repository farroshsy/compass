import CompassDomain
import CompassInfrastructure
import CryptoKit
import Foundation
import Testing

/// **The one network test.** `.claude/skills/testing.md`:
///
/// > Keep exactly **one** network test, hitting the real OpenTimestamps
/// > calendars. The failure guarded against is building on an API nobody ever
/// > called.
///
/// Everything else about this subsystem is tested offline against a scripted
/// session and a captured response. That is the right trade for almost every
/// assertion — but it cannot notice the day `a.pool.opentimestamps.org` stops
/// answering, changes its content type, or starts returning a format this parser
/// does not read, and ADR 0004 names the calendars as this project's one real
/// operational dependency. A dependency nobody ever exercises is a dependency
/// nobody will notice losing.
///
/// **It really submits a digest**, and that is deliberate rather than sloppy.
/// The submitted value is `SHA-256` of a fixed sentence about this test, so it
/// is not a Compass record, not a log head, and carries nothing about anybody's
/// day. The calendars aggregate it into the same Merkle tree as everything else
/// at no marginal cost to them or to anyone.
///
/// It is tagged so it can be excluded from a run on a train:
/// `swift test --skip-tag network`.
@Suite(.tags(.network))
struct CalendarNetworkTests {

    /// Not a record, not a head, and stable across runs so it is one entry in a
    /// calendar's tree rather than a new one every time the suite is run.
    private var probe: Data {
        Data(SHA256.hash(data: Data("compass verifier — the one network test".utf8)))
    }

    /// **All three, and every answer kept.** This is ADR 0004's first required
    /// mitigation, asserted against the servers themselves rather than a stub.
    ///
    /// It expects at least one calendar to answer, not all three: one operator
    /// having a bad afternoon is the ordinary state of the world, and it is
    /// exactly why the design submits to three.
    @Test("The real calendars accept a digest and return a parseable timestamp")
    func theCalendarsAreStillThere() async throws {
        let responses = await Calendars(timeout: 25).submit(probe)

        #expect(responses.count == 3, "every configured calendar must be asked, never just one")

        let answered = responses.filter(\.succeeded)
        try #require(
            !answered.isEmpty,
            Comment(
                rawValue: """
                    No OpenTimestamps calendar answered. This test needs network access, and it \
                    is the only one in the suite that does. What each one said: \
                    \(responses.compactMap(\.failure).joined(separator: " | "))
                    """
            )
        )

        for response in answered {
            let timestamp = try #require(response.timestamp)
            let pending = timestamp.pending(from: probe)
            // A fresh submission is a *promise*, and the shape of that promise is
            // the thing this test is really pinning: a calendar URI, reachable by
            // replaying the operations from the digest we sent.
            #expect(!pending.isEmpty, "a calendar answered without a pending attestation")
            #expect(timestamp.bitcoin(from: probe).isEmpty, "a fresh submission is not a proof")
            #expect(timestamp.unreplayable(from: probe).isEmpty)
            for (calendar, commitment) in pending {
                #expect(calendar.hasPrefix("https://"))
                #expect(commitment.count >= 32)
            }
        }

        // And it survives being written to the file the export bundle carries.
        var merged = OTSTimestamp()
        for response in answered {
            merged.merge(try #require(response.timestamp))
        }
        let file = try OpenTimestamps.writeDetached(digest: probe, timestamp: merged)
        #expect(try OpenTimestamps.readDetached(file).digest == probe)
    }

    /// The other half of the same dependency, and the half that actually matters:
    /// a submission is worth nothing until a calendar hands back the Bitcoin
    /// path, and that upgrade is fetched from the same third-party server hours
    /// later.
    ///
    /// A `404` reading "Pending confirmation in Bitcoin blockchain" is the
    /// **correct** answer for a digest submitted seconds ago, so this asserts
    /// that the endpoint answers coherently either way — never that the proof is
    /// already anchored.
    @Test("The upgrade endpoint answers, whether or not the block has landed yet")
    func theUpgradeEndpointAnswers() async throws {
        let calendars = Calendars(timeout: 25)
        let responses = await calendars.submit(probe)
        let succeeded = responses.filter(\.succeeded)
        let answered = try #require(succeeded.first)
        let pending = try #require(answered.timestamp?.pending(from: probe).first)
        let calendar = try #require(URL(string: pending.calendar))

        let upgrade = await calendars.upgrade(commitment: pending.commitment, from: calendar)

        if let timestamp = upgrade.timestamp {
            // It has been aggregated already. Whatever came back must parse and
            // must be about the value we asked for.
            #expect(timestamp.unreplayable(from: pending.commitment).isEmpty)
        } else {
            let failure = try #require(upgrade.failure)
            #expect(
                failure.contains("404") || failure.contains("Pending"),
                Comment(rawValue: "unexpected answer from the upgrade endpoint: \(failure)")
            )
        }
    }
}

extension Tag {
    /// The one tag in the suite, so the one test that needs the internet can be
    /// left out of a run that does not have it — `swift test --skip-tag network`.
    /// It is a tag and not a `#if`, because a compile-time switch is one nobody
    /// ever turns back on.
    @Tag static var network: Self
}
