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

// MARK: - Freshness

/// A directory's own `mtime`, to the nanosecond, as something two polls can
/// compare exactly.
///
/// `timespec` rather than `Date` because `Date` is a `Double` counting from
/// 2001, and at present-day magnitudes it cannot hold a nanosecond — comparing
/// two of them is comparing rounded numbers. And a `stat(2)` rather than
/// `URL.resourceValues`, because this runs once per listed directory per poll
/// and because the whole point is to see a change: a value that Foundation is
/// entitled to serve from a cache is the wrong tool for asking "has this moved
/// since I last looked?".
struct DirectoryStamp: Equatable {
    let seconds: Int
    let nanoseconds: Int

    static func of(_ path: String) -> DirectoryStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return DirectoryStamp(
            seconds: Int(info.st_mtimespec.tv_sec),
            nanoseconds: Int(info.st_mtimespec.tv_nsec))
    }
}

/// What a whole pass of ``TreeDataSource/reconcile()`` turned up.
public struct TreeReconciliation {
    /// The directories whose listings actually differ from what is on screen.
    public internal(set) var changed: [URL] = []
    /// Files and folders that have just appeared.
    public internal(set) var added: [URL] = []
    /// Rows that are gone, including everything that had been listed below
    /// them — so the controller can forget their expansion state and badges
    /// rather than hold the last reference to a subtree nobody can reach.
    public internal(set) var removed: [TreeNode] = []

    public var isEmpty: Bool { changed.isEmpty }
}

