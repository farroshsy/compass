import CompassDomain
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// What the settings sheet's export control produced.
///
/// It is a value rather than a `throws` because the sheet has to *say* something
/// either way, and what it says is copy — so the message belongs in
/// ``SettingsCopy`` beside every other sentence this app makes, where
/// `SettingsTests` can hold it to the same rule about claims it has not earned.
public enum ExportOutcome: Sendable {
    case ready(ExportBundle)
    /// The sentence to render. Never an `Error`: an error's description is a
    /// Swift type name, and the settings sheet is not a debugger.
    case failed(String)
}

/// The export bundle as a document `fileExporter` can write.
///
/// ### Why `fileExporter` and not `ShareLink`
///
/// `.claude/skills/ui.md`: "Exactly one `ShareLink`, on the certificate,
/// rendered via `ImageRenderer`." That is not a stylistic preference —
/// `docs/product.md` builds the certificate's whole justification on being the
/// one thing you hand to someone, and a second share sheet elsewhere in the app
/// makes the sentence false. Export is not sharing an image; it is producing the
/// file the standalone verifier reads. `fileExporter` puts it in Files, iCloud
/// Drive or wherever the user keeps things, and the app never learns where.
///
/// ### Why a directory and not a zip
///
/// `docs/technical.md` §8 says export produces "a directory or zip", and every
/// other artefact in the project is built around the directory: `Exporter.export`
/// writes one, `Exporter.restore` reads one, and `verifier/compass-verify.py`
/// takes one as its only argument. A zip would add a second shape of the same
/// thing, and the compression would have to come from somewhere — the project
/// has no third-party dependencies and `docs/technical.md` §10 has no fired
/// trigger for one.
///
/// So this is a directory `FileWrapper`, and `manifest.json` inside it means a
/// bundle that survives the trip is checkable and one that does not is caught.
///
/// ### What is not tested here, said out loud
///
/// The picker itself is not driven by any test. `.claude/skills/testing.md`
/// refuses snapshot tests and a broad XCUITest suite, so nothing in this project
/// can assert that a system sheet appeared or that a folder landed on disk. What
/// **is** tested is everything that decides the answer: that ``fileWrapper(configuration:)``
/// reproduces the bundle `Exporter` produces, byte for byte, file for file, and
/// that the filename is what it claims. `memory/known-bugs.md` carries the gap.
public struct BundleDocument: FileDocument {

    /// A directory. The bundle is a set of named files, one of which digests the
    /// others, and it is read by a script that takes a directory path.
    public static let readableContentTypes: [UTType] = [.folder]
    public static let writableContentTypes: [UTType] = [.folder]

    public let bundle: ExportBundle

    public init(bundle: ExportBundle) {
        self.bundle = bundle
    }

    /// **Import is not a feature of this type.** `Exporter.restore(from:)` is the
    /// import path and it is deliberately not on a surface: it refuses a store
    /// that is not empty, because merging two logs is sync's job and doing it on
    /// the one path whose purpose is rescue is how the rescue destroys what it
    /// was called to save. A `FileDocument` must offer this initialiser, so it
    /// refuses rather than half-implementing one.
    public init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        directoryWrapper()
    }

    /// One `FileWrapper` per member, nested under the directories the member
    /// paths name — `rules/`, `proofs/`.
    ///
    /// **It takes no `WriteConfiguration`, and that is the whole reason it is a
    /// separate method.** `FileDocumentWriteConfiguration` has no accessible
    /// initialiser, so a test cannot construct one — and a thing that can only be
    /// called by SwiftUI is a thing only SwiftUI has ever checked. The
    /// conformance above is one line of forwarding; every byte this control hands
    /// over is decided here, where `ExportControlTests` drives it.
    ///
    /// Paths come from `CompassInfrastructure`'s `BundleFile` and from
    /// identifiers this app minted, never from anything a user typed, so there is
    /// nothing here to sanitise. A member with an unexpected number of path
    /// components is dropped rather than flattened: a bundle missing a file fails
    /// its own manifest check loudly on the far side, and one carrying a file
    /// under a name nothing expects would not.
    public func directoryWrapper() -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        var directories: [String: FileWrapper] = [:]

        for (path, data) in bundle.files.sorted(by: { $0.key < $1.key }) {
            let parts = path.split(separator: "/").map(String.init)
            let leaf = FileWrapper(regularFileWithContents: data)

            switch parts.count {
            case 1:
                leaf.preferredFilename = parts[0]
                root.addFileWrapper(leaf)
            case 2:
                leaf.preferredFilename = parts[1]
                let directory = directories[parts[0]] ?? {
                    let made = FileWrapper(directoryWithFileWrappers: [:])
                    made.preferredFilename = parts[0]
                    directories[parts[0]] = made
                    root.addFileWrapper(made)
                    return made
                }()
                directory.addFileWrapper(leaf)
            default:
                continue
            }
        }
        return root
    }
}
