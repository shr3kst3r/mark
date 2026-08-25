import AppKit
import Foundation

/// The state of the sidebar that outlives a launch, and that `mark://` and the
/// socket can read.
public struct SidebarState: Equatable, Sendable {
    public var root: URL
    public var back: [URL]
    public var forward: [URL]
    public var options: TreeListingOptions
    public var sort: TreeSort
    /// Not persisted — a filter is a thing you are doing, not a thing you have.
    public var filter: String

    public init(
        root: URL,
        back: [URL] = [],
        forward: [URL] = [],
        options: TreeListingOptions = .init(),
        sort: TreeSort = .name,
        filter: String = ""
    ) {
        self.root = root
        self.back = back
        self.forward = forward
        self.options = options
        self.sort = sort
        self.filter = filter
    }
}

/// The shared directory sidebar, and — since M8 — a real navigator.
///
/// ADR-4 (`2026-08-24-tab-residency-and-memory-model`, superseding
/// `…-single-window-custom-tab-bar`) calls this out as the reason `mark` is one
/// window rather than N native tabs: the sidebar shows the *project tree*, not a
/// per-document outline, and native tabbing would turn one shared sidebar into
/// N sidebars needing manual synchronization of selection, width, collapse
/// state, and scroll. It is built here, once; M3 added tabs beside it, and M8
/// gives it a movable root, history, a filter, badges, and sorting **without
/// changing that it is one sidebar in one window**.
///
/// The constraint every method here is written against, from research §2.8 and
/// pinned by `core/tests/tree_lazy.rs` on the Rust side and
/// `TreeDataSourceTests` on this one: **the tree must never eagerly walk.**
/// `~/src` holds 608,597 files. So:
///
/// * Moving the root reads exactly one directory.
/// * Filtering and sorting read none.
/// * ``reveal(_:)`` reads exactly one directory per level between the root and
///   the target, which is bounded by path depth rather than by tree size.
/// * Badges come from ``TaskBadgeService`` — background, on demand, one visible
///   row at a time — and never from the listing.
@MainActor
public final class TreeViewController: NSViewController {

    /// Called when the user picks a markdown file.
    public var onSelect: ((URL) -> Void)?

    /// Called after anything the session file records changes — the root, the
    /// history, a toggle, the sort. The window controller uses it to schedule a
    /// save. The filter is deliberately not one of those things.
    public var onStateChange: (() -> Void)?

    public private(set) var outlineView: NSOutlineView!
    public private(set) var breadcrumbBar: BreadcrumbBar!
    public private(set) var filterField: NSSearchField!

    private var dataSource: TreeDataSource!
    private let lister: any DirectoryLister

    /// Root switching, breadcrumbs, and history (plan §1, `Navigator.swift`).
    public let navigator: Navigator

    /// Per-file task badges, lazily and in the background.
    public let badges = TaskBadgeService()

    /// Expansion state, tracked by us rather than read back off the outline
    /// view.
    ///
    /// `NSOutlineView` does mostly preserve expansion across `reloadData()`,
    /// but "mostly" is not a gate, and plan §2 M8 makes one of it: *"filter the
    /// visible tree by name, incremental, without collapsing what the user
    /// expanded"*. Tracking it here means the restore is explicit, ordered
    /// parents-first, and testable without a window on screen.
    private var expanded: [ObjectIdentifier: TreeNode] = [:]

    /// Set while we are re-expanding, so the resulting notifications do not
    /// re-enter and rewrite the very set being replayed.
    private var isRestoringExpansion = false

    /// Coalesces the redraws a burst of arriving badges would otherwise cause,
    /// and remembers which rows they were for.
    private var badgeRedraw: DispatchWorkItem?
    private var badgesPendingRedraw: Set<String> = []

    /// The directory the tree is rooted at. Read by ADR-4's session file, so a
    /// relaunch reopens the same project rather than the launch directory.
    public var root: URL { navigator.root }

    public var listingOptions: TreeListingOptions {
        get { lister.options }
        set {
            guard lister.options != newValue else { return }
            lister.options = newValue
            Log.tree.info(
                "listing options: nonMarkdown=\(newValue.showsNonMarkdown), hidden=\(newValue.showsHidden)"
            )
            refresh()
            onStateChange?()
        }
    }

