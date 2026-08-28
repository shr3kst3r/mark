import AppKit
import Foundation

/// One entry in a document's outline, with the entries nested under it.
///
/// A reference type because `NSOutlineView` identifies items by object, and a
/// tree because a table of contents that ignored heading levels would be a list
/// of every `###` in the file with nothing to say which `##` it belongs to.
@MainActor
public final class TOCNode {

    public let heading: Heading
    public private(set) var children: [TOCNode] = []

    /// The rendered element's `id` — the same string `mark goto` takes, put on
    /// the heading by the core and re-stamped after every patch.
    public var anchor: String { heading.anchor }
    public var level: Int { heading.level }
    public var text: String { heading.text }

    init(_ heading: Heading) {
        self.heading = heading
    }

    /// Nest a flat, document-ordered heading list by level.
    ///
    /// Deliberately tolerant of the levels real documents actually have. A
    /// `###` that follows a `#` with no `##` between them nests under the `#`
    /// rather than being dropped or promoted, and a document that opens on a
    /// `##` gets two roots when a later `#` arrives — markdown does not
    /// promise a well-formed tree, and a pane that only worked for documents
    /// that happened to be well-formed would be wrong on most of them.
    public static func tree(from headings: [Heading]) -> [TOCNode] {
        var roots: [TOCNode] = []
        var ancestors: [TOCNode] = []
        for heading in headings {
            let node = TOCNode(heading)
            while let last = ancestors.last, last.level >= node.level {
                ancestors.removeLast()
            }
            if let parent = ancestors.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            ancestors.append(node)
        }
        return roots
    }

    /// This node and everything under it, in document order.
    public var flattened: [TOCNode] {
        children.reduce([self]) { $0 + $1.flattened }
    }
}

/// The document pane's Contents tab: the selected document's headings,
/// clickable.
///
/// The tree above it answers *"which file"*; this answers *"where in it"*, and
/// the two are stacked rather than tabbed because moving between them is the
/// normal reading loop rather than a mode switch.
///
/// That is still true, and it is **not** what
/// `2026-08-28-tabbed-document-pane` changed. What it added is a second answer
/// to *"where in it"* — the tasks — and headings-versus-tasks *is* a mode
/// switch: a reader outlining a document is not simultaneously working its
/// checklist. So the tree and this pane stay stacked, and this view is now one
/// of two tabs inside the lower half. ``DocumentPaneController`` owns the header
/// and the choice; this class is unchanged apart from no longer drawing a header
/// of its own.
///
/// Three properties this pane is written to keep, each of which is easy to lose
/// by accident:
///
/// * **It never reads a file.** The headings arrive from the tab's
///   ``DocumentMetadata``, which the core already computes off the main thread
///   for the tab bar's badge — so this pane costs one `toc` call that was
///   happening anyway, and it works for a tab whose web view has been torn
///   down (ADR-4's *"no feature may assume a tab's web view exists"*).
/// * **It does not rebuild when nothing changed.** `show(_:for:)` compares the
///   heading list first, because the window controller calls it from
///   `updateChrome()` — which runs on every tab switch, every metadata load,
///   and every tab-list change — and a reload per call would drop the
///   selection and the disclosure triangles under the reader's cursor.
/// * **Collapse state survives a rebuild.** It is keyed by anchor, not by
///   node, because an edit throws every node away and mints new ones.
@MainActor
public final class TableOfContentsViewController: NSViewController {

    /// A heading was picked. The window controller scrolls the preview to it.
    public var onSelect: ((Heading) -> Void)?

    /// The headings currently on show, in document order.
    public private(set) var headings: [Heading] = []

    /// The roots of ``headings`` nested by level.
    public private(set) var roots: [TOCNode] = []

    public private(set) var outlineView: NSOutlineView!

    /// Set while we move the selection ourselves, so the resulting
    /// notification is not reported back as a heading the user clicked.
    private var isSelectingProgrammatically = false

    /// Anchors the user has collapsed. Everything else is expanded.
    private var collapsedAnchors: Set<String> = []

    /// The anchor of the selected row, kept across rebuilds.
    private var selectedAnchor: String?

    /// Whether a document is open at all, as opposed to one with no headings.
    private var hasDocument = false

