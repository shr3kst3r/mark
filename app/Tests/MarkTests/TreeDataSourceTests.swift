import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The sidebar must not walk the tree.
///
/// Research §2.8: the user's real tree holds **608,597 files**, so an eager
/// walk is a multi-second hang. That is a design constraint, not a preference,
/// and "we only list on expand" is the kind of claim that is true when written
/// and false three refactors later — so it is asserted by counting directory
/// reads rather than by reading the code.
@Suite("TreeDataSource — laziness, counted")
@MainActor
struct TreeDataSourceTests {

    /// Wraps the real lister and counts calls.
    final class CountingLister: DirectoryLister {
        private let inner: any DirectoryLister
        private(set) var listings: [String] = []

        init(_ inner: any DirectoryLister = CoreDirectoryLister()) { self.inner = inner }

        var options: TreeListingOptions {
            get { inner.options }
            set { inner.options = newValue }
        }

        func entries(in directory: String) throws -> [TreeEntry] {
            listings.append(directory)
            return try inner.entries(in: directory)
        }
    }

    /// A three-level tree with a markdown file at every level, so an eager walk
    /// has something to be caught doing.
    static func fixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-tree-\(UUID().uuidString)")
        let manager = FileManager.default
        for relative in ["a/aa/aaa", "b/bb", "c"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        for relative in ["top.md", "a/one.md", "a/aa/two.md", "a/aa/aaa/three.md", "b/four.md"] {
            try "# \(relative)\n\n- [ ] a task\n".write(
                to: root.appendingPathComponent(relative), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("constructing the data source reads nothing")
    func constructionIsFree() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let lister = CountingLister()
        _ = TreeDataSource(root: root, lister: lister)
        #expect(lister.listings.isEmpty)
    }

    @Test("only expanded directories are ever read")
    func expansionIsLazy() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let lister = CountingLister()
        let source = TreeDataSource(root: root, lister: lister)
        let outline = NSOutlineView()

        // Listing the root is one read.
        let topLevel = source.outlineView(outline, numberOfChildrenOfItem: nil)
        #expect(topLevel == 4, "expected a/ b/ c/ and top.md, got \(topLevel)")
        #expect(lister.listings.count == 1)

        // Asking whether each row is expandable must NOT read anything: this is
        // the call NSOutlineView makes for every visible row.
        for index in 0..<topLevel {
            let child = source.outlineView(outline, child: index, ofItem: nil)
            _ = source.outlineView(outline, isItemExpandable: child)
        }
        #expect(
            lister.listings.count == 1,
            "isItemExpandable touched the filesystem: \(lister.listings)")

        // Expanding exactly one directory reads exactly one directory.
        let a = try #require(
            (0..<topLevel)
                .map { source.outlineView(outline, child: $0, ofItem: nil) as! TreeNode }
                .first { $0.name == "a" })
        _ = source.outlineView(outline, numberOfChildrenOfItem: a)
        #expect(lister.listings.count == 2)
        #expect(lister.listings.last == a.url.path)

        // And nothing below it.
        #expect(!lister.listings.contains { $0.hasSuffix("/aa") })
    }

    @Test("a listing is cached, so scrolling does not re-read")
    func listingsAreCached() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let lister = CountingLister()
        let source = TreeDataSource(root: root, lister: lister)
        let outline = NSOutlineView()
        for _ in 0..<20 {
            _ = source.outlineView(outline, numberOfChildrenOfItem: nil)
        }
        #expect(lister.listings.count == 1)
    }

    @Test("invalidate makes the next expansion re-read")
    func invalidation() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let lister = CountingLister()
        let source = TreeDataSource(root: root, lister: lister)
        let outline = NSOutlineView()
        _ = source.outlineView(outline, numberOfChildrenOfItem: nil)
        source.invalidate()
        _ = source.outlineView(outline, numberOfChildrenOfItem: nil)
        #expect(lister.listings.count == 2)
    }

    /// One unreadable directory should not cost the user the rest of the tree,
    /// and it should not be retried on every scroll either.
    @Test("an unreadable directory is an empty node with a recorded error")
    func unreadableDirectory() throws {
        final class Failing: DirectoryLister {
            var options = TreeListingOptions()
            func entries(in directory: String) throws -> [TreeEntry] {
                throw CoreError(function: "mark_tree_json", detail: "permission denied")
            }
        }
        let node = TreeNode(directory: URL(fileURLWithPath: "/nope"))
        #expect(node.children(using: Failing()).isEmpty)
        #expect(node.listingError?.contains("permission denied") == true)
    }

    @Test("a file node is never expandable")
    func filesAreLeaves() {
        let node = TreeNode(
            url: URL(fileURLWithPath: "/tmp/x.md"), name: "x.md", isDirectory: false)
        #expect(!node.isExpandable)
    }
}