    public var sort: TreeSort {
        get { dataSource.sort }
        set {
            guard dataSource.sort != newValue else { return }
            dataSource.sort = newValue
            Log.tree.info("sort: \(newValue.rawValue, privacy: .public)")
            reloadPreservingExpansion()
            onStateChange?()
        }
    }

    /// The incremental name filter. Setting it never reads a directory and
    /// never collapses anything.
    public var filter: String {
        get { dataSource.filter }
        set {
            guard dataSource.filter != newValue else { return }
            dataSource.filter = newValue
            if filterField?.stringValue != newValue { filterField?.stringValue = newValue }
            reloadPreservingExpansion()
        }
    }

    public init(root: URL, lister: any DirectoryLister = CoreDirectoryLister()) {
        self.lister = lister
        self.navigator = Navigator(root: root)
        super.init(nibName: nil, bundle: nil)
        self.dataSource = TreeDataSource(root: navigator.root, lister: lister)
        self.dataSource.badges = badges
        self.navigator.onChange = { [weak self] navigator, _ in
            self?.rootDidMove(to: navigator.root)
        }
        self.badges.onBadge = { [weak self] url, _ in
            self?.badgeArrived(for: url)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TreeViewController is created in code, not from a nib")
    }

    // MARK: - View

    public override func loadView() {
        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.autoresizesOutlineColumn = false
        outlineView.indentationPerLevel = 14
        outlineView.floatsGroupRows = false
        outlineView.usesAutomaticRowHeights = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Name"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = dataSource
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)
        // Drag a file out to Finder (plan §2 M8). `forLocal: false` is the
        // out-of-app half; there is no in-app drop target for a row, so the
        // local mask stays empty rather than showing a move cursor that would
        // do nothing.
        outlineView.setDraggingSourceOperationMask([], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy], forLocal: false)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        // The container positions this below the chrome, so AppKit must not
        // also inset it for the title bar — doing both leaves a gap that grows
        // every time the window enters full screen.
        scrollView.automaticallyAdjustsContentInsets = false

        let breadcrumbBar = BreadcrumbBar(frame: .zero)
        breadcrumbBar.onSelect = { [weak self] url in self?.navigate(to: url) }
        breadcrumbBar.onBack = { [weak self] in self?.navigateBack() }
        breadcrumbBar.onForward = { [weak self] in self?.navigateForward() }

        let filterField = NSSearchField()
        filterField.placeholderString = "Filter"
        filterField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filterField.sendsWholeSearchString = false
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.setAccessibilityLabel("Filter files")

