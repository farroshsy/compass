import CompassDomain
import CompassInfrastructure
import CryptoKit
import Foundation
import Testing

/// Export is a **bundle**, not a log dump, and it ships in week 1.
/// `docs/technical.md` §8 and §10a, `docs/product.md`, ADR 0002.
@Suite("Export — the bundle, and the restore that makes it worth having")
struct ExportTests {

    private let exportedAt = instant("2026-07-31T09:00:00+07:00")

    /// Two habits, a rename, a few days, one revoked day.
    private func seed(_ layout: StoreLayout) throws {
        let journal = try EventJournal(layout: layout, writer: writerApp, clock: frozenClock())
        try journal.record(kind: .habitCreated, day: day("2026-07-01"),
                           payload: .habit(habitA, name: "Meditate"))
        try journal.record(kind: .habitCreated, day: day("2026-07-01"),
                           payload: .habit(habitB, name: "Read"))
        for offset in 0..<5 {
            try journal.record(kind: .checkedIn, day: day("2026-07-01").adding(offset),
                               source: .tap, payload: .habit(habitA))
        }
        try journal.record(kind: .checkInRevoked, day: day("2026-07-03"),
                           payload: .habit(habitA))
        try journal.record(kind: .habitRenamed, day: day("2026-07-06"),
                           payload: .habit(habitB, name: "Read a book"))
        journal.close()
    }

    @Test("the bundle has the documented shape")
    func bundleShape() throws {
        try withTemporaryStore { store in
            try seed(store)
            try withTemporaryStore { elsewhere in
                let bundle = elsewhere.storeURL.appendingPathComponent("bundle", isDirectory: true)
                let manifest = try Exporter(layout: store).export(to: bundle, at: exportedAt)

                let files = FileManager.default
                #expect(files.fileExists(atPath: bundle.appendingPathComponent("events.jsonl").path))
                #expect(files.fileExists(atPath: bundle.appendingPathComponent("habits.json").path))
                #expect(files.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))

                // Omitted because the features that produce them do not exist
                // yet — weeks 3 and 4. A placeholder would be indistinguishable
                // from a real file that lost its contents.
                for absent in ["awards.jsonl", "attestations.jsonl", "publickey.pem", "salts.json"] {
                    #expect(!files.fileExists(atPath: bundle.appendingPathComponent(absent).path))
                }

                // The manifest covers every file in the bundle except itself.
                #expect(manifest.files.keys.sorted() == ["events.jsonl", "habits.json"])
                #expect(manifest.exportedAt == 1_785_463_200_000)

                for (name, digest) in manifest.files {
                    let data = try Data(contentsOf: bundle.appendingPathComponent(name))
                    let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    #expect(actual == digest, "manifest digest for \(name) is wrong")
                }

                // The log is copied byte for byte, not re-encoded.
                let copied = try Data(contentsOf: bundle.appendingPathComponent("events.jsonl"))
                let original = try rawLog(store)
                #expect(copied == original)
            }
        }
    }

    @Test("habits.json resolves a name that is deliberately absent from every digest")
    func habitNamesTravelOutsideTheDigest() throws {
        try withTemporaryStore { store in
            try seed(store)
            try withTemporaryStore { elsewhere in
                let bundle = elsewhere.storeURL.appendingPathComponent("bundle", isDirectory: true)
                try Exporter(layout: store).export(to: bundle, at: exportedAt)

                let data = try Data(contentsOf: bundle.appendingPathComponent("habits.json"))
                let names = try JSONDecoder().decode([String: String].self, from: data)
                #expect(names == ["habit-a": "Meditate", "habit-b": "Read a book"])
            }
        }
    }

    @Test("a fresh install fed only the bundle reproduces the same state")
    func restoreRoundTrip() throws {
        try withTemporaryStore { store in
            try seed(store)
            let before = project(try JournalReader(url: store.events).read().events)

            try withTemporaryStore { newPhone in
                let bundle = newPhone.storeURL.appendingPathComponent("bundle", isDirectory: true)
                try Exporter(layout: store).export(to: bundle, at: exportedAt)

                try withTemporaryStore { restored in
                    try Exporter(layout: restored).restore(from: bundle)
                    let after = project(try JournalReader(url: restored.events).read().events)

                    #expect(after == before)
                    #expect(after.habit(habitA)?.checkedDays.count == 4)
                    #expect(after.habit(habitB)?.name == "Read a book")

                    // And the restored log is a log: the writer's sequence
                    // resumes rather than colliding with imported events.
                    let journal = try EventJournal(
                        layout: restored, writer: writerApp, clock: frozenClock()
                    )
                    let next = try journal.record(
                        kind: .checkedIn, day: day("2026-07-06"), source: .tap,
                        payload: .habit(habitB)
                    )
                    #expect(next.lamport == 10)
                }
            }
        }
    }

