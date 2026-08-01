//  Signer — copied in from the `before` repository, `Sources/BeforeKit/Seal.swift`,
//  on 2026-08-01. `docs/technical.md` §1: the consumption mechanism is copying
//  the source in, never an SPM path dependency, a submodule or a symlink — a
//  build that breaks because an unrelated folder was tidied is a restart trigger,
//  and that folder sits in a downloads directory that gets cleaned.
//
//  **Three things were fixed while copying, not copied verbatim** (§1, §8):
//
//  1. `Signer.sign(_ text:)` is not copied at all. It computes `SHA256(text)` and
//     hands the resulting `Data` to CryptoKit's `DataProtocol` overload, which
//     hashes again — so it signs `SHA256(SHA256(text))`. The originating app
//     verifies the same way and is self-consistent, but Compass promises an
//     external verifier and an on-chain WebAuthn verifier would reject a
//     double-hashed signature outright. `docs/achievement-protocol.md` §6.7 fixes
//     the convention and ``signature(over:)`` below is it.
//  2. The inherited `init(preferEnclave:)` unconditionally mints a **new** enclave
//     key on every construction and there is no initialiser that restores one, so
//     every launch would sign with a different public key and "these achievements
//     came from one device" would be false. The key is now persisted and restored
//     — see ``KeychainStore``.
//  3. `Entry`, `Entry.sealBytes` and `seal(_:at:)` are not copied. The canonical
//     bytes discipline they demonstrate is copied instead, as a discipline, into
//     `CompassDomain/CanonicalBytes.swift`.

import CompassDomain
import CryptoKit
import Foundation
import Security

/// The only key in v1: a **Secure Enclave P-256 signing key**, created on first
/// launch, non-extractable, used to sign achievement digests.
/// `docs/technical.md` §8.
///
/// It is never shown, never named, never exported, and the user is never told it
/// exists. Where there is no enclave the key falls back to software, and
/// ``backing`` records which of the two actually signed.
///
/// **The fallback is not the simulator case**, though this comment said it was
/// until 2026-08-01. `SecureEnclave.isAvailable` is `true` inside the iOS
/// Simulator on any host that has an enclave — every T2 and Apple Silicon Mac —
/// so the simulator mints a real enclave key, in the *host's* enclave, and the
/// record honestly says `secureEnclave`. Measured on this machine, an Intel Mac
/// with an Apple T2 Security Chip. The software branch below is reached only on a
/// host with no Secure Enclave at all, or when a test passes `preferEnclave:
/// false`.
///
/// So ``backing`` answers "what backed this key" and has never answered "what
/// kind of machine ran the app". `docs/achievement-protocol.md` §7.0 bis is what
/// its rule can and cannot deliver, and `memory/known-bugs.md` records the gap.
public struct Signer: Sendable {

    /// Recorded on every attestation. `docs/achievement-protocol.md` §7.
    public let backing: SignerBacking

    private let enclaveKey: SecureEnclave.P256.Signing.PrivateKey?
    private let softwareKey: P256.Signing.PrivateKey?

    /// Restores this device's key, or mints and persists one on first use.
    ///
    /// **"Created on first launch" is a promise the inherited code cannot keep**,
    /// and this initialiser is the fix `docs/technical.md` §8 specifies. Without
    /// it, `SecureEnclave.P256.Signing.PrivateKey()` runs on every construction
    /// and the public key changes every launch.
    ///
    /// `preferEnclave` exists so a test can exercise the software path on a
    /// machine that has an enclave. It is never `false` in the app.
    public init(store: KeychainStore, preferEnclave: Bool = true) throws {
        if let stored = try store.read() {
            switch stored.backing {
            case .secureEnclave:
                enclaveKey = try SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: stored.key
                )
                softwareKey = nil
                backing = .secureEnclave
            case .software:
                softwareKey = try P256.Signing.PrivateKey(rawRepresentation: stored.key)
                enclaveKey = nil
                backing = .software
            }
            return
        }

