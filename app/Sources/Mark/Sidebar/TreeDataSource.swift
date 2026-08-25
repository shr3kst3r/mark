import AppKit
import CMarkCore
import Foundation

/// Where the sidebar's directory listings come from.
///
/// A protocol so the laziness can be *asserted* rather than assumed: the test
/// substitutes a counting lister and checks how many directories were read,
/// which is the only way to catch an eager walk before a user with a 608k-file
/// tree does (research §2.8).
///
/// `AnyObject` because ``options`` is mutated through the existential when the
/// user flips a toggle, and a struct behind `any` cannot be.
@MainActor
public protocol DirectoryLister: AnyObject {
    /// The "show me more" toggles. On the lister rather than beside it,
    /// because they end up as `mark_tree_json` flags and only the thing making
    /// that call can honour them.
    var options: TreeListingOptions { get set }
    /// One directory level. Never recursive.
    func entries(in directory: String) throws -> [TreeEntry]
}

/// The real one: `mark_tree_json` at depth 1, no per-file stats.
///
/// `withStats: false` is deliberate and is M8's load-bearing constraint, not
/// M2's convenience. Stats mean opening and parsing every markdown file in the
/// directory, and research §2.8 measured 212 ms + 133 ms for `~/notes` alone.
/// Per-file task counts come from ``TaskBadgeService``, on demand and in the
/// background, one visible row at a time.
public final class CoreDirectoryLister: DirectoryLister {
    /// The two toggles, passed straight through to the core as flags.
    ///
    /// M8 could not do this — `mark_tree_json` hardcoded the defaults — and
    /// reimplemented both over `FileManager` instead, which could not tell a
    /// `.gitignore`d non-markdown file from a visible one. M7 gave that
    /// function a flags parameter, so the reimplementation is gone and the
    /// core's answer is the only answer.
    public var options: TreeListingOptions

    public init(options: TreeListingOptions = TreeListingOptions()) {
        self.options = options
    }

    public func entries(in directory: String) throws -> [TreeEntry] {
        try MarkCore.tree(directory: directory, depth: 1, withStats: false, options: options)
    }
}

// MARK: - Listing options

/// The two "show me more" toggles from plan §2 M8. Both default to off.
///
/// These map one-to-one onto `mark_tree_json`'s flags, which is the whole
/// point: the core owns `.gitignore`, and anything deciding what to show
/// without asking it will get the ignored files wrong.
public struct TreeListingOptions: Equatable, Sendable {
    /// Non-markdown files, drawn dimmed and not openable — *"so a folder does
    /// not look empty when it holds a `.png` and a `.md`"*.
    public var showsNonMarkdown: Bool
    /// Dotfiles and dot-directories.
    public var showsHidden: Bool

    public init(showsNonMarkdown: Bool = false, showsHidden: Bool = false) {
        self.showsNonMarkdown = showsNonMarkdown
        self.showsHidden = showsHidden
    }

    /// `MARK_TREE_*`, as the C ABI wants them.
    public var coreFlags: Int32 {
        var flags: Int32 = 0
        if showsNonMarkdown { flags |= MARK_TREE_ALL_FILES }
        if showsHidden { flags |= MARK_TREE_HIDDEN }
        return flags
    }
}

extension TreeEntry {
    /// Directories first, then files, each by localized name.
    static func displayOrder(_ a: TreeEntry, _ b: TreeEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

// MARK: - Sorting

/// How the sidebar orders the children of a directory.
public enum TreeSort: String, CaseIterable, Sendable {
    case name
    case modified
    case taskCount

    public var menuTitle: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .taskCount: return "Task Count"
        }
    }
}

// MARK: - The node

/// One row in the sidebar.
///
/// `children` is `nil` until the node is actually expanded. That `nil` is the
/// laziness: an unexpanded directory has never been read, however deep the tree
/// below it goes.
public final class TreeNode {
    public let url: URL
    public let name: String
    public let isDirectory: Bool

    /// `nil` means "not listed yet", not "empty".
    public private(set) var children: [TreeNode]?

    /// Set when a listing failed, so the row can say so instead of silently
    /// appearing to be an empty directory.
    public private(set) var listingError: String?

    /// ``children`` after the current sort and filter. Recomputed when the
    /// data source's arrangement stamp moves, so flipping a sort or typing in
    /// the filter field is O(visible), not O(tree), and — critically — reads
    /// no directory that was not already read.
    private var arranged: [TreeNode]?
    private var arrangementStamp: UInt64 = 0

    /// `mtime`, for ``TreeSort/modified``. Read once, on demand: it is a `stat`
    /// per row, and only for rows in a directory that has already been listed.
    private var cachedModified: Date?
    private var didStat = false

