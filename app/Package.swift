// swift-tools-version: 6.0
//
// The Swift/AppKit shell (ADR-1, `2026-08-24-rust-core-swift-appkit-shell`).
//
// `swift build` alone cannot produce a runnable app: the Rust core is a
// `staticlib` that must exist before this package links. `just build` runs
// `cargo build --release` first and then `scripts/assemble-bundle.sh`; running
// `swift build` by hand needs `cargo build --release` by hand too.
//
// Layout note, because it does not match the plan's file list exactly: the app
// code lives in one *library* target (`MarkKit`) rather than in the executable,
// so that both the test target and the benchmark harness can import it. Only
// `main.swift` sits in the executable, in `Sources/MarkMain/`. Everything else
// is where the plan put it.

import Foundation
import PackageDescription

/// `app/`, resolved at manifest-evaluation time so the `-L` below is absolute
/// and does not depend on the linker's working directory.
let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = appDir.deletingLastPathComponent()

/// Both profiles are on the search path so `swift build` and `swift build -c
/// release` work against whichever `cargo` profile is present. The linker takes
/// the first `libmark_core.a` it finds.
// Linking `libmark_core.a` emits a handful of
// `ld: warning: object file (...) was built for newer 'macOS' version (26.0)
// than being linked (14.0)` lines. They come from Rust's *precompiled* std,
// which the Homebrew toolchain ships built for the host OS; `.cargo/config.toml`
// pins MACOSX_DEPLOYMENT_TARGET for everything cargo compiles itself, which
// removes the rest. Silencing the remainder would mean `-Wl,-w`, which would
// also hide real linker warnings, so they are left visible and explained here.
let coreLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(repoRoot.appendingPathComponent("target/release").path)",
        "-L\(repoRoot.appendingPathComponent("target/debug").path)",
    ]),
    .linkedLibrary("mark_core"),
]

// swift-testing on a machine with **Command Line Tools instead of a full
// Xcode**, which is what this one has (`xcode-select -p` →
// `/Library/Developer/CommandLineTools`).
//
// SwiftPM does not wire swift-testing up in that configuration, and it fails in
// three separate stages, each with a different-looking error:
//
//   1. `import Testing` → "no such module 'Testing'" — the framework is in
//      `Library/Developer/Frameworks`, which is not on the default search path.
//   2. Then the built bundle fails to `dlopen`:
//      "Library not loaded: @rpath/Testing.framework/Versions/A/Testing".
//   3. Then `Testing.framework` itself fails to load its own dependency:
//      "Library not loaded: @rpath/lib_TestingInterop.dylib", which lives in a
//      *different* directory again.
//
// Hence a search path plus two rpaths. All of it is conditional on the CLT
// directories existing, so a machine with Xcode — where SwiftPM finds all this
// itself — gets no flags at all.
let commandLineToolsFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let commandLineToolsLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let hasCommandLineToolsFrameworks = FileManager.default.fileExists(
    atPath: commandLineToolsFrameworks)
let testSearchPath: [String] =
    hasCommandLineToolsFrameworks ? ["-F", commandLineToolsFrameworks] : []
let testLinkPath: [String] =
    hasCommandLineToolsFrameworks
    ? [
        "-F", commandLineToolsFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", commandLineToolsFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", commandLineToolsLib,
    ]
    : []

let package = Package(
    name: "Mark",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mark", targets: ["MarkMain"]),
        .executable(name: "mark-bench", targets: ["MarkBench"]),
        .library(name: "MarkKit", targets: ["MarkKit"]),
    ],
    targets: [
        // The hand-written C ABI from `core/include/mark.h`, reachable from
        // Swift. ADR-1 forbids a binding generator, so this is a two-line
        // system-library shim over the committed header.
        .target(
            name: "CMarkCore",
            path: "Sources/CMarkCore",
            linkerSettings: coreLinkerSettings
        ),

        // Everything the app is. `path: "."` (with explicit `sources:`) is what
        // lets the shell assets stay at `app/Resources/` where the plan put
        // them, since SwiftPM resources must live under the target root.
        .target(
            name: "MarkKit",
            dependencies: ["CMarkCore"],
            path: ".",
            exclude: [
                "Package.swift",
                "Sources/CMarkCore",
                "Sources/MarkMain",
                "Sources/MarkBench",
                "Tests",
                // `path: "."` means SwiftPM sees everything under `app/`, and
                // the benchmark's screenshots land in `app/target/` when
                // `mark-bench` is run from this directory. Without this every
                // build prints *"found 5 file(s) which are unhandled"* and
                // names them — a warning about output, on every build, that a
                // new contributor has to decide is harmless.
                "target",
            ],
            sources: ["Sources/Mark"],
            resources: [
                .copy("Resources/shell.html"),
                .copy("Resources/shell.js"),
                .copy("Resources/shell.css"),
                // The markdown reference (Help ▸ Markdown Reference), which is
                // a *document* rather than a shell asset: it is read by Swift
                // and rendered by the core, never served over `mark-asset`.
                // It lives here rather than in `docs/` because a SwiftPM
                // resource must be under the target root, and one copy that
                // ships is better than two that can disagree.
                .copy("Resources/markdown-reference.md"),
            ]
        ),

        .executableTarget(
            name: "MarkMain",
            dependencies: ["MarkKit"],
            path: "Sources/MarkMain"
        ),

        // The ADR-2 gate: core render + inject + first paint, measured in a
        // real window, failing above a committed threshold. `just bench-app`.
        .executableTarget(
            name: "MarkBench",
            dependencies: ["MarkKit"],
            path: "Sources/MarkBench"
        ),

        // `CMarkCore` as well as `MarkKit`: the leak test asserts on the raw
        // ABI, since ADR-1's `mark_free` rule is about the pointer, not about
        // the Swift wrapper that happens to hold it.
        .testTarget(
            name: "MarkTests",
            dependencies: ["MarkKit", "CMarkCore"],
            path: "Tests/MarkTests",
            swiftSettings: testSearchPath.isEmpty ? [] : [.unsafeFlags(testSearchPath)],
            linkerSettings: testLinkPath.isEmpty ? [] : [.unsafeFlags(testLinkPath)]
        ),
    ]
)
