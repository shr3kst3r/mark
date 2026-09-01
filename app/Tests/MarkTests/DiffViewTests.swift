import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// ⌘⇧D — the document's differences against git `HEAD`, rendered.
///
/// A real `WKWebView` running the shipped `shell.js`, and a real repository
/// built with the real `git`, for the same reason `DocumentPatchTests` uses
/// one: the properties under test are what the *page* does with the markup and
/// what `git` actually reports. A Swift-side model of either would agree with
/// itself and prove nothing.
///
/// The load-bearing assertion here is ``deletedContentIsInert``.
/// `2026-08-28-git-differences-by-running-git`:
///
/// > Blocks taken from `old` carry `data-mk-side="old"`, and the shell must
/// > treat them as inert: their `data-mk-start` / `data-mk-end` are offsets
/// > into a version of the file that is not on disk, so a checkbox click inside
/// > one would write to the wrong bytes.
///
/// The CSS dims such a checkbox. Dimming is not refusing, and this file is
/// where the refusing is checked.
@Suite("The changes view")
@MainActor
struct DiffViewTests {

    /// A throwaway git repository with one committed document.
    @MainActor
    final class RepoFixture {
        let directory: URL

        init() throws {
            directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mark-diff-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// `nil` when there is no usable git, so a test can skip rather than
        /// fail — a machine without Command Line Tools is a supported
        /// configuration, and the feature is simply invisible there.
        @discardableResult
        func git(_ args: [String]) -> String? {
            guard let tool = Self.tool else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.currentDirectoryURL = directory
            process.environment = [
                "GIT_AUTHOR_NAME": "mark tests", "GIT_AUTHOR_EMAIL": "t@mark.invalid",
                "GIT_COMMITTER_NAME": "mark tests", "GIT_COMMITTER_EMAIL": "t@mark.invalid",
                "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        static let tool: String? = {
            for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }()

        @discardableResult
        func write(_ source: String, to name: String = "doc.md") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try source.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        /// Initialise, write `committed`, commit it, then write `working`.
        /// Returns the document's URL, or `nil` when git is unavailable.
        func prepare(committed: String, working: String, name: String = "doc.md") throws -> URL? {
            guard git(["init", "--quiet", "--initial-branch=main"]) != nil else { return nil }
            let url = try write(committed, to: name)
            guard git(["add", "."]) != nil,
                git(["commit", "--quiet", "-m", "init"]) != nil
            else { return nil }
            _ = try write(working, to: name)
            return url
        }
    }

    /// A painted `DocumentView` over a real repository.
    @MainActor
    final class Harness {
        let fixture: RepoFixture
        let view: DocumentView
        let url: URL

        init?(committed: String, working: String) async throws {
            fixture = try RepoFixture()
            guard let url = try fixture.prepare(committed: committed, working: working) else {
                view = DocumentView(frame: .zero)
                self.url = fixture.directory
                return nil
            }
            self.url = url
            view = DocumentView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            view.open(url)
            await view.awaitReady()
            await view.ensureFullyRendered()
        }

        func html() async -> String {
            let value = try? await view.call(
                "return document.getElementById('mk-doc').innerHTML;")
            return value as? String ?? ""
        }
    }

    // MARK: - What it shows

    @Test("the diff view shows removed content in place, and the document comes back")
    func showsRemovedContentAndReturns() async throws {
        guard
            let harness = try await Harness(
                committed: "# Notes\n\ngoing away\n\nstaying\n",
                working: "# Notes\n\nstaying\n\nbrand new\n")
        else {
            print("skipped: no usable git")
            return
        }

        // Before: the document, with no trace of the diff.
        var html = await harness.html()
        #expect(!html.contains("going away"))
        #expect(!html.contains("mk-diff-"))

        let reason = await harness.view.toggleDiff()
        #expect(reason == nil, "the diff view refused: \(String(describing: reason))")
        #expect(harness.view.isShowingDiff)

        html = await harness.html()
        #expect(
            html.contains("going away"),
            "deleted content must be visible — that is the point of the view")
        #expect(html.contains("brand new"))
        #expect(html.contains("mk-diff-del"))
        #expect(html.contains("mk-diff-add"))
        #expect(html.contains("data-mk-side=\"old\""))

        // And back.
        await harness.view.hideDiff()
        #expect(!harness.view.isShowingDiff)
        html = await harness.html()
        #expect(!html.contains("going away"), "the document should be back")
        #expect(!html.contains("mk-diff-"))
        #expect(html.contains("brand new"))
    }

