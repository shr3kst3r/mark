import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// The window's structural constraints, asserted rather than commented.
///
/// The suite was named "ADR-4's one window" until
/// `2026-08-26-multiple-windows-and-split-panes` made windows plural. What that
/// ADR did **not** relax is everything below: native tabbing is still rejected,
/// the shared configuration still stands, and both are now per-window
/// obligations rather than single ones.
@Suite("MainWindowController — structure")
@MainActor
struct MainWindowControllerTests {

    /// > **Never call `addTabbedWindow` or set `tabbingMode = .preferred`.**
    /// > Mixing native tabbing into this design produces two competing tab
    /// > bars. Set `tabbingMode = .disallowed` explicitly so AppKit does not
    /// > add one.
    ///
    /// `.automatic` (the default) honours the user's "Prefer tabs: always"
    /// System Settings preference, so the bug appears on *someone else's*
    /// machine.
    ///
    /// **Every** window, not just the first. The superseding ADR turns this
    /// into a per-window obligation — one window missing it reintroduces the
    /// competing-tab-bar failure — so the second window is asserted too.
    @Test("every window disallows native tabbing")
    func tabbingIsDisallowed() throws {
        let coordinator = WindowCoordinator()
        for _ in 0..<2 {
            let controller = coordinator.makeWindow(root: URL(fileURLWithPath: "/tmp"))
            let window = try #require(controller.window)
            #expect(window.tabbingMode == .disallowed)
            #expect(window.tabGroup?.windows.count ?? 1 == 1)
        }
        #expect(coordinator.count == 2)
    }

    /// A popped-out window is another instance of this same class — "no second,
    /// lesser window class, so no document feature has a second place to
    /// drift". The visible difference is the sidebar, which starts collapsed.
    @Test("a popped-out window is a full window with its sidebar collapsed")
    func poppedOutWindowIsFullyFurnished() throws {
        let coordinator = WindowCoordinator()
        let source = coordinator.makeWindow(root: URL(fileURLWithPath: "/tmp"))
        #expect(!source.isSidebarCollapsed)

        let detached = coordinator.makeWindow(
            root: URL(fileURLWithPath: "/tmp"), collapsedSidebar: true)
        #expect(detached.isSidebarCollapsed)
        // Everything a document needs is still there — the point of reusing
        // the class rather than writing a stripped viewer.
        #expect(detached.window?.contentViewController is NSSplitViewController)
        #expect(detached.findBar.superview != nil)
        #expect(detached.tabBar.store === detached.tabs)
    }

    /// Every window shares the app's one residency budget. The window-level
    /// half of `ResidencyTests.budgetIsApplicationWide`.
    @Test("windows share one residency governor")
    func windowsShareTheBudget() throws {
        let coordinator = WindowCoordinator()
        let first = coordinator.makeWindow(root: URL(fileURLWithPath: "/tmp"))
        let second = coordinator.makeWindow(root: URL(fileURLWithPath: "/tmp"))
        #expect(first.tabs.governor === second.tabs.governor)
        #expect(first.tabs.governor === ResidencyGovernor.shared)
    }

    @Test("the window is a split view with a sidebar and a document area")
    func splitView() throws {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        let split = try #require(controller.window?.contentViewController as? NSSplitViewController)
        #expect(split.splitViewItems.count == 2)
        #expect(split.splitViewItems[0].behavior == .sidebar)
        #expect(split.splitViewItems[0].canCollapse)
    }

    /// ADR-4: *"All web views share one `WKWebViewConfiguration` — this is
    /// what keeps them in a single content process."* M2 has one web view, so
    /// this buys nothing today; it is asserted now so M3 inherits it.
    ///
    /// **Not** an identity check on the configuration itself:
    /// `WKWebView.configuration` is `@NSCopying`, so it hands back a *copy* and
    /// `===` is always false — which would make the obvious version of this
    /// test fail while the property it is testing holds. What survives the copy
    /// by reference is the shared state, so that is what is asserted.
    ///
    /// `processPool` would be the most direct proxy for "one content process"
    /// and is deliberately not used: it is deprecated as of macOS 12 with
    /// "creating and using multiple instances no longer has any effect", so it
    /// can no longer distinguish a shared configuration from a per-view one.
    /// M3 replaced M2's single stored `documentView` with one per hydrated
    /// tab, so this now opens tabs rather than reading a controller property
    /// that no longer exists. The property being asserted is unchanged, and it
    /// finally has more than one web view to assert it across.
    @Test("every web view shares one configuration's data store and content controller")
    func sharedConfiguration() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        let first = try #require(controller.documentView?.webView)
        controller.open(fixture.file(named: "b.md"))
        let second = try #require(controller.documentView?.webView)

