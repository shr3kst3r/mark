import AppKit
import Foundation
import Testing

@testable import MarkKit

/// Following a link from one document to another.
///
/// The bug these pin: `DocumentView` resolved a link to a local file and then
/// opened it *on itself*, so the page changed and nothing else did. The tab
/// kept its old URL, and everything hanging off the tab — the tab bar's label,
/// the window title, the sidebar selection, the watch set, and the buffer the
/// editor pane is bound to — kept describing the file the reader had just
/// navigated away from. The most visible symptom was the editor: the preview
/// showed one document and the source beside it showed another.
///
/// A real click in a real page for each, because the whole path is the point —
/// `shell.js`'s listener, the script bridge, the resolution against the
/// document's own directory, and the window's open funnel. A test that called
/// `follow(href:)` directly would skip the two ends that broke.
@Suite("Following a link to another document")
@MainActor
struct LinkFollowTests {

    /// Click the first link in the page the way a reader does.
    private func clickLink(in tab: DocumentTab) async throws {
        let view = try #require(tab.documentView)
        let clicked = try await view.call(
            """
            var link = document.querySelector('#mk-doc a[href]');
            if (!link) return false;
            link.click();
            return true;
            """)
        #expect((clicked as? Bool) == true, "the document has no link to click")
    }

    /// The symptom as reported: the preview moves, the editor does not.
    @Test("following a link rebinds the editor to the document that arrived")
    func theEditorFollowsTheLink() async throws {
        let harness = try RoundTripHarness()
        _ = try harness.fixture.write("# Notes\n\nthe linked document\n", to: "notes.md")
        let index = try await harness.open(
            "# Index\n\n[Meeting notes](./notes.md)\n", named: "index.md")

        harness.controller.setEditorVisible(true)
        let indexBuffer = try #require(harness.controller.buffer(for: index))
        #expect(harness.controller.editor.buffer === indexBuffer)
        #expect(indexBuffer.text.contains("# Index"))

        try await clickLink(in: index)

        let notes = harness.fixture.directory.appendingPathComponent("notes.md")
        #expect(
            await harness.waitUntil("the link to open notes.md") {
                harness.controller.tabs.selected?.url.standardizedFileURL
                    == notes.standardizedFileURL
            })

        // The editor is bound to the new document's buffer, not the old one's.
        // Both halves are asserted: a pane still holding `index.md`'s buffer is
        // the bug, and a pane holding *nothing* would pass a `!==` check while
        // showing the reader an empty source pane.
        let selected = try #require(harness.controller.tabs.selected)
        let notesBuffer = try #require(harness.controller.buffer(for: selected))
        #expect(harness.controller.editor.buffer === notesBuffer)
        #expect(harness.controller.editor.buffer !== indexBuffer)
        #expect(notesBuffer.text.contains("the linked document"))
    }

    /// The rest of the window moves with it. Each of these read through the
    /// tab, which is exactly why they all went stale together.
    @Test("following a link moves the tab, the title and the watch set")
    func theWindowFollowsTheLink() async throws {
        let harness = try RoundTripHarness()
        _ = try harness.fixture.write("# Notes\n\nthe linked document\n", to: "notes.md")
        let index = try await harness.open(
            "# Index\n\n[Meeting notes](./notes.md)\n", named: "index.md")
        #expect(harness.controller.tabs.tabs.count == 1)

        try await clickLink(in: index)

        let notes = harness.fixture.directory.appendingPathComponent("notes.md")
        #expect(
            await harness.waitUntil("the link to open notes.md") {
                harness.controller.tabs.selected?.url.standardizedFileURL
                    == notes.standardizedFileURL
            })

        // A tab of its own, selected, with `index.md` still open behind it —
        // the link was navigation, not a replacement.
        #expect(harness.controller.tabs.tabs.count == 2)
        #expect(harness.controller.tabs.tabs.contains(index))
        #expect(harness.controller.tabs.selected !== index)
        #expect(harness.controller.tabs.selected?.title == "notes.md")
        #expect(
            await harness.waitUntil("the window to retitle") {
                harness.controller.window?.title == "notes.md"
            })
        #expect(
            harness.controller.window?.representedURL?.standardizedFileURL
                == notes.standardizedFileURL)

        // Opening it recorded it, the way every other route in does.
        #expect(
            harness.controller.history.entries.first?.url == notes.standardizedFileURL)
    }

    /// A second click on the same link goes back to the tab that is already
    /// open rather than making another one — the store's own rule, reached
    /// through the link path.
    @Test("following the same link twice does not open it twice")
    func followingTwiceReusesTheTab() async throws {
        let harness = try RoundTripHarness()
        _ = try harness.fixture.write("# Notes\n\nthe linked document\n", to: "notes.md")
        let index = try await harness.open(
            "# Index\n\n[Meeting notes](./notes.md)\n", named: "index.md")

        try await clickLink(in: index)
        let notes = harness.fixture.directory.appendingPathComponent("notes.md")
        #expect(
            await harness.waitUntil("the link to open notes.md") {
                harness.controller.tabs.selected?.url.standardizedFileURL
                    == notes.standardizedFileURL
            })
        let opened = try #require(harness.controller.tabs.selected)

        harness.controller.select(index)
        #expect(await harness.waitUntil("index.md to come back") {
            harness.controller.tabs.selected === index
        })
        try await clickLink(in: index)
        #expect(
            await harness.waitUntil("the link to return to notes.md") {
                harness.controller.tabs.selected === opened
            })
        #expect(harness.controller.tabs.tabs.count == 2)
    }

    /// A link to a file that is not there changes nothing. The reader gets no
    /// tab, no retitle, and no empty pane — the click is logged and dropped.
    @Test("a link to a missing file leaves the window alone")
    func aBrokenLinkChangesNothing() async throws {
        let harness = try RoundTripHarness()
        let index = try await harness.open(
            "# Index\n\n[gone](./not-here.md)\n", named: "index.md")

        try await clickLink(in: index)
        await harness.settle()

        #expect(harness.controller.tabs.tabs.count == 1)
        #expect(harness.controller.tabs.selected === index)
    }
}
