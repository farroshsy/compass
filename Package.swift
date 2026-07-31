// swift-tools-version: 6.2
//
// Compass — one SPM package, four targets. `docs/technical.md` §2.
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
        // imports: Foundation only.
        .target(name: "CompassDomain"),
        .target(name: "CompassApplication", dependencies: ["CompassDomain"]),
        .target(name: "CompassInfrastructure", dependencies: ["CompassDomain"]),
        .target(name: "CompassUI", dependencies: ["CompassApplication", "CompassDomain"]),

        // The largest suite, and the only one that is pure with no filesystem at
        // all. Milliseconds. **Counted on 2026-08-01: 85 of 218 tests, 39%.**
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
        // The impure ones: a real file on a real filesystem, a real timezone.
        .testTarget(
            name: "CompassInfrastructureTests",
            dependencies: ["CompassInfrastructure", "CompassDomain"]
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