        #expect(first !== second)
        let shared = WebViewFactory.configuration
        for view in [first, second] {
            #expect(view.configuration.websiteDataStore === shared.websiteDataStore)
            #expect(view.configuration.userContentController === shared.userContentController)
            #expect(view.configuration.preferences === shared.preferences)
        }
    }

    /// The M2 version of this asserted "exactly one web view — tabs are M3".
    /// M3 is here, so the invariant becomes: **one per hydrated tab, stacked in
    /// the container, exactly one of them visible.**
    @Test("the document container holds one web view per hydrated tab, one visible")
    func oneWebViewPerHydratedTab() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        #expect(controller.documentContainer.documentViews.isEmpty)

        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))
        controller.open(fixture.file(named: "c.md"))

        #expect(controller.documentContainer.documentViews.count == 3)
        for view in controller.documentContainer.documentViews {
            #expect(view.subviews.filter { $0 is WKWebView }.count == 1)
        }
        let visible = controller.documentContainer.documentViews.filter { !$0.isHidden }
        #expect(visible.count == 1)
        #expect(visible.first === controller.tabs.selected?.documentView)
    }

    @Test("the viewport height never collapses to zero")
    func viewportFallback() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        #expect((controller.documentView?.viewportHeight ?? 0) > 1)
    }

    /// ADR-4: *"Session state lives in our own file, not
    /// `NSWindowRestoration`."* Both mechanisms restoring would make the result
    /// depend on the very System Settings checkbox the ADR wanted it to be
    /// independent of.
    @Test("the window opts out of NSWindowRestoration")
    func notRestorable() throws {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        let window = try #require(controller.window)
        #expect(window.isRestorable == false)
    }

    /// The M8 gate: *"⌘⇧O reveals the active tab's file even when that file is
    /// outside the current root"* — and ADR-4's constraint that *"no feature
    /// may assume a tab's web view exists"*, which is the easier of the two to
    /// break here, because reaching for `documentView` to find the file would
    /// work in every manual test and fail on the 4th tab.
    @Test("⌘⇧O reveals a dehydrated tab's file from outside the sidebar's root")
    func revealFromOutsideTheRoot() throws {
        let fixture = try TabFixture()
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-elsewhere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let controller = MainWindowController(root: elsewhere, session: fixture.session)
        _ = controller.sidebar.view
        controller.open(fixture.file(named: "a.md"))
        #expect(controller.sidebar.root.path == elsewhere.path)

        // One tab, then dehydrated: the file, the title, and the task counts
        // are all a dehydrated tab has, and reveal must need nothing more.
        // (One rather than several deliberately — every hydrated tab in a unit
        // test is a real ~52 MB WebContent process, per ADR-4.)
        let tab = try #require(controller.tabs.tab(for: fixture.file(named: "a.md")))
        controller.tabs.dehydrate(tab)
        #expect(
            tab.documentView == nil,
            "the tab must be dehydrated for this to prove anything")

        controller.revealInSidebar(nil)
        #expect(controller.sidebar.root.standardizedFileURL == fixture.directory.standardizedFileURL)
        #expect(controller.sidebar.selectedNode?.url.lastPathComponent == "a.md")
        // The move went through the navigator, so ⌘[ goes back to where the
        // reader was looking.
        #expect(controller.sidebar.navigator.canGoBack)
    }

    /// Issue #7: *"When switching files, the tree should jump to that file."*
    ///
    /// Through the store rather than through ``TreeViewController/follow(_:)``
    /// directly, because the wiring is the thing that was missing: ⌃⇥, the tab
    /// bar, `mark select`, and a close picking a successor all switch tabs by
    /// the same route, and the sidebar has to follow all four.
    @Test("switching tabs moves the sidebar's selection to the new document")
    func sidebarFollowsTheSelectedTab() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        _ = controller.sidebar.view

        controller.open(fixture.file(named: "a.md"))
        #expect(controller.sidebar.selectedNode?.url.lastPathComponent == "a.md")
        controller.open(fixture.file(named: "b.md"))
        #expect(controller.sidebar.selectedNode?.url.lastPathComponent == "b.md")

        controller.tabs.selectPrevious()
        #expect(controller.sidebar.selectedNode?.url.lastPathComponent == "a.md")

        // The selection the tree made must not come back round as "the user
        // picked this file": two tabs went in, two tabs are open, in order.
        #expect(controller.tabs.tabs.map(\.url.lastPathComponent) == ["a.md", "b.md"])
    }

    /// The sidebar root is a place the reader chose, it is in the session file,
    /// and ⌘[ goes back through it. ⌘⇧O moves it on demand
    /// (``revealFromOutsideTheRoot``); a tab switch does not.
    @Test("a tab outside the sidebar's root clears the selection instead of moving it")
    func sidebarFollowStopsAtTheRoot() throws {
        let fixture = try TabFixture()
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-elsewhere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let outside = elsewhere.appendingPathComponent("outside.md")
        try "# outside\n\n- [ ] a task\n".write(to: outside, atomically: true, encoding: .utf8)

        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        _ = controller.sidebar.view
        controller.open(fixture.file(named: "a.md"))
        controller.open(outside)

        #expect(
            controller.sidebar.root.standardizedFileURL == fixture.directory.standardizedFileURL,
            "a tab switch moved the sidebar root")
        #expect(!controller.sidebar.navigator.canGoBack, "a tab switch pushed history")
        #expect(controller.sidebar.selectedNode == nil)

        // Switching back to a document the tree *can* show selects it again.
        controller.tabs.select(controller.tabs.tab(for: fixture.file(named: "a.md")))
        #expect(controller.sidebar.selectedNode?.url.lastPathComponent == "a.md")
    }

    /// Plan §2 M8: *"drop a folder onto the window to set the root"*. Both
    /// halves of the window answer.
    @Test("dropping a folder on either half of the window sets the sidebar root")
    func dropSetsRoot() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(
            root: FileManager.default.temporaryDirectory, session: fixture.session)
        _ = controller.sidebar.view
        #expect(controller.sidebar.handleDrop([fixture.directory]))
        #expect(controller.sidebar.root.standardizedFileURL == fixture.directory.standardizedFileURL)
    }

    // MARK: - Preview tabs

    /// Driven through the **outline view's own selection**, not through
    /// ``TreeViewController/onSelect``, because the wiring is the thing under
    /// test: a click in the tree has to arrive at the store with `preview:
    /// true`, and a test that called the closure by hand would pass with the
    /// two ends connected to nothing.
    @Test("clicking down the tree opens one preview tab, not one tab per file")
    func sidebarClicksPreview() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        _ = controller.sidebar.view
        controller.sidebar.refresh()

        for name in ["a.md", "b.md", "c.md"] {
            try Self.clickRow(named: name, in: controller.sidebar)
        }
        #expect(controller.tabs.count == 1)
        #expect(controller.tabs.selected?.title == "c.md")
        #expect(controller.tabs.selected?.isPreview == true)
    }

    /// The `onActivate` half. `rowDoubleClicked` reads `NSOutlineView.clickedRow`,
    /// which only AppKit sets and no test can, so the double click itself stops
    /// at the callback; what is asserted here is everything after it.
    @Test("double-clicking a file in the tree keeps its tab")
    func sidebarDoubleClickKeeps() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        _ = controller.sidebar.view
        controller.sidebar.refresh()

        try Self.clickRow(named: "a.md", in: controller.sidebar)
        controller.sidebar.onActivate?(fixture.file(named: "a.md"))
        #expect(controller.tabs.count == 1, "the double click must not mint a second tab")
        #expect(controller.tabs.selected?.isPreview == false)

        try Self.clickRow(named: "b.md", in: controller.sidebar)
        #expect(
            controller.tabs.tabs.map(\.title) == ["a.md", "b.md"],
            "the kept tab must survive the next click in the tree")
    }

    /// ADR-6 exempts a dirty tab from eviction so unsaved work is never thrown
    /// away. A preview tab that stayed a preview tab while being typed into
    /// would be the one place that promise leaked — the next click in the tree
    /// would close it.
    @Test("typing into a preview tab keeps it")
    func editingPromotes() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        _ = controller.sidebar.view
        controller.bufferDebounces = (autosave: 60, preview: 60)

        controller.open(fixture.file(named: "a.md"), preview: true)
        let tab = try #require(controller.tabs.selected)
        #expect(tab.isPreview)

        let buffer = try #require(controller.buffer(for: tab))
        buffer.replaceContents(buffer.text + "\ntyped\n")
        #expect(buffer.isDirty)
        #expect(!tab.isPreview, "an edited tab is one the reader is keeping")
    }

    /// Select the row for `name` the way a click does, and let the outline
    /// view's delegate carry it the rest of the way.
    static func clickRow(named name: String, in sidebar: TreeViewController) throws {
        let outline = try #require(sidebar.outlineView)
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? TreeNode,
                node.url.lastPathComponent == name
            else { continue }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }
        Issue.record("no row named \(name) in the tree")
    }

    @Test("closing the last tab leaves the window open on an empty state")
    func lastTabLeavesWindow() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        controller.tabs.closeSelected()

        #expect(controller.tabs.isEmpty)
        #expect(controller.window?.isVisible == false || controller.window != nil)
        #expect(controller.documentView == nil)
        // The tab bar goes away with the last tab, so an empty window is not
        // 30 pt of empty chrome.
        #expect(controller.tabBar.isHidden)
    }

    /// **File ▸ Close All Tabs (⌥⌘W).**
    ///
    /// Three claims, and the middle one is the reason this goes through the
    /// window rather than through ``TabGroups`` alone: closing a tab is what
    /// writes its unsaved buffer, and a command that emptied the window by
    /// dropping stores on the floor would lose 800 ms of typing in every one of
    /// them at once.
    @Test("Close All Tabs empties both halves of a split and writes what was unsaved")
    func closeAllTabsEmptiesTheWindow() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let dirtyURL = fixture.file(named: "a.md")
        controller.open(dirtyURL)
        controller.open(fixture.file(named: "b.md"))
        let dirty = try #require(controller.tabs.tab(for: dirtyURL))
        let buffer = try #require(controller.buffer(for: dirty))
        buffer.replaceContents("# a.md\n\nunsaved words\n")
        #expect(dirty.isDirty)
        #expect(controller.groups.splitRight())
        #expect(controller.groups.isSplit)

        controller.closeAllTabs(nil)

        #expect(controller.groups.allTabs.isEmpty)
        #expect(!controller.groups.isSplit)
        // The window stays. "Close every document" and "close the window" are
        // different requests, and the sidebar is the reason the second one has
        // its own shortcut.
        #expect(controller.window != nil)
        #expect(controller.documentView == nil)
        #expect(
            try String(contentsOf: dirtyURL, encoding: .utf8).contains("unsaved words"),
            "closing every tab discarded a buffer that closing one would have written")
    }

    /// Greyed out with nothing open, and — the part a per-group check would get
    /// wrong — still live when the only documents left are in the other half of
    /// a split.
    @Test("Close All Tabs validates against the window's tabs, not the focused group's")
    func closeAllTabsValidation() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let item = NSMenuItem(
            title: "Close All Tabs",
            action: #selector(MainWindowController.closeAllTabs(_:)), keyEquivalent: "")

        #expect(!controller.validateMenuItem(item), "nothing is open")

        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))
        #expect(controller.validateMenuItem(item))

        #expect(controller.groups.splitRight())
        // Empty the focused group, leaving one document in the other half.
        controller.groups.focused.closeAll()
        #expect(controller.groups.focused.isEmpty)
        #expect(controller.groups.allTabs.count == 1)
        #expect(
            controller.validateMenuItem(item),
            "a document in the other pane is still a document this closes")
    }
}