    private var container: TableOfContentsContainerView {
        // `view` is this controller's own, built in `loadView`.
        view as! TableOfContentsContainerView
    }

    // MARK: - View

    public override func loadView() {
        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.autoresizesOutlineColumn = false
        outlineView.indentationPerLevel = 12
        outlineView.floatsGroupRows = false
        outlineView.usesAutomaticRowHeights = false
        // A table of contents is read top to bottom; nothing here is dragged
        // anywhere, and an outline view that offered to would be lying.
        outlineView.setDraggingSourceOperationMask([], forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.title = "Heading"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        // Single click, not double: the pane exists to move the preview, and
        // making that take two clicks would put a mode in front of the one
        // thing it does.
        outlineView.action = #selector(rowClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false

        self.outlineView = outlineView
        view = TableOfContentsContainerView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 200), scrollView: scrollView)
        updateEmptyState()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        expandAll()
        restoreSelection()
        updateEmptyState()
    }

    // MARK: - Contents

    /// Show `headings` for the document at `url`.
    ///
    /// - Parameter url: the open document, or `nil` when no tab is selected.
    ///   Only the empty-state wording depends on it: "no headings in this
    ///   document" and "no document open" are different facts, and one label
    ///   for both reads as a bug the first time you see it on an empty
    ///   sidebar.
    public func show(_ headings: [Heading], for url: URL?) {
        let hasDocument = url != nil
        guard headings != self.headings || hasDocument != self.hasDocument else { return }
        self.headings = headings
        self.hasDocument = hasDocument
        self.roots = TOCNode.tree(from: headings)
        guard isViewLoaded else { return }

        outlineView.reloadData()
        expandAll()
        restoreSelection()
        updateEmptyState()
    }

    /// Put the selection on the heading with this anchor, without reporting it.
    ///
    /// Used when the preview is scrolled somewhere by another route — a link
    /// click, `mark goto` — so the pane does not go on pointing at whatever was
    /// clicked last.
    @discardableResult
    public func highlight(anchor: String?) -> Bool {
        selectedAnchor = anchor
        guard isViewLoaded else { return false }
        return restoreSelection()
    }

    /// The heading the selection is on, if any.
    public var selectedHeading: Heading? {
        guard let outlineView else { return nil }
        return (outlineView.item(atRow: outlineView.selectedRow) as? TOCNode)?.heading
    }

    private func node(for anchor: String) -> TOCNode? {
        roots.lazy.flatMap(\.flattened).first { $0.anchor == anchor }
    }

    @discardableResult
    private func restoreSelection() -> Bool {
        guard let outlineView else { return false }
        isSelectingProgrammatically = true
        defer { isSelectingProgrammatically = false }
        guard let anchor = selectedAnchor, let node = node(for: anchor) else {
            outlineView.deselectAll(nil)
            return false
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else {
            outlineView.deselectAll(nil)
            return false
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        return true
    }

    /// Open every disclosure triangle the user has not deliberately closed.
    ///
    /// Unlike the file tree, expanding here reads nothing and cannot walk
    /// anything: the whole outline is already in memory, and a table of
    /// contents that opened collapsed would hide the very thing it is for.
    private func expandAll() {
        guard let outlineView else { return }
        isRestoringExpansion = true
        defer { isRestoringExpansion = false }
        for node in roots.flatMap(\.flattened) where !collapsedAnchors.contains(node.anchor) {
            outlineView.expandItem(node)
        }
    }

    /// Set while `expandAll()` runs, so replaying expansion does not rewrite
    /// the very set being replayed.
    private var isRestoringExpansion = false

    private func updateEmptyState() {
        guard isViewLoaded else { return }
        container.emptyMessage =
            headings.isEmpty ? (hasDocument ? "No headings" : "No document open") : nil
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? TOCNode else { return }
        selectedAnchor = node.anchor
        onSelect?(node.heading)
    }
}

// MARK: - NSOutlineViewDataSource

extension TableOfContentsViewController: NSOutlineViewDataSource {

    private func children(of item: Any?) -> [TOCNode] {
        (item as? TOCNode)?.children ?? roots
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any
    {
        children(of: item)[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? TOCNode)?.children.isEmpty ?? true)
    }
}

// MARK: - NSOutlineViewDelegate

extension TableOfContentsViewController: NSOutlineViewDelegate {

    public func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = item as? TOCNode else { return nil }
        let cell =
            outlineView.makeView(withIdentifier: TOCCellView.identifier, owner: self)
            as? TOCCellView ?? TOCCellView(frame: .zero)
        cell.configure(with: node)
        return cell
    }

    public func outlineView(
        _ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer,
        tableColumn: NSTableColumn?, item: Any, mouseLocation: NSPoint
    ) -> String {
        (item as? TOCNode)?.text ?? ""
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically else { return }
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? TOCNode else { return }
        selectedAnchor = node.anchor
        // Keyboard selection scrolls the preview too. The pane is a navigation
        // control, so ↑/↓ in it has to mean the same thing a click does — an
        // outline that moved its highlight and left the document behind would
        // be a list, not a table of contents.
        onSelect?(node.heading)
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringExpansion,
            let node = notification.userInfo?["NSObject"] as? TOCNode
        else { return }
        collapsedAnchors.remove(node.anchor)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringExpansion,
            let node = notification.userInfo?["NSObject"] as? TOCNode
        else { return }
        collapsedAnchors.insert(node.anchor)
    }
}

