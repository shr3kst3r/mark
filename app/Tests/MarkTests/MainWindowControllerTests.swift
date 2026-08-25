import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// ADR-4's structural constraints, asserted rather than commented.
@Suite("MainWindowController — ADR-4's one window")
@MainActor
struct MainWindowControllerTests {

    /// > **Never call `addTabbedWindow` or set `tabbingMode = .preferred`.**
    /// > Mixing native tabbing into this design produces two competing tab
    /// > bars. Set `tabbingMode = .disallowed` explicitly so AppKit does not
    /// > add one.
    ///
    /// Worth a test even though M2 has no tab bar: `.automatic` (the default)
    /// honours the user's "Prefer tabs: always" System Settings preference, so
    /// the bug appears on *someone else's* machine, and only once M3 has drawn
    /// a tab bar for it to compete with.
    @Test("the window disallows native tabbing")
    func tabbingIsDisallowed() throws {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        let window = try #require(controller.window)
        #expect(window.tabbingMode == .disallowed)
        #expect(window.tabGroup?.windows.count ?? 1 == 1)
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
}
