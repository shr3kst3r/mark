import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The background refresh: a sidebar left open while something else writes to
/// the directory it is showing.
///
/// Every test here drives ``TreeViewController/pollForChanges()`` directly
/// rather than waiting on the timer, because what is under test is what a poll
/// *does* — and because a test that waits two seconds per assertion is a test
/// people stop running. The timer's own lifecycle needs a window on screen and
/// is left to the app.
///
/// The gate the whole feature is written against is ``quietPollReadsNothing``:
/// a poll that finds nothing must cost one `stat` per expanded directory and
/// **not one directory read**. Without that, a refresh running every two
/// seconds over the 608,597-file tree from research §2.8 is a permanent
/// background walk, which is the thing the entire sidebar is designed to avoid.
@Suite("Sidebar — the background refresh")
@MainActor
struct SidebarPollTests {

    private func make(_ fixture: SidebarFixture) -> (TreeViewController, CountingDirectoryLister) {
        let lister = CountingDirectoryLister()
        let controller = TreeViewController(root: fixture.root, lister: lister)
        _ = controller.view
        controller.viewDidLoad()
        return (controller, lister)
    }

    private func visibleNames(_ controller: TreeViewController) -> [String] {
        (0..<controller.outlineView.numberOfRows)
            .compactMap { (controller.outlineView.item(atRow: $0) as? TreeNode)?.name }
    }

    private func node(_ controller: TreeViewController, named name: String) -> TreeNode? {
        (0..<controller.outlineView.numberOfRows)
            .compactMap { controller.outlineView.item(atRow: $0) as? TreeNode }
            .first { $0.name == name }
    }

    /// A directory's `mtime` is only nanosecond-resolution on APFS, so a
    /// listing taken within a second of one is deliberately re-read once (see
    /// ``TreeNode``). Settling that means the tests that count reads are
    /// counting the steady state rather than that one-off.
    private func settle(_ controller: TreeViewController) async {
        try? await _Concurrency.Task.sleep(for: .milliseconds(1_100))
        controller.pollForChanges()
    }

    // MARK: - What it is for

    @Test("a file written after the listing shows up on the next poll")
    func newFileAppears() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        #expect(!visibleNames(controller).contains("fresh.md"))

        try "# fresh\n".write(
            to: fixture.url("fresh.md"), atomically: true, encoding: .utf8)

