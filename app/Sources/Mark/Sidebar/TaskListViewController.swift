import AppKit
import Foundation

/// One state's tasks, as a group row in the Tasks tab.
///
/// A reference type for the same reason ``TOCNode`` is: `NSOutlineView`
/// identifies items by object.
@MainActor
public final class TaskGroupNode {

    public let state: TaskState
    public let rows: [TaskRowNode]

    public var count: Int { rows.count }

    /// `"Blocked (2)"`. The count is a count of *markers* — no tag ever affects
    /// it (`2026-08-27-inline-task-metadata`).
    public var title: String { "\(state.title) (\(count))" }

    init(state: TaskState, tasks: [Task]) {
        self.state = state
        self.rows = tasks.map(TaskRowNode.init)
    }
}

/// One task, as a row in the Tasks tab.
@MainActor
public final class TaskRowNode {

    public let task: Task

    /// The item's text with its metadata tokens stripped
    /// (`2026-08-27-inline-task-metadata`): the tokens are still in the
    /// document and still in the preview, and a list that repeated them would
    /// be showing its source rather than its content.
    public var label: String { task.label.isEmpty ? task.text : task.label }

    /// `!!` on its own — what a row too narrow for the date still has room for.
    public var priorityMark: String? {
        task.priority > 0 ? String(repeating: "!", count: min(task.priority, 3)) : nil
    }

    /// `!!` and `@due(…)`, as the row's trailing text — or `nil` when the task
    /// carries neither.
    public var decoration: String? {
        let parts = [priorityMark, task.due].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    init(_ task: Task) {
        self.task = task
    }
}

/// The document pane's Tasks tab: the selected document's tasks, grouped by
/// state, clickable.
///
/// The outline half of the pane answers *"where are the headings"*; this
/// answers *"what is left, and where is it"*. Both are scoped to the same
/// document, which is why they are two tabs of one pane rather than two panes
/// (`2026-08-28-tabbed-document-pane`).
///
/// It keeps the three properties ``TableOfContentsViewController`` is written
/// to keep, for the same reasons:
///
/// * **It never reads a file.** The tasks arrive from the tab's
///   ``DocumentMetadata``, out of the `mark_tasks_json` call the tab bar's badge
///   already pays for — so this tab costs nothing new and works for a tab whose
///   web view has been torn down (ADR-4's *"no feature may assume a tab's web
///   view exists"*).
/// * **It does not rebuild when nothing changed.** ``show(_:counts:for:)`` is
///   called from `updateChrome()`, on every tab switch and every metadata load.
/// * **Collapse state survives a rebuild.** Keyed by state rather than by node,
///   because a metadata refresh throws every node away and mints new ones — and
///   by state rather than by document, because the five states are the same five
///   in every document.
///
/// And one of its own: **it never writes.** Ticking a box stays in the preview
/// and in `mark check`, which keeps a single locked, span-verified, one-byte
/// write path (`2026-08-25-flock-write-locking`,
/// `2026-08-27-five-task-states`).
@MainActor
public final class TaskListViewController: NSViewController {

    /// A task was picked. The window controller scrolls the preview to it.
    public var onSelect: ((Task) -> Void)?

    /// The tasks currently on show, in document order.
    public private(set) var tasks: [Task] = []

    /// The counts behind the summary line. Never re-derived here
    /// (`2026-08-27-five-task-states` owns the arithmetic).
    public private(set) var counts: TaskCounts = .empty

    /// The groups on show, outstanding first. A state with no tasks builds no
    /// group at all.
    public private(set) var groups: [TaskGroupNode] = []

    public private(set) var outlineView: NSOutlineView!

    /// States the user has collapsed. Done and cancelled start in it: a pane
    /// read to answer "what is left" should not open on two screens of what is
    /// not.
    private var collapsedStates: Set<TaskState> = [.done, .cancelled]

    /// Set while we move the selection ourselves, so the resulting
    /// notification is not reported back as a task the user clicked.
    private var isSelectingProgrammatically = false

