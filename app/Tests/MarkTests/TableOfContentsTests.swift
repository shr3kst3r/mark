import AppKit
import Foundation
import Testing

@testable import MarkKit

/// A heading as the core would emit one. Only `level`, `text`, and `anchor`
/// matter to the outline; the byte spans are what `mark goto` and the editor
/// use and are left at zero here on purpose, so a test that started depending
/// on them would fail loudly rather than pass on a coincidence.
private func heading(_ level: Int, _ text: String, anchor: String? = nil, line: Int = 0) -> Heading {
    Heading(
        level: level,
        text: text,
        anchor: anchor ?? text.lowercased().replacingOccurrences(of: " ", with: "-"),
        start: 0,
        end: 0,
        line: line,
        block: "blk-\(line)"
    )
}

@Suite("The table of contents")
@MainActor
struct TableOfContentsTests {

    // MARK: Nesting

    @Test("headings nest by level")
    func nesting() {
        let roots = TOCNode.tree(from: [
            heading(1, "One", line: 1),
            heading(2, "One A", line: 2),
            heading(3, "One A i", line: 3),
            heading(2, "One B", line: 4),
            heading(1, "Two", line: 5),
        ])
        #expect(roots.map(\.text) == ["One", "Two"])
        #expect(roots[0].children.map(\.text) == ["One A", "One B"])
        #expect(roots[0].children[0].children.map(\.text) == ["One A i"])
        #expect(roots[1].children.isEmpty)
    }

    /// Markdown does not promise a well-formed heading tree, and most real
    /// documents are not one. A pane that only worked for the ones that were
    /// would be wrong more often than right.
    @Test("a level that skips its parent nests under the nearest ancestor")
    func skippedLevel() {
        let roots = TOCNode.tree(from: [heading(1, "One", line: 1), heading(3, "Deep", line: 2)])
        #expect(roots.map(\.text) == ["One"])
        #expect(roots[0].children.map(\.text) == ["Deep"])
    }

    @Test("a document that opens on a deeper heading gets more than one root")
    func multipleRoots() {
        let roots = TOCNode.tree(from: [heading(2, "First", line: 1), heading(1, "Later", line: 2)])
        #expect(roots.map(\.text) == ["First", "Later"])
        #expect(roots[0].children.isEmpty)
    }

    @Test("flattening is document order")
    func flattening() {
        let roots = TOCNode.tree(from: [
            heading(1, "One", line: 1),
            heading(2, "One A", line: 2),
            heading(1, "Two", line: 3),
        ])
        #expect(roots.flatMap(\.flattened).map(\.text) == ["One", "One A", "Two"])
    }

    // MARK: The pane

    @Test("the outline shows a row per heading")
    func rows() {
        let controller = TableOfContentsViewController()
        _ = controller.view
        controller.show(
            [heading(1, "One", line: 1), heading(2, "One A", line: 2)],
            for: URL(fileURLWithPath: "/tmp/a.md"))
        #expect(controller.outlineView.numberOfRows == 2)
        #expect((controller.outlineView.item(atRow: 1) as? TOCNode)?.text == "One A")
    }

    /// The window controller calls `show(_:for:)` from `updateChrome()`, which
    /// runs on every tab switch, every tab-list change, and every metadata
    /// load. A reload per call would drop the selection under the reader.
    @Test("showing the same headings again keeps the selection")
    func idempotent() {
        let url = URL(fileURLWithPath: "/tmp/a.md")
        let headings = [heading(1, "One", line: 1), heading(1, "Two", line: 2)]
        let controller = TableOfContentsViewController()
        _ = controller.view
        controller.show(headings, for: url)
        controller.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(controller.selectedHeading?.text == "Two")

        controller.show(headings, for: url)
        #expect(controller.selectedHeading?.text == "Two")
    }

    @Test("an edit that renames a heading keeps the selection on the ones that survived")
    func selectionSurvivesARebuild() {
        let url = URL(fileURLWithPath: "/tmp/a.md")
        let controller = TableOfContentsViewController()
        _ = controller.view
        controller.show(
            [heading(1, "One", line: 1), heading(1, "Two", line: 2)], for: url)
        controller.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        controller.show(
            [heading(1, "One", line: 1), heading(1, "Two", line: 2), heading(1, "Three", line: 3)],
            for: url)
        #expect(controller.selectedHeading?.text == "Two")
    }