// MARK: - Views

/// One outline row: the heading's text, sized by its level.
///
/// Indentation already carries the nesting, so the font carries the *weight* of
/// a heading rather than repeating its depth — a `#` reads as a section title
/// and a `####` as a detail, which is how the document itself reads.
@MainActor
public final class TOCCellView: NSTableCellView {

    public static let identifier = NSUserInterfaceItemIdentifier("TOCCell")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.identifier = TOCCellView.identifier

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        addSubview(text)
        textField = text

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TOCCellView is created in code, not from a nib")
    }

    public func configure(with node: TOCNode) {
        // A heading with no text — `##` on its own, or one made entirely of an
        // image — still occupies a place in the document, so it gets a row
        // that says so rather than a blank one that looks like a glitch.
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        textField?.stringValue = text.isEmpty ? "(untitled)" : text
        textField?.font = Self.font(forLevel: node.level)
        textField?.textColor = text.isEmpty ? .tertiaryLabelColor : .labelColor
        setAccessibilityLabel("Heading level \(node.level), \(text.isEmpty ? "untitled" : text)")
    }

    static func font(forLevel level: Int) -> NSFont {
        let size = NSFont.smallSystemFontSize + 1
        return level <= 2
            ? .systemFont(ofSize: size, weight: .semibold)
            : .systemFont(ofSize: size, weight: .regular)
    }
}

/// The outline view and the empty-state label, stacked.
///
/// Frame-based for the same reason ``SidebarContainerView`` is: two children
/// and a subtraction.
///
/// **No header of its own.** It had one — a "Contents" label — until
/// `2026-08-28-tabbed-document-pane` made this view one of two things the
/// document pane can show; the header is now the pane's, because it holds the
/// control that chooses between them.
@MainActor
public final class TableOfContentsContainerView: NSView {

    /// What to say instead of an outline, or `nil` to show the outline.
    public var emptyMessage: String? {
        didSet {
            emptyLabel.stringValue = emptyMessage ?? ""
            emptyLabel.isHidden = emptyMessage == nil
            scrollView.isHidden = emptyMessage != nil
        }
    }

    private let emptyLabel = NSTextField(labelWithString: "")
    private let scrollView: NSScrollView

    /// The sidebar's material, for the same reason ``SidebarContainerView``
    /// carries one: `mark-bench` hosts these views in a plain window, and a
    /// pane that only looks right inside an `NSSplitViewItem` is a pane whose
    /// appearance cannot be checked.
    private let backing = NSVisualEffectView()

    public init(frame: NSRect, scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: frame)
        backing.material = .sidebar
        backing.blendingMode = .behindWindow
        backing.state = .followsWindowActiveState
        backing.autoresizingMask = [.width, .height]
        addSubview(backing)

        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        addSubview(scrollView)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Table of contents")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TableOfContentsContainerView is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        backing.frame = bounds
        scrollView.frame = bounds
        emptyLabel.frame = NSRect(x: 8, y: 4, width: max(0, bounds.width - 16), height: 16)
        super.layout()
    }
}
