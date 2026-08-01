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

    // MARK: The settings sheet's export — the same bundle, by construction

    /// **The bundle the settings sheet hands to `fileExporter` is the bundle
    /// this suite has been checking since week 1, file for file and byte for
    /// byte.**
    ///
    /// That is the assertion the export control needs and the one a surface
    /// cannot make about itself. `Exporter.bundle(at:)` is the single place that
    /// decides what a bundle contains; ``CompassInfrastructure/Exporter/export(to:at:)``
    /// writes what it returns and adds nothing. This walks the directory that was
    /// written and requires the two to agree in **both** directions, which is
    /// what makes it a comparison rather than a spot check.
    ///
    /// Both directions matter for a specific reason: the in-memory form is what
    /// the user receives, so a member only the disk writer produces is a member
    /// the user never gets, and a member only the in-memory form produces is one
    /// no test in this suite has ever looked at.
    @Test("the in-memory bundle is exactly the bundle export writes to disk")
    func theInMemoryBundleIsTheWrittenBundle() throws {
        try withTemporaryStore { store in
            try seed(store)
            try withTemporaryStore { elsewhere in
                let directory = elsewhere.storeURL
                    .appendingPathComponent("bundle", isDirectory: true)
                let exporter = Exporter(layout: store)
                try exporter.export(to: directory, at: exportedAt)
                let inMemory = try exporter.bundle(at: exportedAt)

                var onDisk: [String: Data] = [:]
                for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
                    let url = directory.appendingPathComponent(path)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(
                        atPath: url.path, isDirectory: &isDirectory
                    ), !isDirectory.boolValue else { continue }
                    onDisk[path] = try Data(contentsOf: url)
                }

                #expect(inMemory.files.keys.sorted() == onDisk.keys.sorted())
                for (name, bytes) in onDisk {
                    #expect(inMemory.files[name] == bytes, "\(name) differs")
                }
                // `manifest.json` is in the in-memory form too — it is the member
                // a reader checks first, and a bundle handed over without it is
                // one nothing can check at all.
                #expect(inMemory.files[BundleFile.manifest] != nil)
                #expect(inMemory.exportedAt == exportedAt)
            }
        }
    }

    /// A bundle written from **the in-memory form alone** verifies.
    ///
    /// The test above proves the two forms agree. This proves the form the
    /// settings sheet actually produces is a bundle rather than a dictionary that
    /// happens to match one: a manifest that digests every member, and every
    /// digest recomputed from what was written.
    @Test("a bundle written from the in-memory form alone verifies")
    func theInMemoryBundleStandsOnItsOwn() throws {
        try withTemporaryStore { store in
            try seed(store)
            try withTemporaryStore { elsewhere in
                let bundle = try Exporter(layout: store).bundle(at: exportedAt)
                let directory = elsewhere.storeURL
                    .appendingPathComponent("handed-over", isDirectory: true)

                // Exactly what `BundleDocument` does with the same value, and
                // nothing else: create the directory a path names, write the
                // bytes under it.
                for (path, data) in bundle.files.sorted(by: { $0.key < $1.key }) {
                    let url = directory.appendingPathComponent(path)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try data.write(to: url)
                }

                try Exporter(layout: store).verify(bundleAt: directory)
            }
        }
    }

    /// The composition root wires it, which is the difference between a port that
    /// exists and a control that works.
    ///
    /// `App/` is not compiled by `swift test` and the settings sheet is a `View`
    /// no test can drive, so this is the last link of the chain anything can
    /// assert: a launch produces a store whose ``CompassDomain/Exporting`` port
    /// returns the same bundle `Exporter` does. Deleting the `exporting:`
    /// argument in `Composition.swift` fails here and nowhere else.
    @Test("a composed launch can export, and exports the same bundle")
    func theComposedStoreExports() async throws {
        try await withTemporaryStoreAsync { layout in
            try seed(layout)
            let clock = frozenClock(at: "2026-07-31T09:00:00+07:00")
            let store = AppComposition.compose(storeURL: layout.storeURL, clock: clock)

            let exporting = try #require(store.exporting)
            let viaPort = try await exporting.exportBundle()
            let direct = try Exporter(layout: layout).bundle(at: clock.now())

            #expect(viaPort.files == direct.files)
            #expect(viaPort.exportedAt == clock.now())
        }
    }
}
