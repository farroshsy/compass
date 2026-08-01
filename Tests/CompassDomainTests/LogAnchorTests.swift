import CompassDomain
import Foundation
import Testing

/// The week-4 arithmetic that lives in Domain: what gets anchored, when it gets
/// anchored, when it may be published, and how long to wait after a failure.
/// `docs/adr/0004`, `docs/achievement-protocol.md` §7.1, `docs/technical.md` §6.
///
/// All four are here rather than beside the network code for the reason
/// `AnchorSchedule` already carried: **a gate that exists only inside the code
/// that wants to skip it is not a gate.** Week 4's submission path must not be
/// the place any of these rules is first written down.
struct LogAnchorTests {

    private func head(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    private let writerOne = "11111111-1111-4111-8111-111111111111"
    private let writerTwo = "22222222-2222-4222-8222-222222222222"

    // MARK: The canonical form

    /// The third canonical form in the corpus, and the only one this repository
    /// fixes for itself — ADR 0004 mandates weekly log-head anchoring and
    /// specifies no encoding at all.
    ///
    /// The expected string is **written out by hand from the form in
    /// `docs/technical.md` §6**, not captured from a run. A byte string captured
    /// from the code pins whatever the code happens to do, and the first session
    /// to reorder a key simply re-records it.
    @Test("The log-head canonical bytes are the form the document states")
    func theCanonicalFormIsWhatTheDocumentSays() throws {
        let heads = [writerTwo: head(0x22), writerOne: head(0x11)]
        let expected = """
            {"v":1,"kind":"logHeads","heads":\
            {"11111111-1111-4111-8111-111111111111":\
            "ERERERERERERERERERERERERERERERERERERERERERE=",\
            "22222222-2222-4222-8222-222222222222":\
            "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI="}}
            """
        #expect(
            String(decoding: try LogAnchor.canonicalBytes(heads: heads), as: UTF8.self) == expected
        )
    }