    /// Set while ``replayExpansion()`` runs, so replaying expansion does not
    /// rewrite the very set being replayed.
    private var isRestoringExpansion = false

    /// Whether a document is open at all, as opposed to one with no tasks.
    private var hasDocument = false

    private var container: TaskListContainerView {
        // `view` is this controller's own, built in `loadView`.
        view as! TaskListContainerView
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
        // Nothing here is dragged anywhere, and an outline view that offered to
        // would be lying — the same reason the outline tab says so.
        outlineView.setDraggingSourceOperationMask([], forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        column.title = "Task"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        // Single click, like the outline tab: the pane exists to move the
        // preview, and making that take two clicks would put a mode in front of
        // the one thing it does.
        outlineView.action = #selector(rowClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false

        self.outlineView = outlineView
        view = TaskListContainerView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 200), scrollView: scrollView)
        updateSummary()
        updateEmptyState()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        replayExpansion()
        updateSummary()
        updateEmptyState()
    }

    // MARK: - Tasks

    /// Show `tasks` for the document at `url`.
    ///
    /// - Parameter counts: the same numbers the badges use. Passed in rather
    ///   than counted here so that the window has exactly one answer to "how
    ///   many are left" (`2026-08-27-five-task-states`).
    /// - Parameter url: the open document, or `nil` when no tab is selected.
    ///   Only the empty-state wording depends on it — "no tasks in this
    ///   document" and "no document open" are different facts.
    public func show(_ tasks: [Task], counts: TaskCounts, for url: URL?) {
        let hasDocument = url != nil
        guard tasks != self.tasks || counts != self.counts || hasDocument != self.hasDocument
        else { return }
        self.tasks = tasks
        self.counts = counts
        self.hasDocument = hasDocument
        self.groups = Self.group(tasks)
        guard isViewLoaded else { return }

        outlineView.reloadData()
        replayExpansion()
        updateSummary()
        updateEmptyState()
    }

    /// Group `tasks` by state, outstanding first, document order within a
    /// group.
    ///
    /// Document order because it is the only order the pane can show without
    /// arguing with `mark tasks --sort`, which is where sorting belongs — and
    /// because the byte offsets a click navigates by ascend with it, so the pane
    /// reads in the direction the preview scrolls.
    static func group(_ tasks: [Task]) -> [TaskGroupNode] {
        TaskState.groupingOrder.compactMap { state in
            let matching = tasks.filter { $0.state == state }
            return matching.isEmpty ? nil : TaskGroupNode(state: state, tasks: matching)
        }
    }

    /// The task the selection is on, if any.
    public var selectedTask: Task? {
        guard let outlineView else { return nil }
        return (outlineView.item(atRow: outlineView.selectedRow) as? TaskRowNode)?.task
    }

    /// What the summary line says, or `nil` when there is nothing to summarise.
    ///
    /// Two lines' worth in one label: the badge's own arithmetic, then the
    /// states that are actually present. A zero is left out rather than shown —
    /// five states each reading `0` is a wall of nothing.
    public var summary: String? {
        guard counts.total > 0 else { return nil }
        let breakdown =
            TaskState.groupingOrder
            .map { ($0, count(of: $0)) }
            .filter { $0.1 > 0 }
            .map { "\($0.1) \($0.0.spoken)" }
            .joined(separator: " · ")
        guard counts.active > 0 else { return breakdown }
        return "\(counts.outstanding) of \(counts.active) outstanding\n\(breakdown)"
    }

    /// One state's count, from ``counts`` — not from ``groups``, so that the
    /// pane and the badges cannot disagree.
    func count(of state: TaskState) -> Int {
        switch state {
        case .open: return counts.open
        case .inProgress: return counts.inProgress
        case .done: return counts.done
        case .cancelled: return counts.cancelled
        case .blocked: return counts.blocked
        }
    }

