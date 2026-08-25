import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The path bar's own behaviour: what it shows when it does not fit, what its
/// menus contain, what the keyboard does to it, and what a drop onto a crumb
/// does to the disk.
///
/// Deliberately split from ``SidebarNavigationTests``: those assert what the
/// *navigator* does, which is filesystem-free and about history semantics.
/// These assert what the *bar* does, which is about layout, menus, and one very
/// carefully bounded directory read.
@Suite("Breadcrumb bar — overflow, menus, keyboard, and drops")
@MainActor
struct BreadcrumbBarTests {

    /// A bar showing `/aaaa/bbbb/cccc/dddd/eeee`, laid out at `width`.
    ///
    /// No filesystem: ``Navigator`` never stats anything, so a path that does
    /// not exist is a perfectly good subject for a layout test and keeps the
    /// measurements from depending on whatever is really in `/tmp`.
    private func bar(width: CGFloat = 400, path: String = "/aaaa/bbbb/cccc/dddd/eeee")
        -> (BreadcrumbBar, Navigator)
    {
        let navigator = Navigator(root: URL(fileURLWithPath: path, isDirectory: true))
        let bar = BreadcrumbBar(
            frame: NSRect(x: 0, y: 0, width: width, height: BreadcrumbBar.barHeight))
        bar.update(with: navigator)
        bar.layoutSubtreeIfNeeded()
        return (bar, navigator)
    }

    // MARK: - Overflow and truncation

    @Test("a path that fits shows every crumb and collapses nothing")
    func nothingCollapsesWhenItFits() {
        let (bar, _) = bar(width: 1200)
        #expect(bar.collapsed.isEmpty)
        #expect(bar.visibleCrumbTitles == bar.crumbTitles)
        #expect(bar.overflowedCrumbTitles.isEmpty)
    }

    /// The two rules that M8's first cut had backwards: the current directory
    /// is never the thing that goes, and the root is the *last* thing to go.
    ///
    /// Asserted as an invariant across a sweep of widths rather than at one
    /// hand-computed width, so the gate does not turn red the day the system
    /// font changes metrics.
    @Test("truncation eats the middle: the root and the current folder go last")
    func truncationPinsRootAndCurrent() {
        let (bar, _) = bar()
        var previousCount = Int.max
        for width in stride(from: CGFloat(500), through: 80, by: -10) {
            bar.frame.size.width = width
            bar.layoutSubtreeIfNeeded()
            let visible = bar.visibleCrumbTitles

            #expect(!visible.isEmpty, "at \(width)pt the bar showed nothing at all")
            #expect(
                visible.last == "eeee",
                "at \(width)pt the current folder was truncated away: \(visible)")
            if visible.count > 1 {
                #expect(
                    visible.first == "/",
                    "at \(width)pt the root went before the middle did: \(visible)")
            }
            // Narrower never shows more.
            #expect(visible.count <= previousCount, "at \(width)pt the bar grew as it narrowed")
            previousCount = visible.count

