import AppKit
import Foundation

/// **File ▸ History** — the files that were opened, in a window of its own.
///
/// `2026-08-26-opened-file-history`. Modelled on ``HelpWindowController`` for
/// the parts that are genuinely the same — a single instance, a strong static
/// ``shared``, teardown on close — and deliberately unlike it in the part that
/// matters most:
///
/// **This window holds no `WKWebView`, so it registers nothing with
/// ``ResidencyGovernor``.** The reference window must register, because it
/// carries ~52 MB of WebContent process and a governor that only counted tabs
/// would under-report the application-wide budget by exactly one web view. A
/// table of paths costs none of that. The two windows differing is the rule the
/// ADR states, not an omission to be tidied up: *the test is the web view, not
/// the window.* `HistoryWindowTests` fails the build if this window ever starts
/// changing the resident count.
///
/// It also holds no ``DocumentTab``, which is what keeps ⌥⌘E's editor and its
/// autosave away from it — the same structural argument the reference window
/// makes for having no tab.
@MainActor
public final class HistoryWindowController: NSWindowController, NSWindowDelegate {

    /// The one that is open, or `nil`. There is never a second.
    ///
    /// **Strong, for ``HelpWindowController/shared``'s documented reason:**
    /// `NSWindow` does not retain its `windowController` and nothing else in
    /// the app holds this one, so a weak reference would deallocate the
    /// controller the instant the menu action returned and take the window with
    /// it. ``tearDown()`` is what releases it.
    public private(set) static var shared: HistoryWindowController?

    /// Open the history, or bring the open one forward.
    @discardableResult
    public static func show(
        history: OpenHistory,
        open: @escaping (URL) -> Void
    ) -> HistoryWindowController {
        if let existing = shared, !existing.isTornDown {
            existing.refresh()
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = HistoryWindowController(history: history, open: open)
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    // MARK: - State

    public let history: OpenHistory

    /// How a row becomes an open document. A closure rather than a reference to
    /// ``WindowCoordinator``, so this window is testable without one and so the
    /// ADR's "opening goes through the existing route" is a thing the caller
    /// supplies rather than a second route defined here.
    private let openDocument: (URL) -> Void

    /// The entries the table is showing: the history, narrowed by the filter.
    private(set) var rows: [OpenHistoryEntry] = []

    /// Which of ``rows`` no longer resolve to a file, by URL.
    ///
    /// Recomputed on ``refresh()`` — at most ``OpenHistory/limit`` `stat`s,
    /// which is not the eager directory walk `TreeViewController` is forbidden
    /// from doing; it is 64 file-exists checks on a list the user is looking at.
    private(set) var missing: Set<URL> = []

    public private(set) var filter: String = ""

    /// How the list is ordered. Which column, and which way.
    ///
    /// Defaults to *last opened, newest first*, because that is what a history
    /// **is** — the other two orders are for finding something in it.
    public private(set) var sort: Sort = .lastOpened
    public private(set) var ascending = false

    public enum Sort: String, Sendable {
        case name, folder, lastOpened
    }

    public private(set) var isTornDown = false

    // MARK: - Views

    let table = HistoryTableView()
    private let search = NSSearchField()
    private let clearButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    public init(history: OpenHistory, open: @escaping (URL) -> Void) {
        self.history = history
        self.openDocument = open

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.minSize = NSSize(width: 420, height: 260)
        window.setFrameAutosaveName("dev.mark.HistoryWindow")
        // Session state is ours, in our own file, and this window is
        // deliberately not in it — the same position the reference window takes.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // `windowWillClose` drops ``shared``, so the controller must still be
        // alive to run it.
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        buildContent()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HistoryWindowController is created in code, not from a nib")
    }

    // MARK: - Building

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))

        search.placeholderString = "Filter"
        search.translatesAutoresizingMaskIntoConstraints = false
        search.target = self
        search.action = #selector(filterChanged(_:))
        // Fires while typing rather than on ↩ — a filter you have to commit
        // reads as a filter that is not working.
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true

        table.translatesAutoresizingMaskIntoConstraints = false
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.allowsMultipleSelection = false
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.onReturn = { [weak self] in self?.openSelected(nil) }
        table.onDelete = { [weak self] in self?.forgetSelected() }