    /// **If this test ever needs updating, something irreversible has happened.**
    /// The hex was computed by `shasum -a 256` and by `openssl dgst`, on the byte
    /// string above, outside this project — so it pins the document rather than
    /// the code.
    @Test("The log-head digest equals a hex computed outside this project")
    func theDigestIsStable() throws {
        let heads = [writerOne: head(0x11), writerTwo: head(0x22)]
        #expect(
            hex(try LogAnchor.digest(heads: heads))
                == "a59bf198274abc2116f0e0048aee7999c7e86c85f04ff4d49b0b0a27669eabe1"
        )
    }

    /// Device keys are sorted **byte-wise**, so the dictionary that produced them
    /// cannot change the digest. `Dictionary` iteration order is not stable
    /// across runs, and this is a value that gets published to Bitcoin.
    @Test("Insertion order cannot change the log-head digest")
    func theDigestDoesNotDependOnDictionaryOrder() throws {
        var forwards: [String: Data] = [:]
        forwards[writerOne] = head(0x11)
        forwards[writerTwo] = head(0x22)

        var backwards: [String: Data] = [:]
        backwards[writerTwo] = head(0x22)
        backwards[writerOne] = head(0x11)

        #expect(try LogAnchor.digest(heads: forwards) == LogAnchor.digest(heads: backwards))
    }

    /// The digest commits to **which** head, not merely to how many. A head that
    /// moved by one event is a different anchor.
    @Test("Moving one writer's head changes the digest")
    func theDigestCoversEveryHead() throws {
        let before = try LogAnchor.digest(heads: [writerOne: head(0x11)])
        let after = try LogAnchor.digest(heads: [writerOne: head(0x12)])
        #expect(before != after)
    }

    // MARK: The weekly cadence

    private func anchor(heads: [String: Data], createdAt: Date) -> LogAnchor {
        LogAnchor(
            heads: heads,
            digest: (try? LogAnchor.digest(heads: heads)) ?? Data(),
            createdAt: createdAt,
            state: .submitted
        )
    }

    @Test("The first anchor is due immediately")
    func theFirstAnchorIsDueAtOnce() {
        #expect(
            LogAnchorSchedule.isDue(
                heads: [writerOne: head(0x11)], since: nil, now: instant("2026-08-01T00:00:00Z")
            )
        )
    }

    /// Nothing has been written, so there is nothing to commit to. Anchoring an
    /// empty set of heads would publish a digest of `{}` once a week forever.
    @Test("An empty log is never anchored")
    func anEmptyLogIsNeverAnchored() {
        #expect(
            !LogAnchorSchedule.isDue(
                heads: [:], since: nil, now: instant("2026-08-01T00:00:00Z")
            )
        )
    }

    @Test("A second anchor waits a week")
    func theCadenceIsWeekly() {
        let previous = anchor(
            heads: [writerOne: head(0x11)], createdAt: instant("2026-08-01T00:00:00Z")
        )
        let moved = [writerOne: head(0x12)]
        #expect(
            !LogAnchorSchedule.isDue(
                heads: moved, since: previous, now: instant("2026-08-06T00:00:00Z")
            )
        )
        #expect(
            LogAnchorSchedule.isDue(
                heads: moved, since: previous, now: instant("2026-08-08T00:00:00Z")
            )
        )
    }

    /// **Unchanged heads are never re-anchored, however long it has been**, and
    /// that is not an optimisation.
    ///
    /// The canonical form carries no timestamp, so the digest of the same heads
    /// is the same digest. Submitting it a second time buys a strictly *later*
    /// Bitcoin timestamp for a value that already has an earlier one — which is
    /// the same operation ADR 0004 names as what makes a discarded proof
    /// unrecoverable, performed deliberately.
    @Test("Unchanged heads are not re-anchored, even after a year")
    func unchangedHeadsAreNeverReAnchored() {
        let heads = [writerOne: head(0x11)]
        let previous = anchor(heads: heads, createdAt: instant("2026-08-01T00:00:00Z"))
        #expect(
            !LogAnchorSchedule.isDue(
                heads: heads, since: previous, now: instant("2027-08-01T00:00:00Z")
            )
        )
    }

    // MARK: The 72-hour provisional window

    /// Sign immediately, publish late. Nothing irreversible is published that the
    /// user might immediately want to take back, and the window costs one
    /// comparison in a background job.
    @Test("Nothing may be submitted before 72 hours have passed")
    func theWindowIsSeventyTwoHours() {
        let detected = instant("2026-08-01T00:00:00Z")
        #expect(!AnchorSchedule.maySubmit(detectedAt: detected, now: detected))
        #expect(
            !AnchorSchedule.maySubmit(
                detectedAt: detected, now: instant("2026-08-03T23:59:59Z")
            )
        )
        // The boundary is stated rather than left to whichever comparison
        // someone types: exactly 72 hours is submittable.
        #expect(
            AnchorSchedule.maySubmit(detectedAt: detected, now: instant("2026-08-04T00:00:00Z"))
        )
    }

    // MARK: The backoff

    /// Doubling from an hour, and it stops widening at a week rather than
    /// running away.
    @Test("The retry delay doubles from one hour and caps at one week")
    func theBackoffDoubles() {
        #expect(AnchorRetry.delay(afterFailures: 1) == 3_600)
        #expect(AnchorRetry.delay(afterFailures: 2) == 7_200)
        #expect(AnchorRetry.delay(afterFailures: 5) == 3_600 * 16)
        #expect(AnchorRetry.delay(afterFailures: 20) == AnchorRetry.widest)
        // Nothing overflows on the hundredth failure of a calendar that has been
        // gone for two years. The count comes from lines in a file.
        #expect(AnchorRetry.delay(afterFailures: 500) == AnchorRetry.widest)
    }

    @Test("A retry waits out the whole schedule so far, measured from the first attempt")
    func theBackoffAccumulates() {
        let first = instant("2026-08-01T00:00:00Z")
        #expect(AnchorRetry.mayRetry(firstAttemptAt: first, failures: 0, now: first))
        #expect(
            !AnchorRetry.mayRetry(
                firstAttemptAt: first, failures: 1, now: instant("2026-08-01T00:30:00Z")
            )
        )
        #expect(
            AnchorRetry.mayRetry(
                firstAttemptAt: first, failures: 1, now: instant("2026-08-01T01:00:00Z")
            )
        )
        // One hour, then two: three hours after the first attempt.
        #expect(
            !AnchorRetry.mayRetry(
                firstAttemptAt: first, failures: 2, now: instant("2026-08-01T02:59:00Z")
            )
        )
        #expect(
            AnchorRetry.mayRetry(
                firstAttemptAt: first, failures: 2, now: instant("2026-08-01T03:00:00Z")
            )
        )
    }

    /// **It never gives up.** ADR 0004 asks for re-attempts "over a long horizon
    /// — months, not the length of one backoff schedule", so there is no attempt
    /// limit and there must not be one: an un-upgraded proof is worthless, and
    /// the only cost of trying again is one request.
    @Test("There is no attempt limit")
    func itNeverStopsRetrying() {
        let first = instant("2026-01-01T00:00:00Z")
        #expect(
            AnchorRetry.mayRetry(
                firstAttemptAt: first, failures: 200, now: instant("2030-01-01T00:00:00Z")
            )
        )
    }
}