    /// What the pane shows instead of a list, or `nil` to show the list.
    public var emptyMessage: String? {
        guard tasks.isEmpty else { return nil }
        return hasDocument ? "No tasks" : "No document open"
    }

    private func updateSummary() {
        guard isViewLoaded else { return }
        container.summary = summary
    }

    private func updateEmptyState() {
        guard isViewLoaded else { return }
        container.emptyMessage = emptyMessage
    }

    /// Open every group the user has not deliberately closed.
    ///
    /// Reads nothing and walks nothing: the whole list is already in memory.
    private func replayExpansion() {
        guard let outlineView else { return }
        isRestoringExpansion = true
        defer { isRestoringExpansion = false }
        for group in groups {
            if collapsedStates.contains(group.state) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
        }
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        let clicked = outlineView.clickedRow
        guard clicked >= 0 else { return }
        // A click on a group row toggles it, which is what a disclosure triangle
        // does and what the row looks like it should do. Only a task row is a
        // destination.
        if let group = outlineView.item(atRow: clicked) as? TaskGroupNode {
            if outlineView.isItemExpanded(group) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
            return
        }
        guard let row = outlineView.item(atRow: clicked) as? TaskRowNode else { return }
        onSelect?(row.task)
    }
}

// MARK: - NSOutlineViewDataSource

extension TaskListViewController: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int
    {
        switch item {
        case nil: return groups.count
        case let group as TaskGroupNode: return group.rows.count
        default: return 0
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any
    {
        switch item {
        case nil: return groups[index]
        case let group as TaskGroupNode: return group.rows[index]
        default: fatalError("a task row has no children")
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is TaskGroupNode
    }
}

// MARK: - NSOutlineViewDelegate

extension TaskListViewController: NSOutlineViewDelegate {

    public func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TaskCell")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? TaskCellView
            ?? TaskCellView(identifier: identifier)
        if let group = item as? TaskGroupNode {
            cell.show(group)
        } else if let row = item as? TaskRowNode {
            cell.show(row)
        }
        return cell
    }

    /// A group heading is a heading, not a destination.
    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is TaskRowNode
    }

    public func outlineView(
        _ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer,
        tableColumn: NSTableColumn?, item: Any, mouseLocation: NSPoint
    ) -> String {
        // The full text, tokens included — the row shows the stripped label, so
        // the tooltip is where `@due(2026-09-01)` is still readable.
        (item as? TaskRowNode)?.task.text ?? (item as? TaskGroupNode)?.title ?? ""
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically else { return }
        guard let task = selectedTask else { return }
        // Keyboard selection moves the preview too, for the reason the outline
        // tab gives: the pane is a navigation control, so ↑/↓ in it has to mean
        // what a click does.
        onSelect?(task)
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isRestoringExpansion,
            let group = notification.userInfo?["NSObject"] as? TaskGroupNode
        else { return }
        collapsedStates.remove(group.state)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isRestoringExpansion,
            let group = notification.userInfo?["NSObject"] as? TaskGroupNode
        else { return }
        collapsedStates.insert(group.state)
    }
}

// MARK: - The cell

/// One row: the marker, the text, and — for a task — its priority and due date.
///
/// The marker is the document's own `[ ]` / `[/]` / `[x]` / `[-]` / `[?]` in a
/// monospaced font, so five rows line up and the vocabulary is the one the file
/// uses.
///
/// **One line per row, truncated at the tail**, like the outline tab's rows and
/// for the same reason: the pane is a navigation control, and a row is a target
/// to click rather than the text to read. The whole text — tokens included — is
/// in the row's tooltip, and the document itself is one click away.
///
/// That is not a free choice, it is an invariant this cell has to defend, because
/// the outline view is on fixed row heights (`usesAutomaticRowHeights = false`)
/// and a row that wraps draws over its neighbours. **The truncation travels in
/// the string, not on the field**: `NSTextField.lineBreakMode` is a property of
/// the cell, and an attributed string carries its own paragraph style whose
/// line-break mode is word wrapping. Assigning `attributedStringValue` — which
/// this cell has to do, for the strikethrough and the per-state colour — throws
/// the field's setting away, so the paragraph style goes in the attributes.
///
/// **Auto Layout, not `layout()`.** Three fields in a row is exactly the
/// arithmetic a `layout()` override is usually the shorter answer to, and here it
/// is the wrong one: `NSTableCellView` lays its own `textField` out, and this
/// cell's title *is* its `textField` — assigned so the outline view's selection
/// colouring and VoiceOver find it. Frames set by hand were moved back to the
/// cell's left edge, on top of the marker, which is what made every row read
/// `[W]rite the summary …` with the brackets around the first letters. Constraints are
/// what `NSTableCellView` cooperates with.
@MainActor
public final class TaskCellView: NSTableCellView {