        let name = NSTableColumn(identifier: .init("name"))
        name.title = Self.columnTitles["name"] ?? ""
        name.width = 200
        name.minWidth = 120
        let folder = NSTableColumn(identifier: .init("folder"))
        folder.title = Self.columnTitles["folder"] ?? ""
        folder.width = 260
        folder.minWidth = 120
        let opened = NSTableColumn(identifier: .init("opened"))
        opened.title = Self.columnTitles["opened"] ?? ""
        opened.width = 130
        opened.minWidth = 90
        // **No `sortDescriptorPrototype`, deliberately.** Prototypes are the
        // usual way to make a header sortable, and they are what makes AppKit
        // draw a sort chevron of its own — one it paints on a column the *user*
        // clicked and refuses to paint for an order set in code, and which
        // `setIndicatorImage(nil, in:)` does not remove. That asymmetry cannot
        // produce a header that is right in both states, so this window does
        // not use the mechanism at all: clicks arrive through
        // `tableView(_:didClick:)` and the arrow is drawn in the title.
        table.addTableColumn(name)
        table.addTableColumn(folder)
        table.addTableColumn(opened)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.title = "Clear History"
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearHistory(_:))

        content.addSubview(search)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(clearButton)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            clearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            clearButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        window?.contentView = content
        updateSortIndicator()
    }

    /// Show which column the list is ordered by, and which way.
    ///
    /// **The direction lives in the column's title, not in AppKit's sort
    /// indicator**, and that is a workaround rather than a preference. The
    /// platform way is `setIndicatorImage(_:in:)` with
    /// `NSAscendingSortIndicator`; it was tried first, the image resolves (9×9,
    /// template) and the call is made, and on macOS 26 nothing is painted —
    /// checked against a running build, with the column carrying ~40 pt of
    /// clear space after its title, and with the header explicitly invalidated.
    /// `highlightedTableColumn` *does* work and gives the sorted column its
    /// bold treatment, which is why it is still set here — but bold alone says
    /// which column and not which way, and a header that toggles direction with
    /// no feedback is a control that looks broken.
    ///
    /// So the arrow is a character in the title. It cannot silently stop being
    /// drawn, which is the failure this is recovering from. Called after every
    /// ordering change, the user's own clicks included, where it is idempotent.
    private func updateSortIndicator() {
        let sorted = table.tableColumns.first { $0.identifier.rawValue == sortColumnIdentifier }
        for column in table.tableColumns {
            let base = Self.columnTitles[column.identifier.rawValue] ?? column.title
            column.title = column === sorted ? "\(base) \(ascending ? "▲" : "▼")" : base
        }
        table.highlightedTableColumn = sorted
        // A title change is a model change; `reloadData()` redraws the rows and
        // never the header.
        table.headerView?.needsDisplay = true
    }

    /// Each column's title without a sort arrow on it, so
    /// ``updateSortIndicator()`` can put one back without ever stacking two.
    static let sortForColumn: [String: Sort] = [
        "name": .name, "folder": .folder, "opened": .lastOpened,
    ]

    static let columnTitles = [
        "name": "Name", "folder": "Folder", "opened": "Last Opened",
    ]

    /// The column identifier for the current ``sort``.
    ///
    /// The two spellings differ by one word — the Last Opened column is
    /// `"opened"` because that is what its cells are built from — so the
    /// mapping is written once here rather than at each call site.
    private var sortColumnIdentifier: String {
        switch sort {
        case .name: return "name"
        case .folder: return "folder"
        case .lastOpened: return "opened"
        }
    }

    // MARK: - Refreshing

    /// Re-read the history, re-apply the filter, and re-check what still
    /// exists.
    public func refresh() {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching =
            needle.isEmpty
            ? history.entries
            : history.entries.filter { $0.url.path.lowercased().contains(needle) }
        rows = Self.sorted(matching, by: sort, ascending: ascending)

        // Only the rows on screen are checked, not the whole history: the
        // question "is this file still there" is only being asked about what
        // the reader can see.
        missing = Set(
            rows.map(\.url).filter { !FileManager.default.fileExists(atPath: $0.path) }
        )

        table.reloadData()
        updateEmptyState()
        clearButton.isEnabled = !history.isEmpty
    }

    /// Order `entries`, case-insensitively for the two text columns.
    ///
    /// `localizedStandardCompare` rather than `<`, so `10.md` sorts after
    /// `9.md` and an accented name lands where a reader expects it.
    static func sorted(_ entries: [OpenHistoryEntry], by sort: Sort, ascending: Bool)
        -> [OpenHistoryEntry]
    {
        let ordered: [OpenHistoryEntry]
        switch sort {
        case .name:
            ordered = entries.sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                    == .orderedAscending
            }
        case .folder:
            ordered = entries.sorted {
                $0.url.deletingLastPathComponent().path.localizedStandardCompare(
                    $1.url.deletingLastPathComponent().path) == .orderedAscending
            }
        case .lastOpened:
            // Ascending here means oldest first, so that the flag means the
            // same thing — "the top of the list is the small end" — in all
            // three columns.
            ordered = entries.sorted { $0.lastOpened < $1.lastOpened }
        }
        return ascending ? ordered : ordered.reversed()
    }

    /// Order the list without a header click — the test seam.
    public func setSort(_ sort: Sort, ascending: Bool) {
        self.sort = sort
        self.ascending = ascending
        updateSortIndicator()
        refresh()
    }

    private func updateEmptyState() {
        let empty = rows.isEmpty
        emptyLabel.isHidden = !empty
        scroll.isHidden = empty
        if empty {
            emptyLabel.stringValue =
                history.isEmpty
                ? "No files opened yet."
                : "No files match “\(filter.trimmingCharacters(in: .whitespaces))”."
        }
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: Any?) {
        filter = search.stringValue
        refresh()
    }

    /// Apply a filter without the search field — the test seam, and the one
    /// place ``filter`` is set from outside a control.
    public func setFilter(_ text: String) {
        filter = text
        search.stringValue = text
        refresh()
    }

    /// Open the selected row's file, through the route the caller supplied.
    @objc public func openSelected(_ sender: Any?) {
        guard let entry = selectedEntry() else { return }
        open(entry)
    }

    /// Open one entry.
    ///
    /// A file that has gone says so out loud rather than doing nothing —
    /// `2026-08-26-new-documents-are-files-on-disk`'s position on refusals,
    /// which a row that silently fails to open would break. The entry is
    /// **kept**: an unmounted volume is not a deleted file.
    public func open(_ entry: OpenHistoryEntry) {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            refresh()
            let alert = NSAlert()
            alert.messageText = "“\(entry.url.lastPathComponent)” could not be opened."
            alert.informativeText =
                "There is no file at \(entry.url.path.abbreviatingWithTilde). "
                + "It may have been moved, renamed, or deleted, or it may be on a volume that is not mounted."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        openDocument(entry.url)
    }

    /// ⌫ — forget one file.
    func forgetSelected() {
        guard let entry = selectedEntry() else { return }
        let row = table.selectedRow
        history.remove(entry.url)
        refresh()
        // Keep the selection where the reader's eye is, rather than losing it
        // to the top of the list after every press.
        if !rows.isEmpty {
            let next = min(row, rows.count - 1)
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
    }

    /// Clear History, behind a confirmation.
    ///
    /// Irreversible and the only way to forget, which is exactly the pair of
    /// properties that earns a confirmation.
    @objc public func clearHistory(_ sender: Any?) {
        guard !history.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the history of opened files?"
        alert.informativeText =
            "\(history.count) file\(history.count == 1 ? "" : "s") will be forgotten. "
            + "This cannot be undone, and it does not delete any file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.history.clear()
            self?.refresh()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            confirm(alert.runModal())
        }
    }

    private func selectedEntry() -> OpenHistoryEntry? {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return nil }
        return rows[row]
    }

    // MARK: - Closing

    public func windowDidBecomeKey(_ notification: Notification) {
        // Files come and go while this window sits behind another one; coming
        // forward is the cheapest honest moment to notice.
        refresh()
    }

    public func windowWillClose(_ notification: Notification) {
        tearDown()
    }

    /// Idempotent, because `windowWillClose` and an explicit close from a test
    /// can both arrive.
    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        if HistoryWindowController.shared === self {
            let released = HistoryWindowController.shared
            HistoryWindowController.shared = nil
            // AppKit is usually inside a delegate call *on this object*, so
            // dropping the last reference here would deallocate the receiver
            // out from under the stack — ``HelpWindowController/tearDown()``
            // documents the same hop for the same reason.
            DispatchQueue.main.async { _ = released }
        }
        Log.app.info("history window closed")
    }
}