        let container = SidebarContainerView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 600),
            breadcrumbBar: breadcrumbBar,
            filterField: filterField,
            scrollView: scrollView
        )
        // Drop a folder onto the sidebar to set the root; drop a markdown file
        // to open it (plan §2 M8).
        container.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }

        self.outlineView = outlineView
        self.breadcrumbBar = breadcrumbBar
        self.filterField = filterField
        self.view = container
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        // One level, so the sidebar shows something on launch without walking
        // anything. Everything below stays unread until the user asks.
        outlineView.expandItem(nil, expandChildren: false)
        breadcrumbBar.update(with: navigator)
    }

    // MARK: - Navigation

    /// Make `url` the root, recording history.
    @discardableResult
    public func navigate(to url: URL) -> Bool {
        navigator.go(to: url)
    }

    /// ⌘↑.
    @discardableResult
    public func navigateToParent() -> Bool { navigator.goToParent() }

    /// ⌘[.
    @discardableResult
    public func navigateBack() -> Bool { navigator.goBack() }

    /// ⌘].
    @discardableResult
    public func navigateForward() -> Bool { navigator.goForward() }

    /// Point the sidebar at a different directory. Kept for the M2-era callers;
    /// it is ``navigate(to:)`` and does record history.
    public func setRoot(_ url: URL) {
        navigate(to: url)
    }

    private func rootDidMove(to url: URL) {
        dataSource.setRoot(url)
        expanded.removeAll()
        outlineView?.reloadData()
        outlineView?.expandItem(nil, expandChildren: false)
        breadcrumbBar?.update(with: navigator)
        onStateChange?()
    }

    // MARK: - Reveal

    /// ⌘⇧O — jump the tree to `url` and select it.
    ///
    /// **Works for a file outside the current root**, which is the case that
    /// makes this worth having: you navigated up to look at something else, and
    /// now want to get back to the document you are reading. When the target is
    /// not under the root, the root moves to the target's directory first, and
    /// that move goes through ``Navigator`` so ⌘[ takes you back to where you
    /// were looking.
    ///
    /// Reads exactly one directory per level between the root and the target.
    ///
    /// - Returns: whether the row was found and selected.
    @discardableResult
    public func reveal(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            Log.tree.error("reveal: \(target.path, privacy: .public) does not exist")
            return false
        }

        if !isUnderRoot(target) {
            let parent = target.deletingLastPathComponent()
            Log.tree.info(
                "reveal: \(target.lastPathComponent, privacy: .public) is outside \(self.root.path, privacy: .public); moving the root"
            )
            navigator.go(to: parent, reason: .reveal)
        }

        if let node = expandChain(to: target), select(node) { return true }

        // A filter can hide the very row the user asked to be taken to. Clear
        // it and try once more — "reveal" cancelling a search is what Finder
        // and every editor sidebar do, and the alternative is a command that
        // silently does nothing.
        guard !filter.isEmpty else { return false }
        Log.tree.info("reveal: clearing the filter to show \(target.lastPathComponent, privacy: .public)")
        filter = ""
        guard let node = expandChain(to: target) else { return false }
        return select(node)
    }

    /// ⌘⌥R — hand the file to Finder.
    public func revealInFinder(_ url: URL?) {
        guard let url else { return }
        Log.tree.info("reveal in Finder: \(url.lastPathComponent, privacy: .public)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The row currently selected, if any.
    public var selectedNode: TreeNode? {
        outlineView?.item(atRow: outlineView.selectedRow) as? TreeNode
    }

    private func isUnderRoot(_ url: URL) -> Bool {
        let rootPath = root.path == "/" ? "/" : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    /// Expand every directory between the root and `target`, returning the
    /// target's node.
    ///
    /// One listing per level, and no more: this is the loop that would become
    /// an eager walk if it ever asked a directory for anything but the one
    /// child it is looking for.
    private func expandChain(to target: URL) -> TreeNode? {
        guard let outlineView, isUnderRoot(target) else { return nil }
        let rootComponents = root.pathComponents
        let components = target.pathComponents
        guard components.count > rootComponents.count else { return dataSource.root }

        var node = dataSource.root
        for component in components[rootComponents.count...] {
            // The data source's root is the outline view's *invisible* root:
            // `expandItem` does not know it, and its children are always shown.
            if node !== dataSource.root { outlineView.expandItem(node) }
            guard
                let next = dataSource.arrangedChildren(of: node).first(where: { $0.name == component })
            else {
                Log.tree.info(
                    "reveal: \(component, privacy: .public) is not listed under \(node.url.path, privacy: .public)"
                )
                return nil
            }
            node = next
        }
        return node
    }

    @discardableResult
    private func select(_ node: TreeNode) -> Bool {
        guard let outlineView else { return false }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        return true
    }

    // MARK: - Refresh

    /// Re-read every expanded directory and recompute every badge.
    public func refresh() {
        let previouslyExpanded = expansionSnapshot()
        dataSource.invalidate()
        badges.invalidateAll()
        expanded.removeAll()
        guard let outlineView else { return }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: false)
        // The nodes are gone — the listing was thrown away — so expansion is
        // replayed by *path*, which re-lists exactly the directories that were
        // open and nothing else.
        for path in previouslyExpanded {
            guard let node = expandChain(to: URL(fileURLWithPath: path)) else { continue }
            outlineView.expandItem(node)
        }
    }

    /// One file changed on disk: drop its badge so the next draw recomputes it.
    public func invalidateBadge(for url: URL) {
        badges.invalidate(url)
        badges.request(url)
    }

    // MARK: - Session

    public func snapshot() -> SidebarState {
        SidebarState(
            root: navigator.root,
            back: navigator.back,
            forward: navigator.forward,
            options: listingOptions,
            sort: sort,
            filter: filter
        )
    }

    /// Adopt a persisted state without recording a navigation.
    public func restore(_ state: SidebarState) {
        lister.options = state.options
        dataSource.sort = state.sort
        dataSource.filter = state.filter
        filterField?.stringValue = state.filter
        navigator.restore(root: state.root, back: state.back, forward: state.forward)
    }

    // MARK: - Expansion

    private func expansionSnapshot() -> [String] {
        expanded.values.map(\.url.path).sorted { $0.count < $1.count }
    }

    /// Reload, then put back exactly the disclosure triangles the user opened.
    ///
    /// Parents first — expanding a child before its parent is a no-op, and the
    /// bug it produces (a filter that quietly closes one level) is exactly what
    /// plan §2 M8's gate is about.
    private func reloadPreservingExpansion() {
        guard let outlineView else { return }
        let nodes = expanded.values.sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }
        outlineView.reloadData()
        isRestoringExpansion = true
        outlineView.expandItem(nil, expandChildren: false)
        for node in nodes {
            outlineView.expandItem(node)
        }
        isRestoringExpansion = false
    }

    // MARK: - Badges

    private func badgeArrived(for url: URL) {
        // One redraw for a burst of badges rather than one per badge: the
        // service lands them a fraction of a millisecond apart, and reloading
        // the outline view per badge is what would make "progressive" feel like
        // "flickering".
        badgesPendingRedraw.insert(url.path)
        badgeRedraw?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.redrawBadgedRows() }
        }
        badgeRedraw = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Redraw the rows a burst of badges landed on.
    ///
    /// **Row-scoped, not a `reloadData()`.** A full reload rebuilds every
    /// visible cell, and `mark-bench` measured that as a 551 ms main-thread
    /// stall while 400 badges arrived — which is exactly the "without blocking
    /// the tree" the gate is about, failed by the redraw rather than by the
    /// work it was reporting. Sorting by task count is the one case that
    /// genuinely needs a reload, because there the badge *is* the order.
    private func redrawBadgedRows() {
        guard let outlineView else { return }
        let paths = badgesPendingRedraw
        badgesPendingRedraw.removeAll()
        guard !paths.isEmpty else { return }

        if dataSource.sort == .taskCount {
            dataSource.rearrange()
            reloadPreservingExpansion()
            return
        }
        var rows = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? TreeNode,
                paths.contains(node.url.path)
            else { continue }
            rows.insert(row)
        }
        guard !rows.isEmpty else { return }
        outlineView.reloadData(
            forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
    }

    // MARK: - Drag and drop

    /// A drop landed on the sidebar. A folder sets the root; a markdown file is
    /// opened.
    @discardableResult
    public func handleDrop(_ urls: [URL]) -> Bool {
        var handled = false
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                Log.tree.info("dropped folder \(url.path, privacy: .public); setting the root")
                navigate(to: url)
                handled = true
                break
            }
            if TreeNode.isMarkdown(url) {
                onSelect?(url)
                handled = true
            }
        }
        return handled
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: NSSearchField) {
        filter = sender.stringValue
    }

    @objc private func rowDoubleClicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? TreeNode else {
            return
        }
        guard node.isDirectory else { return }
        // Double-clicking a folder **descends into it as the new root**, which
        // is plan §2 M8's *"descend into a folder as the new root"*. The
        // disclosure triangle is still there for looking without moving.
        navigate(to: node.url)
    }
}