    private let marker = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    /// The marker's column, wide enough for `[ ]` in the monospaced small
    /// system font plus the gap to the text.
    private static let markerColumn: CGFloat = 24

    /// How much of the row the priority and due date may take before the title
    /// stops giving way to them, as an absolute width and as a share of the row.
    ///
    /// Both, because a sidebar is dragged: 96 pt is what the decoration is worth
    /// in a wide pane, and two fifths is what it is worth in a narrow one, where
    /// `!!  2026-09-01` would otherwise leave `WEB…` where the task was.
    private static let maximumTrailingWidth: CGFloat = 96
    private static let maximumTrailingShare: CGFloat = 0.4

    /// The gap between the title and the trailing text, and between the
    /// trailing text and the row's right edge.
    private static let gap: CGFloat = 6

    /// One line, truncated — as a paragraph style, so it survives being handed
    /// to `attributedStringValue`.
    private static let oneLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// The marker's column, zero on a group row. A constraint rather than a
    /// number in `layout()`, for the reason on this class.
    private var markerWidth: NSLayoutConstraint!

    /// What the priority and due date measured, capped at
    /// ``maximumTrailingWidth`` and zero when the task carries neither.
    private var trailingWidth: NSLayoutConstraint!

    /// The row's decoration in full, and its priority alone — the two things the
    /// row may show in the space it turns out to have. Kept because the choice
    /// depends on a width, and a width is not known until layout.
    private var decoration = ""
    private var priority = ""
    private var taskPriority = 0

    private static func priorityColor(for priority: Int) -> NSColor? {
        switch priority {
        case 1: return .secondaryLabelColor
        case 2: return .systemOrange
        case 3...: return .systemRed
        default: return nil
        }
    }

    private func attributedTrailing(for candidate: String) -> NSAttributedString {
        guard !candidate.isEmpty else { return NSAttributedString() }
        let font = trailing.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let defaultColor = NSColor.tertiaryLabelColor
        guard let pColor = Self.priorityColor(for: taskPriority),
            !priority.isEmpty,
            candidate.hasPrefix(priority)
        else {
            return NSAttributedString(
                string: candidate,
                attributes: [.font: font, .foregroundColor: defaultColor])
        }
        let attributed = NSMutableAttributedString(
            string: candidate,
            attributes: [.font: font, .foregroundColor: defaultColor])
        let priorityRange = NSRange(location: 0, length: (priority as NSString).length)
        attributed.addAttribute(.foregroundColor, value: pColor, range: priorityRange)
        return attributed
    }

    /// The three fields as laid out, in drawing order, for the tests and for
    /// `mark-bench`: what a row *shows* and where, which is the half of this
    /// cell that a model of it cannot check.
    public var fields: [NSTextField] { [marker, title, trailing] }

    public init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        marker.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        marker.alignment = .left
        Self.makeSingleLine(marker)
        addSubview(marker)

        Self.makeSingleLine(title)
        // Lower than anything else in the row: the title is the one thing here
        // that is allowed to lose width, because losing it is what truncating
        // means. Without this a long task breaks the row's constraints instead.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(title)
        textField = title

        trailing.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        trailing.textColor = .tertiaryLabelColor
        trailing.alignment = .right
        Self.makeSingleLine(trailing)
        addSubview(trailing)