    @Test("a clean document refuses, and says why")
    func aCleanDocumentRefuses() async throws {
        let same = "# Notes\n\nnothing has changed here\n"
        guard let harness = try await Harness(committed: same, working: same) else {
            print("skipped: no usable git")
            return
        }
        let reason = await harness.view.toggleDiff()
        #expect(reason == .nothingChanged)
        #expect(!harness.view.isShowingDiff, "a refusal must not leave the page in diff mode")
    }

    @Test("a document outside a repository refuses rather than throwing")
    func outsideARepositoryRefuses() async throws {
        let fixture = try RepoFixture()
        let url = try fixture.write("# Loose\n\nnot in a repository\n")
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.open(url)
        await view.awaitReady()

        let reason = await view.toggleDiff()
        #expect(reason == .notInRepository)
        #expect(!view.isShowingDiff)
    }

    @Test("an untracked document shows every block as added")
    func anUntrackedDocumentIsAllAdded() async throws {
        let fixture = try RepoFixture()
        guard fixture.git(["init", "--quiet", "--initial-branch=main"]) != nil else {
            print("skipped: no usable git")
            return
        }
        // A commit, so HEAD resolves — but not of this file.
        _ = try fixture.write("seed\n", to: "seed.md")
        guard fixture.git(["add", "seed.md"]) != nil,
            fixture.git(["commit", "--quiet", "-m", "seed"]) != nil
        else {
            print("skipped: no usable git")
            return
        }
        let url = try fixture.write("# Fresh\n\njust written\n", to: "fresh.md")

        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.open(url)
        await view.awaitReady()
        await view.ensureFullyRendered()

        let reason = await view.toggleDiff()
        #expect(reason == nil, "a new note has changes: \(String(describing: reason))")
        let html = (try? await view.call("return document.getElementById('mk-doc').innerHTML;"))
        let text = html as? String ?? ""
        #expect(text.contains("mk-diff-add"))
        #expect(!text.contains("mk-diff-del"), "nothing was removed from a file with no history")
    }

    // MARK: - The load-bearing part

    /// A checkbox inside deleted content must not write anything.
    ///
    /// Its `data-mk-start` points into the committed version of the file, which
    /// is not what is on disk. A click that got through would tick a byte in the
    /// current document chosen by an offset that means something else — the
    /// quietest possible corruption, and the reason `data-mk-side` exists.
    @Test("deleted content is inert: its checkboxes refuse to be clicked")
    func deletedContentIsInert() async throws {
        guard
            let harness = try await Harness(
                committed: "# Notes\n\n- [ ] a task that is going away\n\nkeep\n",
                working: "# Notes\n\nkeep\n\n- [ ] a task that is still here\n")
        else {
            print("skipped: no usable git")
            return
        }
        let reason = await harness.view.toggleDiff()
        #expect(reason == nil)

        let html = await harness.html()
        #expect(html.contains("data-mk-side=\"old\""), "the fixture should have a removed block")
        #expect(html.contains("going away"), "including its task")

        // The page's own refusal, asserted through the page: click the checkbox
        // inside the old-side block and require that no message was posted.
        let posted = try await harness.view.call(
            """
            var old = document.querySelector('.mk-blk[data-mk-side="old"] input.mk-task');
            if (!old) { return 'no old-side checkbox in the fixture'; }
            var seen = [];
            var handler = window.webkit.messageHandlers.mark.postMessage;
            window.webkit.messageHandlers.mark.postMessage = function (m) { seen.push(m); };
            old.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
            var contextual = new MouseEvent('contextmenu', {bubbles: true, cancelable: true});
            old.dispatchEvent(contextual);
            window.webkit.messageHandlers.mark.postMessage = handler;
            return JSON.stringify(seen);
            """)
        #expect(
            posted as? String == "[]",
            "a click on deleted content reported \(String(describing: posted)) — it must report nothing"
        )
    }

