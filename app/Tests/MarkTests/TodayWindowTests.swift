import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The **Today** page's window (`2026-08-31-today-page`).
///
/// Modelled on `HelpWindowTests`, and asserting the same three "must not"s a
/// second kind of window goes wrong on — existing twice, leaving a web view
/// behind, and writing to a file — plus the two that are this window's own: it
/// must find the journal from where it was told to start, and it must say so
/// when there is none.
@Suite("The Today window")
@MainActor
struct TodayWindowTests {

    /// A journal with one daily and one project, and a controller over it.
    ///
    /// The fixture is returned as well as the controller because it deletes its
    /// directory on `deinit`, and the controller reads it on every refresh.
    private func makeFixture() throws -> JournalFixture {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        try fixture.write(
            """
            # 2026-08-31 Monday

            ## Today

            - [/] Review the draft
            - [ ] Copy edits @proj(launch)
            """, to: "daily/2026/08/2026-08-31.md")
        try fixture.write(
            """
            # Website launch

            > **Status:** active · tag `@proj(launch)`

            ## Open

            - [ ] Rebuild the landing page
            """, to: "projects/launch/index.md")
        return fixture
    }

    private func makeController(
        startingFrom start: URL,
        governor: ResidencyGovernor,
        opened: @escaping (URL, String?) -> Void = { _, _ in }
    ) -> TodayWindowController {
        TodayWindowController(
            startingFrom: start,
            open: opened,
            now: { day("2026-08-31") },
            governor: governor)
    }

    @Test("it opens on the day's page, with a find bar and no other chrome")
    func itOpens() async throws {
        let fixture = try makeFixture()
        let governor = ResidencyGovernor(limit: 3)
        let controller = makeController(startingFrom: fixture.root, governor: governor)
        defer { controller.tearDown() }
        await controller.refresh()

        let window = try #require(controller.window)
        #expect(window.title == "Today")
        // No tab bar, no sidebar, no editor: the content view is the preview
        // pane and nothing else.
        #expect(window.contentView is PreviewPaneView)
        #expect(!controller.finder.isVisible)

        let journal = try #require(controller.journal)
        #expect(journal.url.path == fixture.journal.url.path)
        let markdown = try #require(controller.markdown)
        #expect(markdown.contains("- [/] Review the draft"))
        #expect(markdown.contains("### [Website launch](<projects/launch/index.md>) · active"))
    }

    /// The page has no file. It is given a URL inside the journal so relative
    /// links resolve and the log lines name something, and that URL must never
    /// be a document anybody has.
    @Test("the document it shows is not a file")
    func theDocumentHasNoFile() async throws {
        let fixture = try makeFixture()
        let governor = ResidencyGovernor(limit: 3)
        let controller = makeController(startingFrom: fixture.root, governor: governor)
        defer { controller.tearDown() }
        await controller.refresh()

        let url = try #require(controller.documentView.url)
        #expect(url.deletingLastPathComponent().path == fixture.journal.url.path)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// **The reason it is a window and not a tab, and why its writer refuses.**
    ///
    /// Every checkbox on the page is a copy of a line in some other file. A
    /// click has nowhere correct to go, so it is refused and logged rather than
    /// writing into the synthesized page's own non-existent file.
    @Test("its checkboxes are copies — a click writes nothing")
    func checkboxesDoNotWrite() async throws {
        let fixture = try makeFixture()
        let governor = ResidencyGovernor(limit: 3)
        let controller = makeController(startingFrom: fixture.root, governor: governor)
        defer { controller.tearDown() }
        await controller.refresh()

        let writer = try #require(controller.documentView.taskWriter as? RefusingTaskWriter)
        let daily = fixture.root.appendingPathComponent("daily/2026/08/2026-08-31.md")
        let before = try Data(contentsOf: daily)

        #expect(throws: TaskWriteRefusal.self) {
            _ = try writer.apply(
                TaskToggle(index: 0, span: 0..<3, rendered: .open, desired: .done), to: daily)
        }
        #expect(try Data(contentsOf: daily) == before)
    }

    /// An empty page and "you have nothing to do" must not look the same.
    @Test("outside a journal it says what it looked for")
    func notAJournal() async throws {
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-not-a-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let governor = ResidencyGovernor(limit: 3)
        let controller = makeController(startingFrom: elsewhere, governor: governor)
        defer { controller.tearDown() }
        await controller.refresh()

        #expect(controller.journal == nil)
        #expect(controller.digest == nil)
        let markdown = try #require(controller.markdown)
        #expect(markdown.contains("No journal here."))
        #expect(markdown.contains("`daily/`"))
    }