        for field in [marker, title, trailing] {
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        markerWidth = marker.widthAnchor.constraint(equalToConstant: Self.markerColumn)
        trailingWidth = trailing.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            markerWidth,

            title.leadingAnchor.constraint(equalTo: marker.trailingAnchor),
            title.trailingAnchor.constraint(
                equalTo: trailing.leadingAnchor, constant: -Self.gap),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.gap),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingWidth,
        ])
    }

    /// Belt and braces on the field itself, for the strings this cell sets as
    /// plain text: the paragraph style covers the attributed ones.
    private static func makeSingleLine(_ field: NSTextField) {
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TaskCellView is created in code, not from a nib")
    }

    /// A group heading. No marker: the state is the words.
    public func show(_ group: TaskGroupNode) {
        marker.stringValue = ""
        marker.isHidden = true
        decoration = ""
        priority = ""
        taskPriority = 0
        trailing.stringValue = ""
        title.attributedStringValue = NSAttributedString(
            string: group.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: Self.oneLine,
            ])
        markerWidth.constant = 0
        trailingWidth.constant = 0
        setAccessibilityLabel(
            "\(group.state.spoken), \(group.count) \(group.count == 1 ? "task" : "tasks")")
        needsLayout = true
    }

    /// A task.
    public func show(_ row: TaskRowNode) {
        let state = row.task.state
        marker.isHidden = false
        marker.stringValue = state.marker
        marker.textColor = state.isTerminal ? .tertiaryLabelColor : .secondaryLabelColor
        decoration = row.decoration ?? ""
        priority = row.priorityMark ?? ""
        taskPriority = row.task.priority
        trailing.stringValue = ""

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 1),
            .foregroundColor: state.isTerminal ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            .paragraphStyle: Self.oneLine,
        ]
        // Struck through, as the preview draws it: cancelled is the one state
        // whose whole point is that the text no longer applies.
        if state == .cancelled {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        title.attributedStringValue = NSAttributedString(string: row.label, attributes: attributes)

        markerWidth.constant = Self.markerColumn
        fitDecoration()

        // `spoken`, not the raw value, so VoiceOver says "in progress" rather
        // than "in-progress".
        var spoken = "\(state.spoken), \(row.label)"
        if let decoration = row.decoration { spoken += ", \(decoration)" }
        setAccessibilityLabel(spoken)
        needsLayout = true
    }

    public override func layout() {
        // The row's width is a thing only layout knows, and which of the
        // decoration's two parts fit depends on it. Constants, not frames — see
        // the note on this class for why the frames are the constraint engine's.
        super.layout()
        fitDecoration()
    }

    /// Give the row as much of the decoration as it has room for: both parts,
    /// the priority alone, or neither.
    ///
    /// The title is what the row is *for* and the decoration is a hint about it,
    /// so the hint is what gives way — and it gives way by dropping the date
    /// rather than by truncating it, because `2026-0…` is not a date. Nothing is
    /// lost: the full text, tokens and all, is the row's tooltip, and the
    /// document is one click away.
    private func fitDecoration() {
        let allowance = min(
            Self.maximumTrailingWidth,
            max(0, bounds.width - markerWidth.constant) * Self.maximumTrailingShare)
        for candidate in [decoration, priority] where !candidate.isEmpty {
            let width = ceil(Self.width(of: candidate, in: trailing)) + 1
            guard width <= allowance else { continue }
            showTrailing(candidate, width: width)
            return
        }
        showTrailing("", width: 0)
    }

    /// Assigned only when it changes: `fitDecoration` runs from `layout`, and a
    /// string or a constant set every pass would ask for another one.
    private func showTrailing(_ text: String, width: CGFloat) {
        if trailing.stringValue != text {
            trailing.attributedStringValue = attributedTrailing(for: text)
        }
        if trailingWidth.constant != width { trailingWidth.constant = width }
    }

    /// `text` measured in `field`'s font — the field's own string is not
    /// disturbed, because this is asked about a string it may not be showing.
    private static func width(of text: String, in field: NSTextField) -> CGFloat {
        let font = field.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        return NSAttributedString(string: text, attributes: [.font: font]).size().width
    }
}

