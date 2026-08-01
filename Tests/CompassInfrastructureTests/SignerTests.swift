import CompassDomain
import CompassInfrastructure
import CryptoKit
import Foundation
import Testing

/// The signing key, and the two defects that had to be fixed while copying it in
/// from the `before` repository. `docs/technical.md` §1, §8 and §9.12,
/// `.claude/skills/testing.md`, `memory/known-bugs.md`.
///
/// These run against the **real keychain**, under a service name unique to each
/// test, deleted on the way out. A fake behind a protocol would have made the
/// relaunch assertion pass while the two `SecItem` calls that actually decide
/// whether the key survives went unexercised — and "the key survives relaunch" is
/// precisely a claim about those two calls.
@Suite(.serialized)
struct SignerTests {

    /// A keychain item nobody else owns, removed when `body` returns.
    private func withTemporaryKeychain<T>(_ body: (KeychainStore) throws -> T) rethrows -> T {
        let store = KeychainStore(
            service: "dev.farros.compass.tests.\(UUID().uuidString)",
            account: "achievement-key"
        )
        defer { store.delete() }
        return try body(store)
    }

    // MARK: §9.12 — the key survives relaunch

    /// **The inherited code fails this test.** `Signer.init(preferEnclave:)` in
    /// `before` unconditionally calls `SecureEnclave.P256.Signing.PrivateKey()`,
    /// minting a brand-new key on every construction, and offers no initialiser
    /// that restores one. Copied verbatim, every launch signs with a different
    /// public key and "these achievements came from one device" is false —
    /// silently, because the user is never told the key exists.
    @Test("Two Signer constructions across a simulated relaunch share one public key")
    func theKeySurvivesRelaunch() throws {
        try withTemporaryKeychain { store in
            let first = try Signer(store: store)
            // A second construction against the same keychain **is** the
            // relaunch: nothing else about a process carries the key.
            let second = try Signer(store: store)

            #expect(first.publicKey == second.publicKey)
            #expect(first.backing == second.backing)
        }
    }

    @Test("A signature made before the relaunch verifies against the key after it")
    func signaturesSurviveRelaunch() throws {
        try withTemporaryKeychain { store in
            let message = Data("100 consecutive days".utf8)
            let before = try Signer(store: store)
            let signature = try before.signature(over: message)

            let after = try Signer(store: store)
            #expect(
                Signer.isValid(signature, over: message, publicKey: after.publicKey)
            )
        }
    }

    @Test("A fresh keychain mints exactly one key, and it is the one that is kept")
    func theFirstKeyIsTheOneKept() throws {
        try withTemporaryKeychain { store in
            #expect(try store.read() == nil)
            let signer = try Signer(store: store)
            let stored = try #require(try store.read())
            #expect(stored.backing == signer.backing)
            #expect(!stored.key.isEmpty)
        }
    }

    // MARK: §6.7 — the convention, at the level the app actually calls it

    /// `AchievementBytesTests` pins the convention against a bare CryptoKit key.
    /// This pins it against the type the application uses, because that is where
    /// a future session would reintroduce the double hash — by reaching for a
    /// `sign(_ text:)` helper that "already exists".
    @Test("Signer signs canonicalBytes, and the signature fails against the digest")
    func signsTheBytesAndNotTheDigest() throws {
        try withTemporaryKeychain { store in
            let signer = try Signer(store: store)
            let bytes = Data("{\"v\":1,\"id\":\"streak.habit-a.100@2026-03-14\"}".utf8)
            let digest = Data(SHA256.hash(data: bytes))

            let signature = try signer.signature(over: bytes)

            #expect(Signer.isValid(signature, over: bytes, publicKey: signer.publicKey))
            // If `SHA256(SHA256(x))` ever comes back, this flips.
            #expect(!Signer.isValid(signature, over: digest, publicKey: signer.publicKey))
        }
    }

    @Test("A tampered message fails verification without any network access")
    func tamperingIsDetectedOffline() throws {
        try withTemporaryKeychain { store in
            let signer = try Signer(store: store)
            let signature = try signer.signature(over: Data("100 consecutive days".utf8))
            #expect(
                !Signer.isValid(
                    signature, over: Data("1000 consecutive days".utf8),
                    publicKey: signer.publicKey
                )
            )
        }
    }

    // MARK: §7 — backing is recorded honestly

    /// "`backing` MUST be recorded honestly", `docs/achievement-protocol.md` §7.
    /// The software path is forced here rather than asserted about the host, so
    /// the test says the same thing on a machine with an enclave and on one
    /// without.
    ///
    /// Forcing it is also the only way to reach this branch on any machine this
    /// project has run on: every T2 and Apple Silicon Mac has an enclave, and the
    /// iOS Simulator on one uses it. §7.0 bis.
    @Test("A software key says it is a software key, and still round-trips")
    func softwareBackingIsRecordedHonestly() throws {
        try withTemporaryKeychain { store in
            let first = try Signer(store: store, preferEnclave: false)
            #expect(first.backing == .software)

            // And it restores as a software key, not as an enclave key: the two
            // representations are not interchangeable, so a wrong label is a
            // decode failure rather than a cosmetic error.
            let second = try Signer(store: store)
            #expect(second.backing == .software)
            #expect(second.publicKey == first.publicKey)
        }
    }

    @Test("The backing recorded on disk is the one that comes back")
    func theBackingRoundTrips() throws {
        try withTemporaryKeychain { store in
            for backing in SignerBacking.allCases {
                try store.write(StoredKey(backing: backing, key: Data([0xAB, 0xCD])))
                let read = try #require(try store.read())
                #expect(read.backing == backing)
                #expect(read.key == Data([0xAB, 0xCD]))
            }
        }
    }
}