        #expect(controller.pollForChanges(), "the poll reported no change")
        #expect(visibleNames(controller).contains("fresh.md"), "got \(visibleNames(controller))")
    }

    @Test("a file written into an expanded subdirectory shows up too")
    func newFileInASubdirectoryAppears() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)

        try "# added\n".write(
            to: fixture.url("docs/added.md"), atomically: true, encoding: .utf8)

        #expect(controller.pollForChanges())
        #expect(visibleNames(controller).contains("added.md"))
    }

    @Test("a deleted file leaves the tree")
    func deletedFileGoes() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let notes = try #require(node(controller, named: "notes"))
        controller.outlineView.expandItem(notes)
        #expect(visibleNames(controller).contains("alpha.md"))

        try FileManager.default.removeItem(at: fixture.url("notes/alpha.md"))

        #expect(controller.pollForChanges())
        #expect(!visibleNames(controller).contains("alpha.md"))
    }

    @Test("a whole directory disappearing takes its rows with it")
    func deletedDirectoryGoes() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)
        let deep = try #require(node(controller, named: "deep"))
        controller.outlineView.expandItem(deep)
        #expect(visibleNames(controller).contains("buried.md"))

        try FileManager.default.removeItem(at: fixture.url("docs"))

        #expect(controller.pollForChanges())
        let names = visibleNames(controller)
        #expect(!names.contains("docs"))
        #expect(!names.contains("deep"))
        #expect(!names.contains("buried.md"))
        // `top.md` is in the same directory and was not touched.
        #expect(names.contains("top.md"))
    }

    // MARK: - What it must not cost

    /// **The gate.** A poll that finds nothing reads no directory at all.
    @Test("a poll that finds nothing reads no directory")
    func quietPollReadsNothing() async throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)
        let notes = try #require(node(controller, named: "notes"))
        controller.outlineView.expandItem(notes)
        await settle(controller)

        lister.reset()
        #expect(!controller.pollForChanges(), "a quiet poll claimed a change")
        #expect(!controller.pollForChanges())
        #expect(lister.count == 0, "a quiet poll read \(lister.listings)")
    }

    /// The laziness the rest of the sidebar promises, kept by the poll: a
    /// directory nobody expanded is a directory nobody reads, however much is
    /// written into it.
    @Test("the poll never reads a directory that was never expanded")
    func unexpandedDirectoriesStayUnread() throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)

        // Two levels down, under a folder that has a row but has never been
        // opened.
        try "# buried too\n".write(
            to: fixture.url("docs/deep/alsoburied.md"), atomically: true, encoding: .utf8)

        lister.reset()
        controller.pollForChanges()
        #expect(
            !lister.listings.contains(fixture.url("docs/deep").path),
            "the poll read \(lister.listings)")
    }

    /// A change in one directory does not re-read its siblings.
    @Test("only the directory that changed is re-read")
    func onlyTheChangedDirectoryIsRead() async throws {
        let fixture = try SidebarFixture()
        let (controller, lister) = make(fixture)
        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)
        let notes = try #require(node(controller, named: "notes"))
        controller.outlineView.expandItem(notes)
        await settle(controller)

        try "# only here\n".write(
            to: fixture.url("notes/delta.md"), atomically: true, encoding: .utf8)

        lister.reset()
        #expect(controller.pollForChanges())
        #expect(lister.listings == [fixture.url("notes").path], "the poll read \(lister.listings)")
    }

    // MARK: - What it must not disturb

    /// The reason a survivor keeps its ``TreeNode``: replacing it would
    /// collapse the folder under it and move the selection off it, so a
    /// refresh arriving while someone reads would close what they opened.
    @Test("a poll keeps the expansion and the selection")
    func expansionAndSelectionSurvive() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)
        let guide = try #require(node(controller, named: "guide.md"))
        let before = controller.outlineView.row(forItem: guide)
        controller.outlineView.selectRowIndexes(
            IndexSet(integer: before), byExtendingSelection: false)

        // Sorts above `guide.md` inside `docs`, so the selected row moves down
        // by one — which is the case a reload that kept the selected *index*
        // would get silently wrong.
        try "# aaa\n".write(to: fixture.url("docs/aaa.md"), atomically: true, encoding: .utf8)

        #expect(controller.pollForChanges())
        #expect(controller.outlineView.isItemExpanded(docs), "the poll collapsed docs")
        #expect(controller.selectedNode?.url.path == fixture.url("docs/guide.md").path)
        #expect(controller.outlineView.selectedRow == before + 1, "the row did not move")
    }

    /// Restoring the selection must not read as the reader picking that file:
    /// it would open a tab every couple of seconds for as long as anything was
    /// writing to the directory.
    @Test("a poll does not report the selection as a file the reader opened")
    func pollDoesNotOpenTabs() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let top = try #require(node(controller, named: "top.md"))
        controller.outlineView.selectRowIndexes(
            IndexSet(integer: controller.outlineView.row(forItem: top)),
            byExtendingSelection: false)

        var opened: [URL] = []
        controller.onSelect = { opened.append($0) }
        controller.onActivate = { opened.append($0) }

        try "# aaa\n".write(to: fixture.url("aaa.md"), atomically: true, encoding: .utf8)
        #expect(controller.pollForChanges())

        #expect(opened.isEmpty, "the poll opened \(opened.map(\.lastPathComponent))")
        #expect(controller.selectedNode?.name == "top.md")
    }

    @Test("a poll that removes the selected file leaves nothing selected")
    func deletedSelectionIsDeselected() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        let notes = try #require(node(controller, named: "notes"))
        controller.outlineView.expandItem(notes)
        let beta = try #require(node(controller, named: "beta.md"))
        controller.outlineView.selectRowIndexes(
            IndexSet(integer: controller.outlineView.row(forItem: beta)),
            byExtendingSelection: false)

        try FileManager.default.removeItem(at: fixture.url("notes/beta.md"))

        #expect(controller.pollForChanges())
        #expect(controller.selectedNode == nil, "kept \(controller.selectedNode?.name ?? "-")")
    }

    /// The filter is a thing the reader is doing; a refresh underneath it is
    /// not a reason to cancel it.
    @Test("a poll keeps the filter and applies it to what just arrived")
    func filterSurvives() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)
        controller.filter = "gu"
        let docs = try #require(node(controller, named: "docs"))
        controller.outlineView.expandItem(docs)

        try "# guest\n".write(to: fixture.url("guest.md"), atomically: true, encoding: .utf8)
        try "# nope\n".write(to: fixture.url("nope.md"), atomically: true, encoding: .utf8)

        #expect(controller.pollForChanges())
        #expect(controller.filter == "gu")
        let names = visibleNames(controller)
        #expect(names.contains("guest.md"))
        #expect(!names.contains("nope.md"), "got \(names)")
    }

    /// The toggles are the core's answer, not ours, so a file the listing
    /// hides stays hidden when it arrives during a poll rather than at launch.
    @Test("a poll honours the hidden and non-markdown toggles")
    func togglesSurvive() throws {
        let fixture = try SidebarFixture()
        let (controller, _) = make(fixture)

        try "# hidden\n".write(
            to: fixture.url(".later.md"), atomically: true, encoding: .utf8)
        try "png".write(to: fixture.url("later.png"), atomically: true, encoding: .utf8)
        try "log".write(to: fixture.url("later.log"), atomically: true, encoding: .utf8)

        controller.pollForChanges()
        var names = visibleNames(controller)
        #expect(!names.contains(".later.md"))
        #expect(!names.contains("later.png"))

        controller.listingOptions = TreeListingOptions(showsNonMarkdown: true, showsHidden: true)
        names = visibleNames(controller)
        #expect(names.contains(".later.md"))
        #expect(names.contains("later.png"))
        // `*.log` is `.gitignore`d, and the toggles do not override that.
        #expect(!names.contains("later.log"), "got \(names)")
    }
}