// MARK: - The table

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// Clicking a column header.
    ///
    /// `tableView(_:didClick:)` rather than `sortDescriptorsDidChange`, for the
    /// reason `buildContent()` gives where the prototypes would have been: this
    /// window owns its ordering outright rather than sharing it with AppKit's
    /// sort machinery.
    ///
    /// Clicking the column already sorted flips the direction. Clicking another
    /// starts it in the direction that column is most useful in — A→Z for the
    /// two text columns, newest first for Last Opened, which is what the window
    /// opens on.
    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let clicked = Self.sortForColumn[tableColumn.identifier.rawValue] else { return }
        setSort(clicked, ascending: clicked == sort ? !ascending : clicked != .lastOpened)
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let isMissing = missing.contains(entry.url)

        let identifier = tableColumn.identifier
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)

        let text: String
        switch identifier.rawValue {
        case "name":
            // The label carries the "missing" state rather than a fourth
            // column: it is a property of the file, and it belongs next to its
            // name where the eye already is.
            text = isMissing
                ? "\(entry.url.lastPathComponent) — missing"
                : entry.url.lastPathComponent
        case "folder":
            text = entry.url.deletingLastPathComponent().path.abbreviatingWithTilde
        default:
            text = Self.relative.localizedString(for: entry.lastOpened, relativeTo: Date())
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = isMissing ? .tertiaryLabelColor : .labelColor
        cell.toolTip = isMissing ? "\(entry.url.path) (missing)" : entry.url.path
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: 12)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// ↩ opens the selected file and ⌫ forgets it.
///
/// A subclass because `NSTableView` has no hook for either: `doubleAction`
/// covers the mouse and nothing covers the keyboard, and a list you can only
/// use with a mouse is not the list this window is for.
@MainActor
public final class HistoryTableView: NSTableView {

    public var onReturn: (() -> Void)?
    public var onDelete: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, Enter
            onReturn?()
        case 51, 117:  // Delete, Forward Delete
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }
}

extension String {
    /// `~/notes` rather than `/Users/someone/notes`.
    ///
    /// `NSString.abbreviatingWithTildeInPath` under a name that reads as a
    /// property, because it is used in two places here and reads badly inline.
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