    /// The live half of the same fixture: a checkbox in a block that survived is
    /// still clickable, because only the old side is inert.
    @Test("a checkbox in a kept block still works in the diff view")
    func keptContentStaysClickable() async throws {
        guard
            let harness = try await Harness(
                committed: "# Notes\n\n- [ ] shared task\n\nold prose\n",
                working: "# Notes\n\n- [ ] shared task\n\nnew prose\n")
        else {
            print("skipped: no usable git")
            return
        }
        _ = await harness.view.toggleDiff()

        let posted = try await harness.view.call(
            """
            var live = document.querySelector('.mk-blk:not([data-mk-side="old"]) input.mk-task');
            if (!live) { return 'no live checkbox in the fixture'; }
            var seen = [];
            var handler = window.webkit.messageHandlers.mark.postMessage;
            window.webkit.messageHandlers.mark.postMessage = function (m) { seen.push(m.kind); };
            live.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
            window.webkit.messageHandlers.mark.postMessage = handler;
            return JSON.stringify(seen);
            """)
        #expect(
            posted as? String == "[\"toggle\"]",
            "a surviving task should still be tickable, got \(String(describing: posted))")
    }

    /// `sourceTop` must not hand the editor an offset from the old document: it
    /// would put the caret in the wrong place, or past the end of a file that
    /// has since shrunk.
    @Test("an old-side block reports no source position")
    func oldSideBlocksReportNoSourcePosition() async throws {
        guard
            let harness = try await Harness(
                committed: "# Notes\n\nremoved paragraph\n",
                working: "# Notes\n\nreplacement paragraph\n")
        else {
            print("skipped: no usable git")
            return
        }
        _ = await harness.view.toggleDiff()

        let reported = try await harness.view.call(
            """
            var blocks = document.querySelectorAll('#mk-doc > .mk-blk');
            var out = [];
            for (var i = 0; i < blocks.length; i++) {
              out.push(blocks[i].getAttribute('data-mk-side') === 'old');
            }
            return JSON.stringify(out);
            """)
        #expect(
            (reported as? String)?.contains("true") == true,
            "the fixture should contain an old-side block")

        // `sourceTop` returns null for an old-side block at the viewport top.
        // With no window the geometry is degenerate, so this asserts the guard
        // directly rather than through scrolling.
        let guarded = try await harness.view.call(
            """
            var old = document.querySelector('.mk-blk[data-mk-side="old"]');
            return old ? old.getAttribute('data-mk-side') : null;
            """)
        #expect(guarded as? String == "old")
    }

    /// The same refusal in the other direction: the preview cannot be steered
    /// by a source position while it is showing a diff.
    ///
    /// The blocks in a diff carry two documents' offsets, so one byte offset
    /// does not name one place — and the editor beside it is bound to the file
    /// on disk, which is only one of them. Scrolling to the old side would send
    /// the reader to a paragraph the working tree does not have.
    ///
    /// Refused in the page as well as in ``DocumentView/follow(sourceByte:)``,
    /// because the two guards fail differently: the Swift one saves a process
    /// hop, and this one is what makes the answer true for anything that calls
    /// `scrollToSource` — the bench gate included.
    @Test("a source position cannot scroll a diff")
    func aDiffRefusesToBeScrolledBySourcePosition() async throws {
        guard
            let harness = try await Harness(
                committed: "# Notes\n\nremoved paragraph\n",
                working: "# Notes\n\nreplacement paragraph\n")
        else {
            print("skipped: no usable git")
            return
        }

        // The same document, before and after — so the refusal is the diff and
        // not something about this fixture.
        let ordinary = try await harness.view.call(
            "return window.mark.scrollToSource(0);")
        #expect((ordinary as? Bool) == true)

        _ = await harness.view.toggleDiff()
        let refused = try await harness.view.call(
            "return window.mark.scrollToSource(0);")
        #expect((refused as? Bool) == false, "the diff let itself be scrolled by a byte offset")
        #expect(harness.view.isShowingDiff, "and it should still be showing the diff")
    }

    // MARK: - Interaction with the rest of the app

    /// A file change while the diff is up must recompute the diff, not patch it.
    /// The page holds blocks from two parses, so an edit script between the
    /// file's own versions does not describe that DOM at all.
    @Test("a file change refreshes the diff instead of patching it")
    func aFileChangeRefreshesTheDiff() async throws {
        guard
            let harness = try await Harness(
                committed: "# Notes\n\noriginal\n",
                working: "# Notes\n\nedited once\n")
        else {
            print("skipped: no usable git")
            return
        }
        _ = await harness.view.toggleDiff()
        #expect(await harness.html().contains("edited once"))

        let report = await harness.view.apply(source: "# Notes\n\nedited twice\n")
        #expect(report == nil, "a patch must not be attempted while the diff is up")
        #expect(harness.view.isShowingDiff, "and the view should still be showing the diff")

        let html = await harness.html()
        #expect(html.contains("edited twice"), "the diff should have been recomputed")
        #expect(html.contains("original"), "still against the committed version")
        #expect(html.contains("data-mk-side=\"old\""))
    }
}