/// What re-reading one directory turned up.
struct TreeChange {
    /// Rows that were not in the previous listing.
    var added: [TreeNode] = []
    /// Rows that are no longer in the directory — including a name whose kind
    /// changed, which is a different row wearing the same label.
    var removed: [TreeNode] = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }
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

    /// The directory's **own** `mtime` when ``children`` was read.
    ///
    /// The poll's gate, and the reason a background refresh is affordable at
    /// all: a directory that has not gained, lost, or renamed an entry has not
    /// moved its own `mtime`, so the poll can skip re-reading it after a single
    /// `stat`. Content changes inside a file do *not* move it — which is
    /// correct, because they do not change the listing either.
    private var listingStamp: DirectoryStamp?

    /// Set when ``listingStamp`` was read less than a second before the
    /// listing itself.
    ///
    /// APFS timestamps are nanosecond-resolution, but HFS+ and most network
    /// mounts round to the second — and there, a file written in the *same
    /// second* as the listing leaves the stamp unchanged and would stay
    /// invisible for as long as nothing else touched the directory. Such a
    /// listing is therefore re-read once on the next poll, by which time the
    /// second has passed and the stamp can be trusted. It costs one extra
    /// listing per directory the reader expands, and it is the difference
    /// between a refresh that works everywhere and one that works on the
    /// developer's laptop.
    private var listingStampIsProvisional = false

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
        // Stamped *before* the read, so a write that lands between the two is
        // caught by the next poll rather than missed forever.
        let stamp = DirectoryStamp.of(url.path)
        defer { recordListing(stamp: stamp) }
        do {
            let entries = try lister.entries(in: url.path)
            let loaded = entries.map(TreeNode.init(entry:))
            children = loaded
            listingError = nil
            Log.tree.debug("listed \(self.url.path, privacy: .public): \(loaded.count) entries")
            return loaded
        } catch {
            // One unreadable directory should not cost the user the rest of the
            // tree, and it should not be retried on every scroll either — nor,
            // since the stamp is recorded above, on every poll.
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
        listingStamp = nil
        listingStampIsProvisional = false
        arranged = nil
        arrangementStamp = 0
        didStat = false
        cachedModified = nil
    }

    // MARK: - Polling

    /// Whether the directory has changed since ``children`` was read.
    ///
    /// One `stat`, and nothing else — this is asked of every listed directory
    /// every couple of seconds, so it is the one thing here that must not be a
    /// directory read. A node that has never been listed is never stale: there
    /// is nothing on screen under it to be wrong.
    ///
    /// A directory that cannot be `stat`ed is reported as *not* stale rather
    /// than as always stale: the poll could not have read it either, and a
    /// directory that fails both is one that would otherwise be re-listed
    /// every two seconds for the life of the window. Its disappearance is
    /// still noticed — by its parent, whose own listing loses the row.
    var listingIsStale: Bool {
        guard isDirectory, children != nil else { return false }
        if listingStampIsProvisional { return true }
        guard let listingStamp, let current = DirectoryStamp.of(url.path) else { return false }
        return current != listingStamp
    }

    /// Take a fresh listing, **keeping the existing node for every entry that
    /// is still there**.
    ///
    /// Identity is the load-bearing part. `NSOutlineView` addresses rows by
    /// object and ``TreeViewController`` keys its expansion set by one, so
    /// replacing a surviving row's node would collapse the directory under it
    /// and move the selection off it. A refresh that closed folders while
    /// someone was reading would be worse than one that never ran.
    ///
    /// - Returns: what arrived and what left. Empty when the directory moved
    ///   its `mtime` without changing anything the sidebar shows — a
    ///   `.gitignore`d file appearing, most often — which is why the stamp is
    ///   recorded either way.
    @discardableResult
    func adopt(_ entries: [TreeEntry], stamp: DirectoryStamp?) -> TreeChange {
        recordListing(stamp: stamp)
        listingError = nil
        arranged = nil
        arrangementStamp = 0

        var change = TreeChange()
        var survivors: [String: TreeNode] = [:]
        for child in children ?? [] { survivors[child.url.path] = child }

        var next: [TreeNode] = []
        next.reserveCapacity(entries.count)
        for entry in entries {
            // A name whose *kind* changed — a file replaced by a directory —
            // is not the same row. Leaving it in `survivors` reports it as
            // departed, which it is.
            if let kept = survivors[entry.path], kept.isDirectory == entry.isDirectory {
                survivors.removeValue(forKey: entry.path)
                // The listing changed, so a file in it may have been rewritten
                // as well as added; forget the cached `mtime` so a modified
                // sort can still move the row. Paid lazily, and only for a
                // directory that actually changed.
                kept.forgetModified()
                next.append(kept)
            } else {
                let node = TreeNode(entry: entry)
                change.added.append(node)
                next.append(node)
            }
        }
        change.removed = Array(survivors.values)
        children = next
        return change
    }

    /// This node and every descendant whose listing was read.
    ///
    /// What a departing directory hands back, so the controller can forget the
    /// expansion state and the badges of everything that went with it.
    func listedSubtree() -> [TreeNode] {
        var result: [TreeNode] = []
        var stack: [TreeNode] = [self]
        while let node = stack.popLast() {
            result.append(node)
            if let children = node.children { stack.append(contentsOf: children) }
        }
        return result
    }

    /// Forget the cached `mtime`, so the next modified sort re-stats.
    private func forgetModified() {
        didStat = false
        cachedModified = nil
    }

    private func recordListing(stamp: DirectoryStamp?) {
        listingStamp = stamp
        listingStampIsProvisional =
            stamp.map { Date().timeIntervalSince1970 - Double($0.seconds) < 1 } ?? false
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

    /// Re-read the directories the sidebar is showing whose contents have
    /// actually moved, keeping every row that is still there.
    ///
    /// The background refresh, run every ``TreeViewController/pollInterval``.
    /// Its whole cost model is one `stat` per **listed** directory: a
    /// directory that has not gained, lost, or renamed an entry has not moved
    /// its own `mtime`, and is not read. So the work is bounded by what the
    /// reader has expanded — never by the size of the tree — and stays flat
    /// while a build churns through a hundred thousand files somewhere below
    /// a folder nobody has opened.
    ///
    /// It reads no directory that ``arrangedChildren(of:)`` had not already
    /// read, which is the same promise the rest of this file makes.
    ///
    /// One thing it deliberately does not see: a file whose *bytes* changed
    /// without the directory changing. That moves no row and renames nothing;
    /// it only stales a task badge, which is what ⌘R and the document
    /// watcher are for.
    @discardableResult
    public func reconcile() -> TreeReconciliation {
        // Snapshotted first: re-listing a directory mutates the very array
        // that walking it would be iterating.
        var listed: [TreeNode] = []
        var stack: [TreeNode] = [root]
        while let node = stack.popLast() {
            guard node.isDirectory, let children = node.children else { continue }
            listed.append(node)
            stack.append(contentsOf: children)
        }

        var result = TreeReconciliation()
        for node in listed where node.listingIsStale {
            let stamp = DirectoryStamp.of(node.url.path)
            guard let entries = try? lister.entries(in: node.url.path) else {
                // A directory mid-rename, or one that just lost its
                // permissions. Keep what is on screen rather than blanking it
                // on a transient read; if it is really gone, the parent's own
                // listing drops the row on this same pass.
                Log.tree.info("poll: could not re-read \(node.url.path, privacy: .public)")
                continue
            }
            let change = node.adopt(entries, stamp: stamp)
            guard !change.isEmpty else { continue }
            result.changed.append(node.url)
            result.added.append(contentsOf: change.added.map(\.url))
            result.removed.append(contentsOf: change.removed.flatMap { $0.listedSubtree() })
        }

        if !result.isEmpty { rearrange() }
        return result
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
                    // Outstanding, then active: the badge's own two numbers, so
                    // the order matches what the row draws
                    // (`2026-08-27-five-task-states`).
                    if left.outstanding != right.outstanding {
                        return left.outstanding > right.outstanding
                    }
                    if left.active != right.active { return left.active > right.active }
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