    public init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }

    public convenience init(directory url: URL) {
        self.init(
            url: url,
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            isDirectory: true
        )
    }

    convenience init(entry: TreeEntry) {
        self.init(
            url: URL(fileURLWithPath: entry.path),
            name: entry.name,
            isDirectory: entry.isDirectory
        )
    }

    /// Extensions treated as markdown.
    ///
    /// Mirrors `core/src/tree.rs::MARKDOWN`. Duplicated rather than asked for
    /// over the ABI because the alternative is a C call per row per redraw, and
    /// because this list has not changed since M1; `MarkCoreTests` pins the two
    /// lists together so a drift is a failing test rather than a file that
    /// silently stops being openable.
    public static let markdownExtensions = ["md", "markdown", "mdown", "mkd", "mdx"]

    public static func isMarkdown(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty else { return false }
        return markdownExtensions.contains { $0.compare(ext, options: .caseInsensitive) == .orderedSame }
    }

    /// Whether this row can be opened as a document. Non-markdown rows are
    /// drawn dimmed and refuse to open (plan §2 M8).
    public var isMarkdown: Bool { !isDirectory && Self.isMarkdown(url) }

    public var isHidden: Bool { name.hasPrefix(".") }

    /// Whether this row draws a disclosure triangle.
    ///
    /// **Must not touch the filesystem.** `NSOutlineView` asks this for every
    /// visible row; answering it by listing the directory would turn scrolling
    /// the sidebar into a directory walk, which is the eager behaviour the
    /// lazy design exists to avoid.
    public var isExpandable: Bool { isDirectory }

    /// Whether this directory has been listed. Reading it is free, and it is
    /// what lets the filter recurse without forcing an expansion.
    public var isListed: Bool { children != nil }

    /// The children, listing the directory the first time it is asked.
    @MainActor
    @discardableResult
    public func children(using lister: any DirectoryLister) -> [TreeNode] {
        if let children { return children }
        guard isDirectory else {
            children = []
            return []
        }
        do {
            let entries = try lister.entries(in: url.path)
            let loaded = entries.map(TreeNode.init(entry:))
            children = loaded
            listingError = nil
            Log.tree.debug("listed \(self.url.path, privacy: .public): \(loaded.count) entries")
            return loaded
        } catch {
            // One unreadable directory should not cost the user the rest of the
            // tree, and it should not be retried on every scroll either.
            listingError = String(describing: error)
            children = []
            Log.tree.error("\(self.url.path, privacy: .public): \(String(describing: error))")
            return []
        }
    }

    /// Forget the listing so the next expansion re-reads it.
    public func invalidate() {
        children = nil
        listingError = nil
        arranged = nil
        arrangementStamp = 0
        didStat = false
        cachedModified = nil
    }

    /// `mtime`, or `nil` for a file that cannot be stat'ed.
    public var modified: Date? {
        if !didStat {
            didStat = true
            cachedModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return cachedModified
    }

    func arrangement(stamp: UInt64) -> [TreeNode]? {
        arrangementStamp == stamp ? arranged : nil
    }

    func setArrangement(_ nodes: [TreeNode], stamp: UInt64) {
        arranged = nodes
        arrangementStamp = stamp
    }
}

// MARK: - The data source

/// `NSOutlineView` data source over a lazily-listed directory tree.
///
/// The whole design constraint, from research §2.8: the user's real tree holds
/// **608,597 files**, so an eager full-tree walk is a multi-second hang and
/// computing per-file task counts eagerly means parsing 37 MB of markdown.
/// Nothing in this file reads a directory that has not been expanded, and
/// **neither sorting nor filtering ever causes a read** — both operate on
/// listings that already exist in memory.
@MainActor
public final class TreeDataSource: NSObject, NSOutlineViewDataSource {

    public private(set) var root: TreeNode
    private let lister: any DirectoryLister

    /// Where ``TreeSort/taskCount`` gets its numbers. Optional so a plain
    /// listing test does not have to build one.
    public weak var badges: TaskBadgeService?

    /// Bumped whenever the arrangement changes, which invalidates every node's
    /// cached order without walking the tree to clear it.
    private var stamp: UInt64 = 1

    public var sort: TreeSort = .name {
        didSet { if sort != oldValue { rearrange() } }
    }

    /// Incremental name filter. Empty means "everything".
    public var filter: String = "" {
        didSet { if filter != oldValue { rearrange() } }
    }

    public init(root: URL, lister: any DirectoryLister = CoreDirectoryLister()) {
        self.root = TreeNode(directory: root)
        self.lister = lister
    }

    /// Point the sidebar at a different directory.
    public func setRoot(_ url: URL) {
        root = TreeNode(directory: url)
        rearrange()
    }