/// **What counts as opening a file** (`2026-08-26-opened-file-history`).
///
/// `MainWindowController.openInFocusedGroup(_:preview:)` is the funnel every
/// route into a document already passes through, and it is the one place the
/// history is written. These are the rules that make the history worth reading
/// rather than a log of everything that touched a file.
@Suite("MainWindowController — the opened-file history")
@MainActor
struct MainWindowHistoryTests {

    private func make(_ fixture: TabFixture, _ history: OpenHistory) -> MainWindowController {
        MainWindowController(root: fixture.directory, session: fixture.session, history: history)
    }

    @Test("a permanent open is recorded")
    func permanentOpenRecords() throws {
        let fixture = try TabFixture()
        let history = OpenHistory()
        let controller = make(fixture, history)

        controller.open(fixture.file(named: "a.md"))
        #expect(history.entries.map(\.url.lastPathComponent) == ["a.md"])

        controller.open(fixture.file(named: "b.md"))
        #expect(history.entries.map(\.url.lastPathComponent) == ["b.md", "a.md"])
    }

    /// The sidebar's single click is a skim. `TabStore.open` already models a
    /// skim as not the same act as opening — *"clicking down forty files leaves
    /// one tab rather than forty"* — and the history follows it, or forty
    /// glances would evict everything the reader actually chose.
    @Test("a preview open records nothing")
    func previewOpenRecordsNothing() throws {
        let fixture = try TabFixture()
        let history = OpenHistory()
        let controller = make(fixture, history)

        for name in ["a.md", "b.md", "c.md", "d.md"] {
            controller.open(fixture.file(named: name), preview: true)
        }
        #expect(history.isEmpty)
        // And the skims really did happen — one preview tab, as the store
        // promises.
        #expect(controller.tabs.count == 1)
    }