// MARK: - NSOutlineViewDelegate

extension TreeViewController: NSOutlineViewDelegate {

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let cell =
            outlineView.makeView(withIdentifier: TreeCellView.identifier, owner: self)
            as? TreeCellView ?? TreeCellView(frame: .zero)

        // **The badge request happens here and only here**: one per row that is
        // about to be drawn, which is bounded by the height of the sidebar
        // rather than by the size of the tree. `badge(for:)` is a dictionary
        // lookup; `request(_:)` queues a background read and returns.
        let badge = badges.badge(for: node.url)
        if badge == nil, node.isMarkdown {
            badges.request(node.url)
        }
        cell.configure(with: node, badge: badge)
        return cell
    }

    /// The row's tooltip, asked for when the pointer stops over it rather than
    /// registered per cell. See ``TreeCellView/configure(with:badge:)``.
    public func outlineView(
        _ outlineView: NSOutlineView,
        toolTipFor cell: NSCell,
        rect: NSRectPointer,
        tableColumn: NSTableColumn?,
        item: Any,
        mouseLocation: NSPoint
    ) -> String {
        guard let node = item as? TreeNode else { return "" }
        return node.listingError ?? node.url.path
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? TreeNode else {
            return
        }
        // Directories are selectable (so ⌘⌥R can reveal one) but do not open a
        // tab; non-markdown files are selectable and deliberately **not
        // openable**, which is what "dimmed" is telling the user.
        guard node.isMarkdown else { return }
        onSelect?(node.url)
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringExpansion,
            let node = notification.userInfo?["NSObject"] as? TreeNode
        else { return }
        expanded[ObjectIdentifier(node)] = node
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringExpansion,
            let node = notification.userInfo?["NSObject"] as? TreeNode
        else { return }
        expanded.removeValue(forKey: ObjectIdentifier(node))
    }
}

