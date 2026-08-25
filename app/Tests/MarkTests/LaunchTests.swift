import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The launch path, and what it says about itself.
///
/// Two things live here that used to have no home: the order in which a
/// document handed to a *launching* app arrives, and the build string that
/// makes one install distinguishable from another.
@Suite("Launch — documents handed to a launching app, and which build it is")
@MainActor
struct LaunchTests {

    // MARK: - The cold-launch open

    /// The regression. `open README.md` put up a window with the document
    /// nowhere in it, and the reason is an ordering nobody chooses:
    /// `NSApplication.finishLaunching` dispatches the queued
    /// `kAEOpenDocuments` Apple event — `application(_:open:)` — *before*
    /// posting `applicationDidFinishLaunching`, which is where this app builds
    /// its window. The delegate's `guard let controller … else { return }` was
    /// therefore the normal case for a Finder launch, not the exceptional one.
    @Test("a URL that arrives before the window is held, not dropped")
    func urlsBeforeTheWindowAreHeld() {
        let delegate = AppDelegate()
        let url = URL(fileURLWithPath: "/tmp/held.md")

        delegate.application(NSApplication.shared, open: [url])

        #expect(delegate.pendingURLs == [url])
    }

    /// Both entry paths queue into the same place, and in arrival order — a
    /// `mark://` command and a document can be handed to one launch together.
    @Test("everything that arrives early is held, in order")
    func everythingEarlyIsHeld() {
        let delegate = AppDelegate()
        let file = URL(fileURLWithPath: "/tmp/held.md")
        let command = URL(string: "mark://open?path=/tmp/other.md")!

        delegate.application(NSApplication.shared, open: [file])
        delegate.application(NSApplication.shared, open: [command])

        #expect(delegate.pendingURLs == [file, command])
    }

    // MARK: - A root that is no longer there

    /// A session root outlives the directory it names — a worktree is deleted,
    /// a volume is unmounted — and the window then comes back rooted at a path
    /// with nothing in it and nothing to say why. ``Navigator`` deliberately
    /// never checks that a root exists; this check belongs to *restoring* one.
    @Test("a session root that no longer exists falls back to its nearest parent")
    func missingRootFallsBack() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let gone = parent.appendingPathComponent("deleted-worktree")

        // `.path`, not the URL: `existing` walks up with
        // `deletingLastPathComponent`, which leaves a trailing slash that no
        // caller can see and that URL equality would trip over.
        #expect(AppDelegate.existing(gone)?.path == parent.path)
        #expect(AppDelegate.existing(parent)?.path == parent.path)
    }

    @Test("a file is not a root; its directory is")
    func aFileIsNotARoot() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        try "# notes\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(AppDelegate.existing(file)?.path == directory.path)
    }

    // MARK: - Which build is this?

    @Test("the build summary is version, commit, and commit date")
    func summary() {
        let stamped: BuildInfo.Lookup = [
            "CFBundleShortVersionString": "0.2.0",
            "MarkBuildCommit": "f63a7ca",
            "MarkBuildDate": "2026-08-25",
        ].lookup

        #expect(BuildInfo.summary(stamped) == "0.2.0 (f63a7ca 2026-08-25)")
    }

    /// A build from a source tarball has no `.git` to ask, and `build.rs` and
    /// `assemble-bundle.sh` both write `unknown` rather than nothing. Reporting
    /// a blank where a commit belongs reads as the reporting being broken.
    @Test("a bundle with no stamp says so rather than reporting a blank")
    func unstamped() {
        let empty: BuildInfo.Lookup = { _ in nil }
        let blank: BuildInfo.Lookup = ["MarkBuildCommit": "", "MarkBuildDate": ""].lookup

        #expect(BuildInfo.commit(empty) == BuildInfo.unknown)
        #expect(BuildInfo.date(empty) == BuildInfo.unknown)
        #expect(BuildInfo.commit(blank) == BuildInfo.unknown)
        #expect(BuildInfo.date(blank) == BuildInfo.unknown)
    }

    /// The About panel's two fields. Left to itself it pairs
    /// `CFBundleShortVersionString` with `CFBundleVersion`, which this bundle
    /// sets to the same string — "Version 0.2.0 (0.2.0)", on every build ever
    /// made from that version.
    @Test("About names the commit, not the version twice")
    func aboutPanelNamesTheBuild() throws {
        let options = AppDelegate.aboutOptions

        let version = try #require(options[.applicationVersion] as? String)
        let build = try #require(options[.version] as? String)

        #expect(version == BuildInfo.version)
        #expect(build == "\(BuildInfo.commit) \(BuildInfo.date)")
        #expect(build != version)
    }

    /// Outside a bundle — `swift test`, `mark-bench` — there is no plist, and
    /// the core is still linked in and still knows its own version.
    @Test("with no plist the version comes from the linked core")
    func versionFallsBackToTheCore() throws {
        let core = try MarkCore.version()

        #expect(BuildInfo.version({ _ in nil }) == core)
        #expect(!core.isEmpty)
    }
}

extension [String: String] {
    /// This dictionary as a ``BuildInfo/Lookup``.
    fileprivate var lookup: BuildInfo.Lookup {
        let copy = self
        return { copy[$0] }
    }
}