    /// Drop every cached listing. The sidebar's refresh; also what M5's file
    /// watcher calls.
    public func invalidate() {
        root.invalidate()
        rearrange()
    }

    /// Recompute every node's order and visibility on next access.
    public func rearrange() {
        stamp &+= 1
        if stamp == 0 { stamp = 1 }
    }

    // MARK: Arrangement

    /// `node`'s children, listed if necessary, then sorted and filtered.
    ///
    /// The one place `NSOutlineView` reaches the tree, so it is the one place
    /// a directory read can happen — and it happens only for a node the
    /// outline view is actually displaying children of.
    public func arrangedChildren(of node: TreeNode) -> [TreeNode] {
        if let cached = node.arrangement(stamp: stamp) { return cached }
        let children = node.children(using: lister)
        var arranged = sorted(children)
        if !filter.isEmpty {
            arranged = arranged.filter { matchesFilter($0) }
        }
        node.setArrangement(arranged, stamp: stamp)
        return arranged
    }

    private func sorted(_ nodes: [TreeNode]) -> [TreeNode] {
        switch sort {
        case .name:
            return nodes.sorted(by: Self.byName)

        case .modified:
            // Directories keep their alphabetical order: a directory's mtime is
            // when its *listing* last changed, which has nothing to do with the
            // documents inside it, and sorting on it puts folders in an order
            // no user can predict.
            return nodes.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                if a.isDirectory { return Self.byName(a, b) }
                switch (a.modified, b.modified) {
                case (let left?, let right?):
                    if left != right { return left > right }
                    return Self.byName(a, b)
                case (nil, .some): return false
                case (.some, nil): return true
                case (nil, nil): return Self.byName(a, b)
                }
            }

        case .taskCount:
            // **The decision plan §2 M8 asked for, stated explicitly.** Sorting
            // by task count needs badges, and badges are exactly the thing that
            // must not be computed eagerly. So this sorts on the badges that
            // are *already known*, files with no badge yet sort last in name
            // order, and asking for this sort schedules the missing ones in the
            // background — over the children of directories that have already
            // been listed, never causing a directory read. As each badge lands
            // the sidebar rearranges that row, so the order converges within a
            // few frames without a single blocking read.
            if let badges {
                badges.request(contentsOf: nodes.lazy.filter(\.isMarkdown).map(\.url))
            }
            return nodes.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                if a.isDirectory { return Self.byName(a, b) }
                let left = badges?.badge(for: a.url)
                let right = badges?.badge(for: b.url)
                switch (left, right) {
                case (let left?, let right?):
                    if left.open != right.open { return left.open > right.open }
                    if left.total != right.total { return left.total > right.total }
                    return Self.byName(a, b)
                case (nil, .some): return false
                case (.some, nil): return true
                case (nil, nil): return Self.byName(a, b)
                }
            }
        }
    }

    private static func byName(_ a: TreeNode, _ b: TreeNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    // MARK: Filtering

    /// Whether `node` survives the current filter.
    ///
    /// Three rules, and the third is the one that matters:
    ///
    /// 1. A row whose name contains the filter text stays.
    /// 2. A directory that has been listed stays if anything under it — again,
    ///    among rows that have already been listed — stays.
    /// 3. **A directory that has *not* been listed always stays.** Deciding
    ///    otherwise would mean reading it, and reading every unexpanded
    ///    directory to answer "does it contain a match?" is precisely the eager
    ///    walk this sidebar exists to avoid. So the filter is a filter over
    ///    *what is on screen*, which is what plan §2 M8 asks for — *"filter the
    ///    visible tree by name"* — and an unexpanded folder stays available to
    ///    drill into.
    private func matchesFilter(_ node: TreeNode) -> Bool {
        if node.name.localizedCaseInsensitiveContains(filter) { return true }
        guard node.isDirectory else { return false }
        guard let children = node.children else { return true }
        return children.contains { matchesFilter($0) }
    }

    // MARK: NSOutlineViewDataSource

    private func node(_ item: Any?) -> TreeNode {
        (item as? TreeNode) ?? root
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        arrangedChildren(of: node(item)).count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?)
        -> Any
    {
        arrangedChildren(of: node(item))[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        node(item).isExpandable
    }

    // MARK: Dragging out

    /// Drag a file out of the sidebar and drop it in Finder (plan §2 M8).
    ///
    /// `NSURL` rather than a custom type on purpose: `NSURL` already conforms to
    /// `NSPasteboardWriting` and promises `public.file-url`, which is what
    /// Finder, Mail, and every other drop target actually read. Directories are
    /// draggable too — dragging a folder to Finder is a copy, which is what the
    /// gesture means everywhere else on the platform.
    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any)
        -> (any NSPasteboardWriting)?
    {
        guard let node = item as? TreeNode else { return nil }
        return node.url as NSURL
    }
}
