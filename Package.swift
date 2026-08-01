// swift-tools-version: 6.2
//
// Compass — one SPM package. Four library targets, plus one executable that
// exists only so a test can spawn a second process. `docs/technical.md` §2.
//
// Swift enforces `import` at target granularity, so a target that does not
// declare a dependency physically cannot import it. That is the boundary guard,
// and only one boundary is load-bearing: CompassDomain must not know
// CompassInfrastructure exists.
//
// Third-party dependencies: none. `docs/technical.md` §1.

import PackageDescription

let package = Package(
    name: "compass",
    platforms: [
        // iOS 18 is the product minimum (`Synchronization.Mutex`, `ControlWidget`).
        // macOS is declared only so the pure Domain suite runs under `swift test`
        // with no simulator — see `README.md` and `memory/next-tasks.md`.
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CompassDomain", targets: ["CompassDomain"]),
        .library(name: "CompassApplication", targets: ["CompassApplication"]),
        .library(name: "CompassInfrastructure", targets: ["CompassInfrastructure"]),
        .library(name: "CompassUI", targets: ["CompassUI"]),
    ],
    targets: [
        // imports: Foundation and CryptoKit.
        .target(name: "CompassDomain"),
        .target(name: "CompassApplication", dependencies: ["CompassDomain"]),
        // **Infrastructure gained `CompassApplication` in week 2**, when the
        // widget became a second writer. `CheckIn.toggle` is the single append
        // API `docs/technical.md` §11 requires both writers to use, and the
        // widget's path into the store is Infrastructure — it reads the log, it
        // takes the `flock`, it writes the disposable cache. The alternatives
        // were to duplicate the decision in the widget path, which is the fork §4
        // exists to prevent, or to move `CheckIn` into Domain, which reverses a
        // written decision to buy nothing. The edge runs Infrastructure ->
        // Application -> Domain: no cycle, and the one load-bearing boundary —
        // Domain must not know Infrastructure exists — is untouched.
        // `docs/technical.md` §2, `memory/decisions.md` 2026-08-01.
        //
        // **The rule JSON is a resource, because rules are data.**
        // `docs/technical.md` §5: "A rule is a `RuleSpec` value shipped as JSON in
        // the bundle... Adding an achievement is a JSON row, not a code change."
        // `Sources/CompassInfrastructure/Rules/` is copied verbatim, and
        // `RuleStore` seeds it into the store's own `rules/` directory so that §6's
        // "bundle + user directory, hot-reloadable" and §8's `rules/*.json` in the
        // export bundle are both literally true. `.copy` rather than `.process`:
        // these files are read as bytes and must not be re-encoded by a build
        // phase that has its own opinion about JSON.
        .target(
            name: "CompassInfrastructure",
            dependencies: ["CompassApplication", "CompassDomain"],
            resources: [.copy("Rules")]
        ),
        //
        // **The only image asset in the product besides the app icon: the seal
        // die frame, with no matrix in it.** The 64 cells are struck over it in
        // SwiftUI at issue time, per turn 5d of the design, because a pre-baked
        // matrix PNG would print an identical hallmark on every certificate and
        // destroy the exact property the impression is for — that two records can
        // never carry the same one. `Assets/seal/README.md`, `SealView`.
        //
        // `Assets/seal/reference/matrix-*` are comparison targets and are **not**
        // here and must never be: they are one particular record's die.
        // `SealTests` asserts that no matrix asset has been linked in.
        //
        // They are four loose PNGs rather than an asset catalogue, and that is a
        // testability decision rather than a taste one: `swift build` does not run
        // `actool`, so a catalogue is copied verbatim into the bundle on macOS and
        // every lookup inside it fails — which would make `SealTests`' guard
        // against a matrix render passing vacuously, on the one assertion in the
        // suite that exists to stop a false statement reaching a signed document.
        // `SealView` already knows the appearance, so choosing the file is one
        // line and buys back a test that actually runs.
        .target(
            name: "CompassUI",
            dependencies: ["CompassApplication", "CompassDomain"],
            resources: [.copy("SealFrames")]
        ),

        // The second process in the two-writer test, and nothing else.
        // `docs/technical.md` §9.10 requires two **processes** appending to one
        // file, and says why in the same breath: every other test in the suite
        // uses synthesised in-process streams and would pass while real data
        // corrupts. A test that cannot spawn a second process cannot make that
        // assertion, so the process it spawns is built here.
        //
        // It is deliberately not a product: nothing links it, the app never sees
        // it, and it ships nowhere. `swift test` builds it because
        // `CompassInfrastructureTests` depends on it, which is also what stops it
        // rotting.
        .executableTarget(
            name: "CompassLogWriter",
            dependencies: ["CompassInfrastructure", "CompassDomain"]
        ),

        // The largest suite, and the only one that is pure with no filesystem at
        // all. Milliseconds. **Counted on 2026-08-01 after week 4: 170 of 482
        // tests, 35%.**
        // This comment said "~80% of all tests" until then, which was written
        // before any test existed and was never re-measured; four documents had
        // copied it. If it drifts again, count with
        // `grep -h '^\s*@Test' Tests/*/*.swift | wc -l` per directory — the
        // totals line up with what `swift test` reports.
        .testTarget(name: "CompassDomainTests", dependencies: ["CompassDomain"]),
        .testTarget(
            name: "CompassApplicationTests",
            dependencies: ["CompassApplication", "CompassDomain"]
        ),
        // The impure ones: a real file on a real filesystem, a real timezone, and
        // from week 2 a real second process — see ``CompassLogWriter``.
        .testTarget(
            name: "CompassInfrastructureTests",
            dependencies: [
                "CompassInfrastructure", "CompassApplication", "CompassDomain",
                "CompassLogWriter",
            ]
        ),
        // `TodayModel` only — the tap path and the launch path, against fake
        // ports. Not SwiftUI snapshot tests and not XCUITest, both of which
        // `.claude/skills/testing.md` says out loud not to write.
        .testTarget(
            name: "CompassUITests",
            dependencies: ["CompassUI", "CompassApplication", "CompassDomain"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