            // Whatever is not shown is behind the ellipsis, and the two sets
            // together are still the whole path.
            #expect(
                (visible + bar.overflowedCrumbTitles).sorted() == bar.crumbTitles.sorted(),
                "at \(width)pt a crumb was neither shown nor overflowed")
        }
    }

    @Test("the hidden crumbs are reachable from the ellipsis menu")
    func overflowMenuListsWhatWasHidden() {
        let (bar, _) = bar(width: 220)
        #expect(!bar.collapsed.isEmpty, "220pt should not fit this path")

        let menu = bar.makeOverflowMenu()
        #expect(menu.items.map(\.title) == bar.overflowedCrumbTitles)

        // And choosing one navigates — the whole reason the first cut's dead
        // `…` label was a bug rather than a cosmetic gap.
        var chosen: URL?
        bar.onSelect = { chosen = $0 }
        let item = try! #require(menu.items.first)
        _ = item.target?.perform(item.action, with: item)
        #expect(chosen?.lastPathComponent == item.title)
    }

    @Test("a single-crumb path never collapses itself")
    func rootOnlyPathSurvives() {
        let (bar, _) = bar(width: 60, path: "/")
        #expect(bar.collapsed.isEmpty)
        #expect(bar.visibleCrumbTitles == ["/"])
    }

    // MARK: - Menus

    @Test("a chevron menu lists that folder's subfolders and checks the one on the path")
    func siblingMenuMarksThePath() {
        let (bar, _) = bar()
        var asked: [URL] = []
        bar.childDirectories = { url in
            asked.append(url)
            return ["bbbb", "zzzz"].map { url.appendingPathComponent($0, isDirectory: true) }
        }
        // Crumb 1 is `aaaa`; the path goes through `bbbb`.
        let menu = try! #require(bar.makeSiblingMenu(forCrumbAt: 1))
        #expect(asked.map(\.path) == ["/aaaa"], "the menu read more than its own folder")
        #expect(menu.items.map(\.title) == ["bbbb", "zzzz"])
        #expect(menu.items[0].state == .on, "the folder the path goes through was not marked")
        #expect(menu.items[1].state == .off)
    }

    @Test("laying the bar out reads no directory at all")
    func layoutNeverLists() {
        let (bar, navigator) = bar()
        var reads = 0
        bar.childDirectories = { _ in
            reads += 1
            return []
        }
        for width in stride(from: CGFloat(500), through: 100, by: -25) {
            bar.frame.size.width = width
            bar.layoutSubtreeIfNeeded()
        }
        navigator.goToParent()
        bar.update(with: navigator)
        bar.layoutSubtreeIfNeeded()
        #expect(reads == 0, "the path bar listed \(reads) directories without being asked to")
    }

    @Test("an empty folder's chevron says so rather than opening an empty menu")
    func emptySiblingMenu() {
        let (bar, _) = bar()
        bar.childDirectories = { _ in [] }
        let menu = try! #require(bar.makeSiblingMenu(forCrumbAt: 2))
        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == "No Folders")
        #expect(!menu.items[0].isEnabled)
    }

    @Test("a folder with more subfolders than the menu limit says how many are missing")
    func siblingMenuAdmitsTruncation() {
        let (bar, _) = bar()
        let count = BreadcrumbBar.menuLimit + 7
        bar.childDirectories = { url in
            (0..<count).map { url.appendingPathComponent("d\($0)", isDirectory: true) }
        }
        let menu = try! #require(bar.makeSiblingMenu(forCrumbAt: 1))
        #expect(menu.items.last?.title == "7 more not shown")
        #expect(menu.items.last?.isEnabled == false)
    }

    /// GNOME's rule, and the reason it exists: "Go Here" on the folder you are
    /// already in is the item that makes a path bar look broken.
    @Test("the current folder's context menu has no Go Here; the others do")
    func contextMenuDiffersForTheCurrentFolder() {
        let (bar, _) = bar()
        let middle = try! #require(bar.makeContextMenu(forCrumbAt: 2))
        #expect(middle.items.map(\.title).contains("Go Here"))
        #expect(middle.items.map(\.title).contains("Copy Path"))
        #expect(middle.items.map(\.title).contains("Reveal in Finder"))

        let current = try! #require(bar.makeContextMenu(forCrumbAt: bar.crumbTitles.count - 1))
        #expect(!current.items.map(\.title).contains("Go Here"))
        #expect(current.items.map(\.title).contains("Copy Path"))
    }

    // MARK: - Keyboard

    @Test("← and → walk the crumbs, and ⏎ navigates to the focused one")
    func keyboardWalksAndNavigates() {
        let (bar, _) = bar(width: 1200)
        var chosen: URL?
        bar.onSelect = { chosen = $0 }

        // Focus starts on the current folder, which is where the keyboard
        // arrives from ⌘⌥P.
        #expect(bar.moveFocus(by: -1))
        #expect(bar.focusedCrumbIndex == bar.crumbTitles.count - 2)
        #expect(bar.moveFocus(by: -1))
        #expect(bar.focusedCrumbIndex == bar.crumbTitles.count - 3)
        #expect(bar.moveFocus(by: 1))
        #expect(bar.focusedCrumbIndex == bar.crumbTitles.count - 2)

        #expect(bar.activateFocusedCrumb())
        #expect(chosen?.lastPathComponent == "dddd")
    }

    @Test("focus stops at the ends instead of wrapping")
    func keyboardStopsAtTheEnds() {
        let (bar, _) = bar(width: 1200)
        while bar.moveFocus(by: -1) {}
        #expect(bar.focusedCrumbIndex == 0)
        #expect(!bar.moveFocus(by: -1))
        while bar.moveFocus(by: 1) {}
        #expect(bar.focusedCrumbIndex == bar.crumbTitles.count - 1)
        #expect(!bar.moveFocus(by: 1))
    }

    /// Focus sitting on a crumb nobody can see is focus nobody can use, and a
    /// sidebar being dragged narrower is exactly how it would get there.
    @Test("narrowing the bar moves focus off a crumb it folds away")
    func resizeMovesFocusOffAFoldedCrumb() {
        let (bar, _) = bar(width: 1200)
        while bar.moveFocus(by: -1) {}
        #expect(bar.focusedCrumbIndex == 0)

        bar.frame.size.width = 200
        bar.layoutSubtreeIfNeeded()
        let focused = try! #require(bar.focusedCrumbIndex)
        #expect(!bar.collapsed.contains(focused))
        #expect(!bar.crumbTitles.isEmpty && focused < bar.crumbTitles.count)
    }

    @Test("focus skips the crumbs folded behind the ellipsis")
    func keyboardSkipsCollapsedCrumbs() {
        let (bar, _) = bar(width: 220)
        #expect(!bar.collapsed.isEmpty, "220pt should not fit this path")
        var landed: [Int] = []
        while bar.moveFocus(by: -1) { landed.append(bar.focusedCrumbIndex!) }
        for index in landed {
            #expect(!bar.collapsed.contains(index), "focus landed on the hidden crumb \(index)")
        }
    }
}