    @Test("verify rejects a tampered bundle")
    func tamperedBundleIsRefused() throws {
        try withTemporaryStore { store in
            try seed(store)
            try withTemporaryStore { elsewhere in
                let bundle = elsewhere.storeURL.appendingPathComponent("bundle", isDirectory: true)
                try Exporter(layout: store).export(to: bundle, at: exportedAt)

                let events = bundle.appendingPathComponent("events.jsonl")
                var bytes = try Data(contentsOf: events)
                bytes.append(contentsOf: Data("{}\n".utf8))
                try bytes.write(to: events)

                #expect(throws: ExportError.self) {
                    try Exporter(layout: store).verify(bundleAt: bundle)
                }
                try withTemporaryStore { restored in
                    #expect(throws: ExportError.self) {
                        try Exporter(layout: restored).restore(from: bundle)
                    }
                    #expect(!FileManager.default.fileExists(atPath: restored.events.path))
                }
            }
        }
    }

    @Test("restore refuses to land on top of an existing log")
    func restoreDoesNotMerge() throws {
        try withTemporaryStore { store in
            try seed(store)
            try withTemporaryStore { elsewhere in
                let bundle = elsewhere.storeURL.appendingPathComponent("bundle", isDirectory: true)
                try Exporter(layout: store).export(to: bundle, at: exportedAt)

                #expect(throws: ExportError.storeNotEmpty) {
                    try Exporter(layout: store).restore(from: bundle)
                }
                // The store it refused to overwrite is untouched.
                #expect(try JournalReader(url: store.events).read().events.count == 9)
            }
        }
    }

    @Test("a bundle member this build has never heard of is installed, not dropped")
    func unknownBundleMemberSurvivesRestore() throws {
        try withTemporaryStore { store in
            try seed(store)
            try withTemporaryStore { elsewhere in
                let bundle = elsewhere.storeURL.appendingPathComponent("bundle", isDirectory: true)
                try Exporter(layout: store).export(to: bundle, at: exportedAt)
                // A file a newer build wrote — week 4's public key, say.
                try addMember("publickey.pem", Data("-----BEGIN PUBLIC KEY-----".utf8), to: bundle)

                try withTemporaryStore { restored in
                    try Exporter(layout: restored).restore(from: bundle)
                    #expect(
                        FileManager.default.fileExists(
                            atPath: restored.storeURL.appendingPathComponent("publickey.pem").path
                        )
                    )
                }
            }
        }
    }

    @Test("restore refuses a manifest entry that would write outside the store")
    func restoreRefusesToEscapeTheStore() throws {
        try withTemporaryStore { store in
            try seed(store)
            try withTemporaryStore { elsewhere in
                let bundle = elsewhere.storeURL.appendingPathComponent("bundle", isDirectory: true)
                try Exporter(layout: store).export(to: bundle, at: exportedAt)
                try addMember("../escaped.json", Data("{}".utf8), to: bundle)

                try withTemporaryStore { restored in
                    #expect(throws: ExportError.unsafeFileName("../escaped.json")) {
                        try Exporter(layout: restored).restore(from: bundle)
                    }
                }
            }
        }
    }

    /// Writes `data` into the bundle under `name` and records its digest, the
    /// way a newer build's exporter would have.
    private func addMember(_ name: String, _ data: Data, to bundle: URL) throws {
        let url = bundle.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)

        let manifestURL = bundle.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            ExportManifest.self, from: try Data(contentsOf: manifestURL)
        )
        var files = manifest.files
        files[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(ExportManifest(exportedAt: manifest.exportedAt, files: files))
            .write(to: manifestURL)
    }

    @Test("an empty store still exports a well-formed bundle")
    func emptyStoreExports() throws {
        try withTemporaryStore { store in
            try withTemporaryStore { elsewhere in
                let bundle = elsewhere.storeURL.appendingPathComponent("bundle", isDirectory: true)
                let manifest = try Exporter(layout: store).export(to: bundle, at: exportedAt)

                #expect(manifest.files.keys.sorted() == ["events.jsonl", "habits.json"])
                try Exporter(layout: store).verify(bundleAt: bundle)
            }
        }
    }
}