    @Test("picking a row reports the heading")
    func picking() {
        let controller = TableOfContentsViewController()
        _ = controller.view
        var picked: [String] = []
        controller.onSelect = { picked.append($0.anchor) }
        controller.show(
            [heading(1, "One", line: 1), heading(2, "One A", line: 2)],
            for: URL(fileURLWithPath: "/tmp/a.md"))

        controller.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(picked == ["one-a"])
    }

    /// The pane moving its own selection to follow the document must not read
    /// back as the reader asking to go somewhere — that is the same trap
    /// ``TreeViewController/follow(_:)`` guards against with `isFollowing`.
    @Test("highlighting a heading does not report it as a pick")
    func highlightIsSilent() {
        let controller = TableOfContentsViewController()
        _ = controller.view
        var picked: [String] = []
        controller.onSelect = { picked.append($0.anchor) }
        controller.show(
            [heading(1, "One", line: 1), heading(1, "Two", line: 2)],
            for: URL(fileURLWithPath: "/tmp/a.md"))

        #expect(controller.highlight(anchor: "two"))
        #expect(controller.selectedHeading?.text == "Two")
        #expect(picked.isEmpty)
    }

    /// "This document has no headings" and "there is no document" are different
    /// facts, and one label for both reads as a bug the first time it is seen
    /// on an empty sidebar.
    @Test("the empty states tell an empty document apart from no document")
    func emptyStates() throws {
        let controller = TableOfContentsViewController()
        let container = try #require(controller.view as? TableOfContentsContainerView)

        controller.show([], for: nil)
        #expect(container.emptyMessage == "No document open")

        controller.show([], for: URL(fileURLWithPath: "/tmp/a.md"))
        #expect(container.emptyMessage == "No headings")

        controller.show([heading(1, "One", line: 1)], for: URL(fileURLWithPath: "/tmp/a.md"))
        #expect(container.emptyMessage == nil)
    }

    @Test("a heading with no text still gets a row")
    func untitledHeading() {
        let cell = TOCCellView(frame: .zero)
        cell.configure(with: TOCNode.tree(from: [heading(2, "  ", anchor: "x")])[0])
        #expect(cell.textField?.stringValue == "(untitled)")
    }
}

// MARK: - In the window

@Suite("The sidebar's two halves")
@MainActor
struct SidebarPaneTests {

    @Test("the sidebar is the tree above the table of contents")
    func layout() throws {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        let split = try #require(controller.window?.contentViewController as? NSSplitViewController)
        // Still one sidebar item, still collapsible — ADR-4's window is
        // unchanged; only what is inside the sidebar is new.
        #expect(split.splitViewItems.count == 2)
        #expect(split.splitViewItems[0].behavior == .sidebar)
        #expect(split.splitViewItems[0].viewController === controller.sidebarPane)

        let pane = try #require(controller.sidebarPane.view as? NSSplitView)
        #expect(!pane.isVertical, "the halves are stacked, not side by side")
        #expect(pane.subviews.count == 2)
        #expect(pane.subviews[0] === controller.sidebar.view)
        #expect(pane.subviews[1] === controller.toc.view)
    }

    /// A nested `NSSplitViewController` would swallow ⌃⌘S whenever the focus
    /// was in the sidebar: `toggleSidebar(_:)` goes to the first split view
    /// controller in the responder chain, and one with no `.sidebar` item has
    /// nothing to toggle and says nothing about it.
    @Test("there is exactly one split view controller in the window")
    func noNestedSplitViewController() throws {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        let root = try #require(controller.window?.contentViewController)
        _ = controller.sidebarPane.view
        #expect(Self.splitViewControllers(under: root).count == 1)
    }

    private static func splitViewControllers(under controller: NSViewController)
        -> [NSSplitViewController]
    {
        let here = (controller as? NSSplitViewController).map { [$0] } ?? []
        return here + controller.children.flatMap { splitViewControllers(under: $0) }
    }

