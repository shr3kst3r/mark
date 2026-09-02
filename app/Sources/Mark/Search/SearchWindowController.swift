import AppKit
import Foundation

/// **Edit ▸ Find ▸ Find in Folder…** (⇧⌘F) — searching every note below the
/// sidebar's root.
///
/// The gap this closes: `mark grep` has answered the useful question since M1 —
/// it reports the heading each hit sits under, so a result reads
/// `notes.md › Deploys › Rollback` rather than `notes.md:412` — and nothing in
/// the window called it. The sidebar's filter is name-only and, deliberately,
/// covers only rows already on screen (`TreeDataSource.matchesFilter`). For a
/// tool whose subject is a directory of notes, "find that note" was missing.
///
/// # Why a window, not a sidebar pane
///
/// The same argument `2026-08-26-opened-file-history` makes for History: this
/// holds no web view, so opening it costs nothing from the residency budget
/// (ADR-4's ~52 MB per resident page), and it can be as wide as it needs to be.
/// A result row is a path, a breadcrumb, and a line of prose; the sidebar is
/// none of those wide.
///
/// # Why the search runs off the main actor
///
/// It opens every markdown file below the root. That is fine on a notes
/// directory and is not fine on a home directory, and the reader gets to point
/// the sidebar wherever they like. So every search is a detached task, the
/// previous one is cancelled when the pattern changes, and a result that
/// arrives for a pattern the reader has already typed past is dropped rather
/// than shown.
@MainActor
public final class SearchWindowController: NSWindowController, NSWindowDelegate {

    /// The one that is open, or `nil`.
    ///
    /// Strong, for the reason ``HistoryWindowController/shared`` documents:
    /// `NSWindow` does not retain its `windowController`, so a weak reference
    /// would deallocate this the instant the menu action returned.
    public private(set) static var shared: SearchWindowController?

    @discardableResult
    public static func show(
        root: URL,
        open: @escaping (URL, Int) -> Void
    ) -> SearchWindowController {
        if let existing = shared, !existing.isTornDown {
            existing.setRoot(root)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.focusSearchField()
            return existing
        }
        let controller = SearchWindowController(root: root, open: open)
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusSearchField()
        return controller
    }

    // MARK: - State

    /// How a row becomes an open document, scrolled to the hit. A closure
    /// rather than a reference to ``WindowCoordinator``, so this window is
    /// testable without one — the same shape History uses.
    private let openDocument: (URL, Int) -> Void

    public private(set) var root: URL
    public private(set) var pattern: String = ""
    public private(set) var ignoreCase = true
    public private(set) var rows: [SearchMatch] = []
    public private(set) var truncated = false
    public private(set) var isTornDown = false

    /// The hits any one search will report.
    ///
    /// A cap, because this runs on every keystroke and a one-letter pattern
    /// over a real tree has more hits than anyone will read. The window says so
    /// rather than silently showing a prefix.
    public nonisolated static let resultLimit = 500

    /// How long the field waits after a keystroke before searching.
    ///
    /// Long enough that typing a word is one search rather than five, short
    /// enough to feel like it is keeping up. The same reasoning, and roughly
    /// the same value, as the editor's autosave debounce.
    static let debounce: Duration = .milliseconds(180)

    /// The search in flight. Cancelled when the pattern changes, so a slow
    /// search over a large tree cannot land on top of a newer one.
    private var searchTask: _Concurrency.Task<Void, Never>?

    /// Bumped on every request. A result whose generation is stale is dropped —
    /// belt to `searchTask`'s braces, since cancellation is cooperative and the
    /// core call is not interruptible once it has started.
    private var generation: UInt64 = 0

    // MARK: - Views

    let table = SearchTableView()
    private let field = NSSearchField()
    private let scopeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let caseButton = NSButton()
    private let scroll = NSScrollView()

    public init(root: URL, open: @escaping (URL, Int) -> Void) {
        self.root = root
        self.openDocument = open

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Find in Folder"
        window.minSize = NSSize(width: 480, height: 260)
        window.setFrameAutosaveName("dev.mark.SearchWindow")
        // Session state is ours, in our own file, and this window is
        // deliberately not in it — the position History and the reference both
        // take.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        buildContent()
        updateScope()
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearchWindowController is created in code, not from a nib")
    }