/// Drops onto a crumb, which are the one part of the path bar that touches the
/// disk.
@Suite("Breadcrumb bar — dropping files onto a folder")
@MainActor
struct BreadcrumbDropTests {

    private func make(_ fixture: SidebarFixture) -> TreeViewController {
        let controller = TreeViewController(root: fixture.root, lister: CoreDirectoryLister())
        _ = controller.view
        controller.viewDidLoad()
        return controller
    }

    @Test("a plain drop copies, leaving the original where it was")
    func dropCopies() throws {
        let fixture = try SidebarFixture()
        let controller = make(fixture)
        let source = fixture.root.appendingPathComponent("top.md")
        let destination = fixture.root.appendingPathComponent("docs", isDirectory: true)

        #expect(controller.drop([source], into: destination, move: false))
        #expect(FileManager.default.fileExists(atPath: source.path), "the original was removed")
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("top.md").path))
    }

    @Test("⌘ makes it a move")
    func dropMoves() throws {
        let fixture = try SidebarFixture()
        let controller = make(fixture)
        let source = fixture.root.appendingPathComponent("top.md")
        let destination = fixture.root.appendingPathComponent("notes", isDirectory: true)

        #expect(controller.drop([source], into: destination, move: true))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("top.md").path))
    }

    /// Silently replacing a note with a same-named one from somewhere else is
    /// data loss that looks like a successful drop.
    @Test("a name already taken at the destination is refused, not overwritten")
    func dropRefusesToOverwrite() throws {
        let fixture = try SidebarFixture()
        let controller = make(fixture)
        let destination = fixture.root.appendingPathComponent("docs", isDirectory: true)
        let existing = destination.appendingPathComponent("guide.md")
        let before = try String(contentsOf: existing, encoding: .utf8)

        // A different `guide.md`, dropped on top of the one that is there.
        let intruder = fixture.elsewhere.appendingPathComponent("guide.md")
        try "# not the guide\n".write(to: intruder, atomically: true, encoding: .utf8)

        #expect(!controller.drop([intruder], into: destination, move: false))
        #expect(try String(contentsOf: existing, encoding: .utf8) == before)
        #expect(FileManager.default.fileExists(atPath: intruder.path))
    }

    @Test("dropping a file back into the folder it is already in does nothing")
    func dropOntoItsOwnFolderIsANoOp() throws {
        let fixture = try SidebarFixture()
        let controller = make(fixture)
        let source = fixture.root.appendingPathComponent("top.md")
        #expect(!controller.drop([source], into: fixture.root, move: false))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}

/// The controller half of the chevron menus: where the folder list comes from,
/// and what it costs.
@Suite("Breadcrumb bar — the subfolder listing behind the chevrons")
@MainActor
struct BreadcrumbListingTests {

    @Test("a chevron menu costs exactly one directory read")
    func oneReadPerMenu() throws {
        let fixture = try SidebarFixture()
        let lister = CountingDirectoryLister()
        let controller = TreeViewController(root: fixture.root, lister: lister)
        _ = controller.view
        controller.viewDidLoad()
        lister.reset()

        let folders = controller.subdirectories(of: fixture.root)
        #expect(lister.count == 1, "the menu read \(lister.listings)")
        #expect(folders.map(\.lastPathComponent) == ["docs", "notes"])
    }

    /// A chevron offering a folder the tree refuses to show would be two
    /// answers to one question.
    @Test("the chevron menu honours the same gitignore and hidden-file toggles as the tree")
    func listingHonoursTheToggles() throws {
        let fixture = try SidebarFixture()
        let controller = TreeViewController(root: fixture.root, lister: CoreDirectoryLister())
        _ = controller.view
        controller.viewDidLoad()

        #expect(!controller.subdirectories(of: fixture.root).map(\.lastPathComponent)
            .contains("ignored"))
        #expect(!controller.subdirectories(of: fixture.root).map(\.lastPathComponent)
            .contains(".hiddendir"))

        controller.listingOptions.showsHidden = true
        #expect(controller.subdirectories(of: fixture.root).map(\.lastPathComponent)
            .contains(".hiddendir"))
    }

    @Test("an unreadable directory yields no folders rather than throwing")
    func unreadableDirectoryIsEmpty() throws {
        let fixture = try SidebarFixture()
        let controller = TreeViewController(root: fixture.root, lister: CoreDirectoryLister())
        _ = controller.view
        controller.viewDidLoad()
        let missing = fixture.root.appendingPathComponent("nope", isDirectory: true)
        #expect(controller.subdirectories(of: missing).isEmpty)
    }
}