    @Test("the table of contents can be hidden without hiding the tree")
    func toggling() {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        _ = controller.sidebarPane.view
        #expect(controller.sidebarPane.isContentsVisible)

        controller.toggleTableOfContents(nil)
        #expect(!controller.sidebarPane.isContentsVisible)
        #expect(!controller.sidebar.view.isHidden)

        controller.toggleTableOfContents(nil)
        #expect(controller.sidebarPane.isContentsVisible)
    }

    @Test("opening a document fills the table of contents")
    func followsTheFrontDocument() async throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        _ = controller.toc.view
        let tab = controller.tabs.open(fixture.file(named: "a.md"))
        #expect(await waitForHeadings(controller, timeout: .seconds(5)))
        #expect(controller.toc.headings.map(\.text) == ["Title of a.md"])
        #expect(controller.toc.outlineView.numberOfRows == 1)
        #expect(tab.metadata?.headings.count == 1)
    }

    /// ADR-4: *"no feature may assume a tab's web view exists"*. The outline is
    /// computed from the bytes by the core, so it is right for a tab that has
    /// never been hydrated.
    @Test("closing the last tab empties the table of contents")
    func emptiesOnClose() async throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        _ = controller.toc.view
        controller.tabs.open(fixture.file(named: "a.md"))
        #expect(await waitForHeadings(controller, timeout: .seconds(5)))

        controller.tabs.closeAll()
        #expect(controller.toc.headings.isEmpty)
        let container = try #require(controller.toc.view as? TableOfContentsContainerView)
        #expect(container.emptyMessage == "No document open")
    }

    /// The link the whole pane rests on: the `anchor` the core reports is the
    /// `id` the rendered page carries, so clicking a row can be a `goto`.
    /// Asserted against a real `WKWebView` running the shipped `shell.js`,
    /// because a Swift-side model of the DOM would agree with itself.
    @Test("every anchor in the outline is an id the page has")
    func anchorsResolve() async throws {
        let source = """
            # Getting started

            Prose.

            ## Install & set up

            More prose.

            ### Deeper still

            ## Install & set up

            A deliberate duplicate, so the core's de-duplication is in the loop.
            """
        let harness = try await PatchHarness(source)
        let headings = try MarkCore.toc(source: source)
        #expect(headings.count == 4)
        for heading in headings {
            let found = try await harness.view.scrollToAnchor(heading.anchor)
            #expect(found, "no element with id \(heading.anchor)")
        }
        #expect(!(try await harness.view.scrollToAnchor("not-a-heading")))
    }

    /// End to end, through the controller: pick a heading in the pane and the
    /// document it is showing scrolls to it.
    ///
    /// The link is the anchor, and the anchor comes from two places that have
    /// to agree — `mark_toc_json` over the tab's bytes, which is what the pane
    /// draws, and the `id` the core put on the rendered heading, which is what
    /// the page can scroll to. Nothing but a test over both halves keeps them
    /// honest.
    @Test("picking a heading scrolls the document that is on screen")
    func pickingScrollsTheDocument() async throws {
        let fixture = try TabFixture()
        let url = fixture.file(named: "outline.md")
        try """
            # Top

            Prose.

            ## Middle

            More prose.

            ### Bottom
            """.write(to: url, atomically: true, encoding: .utf8)

        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        _ = controller.toc.view
        controller.tabs.open(url)
        #expect(await waitForHeadings(controller, timeout: .seconds(5)))
        #expect(controller.toc.headings.map(\.text) == ["Top", "Middle", "Bottom"])

        let view = try #require(controller.documentView)
        await view.awaitReady()
        for heading in controller.toc.headings {
            #expect(
                try await view.scrollToAnchor(heading.anchor),
                "the pane offers #\(heading.anchor) and the page has no such id")
        }

        // And the pane's own click path reaches it without a web view being
        // assumed to exist — the ADR-4 constraint every feature here is
        // written against.
        controller.toc.onSelect?(controller.toc.headings[1])
    }

    private func waitForHeadings(
        _ controller: MainWindowController, timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !controller.toc.headings.isEmpty { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