// MARK: - The container

/// The summary line, the outline view, and the empty-state label, stacked.
///
/// Frame-based for the same reason ``TableOfContentsContainerView`` is: a few
/// children and a subtraction. No header — the pane above it owns that, because
/// it holds the control that chose this tab
/// (`2026-08-28-tabbed-document-pane`).
@MainActor
public final class TaskListContainerView: NSView {

    /// Two lines of small text, or `nil` for none.
    public var summary: String? {
        didSet {
            summaryLabel.stringValue = summary ?? ""
            summaryLabel.isHidden = summary == nil
            needsLayout = true
        }
    }

    /// What to say instead of a list, or `nil` to show the list.
    public var emptyMessage: String? {
        didSet {
            emptyLabel.stringValue = emptyMessage ?? ""
            emptyLabel.isHidden = emptyMessage == nil
            scrollView.isHidden = emptyMessage != nil
            needsLayout = true
        }
    }

    private let summaryLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let scrollView: NSScrollView

    /// The summary line and the list under it, as laid out — for the tests and
    /// for `mark-bench`, which are where "the summary has room for its second
    /// line" is checkable at all.
    public var summaryField: NSTextField { summaryLabel }
    public var listView: NSScrollView { scrollView }

    /// The sidebar's material, for the reason ``TableOfContentsContainerView``
    /// carries one: `mark-bench` hosts these views in a plain window, and a pane
    /// that only looks right inside an `NSSplitViewItem` is a pane whose
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

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        // Two lines, wrapping: the summary is "4 of 5 outstanding" and a
        // five-state breakdown, which fits on one line in a wide sidebar and on
        // two in a 260 pt one. A single-line label would draw the newline as a
        // glyph and clip the rest.
        summaryLabel.usesSingleLineMode = false
        summaryLabel.cell?.wraps = true
        summaryLabel.cell?.isScrollable = false
        // As many lines as the two it is given actually need. It was capped at
        // two, which is a cap on *visual* lines: at a sidebar's real width the
        // breakdown alone wraps past one, and the cap cut it off mid-word —
        // silently, since ``summaryHeight(forWidth:)`` measured the wrapping it
        // was not allowed to do and left a blank strip where the rest should be.
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.isHidden = true
        addSubview(summaryLabel)

        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        addSubview(scrollView)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tasks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TaskListContainerView is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    /// How tall the summary is, given the width it has to wrap in. Measured
    /// rather than assumed: "4 of 5 outstanding" plus a five-state breakdown is
    /// two lines of text and three or four lines of drawing in a narrow sidebar,
    /// and one in a wide one.
    ///
    /// Measured through the *cell*, which is what will draw it: the string's own
    /// `boundingRect` leaves out the couple of points the cell keeps around the
    /// text, and a frame that short loses the last line entirely.
    private func summaryHeight(forWidth width: CGFloat) -> CGFloat {
        guard summary != nil else { return 0 }
        let available = max(0, width - 16)
        guard let cell = summaryLabel.cell else { return 0 }
        let measured = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: available, height: 10_000))
        return ceil(measured.height) + 8
    }

    public override func layout() {
        backing.frame = bounds
        let summaryTop = summaryHeight(forWidth: bounds.width)
        summaryLabel.frame = NSRect(
            x: 8, y: 4, width: max(0, bounds.width - 16), height: max(0, summaryTop - 8))
        let body = NSRect(
            x: 0, y: summaryTop, width: bounds.width, height: max(0, bounds.height - summaryTop))
        scrollView.frame = body
        emptyLabel.frame = NSRect(
            x: 8, y: summaryTop + 4, width: max(0, bounds.width - 16), height: 16)
        super.layout()
    }
}