    /// Promotion is the moment the reader named the file.
    @Test("promoting a skimmed file to a permanent tab records it")
    func promotionRecords() throws {
        let fixture = try TabFixture()
        let history = OpenHistory()
        let controller = make(fixture, history)

        let file = fixture.file(named: "a.md")
        controller.open(file, preview: true)
        #expect(history.isEmpty)

        controller.open(file)
        #expect(history.entries.map(\.url.lastPathComponent) == ["a.md"])
        #expect(controller.tabs.selected?.isPreview == false)
    }

    /// **The ADR's rule, pinned.**
    ///
    /// Restore records nothing. This holds today because `TabStore.restore(_:)`
    /// builds tabs directly rather than calling `open(_:preview:)` — which is a
    /// rule and not a happy accident. Route restore through the open path
    /// without suppressing recording and every relaunch stamps every restored
    /// tab with the launch time, turning a history of documents into a list of
    /// launches. That refactor looks like a simplification; this test is what
    /// tells whoever writes it that it is not.
    @Test("restoring a session records nothing")
    func restoreRecordsNothing() throws {
        let fixture = try TabFixture()
        let history = OpenHistory()
        let controller = make(fixture, history)

        controller.restore(
            SessionWindow(
                tabs: [
                    SessionTab(path: fixture.file(named: "a.md").path),
                    SessionTab(path: fixture.file(named: "b.md").path),
                ],
                selectedIndex: 0
            ))

        #expect(controller.tabs.count == 2)
        #expect(history.isEmpty)
    }

