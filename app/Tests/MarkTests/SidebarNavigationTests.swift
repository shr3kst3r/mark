import AppKit
import Foundation
import Testing

@testable import MarkKit

/// A real directory tree on disk, shaped so every M8 behaviour has something to
/// be wrong about.
///
/// ```
/// root/
///   .gitignore            "ignored/\nsecret.md\n*.log\n"
///   top.md                3 open / 5 total tasks
///   picture.png           not markdown
///   build.log             not markdown *and* gitignored
///   secret.md             markdown, gitignored
///   .hidden.md            hidden markdown
///   .hiddendir/inside.md  hidden directory
///   ignored/ignored.md    gitignored directory
///   docs/
///     guide.md            1 open / 4 total
///     deep/
///       buried.md         0 open / 0 total
///   notes/                three files whose alphabetical order is deliberately
///     alpha.md            0 open / 2 total   not their task-count order, so a
///     beta.md             7 open / 7 total   sort that silently falls back to
///     gamma.md            2 open / 2 total   name is a failing test
/// ```
@MainActor
final class SidebarFixture {

    let root: URL
    /// A directory *outside* ``root``, for the ⌘⇧O gate.
    let elsewhere: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-sidebar-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)

        let manager = FileManager.default
        for relative in ["docs/deep", "notes", ".hiddendir", "ignored"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        try "ignored/\nsecret.md\n*.log\n".write(
            to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        try write("top.md", open: 3, done: 2)
        try write("secret.md", open: 1, done: 0)
        try write(".hidden.md", open: 1, done: 0)
        try write(".hiddendir/inside.md", open: 1, done: 0)
        try write("ignored/ignored.md", open: 1, done: 0)
        try write("docs/guide.md", open: 1, done: 3)
        try write("docs/deep/buried.md", open: 0, done: 0)
        try write("notes/alpha.md", open: 0, done: 2)
        try write("notes/beta.md", open: 7, done: 0)
        try write("notes/gamma.md", open: 2, done: 0)
        try "not markdown".write(
            to: root.appendingPathComponent("picture.png"), atomically: true, encoding: .utf8)
        try "log line".write(
            to: root.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)

        try "# outside\n\n- [ ] a task\n".write(
            to: elsewhere.appendingPathComponent("outside.md"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    private func write(_ relative: String, open: Int, done: Int) throws {
        var body = "# \(relative)\n\nProse with a literal [ ] bracket.\n\n"
        for index in 0..<open { body += "- [ ] open \(index)\n" }
        for index in 0..<done { body += "- [x] done \(index)\n" }
        try (body + "\n").write(
            to: root.appendingPathComponent(relative), atomically: true, encoding: .utf8)
    }
}

/// Wraps a lister and counts what it read. The only way to catch an eager walk
/// before a user with 608,597 files does (research §2.8).
@MainActor
final class CountingDirectoryLister: DirectoryLister {
    private let inner: any DirectoryLister
    private(set) var listings: [String] = []

    init(_ inner: any DirectoryLister = CoreDirectoryLister()) { self.inner = inner }

    /// Forwarded, not stored: the toggles have to reach the core, which is the
    /// only thing that knows what `.gitignore` says.
    var options: TreeListingOptions {
        get { inner.options }
        set { inner.options = newValue }
    }

    func entries(in directory: String) throws -> [TreeEntry] {
        listings.append(directory)
        return try inner.entries(in: directory)
    }

    var count: Int { listings.count }
    func reset() { listings.removeAll() }
}

@Suite("Sidebar — M8's navigator, filter, badges, and toggles")
@MainActor
struct SidebarNavigationTests {

    /// A loaded controller, its counting lister, and the fixture, held
    /// together: letting the fixture go out of scope deletes the tree out from
    /// under the test.
    private func make(_ fixture: SidebarFixture) -> (TreeViewController, CountingDirectoryLister) {
        let lister = CountingDirectoryLister()
        let controller = TreeViewController(root: fixture.root, lister: lister)
        _ = controller.view  // loadView
        controller.viewDidLoad()
        return (controller, lister)
    }

    private func node(_ controller: TreeViewController, named name: String) -> TreeNode? {
        (0..<controller.outlineView.numberOfRows)
            .compactMap { controller.outlineView.item(atRow: $0) as? TreeNode }
            .first { $0.name == name }
    }

    private func visibleNames(_ controller: TreeViewController) -> [String] {
        (0..<controller.outlineView.numberOfRows)
            .compactMap { (controller.outlineView.item(atRow: $0) as? TreeNode)?.name }
    }

    // MARK: - Laziness

    /// The gate: *"navigating into a 608k-file tree stays responsive, and
    /// directory reads stay bounded"* — asserted the way `core/tests/
    /// tree_lazy.rs` does, from the Swift side.
    @Test("showing a root reads exactly one directory, however deep the tree")
    func rootIsOneRead() throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        #expect(lister.count == 1)
        #expect(lister.listings == [fixture.root.path])
        withExtendedLifetime(controller) {}
    }

    @Test("moving the root — parent, back, forward, a crumb — is one read each")
    func navigationIsOneReadEach() throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        lister.reset()

        #expect(controller.navigateToParent())
        #expect(lister.count == 1, "going up read \(lister.listings)")
        #expect(controller.navigateBack())
        #expect(lister.count == 2)
        #expect(controller.navigateForward())
        #expect(lister.count == 3)
        // Back to the fixture root, and the breadcrumb agrees.
        #expect(controller.navigateBack())
        #expect(controller.root.path == fixture.root.path)
        #expect(controller.breadcrumbBar.crumbTitles.last == "root")
    }

    @Test("filtering reads nothing and expands nothing")
    func filteringIsFree() throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        lister.reset()

        controller.filter = "guide"
        controller.filter = "gui"
        controller.filter = "g"
        controller.filter = ""
        #expect(lister.count == 0, "the filter read \(lister.listings)")
    }

    @Test("changing the sort reads nothing")
    func sortingIsFree() throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        lister.reset()
        for sort in TreeSort.allCases { controller.sort = sort }
        #expect(lister.count == 0, "sorting read \(lister.listings)")
    }

    // MARK: - Filter

    /// Plan §2 M8's gate: *"filter the visible tree by name, incremental,
    /// **without collapsing what the user expanded**"*.
    @Test("the filter does not collapse what the user expanded")
    func filterPreservesExpansion() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)

        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)
        #expect(controller.outlineView.isItemExpanded(docs))
        let deep = try #require(node(controller, named: "deep"))
        controller.outlineView.expandItem(deep)
        #expect(controller.outlineView.isItemExpanded(deep))

        controller.filter = "d"
        #expect(controller.outlineView.isItemExpanded(docs), "the filter collapsed docs/")
        #expect(controller.outlineView.isItemExpanded(deep), "the filter collapsed docs/deep/")

        controller.filter = ""
        #expect(controller.outlineView.isItemExpanded(docs))
        #expect(controller.outlineView.isItemExpanded(deep))
    }

    @Test("the filter hides non-matching rows and keeps matching ones")
    func filterMatches() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)

        controller.filter = "guide"
        let names = visibleNames(controller)
        #expect(names.contains("guide.md"))
        #expect(names.contains("docs"), "a listed directory with a match under it stays")
        #expect(!names.contains("top.md"))
        // `notes/` has never been listed, so whether it holds a match is
        // unknowable without reading it — and reading every unexpanded
        // directory is the eager walk this sidebar exists to avoid.
        #expect(names.contains("notes"))
    }

    // MARK: - Reveal

    /// The gate: *"⌘⇧O reveals the active tab's file even when that file is
    /// outside the current root."*
    @Test("reveal moves the root when the file is outside it, and records history")
    func revealOutsideTheRoot() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let outside = fixture.elsewhere.appendingPathComponent("outside.md")
        #expect(!controller.root.path.hasPrefix(fixture.elsewhere.path))

        #expect(controller.reveal(outside))
        #expect(controller.root.path == fixture.elsewhere.path)
        #expect(controller.selectedNode?.url.lastPathComponent == "outside.md")
        // And ⌘[ takes you back to where you were looking.
        #expect(controller.navigator.back.map(\.path) == [fixture.root.path])
        #expect(controller.navigateBack())
        #expect(controller.root.path == fixture.root.path)
    }

    @Test("reveal inside the root reads one directory per level and nothing else")
    func revealIsBounded() throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        lister.reset()

        #expect(controller.reveal(fixture.url("docs/deep/buried.md")))
        #expect(controller.selectedNode?.url.lastPathComponent == "buried.md")
        // `docs` and `docs/deep`. The root was already listed.
        #expect(
            lister.listings == [fixture.url("docs").path, fixture.url("docs/deep").path],
            "reveal read \(lister.listings)")
    }

    @Test("reveal clears a filter that would hide the row rather than doing nothing")
    func revealDefeatsTheFilter() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        controller.filter = "zzzz-matches-nothing"
        #expect(controller.reveal(fixture.url("docs/guide.md")))
        #expect(controller.filter.isEmpty)
        #expect(controller.selectedNode?.url.lastPathComponent == "guide.md")
    }

    @Test("revealing a file that does not exist fails rather than moving the root")
    func revealMissingFile() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        #expect(!controller.reveal(fixture.url("nope/never.md")))
        #expect(controller.root.path == fixture.root.path)
    }

    // MARK: - Following the front document

    /// Issue #7: *"When switching files, the tree should jump to that file."*
    @Test("following the front document expands to it and selects it")
    func followSelectsTheFrontDocument() throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        lister.reset()

        #expect(controller.follow(fixture.url("docs/deep/buried.md")))
        #expect(controller.selectedNode?.url.lastPathComponent == "buried.md")
        // Same bound as reveal: one read per level between the root and the
        // file, and nothing else. `docs` and `docs/deep`.
        #expect(
            lister.listings == [fixture.url("docs").path, fixture.url("docs/deep").path],
            "follow read \(lister.listings)")

        // Following the row that is already selected reads nothing at all,
        // which is the common case: clicking a file in the tree is what
        // selected it and what opened the tab.
        lister.reset()
        #expect(controller.follow(fixture.url("docs/deep/buried.md")))
        #expect(lister.count == 0, "a redundant follow read \(lister.listings)")
    }

    /// The one deliberate difference from ⌘⇧O. A tab switch is not an
    /// instruction about where the sidebar should be rooted, and two tabs in
    /// different directories would otherwise drag the root back and forth on
    /// every ⌃⇥.
    @Test("following a file outside the root deselects instead of moving the root")
    func followNeverMovesTheRoot() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        #expect(controller.follow(fixture.url("top.md")))
        #expect(controller.selectedNode?.url.lastPathComponent == "top.md")

        let outside = fixture.elsewhere.appendingPathComponent("outside.md")
        #expect(!controller.follow(outside))
        #expect(controller.root.path == fixture.root.path, "follow moved the root")
        #expect(controller.navigator.back.isEmpty, "follow pushed history")
        // And it does not go on pointing at the file the reader has switched
        // away from.
        #expect(controller.selectedNode == nil)
    }

    /// The other difference: ``TreeViewController/reveal(_:)`` clears a filter
    /// that hides its target, because the user asked for that row by name. A
    /// filter is a thing you are doing, and the tree keeping up with you is not
    /// a reason to cancel it.
    @Test("following does not clear the filter the way reveal does")
    func followLeavesTheFilterAlone() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        controller.filter = "zzzz-matches-nothing"
        #expect(!controller.follow(fixture.url("docs/guide.md")))
        #expect(controller.filter == "zzzz-matches-nothing")
        #expect(controller.selectedNode == nil)
    }

    /// The feedback loop this would otherwise be: the tree follows a tab
    /// switch, the selection it makes is reported as the user picking a file,
    /// and the store is asked to open the tab it just switched to.
    @Test("the selection a follow makes is not reported back as a file the user picked")
    func followDoesNotReportASelection() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        var opened: [URL] = []
        controller.onSelect = { opened.append($0) }

        #expect(controller.follow(fixture.url("docs/guide.md")))
        #expect(opened.isEmpty, "follow asked for \(opened.map(\.lastPathComponent)) to be opened")

        // The user picking that same row still does report it — the follow
        // suppressed one selection, not the delegate.
        let guide = try #require(node(controller, named: "guide.md"))
        let row = controller.outlineView.row(forItem: guide)
        controller.outlineView.deselectAll(nil)
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(opened.map(\.lastPathComponent) == ["guide.md"])
    }

    // MARK: - Badges

    /// The gate: *"badges appear progressively without blocking the tree, and
    /// are correct."*
    @Test("a badge is absent on first draw and correct once it lands")
    func badgesAreProgressiveAndCorrect() async throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)

        let top = fixture.url("top.md")
        // The draw path: no badge yet, and asking does not read the file on
        // this thread.
        #expect(controller.badges.badge(for: top) == nil)
        controller.badges.request(top)
        #expect(controller.badges.badge(for: top) == nil, "request() must not compute inline")

        let landed = await waitForBadge(controller, url: top)
        #expect(landed == TaskBadge(open: 3, total: 5))
        // Computing a badge is a file read, not a directory read.
        #expect(!lister.listings.contains { $0.hasSuffix("top.md") })
    }

    @Test("badges are computed once and served from cache after that")
    func badgesAreCached() async throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let url = fixture.url("top.md")
        controller.badges.request(url)
        controller.badges.request(url)
        _ = await waitForBadge(controller, url: url)
        #expect(controller.badges.computed == 1)
        for _ in 0..<10 { controller.badges.request(url) }
        #expect(controller.badges.computed == 1)
    }

    @Test("a document with no tasks gets a badge with no label")
    func emptyBadge() async throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let badge = try #require(
            await waitForBadge(controller, url: fixture.url("docs/deep/buried.md")))
        #expect(badge == TaskBadge(open: 0, total: 0))
        #expect(badge.label == nil)
    }

    // MARK: - Sorting

    @Test("name sort puts directories first, then files, alphabetically")
    func nameSort() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        #expect(visibleNames(controller) == ["docs", "notes", "top.md"])
    }

    /// The decision plan §2 M8 asked to be made explicit: sorting by task count
    /// uses the badges that are known, schedules the rest in the background,
    /// and converges — it never blocks and never walks.
    @Test("task-count sort converges as badges arrive, without a blocking read")
    func taskCountSort() async throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        let notes = try #require(node(controller, named: "notes"))
        controller.outlineView.expandItem(notes)
        // By name, which is the order the core hands back.
        #expect(inNotes(controller) == ["alpha.md", "beta.md", "gamma.md"])
        lister.reset()

        controller.sort = .taskCount
        // Immediately after the switch no badge has landed, so the order is
        // still by name — and crucially the call *returned* rather than
        // blocking on three file reads.
        #expect(lister.count == 0, "the task-count sort read \(lister.listings)")
        #expect(inNotes(controller) == ["alpha.md", "beta.md", "gamma.md"])

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if ["alpha.md", "beta.md", "gamma.md"].allSatisfy({
                controller.badges.badge(for: fixture.url("notes/\($0)")) != nil
            }) { break }
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        // Let the coalesced redraw land.
        try? await _Concurrency.Task.sleep(for: .milliseconds(300))

        #expect(
            inNotes(controller) == ["beta.md", "gamma.md", "alpha.md"],
            "7 open, then 2, then 0 — got \(inNotes(controller))")
        #expect(lister.count == 0, "converging read \(lister.listings)")
    }

    /// The three files in `notes/`, in row order.
    private func inNotes(_ controller: TreeViewController) -> [String] {
        visibleNames(controller).filter { ["alpha.md", "beta.md", "gamma.md"].contains($0) }
    }

    @Test("modified sort puts the most recently changed file first")
    func modifiedSort() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        // `top.md` is the only file at the root; give it a companion with a
        // known, older timestamp so the comparison has two sides.
        let older = fixture.url("older.md")
        try "# older\n".write(to: older, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: older.path)
        controller.refresh()

        controller.sort = .modified
        let names = visibleNames(controller).filter { $0.hasSuffix(".md") }
        #expect(names == ["top.md", "older.md"], "got \(names)")
    }

    // MARK: - Toggles

    @Test("non-markdown files are hidden by default and dimmed when shown")
    func nonMarkdownToggle() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        #expect(!visibleNames(controller).contains("picture.png"))

        controller.listingOptions.showsNonMarkdown = true
        #expect(visibleNames(controller).contains("picture.png"))

        let png = try #require(node(controller, named: "picture.png"))
        #expect(!png.isMarkdown)
        let cell = TreeCellView(frame: .zero)
        cell.configure(with: png, badge: nil)
        #expect(cell.textField?.textColor == .tertiaryLabelColor)
        #expect(TreeCellView.accessibilityLabel(for: png, badge: nil).contains("not a markdown"))
    }

    @Test("a non-markdown row is selectable but does not open")
    func nonMarkdownIsNotOpenable() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        controller.listingOptions.showsNonMarkdown = true

        var opened: [URL] = []
        controller.onSelect = { opened.append($0) }

        let png = try #require(node(controller, named: "picture.png"))
        let row = controller.outlineView.row(forItem: png)
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(opened.isEmpty, "a .png must not open a tab")

        let top = try #require(node(controller, named: "top.md"))
        let markdownRow = controller.outlineView.row(forItem: top)
        controller.outlineView.selectRowIndexes(
            IndexSet(integer: markdownRow), byExtendingSelection: false)
        #expect(opened.map(\.lastPathComponent) == ["top.md"])
    }

    @Test("hidden files appear only behind the toggle, and .git never does")
    func hiddenToggle() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        #expect(!visibleNames(controller).contains(".hidden.md"))
        #expect(!visibleNames(controller).contains(".hiddendir"))

        controller.listingOptions.showsHidden = true
        let names = visibleNames(controller)
        #expect(names.contains(".hidden.md"))
        #expect(names.contains(".hiddendir"))
        #expect(!names.contains(".git"))
    }

    /// `.gitignore` is honoured with both toggles on, **including for
    /// non-markdown files** — the gap M8 recorded and M7 closed.
    ///
    /// M8 could not reach `tree::Options.markdown_only` or `.hidden` over the
    /// ABI, so it reimplemented both over `FileManager` and added back what the
    /// core had not returned. That could not distinguish "dropped because it is
    /// not markdown" from "dropped because `.gitignore` says so", because the
    /// core drops non-markdown files *after* the ignore test — so `build.log`,
    /// matched by `*.log`, appeared. This expectation is the inverted one: the
    /// flags now go to the core, the reimplementation is gone, and the core's
    /// answer is the only answer.
    @Test("gitignored entries stay hidden with both toggles on, non-markdown included")
    func gitignoreIsStillHonoured() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        controller.listingOptions = TreeListingOptions(showsNonMarkdown: true, showsHidden: true)

        let names = visibleNames(controller)
        #expect(!names.contains("ignored"), "a gitignored directory must not appear")
        #expect(!names.contains("secret.md"), "a gitignored markdown file must not appear")
        #expect(
            !names.contains("build.log"),
            "a gitignored non-markdown file must not appear either (M7 closed this gap)")
        // The toggle still does what it is for: the *unignored* non-markdown
        // file and the hidden entries are there.
        #expect(names.contains("picture.png"))
        #expect(names.contains(".hidden.md"))
        #expect(names.contains(".hiddendir"))
    }

    /// The Swift-side markdown extension list mirrors `core/src/tree.rs`.
    /// Asserted against the core itself rather than against a copy of the
    /// constant, so a change on either side fails here.
    @Test("the Swift markdown extension list agrees with the core's")
    func markdownExtensionParity() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Numbered base names, because this filesystem is case-insensitive:
        // `f.md` and `f.MD` would be one file, and the surviving name is
        // whichever was created first — which would make the `MD` case assert
        // against a file that is not there rather than against the core.
        let candidates = ["md", "markdown", "mdown", "mkd", "mdx", "txt", "rs", "png", "MD"]
        let names = candidates.enumerated().map { "f\($0.offset).\($0.element)" }
        for name in names {
            try "# x\n".write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let fromCore = Set(
            try MarkCore.tree(directory: directory.path).filter { !$0.isDirectory }.map(\.name))
        for (ext, name) in zip(candidates, names) {
            let url = directory.appendingPathComponent(name)
            #expect(
                TreeNode.isMarkdown(url) == fromCore.contains(name),
                "\(ext): Swift says \(TreeNode.isMarkdown(url)), the core says \(fromCore.contains(name))"
            )
        }
    }

    // MARK: - Drag and drop

    @Test("dropping a folder sets the root; dropping a markdown file opens it")
    func drop() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        var opened: [URL] = []
        controller.onSelect = { opened.append($0) }

        #expect(controller.handleDrop([fixture.url("docs")]))
        #expect(controller.root.path == fixture.url("docs").path)
        #expect(controller.navigator.back.map(\.path) == [fixture.root.path])

        #expect(controller.handleDrop([fixture.url("docs/guide.md")]))
        #expect(opened.map(\.lastPathComponent) == ["guide.md"])

        #expect(!controller.handleDrop([fixture.url("nothing-here")]))
    }

    /// Dragging a row out has to put a `public.file-url` on the pasteboard, or
    /// Finder ignores the drop entirely.
    @Test("a row drags out as a file URL")
    func dragOut() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let top = try #require(node(controller, named: "top.md"))
        let writer = controller.outlineView.dataSource?.outlineView?(
            controller.outlineView, pasteboardWriterForItem: top)
        let url = try #require(writer as? NSURL)
        #expect((url as URL).lastPathComponent == "top.md")
        #expect(url.writableTypes(for: NSPasteboard.general).contains(.fileURL))
    }

    // MARK: - Session

    @Test("the sidebar's root, history, toggles, and sort round-trip")
    func sessionRoundTrip() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)

        controller.navigate(to: fixture.url("docs"))
        controller.navigateToParent()
        controller.navigateBack()
        controller.listingOptions = TreeListingOptions(showsNonMarkdown: true, showsHidden: false)
        controller.sort = .taskCount

        let snapshot = controller.snapshot()
        #expect(snapshot.root.path == fixture.url("docs").path)
        #expect(snapshot.back.map(\.path) == [fixture.root.path])
        #expect(snapshot.forward.map(\.path) == [fixture.root.path])

        let (restored, _) = make(fixture)
        restored.restore(snapshot)
        #expect(restored.root.path == snapshot.root.path)
        #expect(restored.navigator.back.map(\.path) == snapshot.back.map(\.path))
        #expect(restored.navigator.forward.map(\.path) == snapshot.forward.map(\.path))
        #expect(restored.listingOptions.showsNonMarkdown)
        #expect(restored.sort == .taskCount)
        #expect(restored.breadcrumbBar.crumbTitles.last == "docs")
    }

    // MARK: - Helpers

    private func waitForBadge(
        _ controller: TreeViewController, url: URL, timeout: Duration = .seconds(5)
    ) async -> TaskBadge? {
        controller.badges.request(url)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let badge = controller.badges.badge(for: url) { return badge }
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}