// MARK: - Layout

/// Breadcrumb bar, filter field, and the outline view, stacked.
///
/// Frame-based for the same reason ``DocumentAreaView`` is: three children whose
/// geometry is two subtractions. It is also the sidebar's **drop target** —
/// plan §2 M8's *"drop a folder onto the window to set the root"*.
@MainActor
public final class SidebarContainerView: NSView {

    /// Returns whether the drop was accepted.
    public var onDrop: (([URL]) -> Bool)?

    private let breadcrumbBar: BreadcrumbBar
    private let filterField: NSSearchField
    private let scrollView: NSScrollView

    /// The sidebar's material, behind everything.
    ///
    /// `NSSplitViewItem(sidebarWithViewController:)` supplies one of these
    /// itself, so in the shipping window this is belt and braces — but the
    /// sidebar is also hosted in a plain window by `mark-bench`, and there it
    /// is the difference between a snapshot that shows the sidebar and one
    /// where the chrome above the outline view is transparent. A view that only
    /// looks right inside one particular parent is a view whose appearance
    /// cannot be checked.
    private let backing = NSVisualEffectView()

    public init(
        frame: NSRect,
        breadcrumbBar: BreadcrumbBar,
        filterField: NSSearchField,
        scrollView: NSScrollView
    ) {
        self.breadcrumbBar = breadcrumbBar
        self.filterField = filterField
        self.scrollView = scrollView
        super.init(frame: frame)
        backing.material = .sidebar
        backing.blendingMode = .behindWindow
        backing.state = .followsWindowActiveState
        backing.autoresizingMask = [.width, .height]
        addSubview(backing)
        addSubview(breadcrumbBar)
        addSubview(filterField)
        addSubview(scrollView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarContainerView is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        backing.frame = bounds
        // `NSSplitViewController` applies the title-bar allowance to its
        // *sidebar* item, so unlike `DocumentAreaView` this really does get a
        // non-zero `safeAreaInsets.top` and does not have to derive one.
        let top = safeAreaInsets.top
        let filterHeight: CGFloat = 24
        breadcrumbBar.frame = NSRect(
            x: 0, y: top, width: bounds.width, height: BreadcrumbBar.barHeight)
        filterField.frame = NSRect(
            x: 6, y: top + BreadcrumbBar.barHeight + 3, width: max(0, bounds.width - 12),
            height: filterHeight)
        let listTop = top + BreadcrumbBar.barHeight + filterHeight + 6
        scrollView.frame = NSRect(
            x: 0, y: listTop, width: bounds.width, height: max(0, bounds.height - listTop))
        super.layout()
    }

    // MARK: Dropping

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.urls(from: sender).isEmpty ? [] : .generic
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.urls(from: sender).isEmpty ? [] : .generic
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop?(Self.urls(from: sender)) ?? false
    }

    /// File URLs on a dragging pasteboard, or none.
    static func urls(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
            as? [URL]) ?? []
    }
}