    /// Being sent to a document already open in the other half of a split is
    /// still the reader asking to open it, so it moves to the front.
    @Test("re-opening a document held by the other group still records")
    func openingAcrossGroupsRecords() throws {
        let fixture = try TabFixture()
        let history = OpenHistory()
        let controller = make(fixture, history)

        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))
        #expect(controller.groups.splitRight())
        #expect(controller.groups.isSplit)

        // `b.md` is now alone in the second group and `a.md` is selected in the
        // first, so opening `b.md` takes the "already open over there" branch.
        controller.open(fixture.file(named: "a.md"))
        controller.open(fixture.file(named: "b.md"))

        #expect(history.entries.map(\.url.lastPathComponent) == ["b.md", "a.md"])
        // And it went there rather than making a second tab and a second web
        // view for one document.
        #expect(controller.groups.allTabs.count == 2)
    }

    /// The history is the application's, not a window's: two windows, one list.
    @Test("two windows share one history")
    func windowsShareOneHistory() throws {
        let fixture = try TabFixture()
        let history = OpenHistory()
        let coordinator = WindowCoordinator(session: fixture.session, history: history)

        let first = coordinator.makeWindow(root: fixture.directory)
        let second = coordinator.makeWindow(root: fixture.directory)
        first.open(fixture.file(named: "a.md"))
        second.open(fixture.file(named: "b.md"))

        #expect(history.entries.map(\.url.lastPathComponent) == ["b.md", "a.md"])
    }

    /// **A test must not be able to write the developer's real history.**
    ///
    /// There is no `OpenHistory.shared`, and the default on both
    /// `MainWindowController` and `WindowCoordinator` is a *fresh* history
    /// rather than a shared one. That matters because `just swift-test` does
    /// not set `MARK_SESSION_FILE`, so a `WindowCoordinator()` built with the
    /// default `Session()` saves to `~/Library/Application Support/mark/
    /// session.json` — the developer's own. With a shared default, every test
    /// in this file that opens a fixture document would have recorded a path
    /// under `/var/folders/…` into the history the developer sees in ⌘Y.
    ///
    /// Two windows built with no history given are therefore isolated from each
    /// other, which is the observable form of that property.
    @Test("windows built without a coordinator do not share a history")
    func defaultHistoriesAreIsolated() throws {
        let fixture = try TabFixture()
        let first = MainWindowController(root: fixture.directory, session: fixture.session)
        let second = MainWindowController(root: fixture.directory, session: fixture.session)

        first.open(fixture.file(named: "a.md"))
        #expect(first.history.count == 1)
        #expect(second.history.isEmpty)

        // Same for coordinators: two of them do not see each other's opens.
        let left = WindowCoordinator(session: fixture.session)
        let right = WindowCoordinator(session: fixture.session)
        left.makeWindow(root: fixture.directory).open(fixture.file(named: "b.md"))
        #expect(left.history.count == 1)
        #expect(right.history.isEmpty)
    }

    /// A window built directly and then adopted must not be the one window
    /// whose opens go unrecorded.
    @Test("an adopted window records into the coordinator's history")
    func adoptedWindowRecords() throws {
        let fixture = try TabFixture()
        let history = OpenHistory()
        let coordinator = WindowCoordinator(session: fixture.session, history: history)

        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        coordinator.adopt(controller)
        controller.open(fixture.file(named: "a.md"))

        #expect(history.entries.map(\.url.lastPathComponent) == ["a.md"])
    }
}