        if preferEnclave, SecureEnclave.isAvailable {
            let key = try SecureEnclave.P256.Signing.PrivateKey()
            // The enclave's `dataRepresentation` is an encrypted blob only this
            // device's enclave can use, so persisting it is not an export: the
            // private key still never leaves the enclave. That is why §8 asks for
            // the keychain rather than for a key that can be reconstructed.
            try store.write(StoredKey(backing: .secureEnclave, key: key.dataRepresentation))
            enclaveKey = key
            softwareKey = nil
            backing = .secureEnclave
        } else {
            let key = P256.Signing.PrivateKey()
            try store.write(StoredKey(backing: .software, key: key.rawRepresentation))
            softwareKey = key
            enclaveKey = nil
            backing = .software
        }
    }

    /// X9.63, the same representation the inherited code used, so a key exported
    /// from either project is readable by the other's verifier.
    public var publicKey: Data {
        if let enclaveKey { return enclaveKey.publicKey.x963Representation }
        return softwareKey.unsafelyUnwrapped.publicKey.x963Representation
    }

    /// **The signing convention, `docs/achievement-protocol.md` §6.7.**
    ///
    /// ```swift
    /// let signature = try privateKey.signature(for: canonicalBytes).rawRepresentation
    /// ```
    ///
    /// The `DataProtocol` overload hashes its argument **once**, so the signed
    /// message is `SHA-256(canonicalBytes)` — which is exactly `digest` as §6.6
    /// defines it. **There is no second hash.** A verifier recomputes
    /// `canonicalBytes` and passes that same byte string to both the hash and the
    /// signature check; it never signs or verifies over `digest` itself.
    ///
    /// The parameter is named `canonicalBytes` rather than `data` on purpose: the
    /// one way to get this wrong is to hand it the digest, and a call site reading
    /// `signature(over: digest)` should look wrong.
    public func signature(over canonicalBytes: Data) throws -> Data {
        if let enclaveKey {
            return try enclaveKey.signature(for: canonicalBytes).rawRepresentation
        }
        return try softwareKey.unsafelyUnwrapped.signature(for: canonicalBytes).rawRepresentation
    }

    /// The mirror of ``signature(over:)``:
    /// `publicKey.isValidSignature(sig, for: canonicalBytes)`.
    ///
    /// It is `static` and takes the public key because verification is not a
    /// property of holding the private key — the standalone verifier in week 4
    /// does exactly this with nothing but the export bundle.
    public static func isValid(
        _ signature: Data, over canonicalBytes: Data, publicKey: Data
    ) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { return false }
        return key.isValidSignature(parsed, for: canonicalBytes)
    }
}

/// What the keychain holds: which kind of key, and its bytes.
public struct StoredKey: Hashable, Sendable {
    public let backing: SignerBacking
    /// The enclave key's `dataRepresentation`, or a software key's
    /// `rawRepresentation`.
    public let key: Data

    public init(backing: SignerBacking, key: Data) {
        self.backing = backing
        self.key = key
    }
}

/// The one keychain item this application owns. `docs/technical.md` §8.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, exactly as §8 requires:
/// **after first unlock**, because a background pass must be able to construct
/// the signer while the phone is locked, and **this device only**, because a key
/// that syncs to iCloud is not a device attestation.
///
/// It is a plain struct with an injectable service name rather than a protocol
/// with a fake behind it. `PROJECT_CONSTITUTION.md` §8 forbids an abstraction
/// with a single use site, and there is only one implementation that could ever
/// ship — so the relaunch test in `docs/technical.md` §9.12 drives the **real**
/// keychain under its own service name and deletes what it wrote. A fake would
/// have made that test pass while the two `SecItem` calls that actually decide
/// whether the key survives went unexercised.
public struct KeychainStore: Sendable {

    /// Defaults to the bundle identifier's namespace. Injectable so a test can
    /// take a service of its own and clean up after itself.
    public let service: String
    public let account: String

    public init(
        service: String = "dev.farros.compass.signing",
        account: String = "achievement-key"
    ) {
        self.service = service
        self.account = account
    }

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored key, or `nil` when there is none yet.
    ///
    /// The backing is stored as one leading byte rather than as a second keychain
    /// item, because the two values are only ever correct together: a key restored
    /// as the wrong kind is not a wrong label, it is a decode failure or — worse —
    /// a valid-looking key that signs with something the enclave never held.
    public func read() throws -> StoredKey? {
        var query = base
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let tag = data.first else {
            throw KeychainError.readFailed(status: status)
        }
        guard let backing = KeychainStore.backing(forTag: tag) else {
            throw KeychainError.unknownBacking(tag: tag)
        }
        return StoredKey(backing: backing, key: data.dropFirst())
    }

    /// Writes the key, replacing whatever was there.
    ///
    /// It replaces rather than refusing, because the only caller writes exactly
    /// once — on the launch that finds nothing — and a `Signer` that could not
    /// recover from a half-written item would leave the app unable to seal
    /// anything, forever, with no way to say so.
    public func write(_ stored: StoredKey) throws {
        var payload = Data([KeychainStore.tag(for: stored.backing)])
        payload.append(stored.key)

        var attributes = base
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: payload] as CFDictionary
            )
            guard update == errSecSuccess else {
                throw KeychainError.writeFailed(status: update)
            }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.writeFailed(status: status) }
    }

    /// Removes the item. Used by the tests that create one, and by nothing in the
    /// application: **there is no code path in Compass that destroys the signing
    /// key.** Losing it loses the ability to extend this device's chain, and
    /// `docs/technical.md` §6 lists a signature as unrecomputable once the key is
    /// gone.
    @discardableResult
    public func delete() -> Bool {
        SecItemDelete(base as CFDictionary) == errSecSuccess
    }

    private static func tag(for backing: SignerBacking) -> UInt8 {
        switch backing {
        case .secureEnclave: 0x01
        case .software: 0x02
        }
    }

    private static func backing(forTag tag: UInt8) -> SignerBacking? {
        switch tag {
        case 0x01: .secureEnclave
        case 0x02: .software
        default: nil
        }
    }
}

public enum KeychainError: Error, Hashable, Sendable {
    case readFailed(status: OSStatus)
    case writeFailed(status: OSStatus)
    /// A stored item this build does not recognise. Reported rather than
    /// overwritten: a key it cannot read is still the only copy of a key.
    case unknownBacking(tag: UInt8)
}