    // MARK: - Building

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))

        field.placeholderString = "Find in folder"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(patternChanged(_:))
        // Fires while typing. A search box you have to commit reads as one that
        // is not working — and the debounce below is what makes that
        // affordable.
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true

        caseButton.translatesAutoresizingMaskIntoConstraints = false
        caseButton.setButtonType(.switch)
        caseButton.title = "Ignore case"
        caseButton.state = ignoreCase ? .on : .off
        caseButton.target = self
        caseButton.action = #selector(caseChanged(_:))

        scopeLabel.translatesAutoresizingMaskIntoConstraints = false
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.font = .systemFont(ofSize: 11)
        scopeLabel.lineBreakMode = .byTruncatingHead

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.alignment = .right

        table.translatesAutoresizingMaskIntoConstraints = false
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.headerView = NSTableHeaderView()
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.onReturn = { [weak self] in self?.openSelected(nil) }

        let file = NSTableColumn(identifier: .init("file"))
        file.title = "File"
        file.width = 180
        file.minWidth = 100
        let heading = NSTableColumn(identifier: .init("heading"))
        heading.title = "Section"
        heading.width = 200
        heading.minWidth = 80
        let text = NSTableColumn(identifier: .init("text"))
        text.title = "Match"
        text.width = 340
        text.minWidth = 140
        table.addTableColumn(file)
        table.addTableColumn(heading)
        table.addTableColumn(text)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        content.addSubview(field)
        content.addSubview(caseButton)
        content.addSubview(scopeLabel)
        content.addSubview(statusLabel)
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(
                equalTo: caseButton.leadingAnchor, constant: -10),

            caseButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            caseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scopeLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            scopeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scopeLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -10),

            statusLabel.centerYAnchor.constraint(equalTo: scopeLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: scopeLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window?.contentView = content
    }

    /// Drive the field the way typing does, for tests.
    ///
    /// Setting `stringValue` does not fire the action — AppKit only does that
    /// for real input — so a test that set it and waited would be asserting on
    /// a search that never started.
    func setPatternForTesting(_ text: String) {
        field.stringValue = text
        patternChanged(nil)
    }

    public func focusSearchField() {
        window?.makeFirstResponder(field)
    }

    // MARK: - Driving

    /// Point the search at a different folder — the sidebar moved, or the
    /// window was reopened from somewhere else.
    public func setRoot(_ root: URL) {
        guard root != self.root else { return }
        self.root = root
        updateScope()
        runSearch()
    }

    @objc private func patternChanged(_ sender: Any?) {
        pattern = field.stringValue
        runSearch()
    }

    @objc private func caseChanged(_ sender: Any?) {
        ignoreCase = caseButton.state == .on
        runSearch()
    }

    /// Debounce, then search off the main actor, then show the result if it is
    /// still the one being asked for.
    func runSearch() {
        searchTask?.cancel()
        generation &+= 1
        let generation = self.generation

        let pattern = self.pattern
        guard !pattern.isEmpty else {
            rows = []
            truncated = false
            table.reloadData()
            updateStatus()
            return
        }

        let root = self.root.path
        let ignoreCase = self.ignoreCase
        searchTask = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: Self.debounce)
            guard !_Concurrency.Task.isCancelled, let self, generation == self.generation else {
                return
            }

            let found = await _Concurrency.Task.detached(priority: .userInitiated) {
                () -> SearchResults? in
                try? MarkCore.search(
                    root: root,
                    pattern: pattern,
                    limit: Self.resultLimit,
                    ignoreCase: ignoreCase)
            }.value

            guard generation == self.generation else { return }
            // `nil` is an invalid pattern, which is the normal state of a
            // regex halfway through being typed — `(` is not an error worth
            // showing, it is a person still going. The previous results stay
            // and the status line says so.
            guard let found else {
                self.updateStatus(invalidPattern: true)
                return
            }
            self.rows = found.matches
            self.truncated = found.truncated
            self.table.reloadData()
            self.updateStatus(files: found.files)
        }
    }

    private func updateScope() {
        scopeLabel.stringValue = "in \(root.path.abbreviatingWithTilde)"
    }

    private func updateStatus(files: Int? = nil, invalidPattern: Bool = false) {
        if invalidPattern {
            statusLabel.stringValue = "…"
            return
        }
        if pattern.isEmpty {
            statusLabel.stringValue = ""
            return
        }
        if rows.isEmpty {
            statusLabel.stringValue = "No results"
            return
        }
        let hits = rows.count == 1 ? "1 result" : "\(rows.count) results"
        // `truncated` comes from the core rather than from `count == limit`,
        // which is ambiguous when a tree holds exactly that many.
        let more = truncated ? " (first \(Self.resultLimit))" : ""
        let scanned = files.map { $0 == 1 ? " in 1 file" : " in \($0) files" } ?? ""
        statusLabel.stringValue = hits + more + scanned
    }

    // MARK: - Acting

    @objc public func openSelected(_ sender: Any?) {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let match = rows[table.selectedRow]
        openDocument(URL(fileURLWithPath: match.path), match.offset)
    }

    // MARK: - Lifetime

    public func windowWillClose(_ notification: Notification) {
        tearDown()
    }

    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        searchTask?.cancel()
        searchTask = nil
        table.dataSource = nil
        table.delegate = nil
        window?.delegate = nil
        if Self.shared === self { Self.shared = nil }
    }
}

extension SearchWindowController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < rows.count, let column = tableColumn else { return nil }
        let match = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("cell.\(column.identifier.rawValue)")

        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingTail
                text.font = .systemFont(ofSize: 12)
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()

        switch column.identifier.rawValue {
        case "file":
            let name = (match.path as NSString).lastPathComponent
            cell.textField?.stringValue = "\(name):\(match.line)"
            cell.textField?.toolTip = match.path.abbreviatingWithTilde
        case "heading":
            // The thing that makes this more than grep. Empty above the first
            // heading, and an em dash reads better there than a blank cell.
            cell.textField?.stringValue = match.heading.isEmpty ? "—" : match.heading
            cell.textField?.textColor =
                match.heading.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
            cell.textField?.toolTip = match.heading.isEmpty ? nil : match.heading
        default:
            // The hit picked out of its line, using the span the core reported
            // rather than searching the line again with an engine that might
            // disagree about where the match was.
            cell.textField?.attributedStringValue = match.styled(
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                highlight: .findHighlightColor)
            cell.textField?.textColor = .labelColor
        }
        return cell
    }
}

/// A subclass for the one thing `NSTableView` has no hook for: ↩ on the
/// keyboard. `doubleAction` covers the mouse, and a result list you can only
/// use with a mouse is not the list this window is for.
@MainActor
public final class SearchTableView: NSTableView {

    public var onReturn: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:  // Return, Enter
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }
}