/// **Edit ▸ Copy as HTML.** The clipboard gets the rendered fragment, twice:
/// as HTML for a rich-text target and as the same text for a plain one.
@Suite("Copy as HTML", .serialized)
@MainActor
struct CopyAsHTMLTests {
    @Test("the rendered fragment lands on the pasteboard as HTML and as text")
    func copiesRenderedFragment() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.open(fixture.file(named: "a.md"))
        let source = try String(contentsOf: fixture.file(named: "a.md"), encoding: .utf8)
        let expected = try MarkCore.renderHTML(
            source: source, theme: ThemeController.shared.name, standalone: false)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        controller.copyAsHTML(nil)

        let html = try #require(pasteboard.string(forType: .html))
        #expect(html == expected)
        #expect(pasteboard.string(forType: .string) == expected)
        // A fragment, not a page: what is pasted goes into something that
        // already has a head.
        #expect(!html.contains("<!doctype"), "\(html.prefix(80))")
        #expect(!html.contains("<html"), "\(html.prefix(80))")
    }

    @Test("with no document there is nothing to copy, and nothing is written")
    func nothingWithoutADocument() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)
        controller.copyAsHTML(nil)
        #expect(pasteboard.string(forType: .string) == "untouched")
        #expect(pasteboard.string(forType: .html) == nil)
    }
}
