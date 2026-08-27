import AppKit
import Foundation

@testable import MarkKit

/// A throwaway directory of real markdown files, plus a session file inside
/// it.
///
/// Real files rather than stubs on purpose. ADR-4's badge constraint —
/// *"anything operating across all open documents goes through the core
/// against the file on disk"* — is only actually tested if there is a disk and
/// a core in the loop; a fake metadata loader would pass whether or not the
/// production path ever opens the file.
@MainActor
final class TabFixture {

    let directory: URL
    let session: Session

    /// Files created up front, each with a known number of open tasks so the
    /// badge assertions have something to check against.
    static let openTaskCounts: [String: Int] = [
        "a.md": 3,
        "b.md": 1,
        "c.md": 0,
        "d.md": 7,
    ]

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = Session(url: directory.appendingPathComponent("session.json"), debounce: 0.01)

        for (name, open) in Self.openTaskCounts {
            try Self.write(name: name, openTasks: open, checked: 2, in: directory)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Create `count` extra documents, for the eviction and overflow tests.
    @discardableResult
    func makeDocuments(count: Int, prefix: String = "doc") throws -> [URL] {
        try (0..<count).map { index in
            let name = "\(prefix)-\(index).md"
            try Self.write(name: name, openTasks: index % 4, checked: 1, in: directory)
            return file(named: name)
        }
    }

    /// A document using all five task states, for the badge arithmetic
    /// `2026-08-27-five-task-states` changed.
    ///
    /// Three outstanding (open, in-progress, blocked), one done, two
    /// cancelled — so the badge is `3/4` where a count of "not ticked" over
    /// "every task" would say `5/7`, and the difference is the point.
    @discardableResult
    func makeExtendedDocument(named name: String = "extended.md") throws -> URL {
        let body = """
            # Every state

            - [ ] open
            - [/] in progress
            - [?] blocked
            - [x] done
            - [-] dropped
            - [-] also dropped

            """
        let url = file(named: name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A document long enough that a scroll offset of a few thousand points is
    /// actually reachable, for the rehydration test.
    func makeLongDocument(named name: String, paragraphs: Int = 400) throws -> URL {
        var body = "# \(name)\n\n- [ ] one open task\n\n"
        for index in 0..<paragraphs {
            body += "Paragraph \(index) of a document that has to be tall enough to scroll.\n\n"
        }
        let url = file(named: name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func write(name: String, openTasks: Int, checked: Int, in directory: URL) throws {
        var body = "# Title of \(name)\n\nSome prose with a literal [ ] bracket in it.\n\n"
        for index in 0..<openTasks {
            body += "- [ ] open task \(index)\n"
        }
        for index in 0..<checked {
            body += "- [x] done task \(index)\n"
        }
        body += "\n"
        try body.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

/// A ``TabHydrator`` that makes real ``DocumentView``s and counts what it was
/// asked to do.
///
/// Real views, not stubs: the thing under test is that dehydration actually
/// releases a `WKWebView` and that rehydration goes back through
/// ``DocumentView/open(_:restoringScrollTo:)`` — neither of which a stub would
/// exercise.
@MainActor
final class CountingHydrator: TabHydrator {

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

    private(set) var hydrated: [URL] = []
    private(set) var dehydrated: [URL] = []

    /// Scroll offsets ``DocumentView`` was asked to restore, in call order.
    private(set) var restoredOffsets: [Double] = []

    func makeDocumentView(for tab: DocumentTab) -> DocumentView {
        hydrated.append(tab.url)
        restoredOffsets.append(tab.scrollOffset)
        let view = DocumentView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        container.addSubview(view)
        // Mirrors ``MainWindowController/makeDocumentView(for:)``: the tab's
        // cached offset has to track the live one, or dehydration and the
        // session file read a stale value.
        view.onScroll = { [weak tab] y in tab?.scrollOffset = y }
        view.open(tab.url, restoringScrollTo: tab.scrollOffset)
        return view
    }

    func discardDocumentView(_ view: DocumentView, for tab: DocumentTab) {
        dehydrated.append(tab.url)
        view.tearDown()
    }

    /// Views that arrived from another store, in call order.
    ///
    /// The property a pop-out test actually needs: a moved tab must arrive
    /// *without* going through `makeDocumentView`, because remaking the view
    /// would throw away the DOM and the scroll position the move exists to
    /// keep.
    private(set) var adopted: [URL] = []

    func adopt(_ view: DocumentView, for tab: DocumentTab) {
        adopted.append(tab.url)
        container.addSubview(view)
        view.onScroll = { [weak tab] y in tab?.scrollOffset = y }
    }

    var liveWebViewCount: Int {
        container.subviews.compactMap { $0 as? DocumentView }.count
    }
}

/// Fixture + store + hydrator + bar, in one object.
///
/// Not a convenience: ``TabStore/hydrator`` and ``TabBarView/store`` are both
/// `weak` (the production graph is window controller → store → hydrator, back
/// to the same controller), so a test that lets either go out of scope gets a
/// store that silently stops hydrating and a bar that silently stops laying
/// out. Holding one object holds the whole graph.
@MainActor
final class TabHarness {

    let fixture: TabFixture
    let store: TabStore
    let hydrator: CountingHydrator
    let bar: TabBarView

    /// - Parameter governor: shared with another harness to stand in for two
    ///   windows sharing one memory budget
    ///   (`2026-08-26-multiple-windows-and-split-panes`). Left nil, the harness
    ///   gets a private governor, so a test that changes the limit cannot
    ///   change the answer for a suite running beside it.
    init(
        files: [String] = [],
        residentLimit: Int = TabStore.defaultResidentLimit,
        governor: ResidencyGovernor? = nil,
        barWidth: CGFloat = 900
    ) throws {
        fixture = try TabFixture()
        store = governor.map { TabStore(governor: $0) } ?? TabStore(residentLimit: residentLimit)
        hydrator = CountingHydrator()
        store.hydrator = hydrator
        bar = TabBarView(store: store)
        bar.frame = NSRect(x: 0, y: 0, width: barWidth, height: TabBarView.barHeight)
        for name in files { store.open(fixture.file(named: name)) }
        bar.reload()
    }

    func file(named name: String) -> URL { fixture.file(named: name) }

    /// Wrap this harness's store in a window's worth of groups.
    ///
    /// The store the harness already built becomes group 0, so a test can set
    /// up tabs the familiar way and then split. Every group a split makes is
    /// wired to the same hydrator, which is what the window controller's
    /// `configureStore` does in production — a group whose store has no
    /// hydrator silently never hydrates, and the test would pass for the wrong
    /// reason.
    func makeGroups() -> TabGroups {
        let groups = TabGroups(governor: store.governor, first: store)
        groups.configureStore = { [hydrator] store in
            store.hydrator = hydrator
        }
        return groups
    }

    @discardableResult
    func open(_ name: String) -> DocumentTab {
        let tab = store.open(fixture.file(named: name))
        bar.reload()
        return tab
    }

    @discardableResult
    func openAll(_ urls: [URL]) -> [DocumentTab] {
        let tabs = urls.map { store.open($0) }
        bar.reload()
        return tabs
    }

    /// Simulate the page reporting a scroll, through the real bridge path, so
    /// the offset lands where dehydration will actually read it.
    func reportScroll(_ y: Double, source: Int? = nil, on tab: DocumentTab) {
        guard let view = tab.documentView else { return }
        view.scriptBridge(ScriptBridge(), didReceive: .scroll(y: y, source: source))
    }

    /// ``DocumentTab/refreshMetadata(completion:)`` reads the file off the main
    /// thread, so badge assertions have to wait for it. Polled rather than
    /// continuation-based because the store refreshes on its own schedule and a
    /// single completion is not the only writer.
    func waitForMetadata(
        of tabs: [DocumentTab],
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if tabs.allSatisfy({ $0.metadata != nil }) { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// The one thing a window does that a ``TabGroups`` cannot do for itself:
/// collapse a group that has just run out of documents.
///
/// ``MainWindowController`` does this in `tabStoreDidEmpty`; a test that drives
/// the model without a window needs the same wiring, or a group empties and the
/// split stays open — which is the state the ADR says is not a state.
@MainActor
final class GroupCollapser: TabStoreDelegate {
    let groups: TabGroups

    init(groups: TabGroups) {
        self.groups = groups
    }

    func tabStoreDidChangeTabs(_ store: TabStore) {}
    func tabStore(_ store: TabStore, didSelect tab: DocumentTab?, previous: DocumentTab?) {}
    func tabStoreDidEmpty(_ store: TabStore) {
        groups.collapseIfEmpty(store)
    }
}