    /// A change in a file the page was built from re-renders it. Asserted
    /// through ``TodayWindowController/refresh()`` rather than by waiting on
    /// FSEvents: the watcher's own delivery is `FileWatcherTests`' subject, and
    /// what this window adds is "the second render is a patch, not a reopen".
    @Test("a rebuild patches the page rather than reopening it")
    func rebuildPatches() async throws {
        let fixture = try makeFixture()
        let governor = ResidencyGovernor(limit: 3)
        let controller = makeController(startingFrom: fixture.root, governor: governor)
        defer { controller.tearDown() }
        await controller.refresh()
        let url = try #require(controller.documentView.url)

        try fixture.write(
            """
            # 2026-08-31 Monday

            ## Today

            - [x] Review the draft
            - [ ] Copy edits @proj(launch)
            - [ ] Something new
            """, to: "daily/2026/08/2026-08-31.md")
        await controller.refresh()

        let markdown = try #require(controller.markdown)
        #expect(markdown.contains("- [ ] Something new"))
        #expect(!markdown.contains("Review the draft"))
        // Same document, so the reader's scroll position was never thrown away.
        #expect(controller.documentView.url == url)
    }

    @Test("there is only ever one of it, and a closed one is not reused")
    func singleInstance() throws {
        let fixture = try JournalFixture()
        try fixture.makeJournal()
        // Goes through the real `show()`, because the single-instance rule
        // lives there rather than in `init`.
        let first = TodayWindowController.show(startingFrom: fixture.root) { _, _ in }
        let second = TodayWindowController.show(startingFrom: fixture.root) { _, _ in }
        #expect(first === second)
        #expect(TodayWindowController.shared === first)

        first.tearDown()
        #expect(TodayWindowController.shared == nil)

        let third = TodayWindowController.show(startingFrom: fixture.root) { _, _ in }
        defer { third.tearDown() }
        #expect(third !== first, "⇧⌘T reopened a controller that had given its web view back")
    }

    /// Closing gives the ~52 MB back, and stops the watcher. Without this the
    /// window would be a leak that only shows up as WebContent processes
    /// accumulating.
    @Test("closing releases the web view and drops the shared instance")
    func closingTearsDown() async throws {
        let fixture = try makeFixture()
        let routedBefore = WebViewFactory.routedWebViewCount
        let governor = ResidencyGovernor(limit: 3)
        let controller = makeController(startingFrom: fixture.root, governor: governor)
        await controller.refresh()
        #expect(governor.auxiliaryWebViews == 1)
        #expect(WebViewFactory.routedWebViewCount == routedBefore + 1)

        controller.tearDown()
        #expect(governor.auxiliaryWebViews == 0)
        // A leaked web view shows up as a routing-table entry;
        // ``WebViewFactory/release(_:)`` is the only thing that removes one.
        #expect(WebViewFactory.routedWebViewCount == routedBefore)

        // Idempotent: `windowWillClose` and an explicit close can both arrive.
        controller.tearDown()
        #expect(governor.auxiliaryWebViews == 0)
        #expect(WebViewFactory.routedWebViewCount == routedBefore)
    }

    /// A link on this page is the reader naming a file, and it leaves through
    /// the closure the caller supplied — carrying the heading the item sits
    /// under, so arriving at the top of a 200-line daily is not what happens.
    @Test("following a link hands the file, and its anchor, to the caller")
    func followingALink() async throws {
        let fixture = try makeFixture()
        let governor = ResidencyGovernor(limit: 3)
        var opened: [(URL, String?)] = []
        let controller = makeController(startingFrom: fixture.root, governor: governor) {
            opened.append(($0, $1))
        }
        defer { controller.tearDown() }
        await controller.refresh()

        let daily = fixture.root.appendingPathComponent("daily/2026/08/2026-08-31.md")
        controller.documentView.onFollow?(daily)
        controller.documentView.onFollowFragment?(daily, "today")

        #expect(opened.count == 2)
        #expect(opened[0].0 == daily)
        #expect(opened[0].1 == nil)
        #expect(opened[1].1 == "today")
    }
}
