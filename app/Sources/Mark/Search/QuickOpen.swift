import AppKit
import Foundation

/// Ranking file paths against what someone has typed.
///
/// Subsequence matching, the way every "open quickly" works: `rbk` finds
/// `deploys/runbook.md` because those letters appear in that order. Written
/// here rather than delegated to the core, and that is not a contradiction of
/// `2026-09-01-search-in-the-core` — that ADR is about *document* search, where
/// a second regex dialect would make `mark grep` and the window disagree about
/// what a pattern means. Nothing in the CLI ranks filenames, so there is no
/// second implementation to drift from, and the scoring is a feel decision that
/// belongs next to the list it orders.
public enum QuickOpenScore {

    /// How well `query` matches `path`, or `nil` if it does not.
    ///
    /// Higher is better. The scoring exists to answer one question well: when
    /// someone types `read`, `README.md` has to come above
    /// `notes/already-done.md`, even though both contain those letters in
    /// order. So:
    ///
    /// * matches in the **filename** count more than matches in the directory
    ///   part, because that is what people are typing;
    /// * **consecutive** characters count much more than scattered ones;
    /// * a match at the **start of a word** — after `/`, `-`, `_`, `.`, or a
    ///   case change — counts more than one in the middle.
    ///
    /// Case-insensitive, but an exact-case hit breaks ties, so `Makefile`
    /// outranks `makefile-notes` for `M`.
    public static func score(_ path: String, query: String) -> Int? {
        if query.isEmpty { return 0 }

        let haystack = Array(path)
        let needle = Array(query)
        // Where the filename begins, so its characters can be worth more.
        // Indexed into `haystack` rather than into `path`, because everything
        // below counts array positions and mixing the two is how an offset
        // lands a character out on a path with any non-ASCII in it.
        let nameStart = haystack.lastIndex(of: "/").map { $0 + 1 } ?? 0

        var total = 0
        var index = 0
        var previousMatch = -2

        for (position, wanted) in needle.enumerated() {
            var found: Int?
            var cursor = index
            while cursor < haystack.count {
                if haystack[cursor].lowercased() == wanted.lowercased() {
                    found = cursor
                    break
                }
                cursor += 1
            }
            guard let at = found else { return nil }

            var points = 1
            if at >= nameStart { points += 8 }
            if at == previousMatch + 1 { points += 12 }
            if isBoundary(haystack, at) { points += 6 }
            if haystack[at] == wanted { points += 2 }
            // An early match in the name is worth more than a late one, so a
            // short name beats a long one that merely contains the letters.
            if position == 0 && at == nameStart { points += 10 }

            total += points
            previousMatch = at
            index = at + 1
        }

        // Shorter paths win ties: `notes.md` over `archive/2019/notes.md` when
        // both match equally well.
        return total * 100 - haystack.count
    }

    /// Whether the character at `index` starts a word.
    private static func isBoundary(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous == "/" || previous == "-" || previous == "_" || previous == "." || previous == " " {
            return true
        }
        // A case change, so `runBook` has a boundary at `B`.
        return previous.isLowercase && characters[index].isUppercase
    }
}

/// **File ▸ Open Quickly…** (⌥⌘O) — jumping to a note by name from anywhere
/// below the sidebar's root.
///
/// The gap: the sidebar's filter matches names, but only among rows that are
/// already expanded (`TreeDataSource.matchesFilter`, which is deliberate — the
/// tree must never walk ahead of what you opened). So there was no way to reach
/// a file three directories down without navigating to it. This is the other
/// half of ⇧⌘F: that one finds notes by what is *in* them, this one by what
/// they are *called*.
///
/// A panel rather than a window, because it is modal in feel and transient in
/// life: it takes the keyboard, you type, you press ↩, it goes away. Escape
/// closes it and nothing is remembered.
@MainActor
public final class QuickOpenController: NSWindowController, NSWindowDelegate {

    public private(set) static var shared: QuickOpenController?

    @discardableResult
    public static func show(root: URL, open: @escaping (URL) -> Void) -> QuickOpenController {
        if let existing = shared, !existing.isTornDown {
            existing.setRoot(root)
            existing.window?.makeKeyAndOrderFront(nil)
            existing.focusField()
            return existing
        }
        let controller = QuickOpenController(root: root, open: open)
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusField()
        return controller
    }

    // MARK: - State

    private let openDocument: (URL) -> Void
    public private(set) var root: URL
    public private(set) var query: String = ""

    /// Every markdown file below the root, relative to it. Loaded once when the
    /// panel opens and not watched: a panel that is on screen for four seconds
    /// does not need to notice a file appearing, and the alternative is a
    /// recursive walk on a timer.
    public private(set) var candidates: [String] = []

    /// What the list is showing, best first.
    public private(set) var rows: [String] = []

    /// The most a list is ever worth showing. Beyond this nobody scrolls; they
    /// type another letter.
    public nonisolated static let visibleLimit = 40

    public private(set) var isTornDown = false
    private var loadTask: _Concurrency.Task<Void, Never>?

    // MARK: - Views

    let table = QuickOpenTableView()
    private let field = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()

    public init(root: URL, open: @escaping (URL) -> Void) {
        self.root = root
        self.openDocument = open

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Open Quickly"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("dev.mark.QuickOpenPanel")

        super.init(window: panel)
        panel.delegate = self
        buildContent()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("QuickOpenController is created in code, not from a nib")
    }

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 380))

        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Open quickly"
        field.font = .systemFont(ofSize: 15)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(openSelected(_:))

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.rowHeight = 22
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        let column = NSTableColumn(identifier: .init("path"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        content.addSubview(field)
        content.addSubview(statusLabel)
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 5),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window?.contentView = content
    }

    public func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    // MARK: - Driving

    public func setRoot(_ root: URL) {
        guard root != self.root else { return }
        self.root = root
        reload()
    }

    /// Walk the root for markdown files. Off the main actor: it is a recursive
    /// listing, and the reader gets to point the sidebar at anything.
    func reload() {
        loadTask?.cancel()
        let root = self.root
        statusLabel.stringValue = "Looking…"
        loadTask = _Concurrency.Task { @MainActor [weak self] in
            let found = await _Concurrency.Task.detached(priority: .userInitiated) {
                () -> [String] in
                guard
                    let entries = try? MarkCore.tree(
                        directory: root.path, depth: 0, withStats: false)
                else { return [] }
                let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                return entries
                    .filter { !$0.isDirectory }
                    .map { entry in
                        entry.path.hasPrefix(prefix)
                            ? String(entry.path.dropFirst(prefix.count)) : entry.path
                    }
            }.value
            guard !_Concurrency.Task.isCancelled, let self else { return }
            self.candidates = found
            self.rank()
        }
    }

    func setQueryForTesting(_ text: String) {
        field.stringValue = text
        query = text
        rank()
    }

    /// Order the candidates against the query and show the best of them.
    func rank() {
        if query.isEmpty {
            // No query: the list is what is there, alphabetically, so the panel
            // is useful before you have typed anything.
            rows = Array(candidates.sorted().prefix(Self.visibleLimit))
        } else {
            rows =
                candidates
                .compactMap { path -> (String, Int)? in
                    QuickOpenScore.score(path, query: query).map { (path, $0) }
                }
                // Sorted by score, then by path, so an equal-scoring pair has a
                // stable order rather than whichever the walk happened to hit.
                .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
                .prefix(Self.visibleLimit)
                .map(\.0)
        }
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateStatus()
    }

    private func updateStatus() {
        if candidates.isEmpty {
            statusLabel.stringValue = "No markdown files below \(root.lastPathComponent)"
            return
        }
        if rows.isEmpty {
            statusLabel.stringValue = "No matches in \(candidates.count) files"
            return
        }
        let shown = rows.count < candidates.count ? "\(rows.count) of \(candidates.count)" : "\(rows.count)"
        statusLabel.stringValue = "\(shown) in \(root.lastPathComponent)"
    }

    // MARK: - Acting

    @objc public func openSelected(_ sender: Any?) {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        let relative = rows[table.selectedRow]
        openDocument(root.appendingPathComponent(relative))
        close()
    }

    /// ↑ and ↓ move the list while the caret stays in the field. Without this
    /// the arrows move the caret and the panel is a list you cannot reach.
    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let next = max(0, min(rows.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: - Lifetime

    public func windowWillClose(_ notification: Notification) {
        tearDown()
    }

    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        loadTask?.cancel()
        loadTask = nil
        table.dataSource = nil
        table.delegate = nil
        field.delegate = nil
        window?.delegate = nil
        if Self.shared === self { Self.shared = nil }
    }
}

extension QuickOpenController: NSTextFieldDelegate {

    public func controlTextDidChange(_ notification: Notification) {
        query = field.stringValue
        rank()
    }

    public func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

extension QuickOpenController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("quickOpenCell")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingHead
                cell.addSubview(text)
                cell.textField = text
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()

        let path = rows[row]
        // The name in full strength and the folder in grey: the name is what
        // was typed at, and the folder is what tells two `index.md`s apart.
        let attributed = NSMutableAttributedString()
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        attributed.append(
            NSAttributedString(
                string: name,
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        if !directory.isEmpty {
            attributed.append(
                NSAttributedString(
                    string: "  \(directory)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
        }
        cell.textField?.attributedStringValue = attributed
        cell.textField?.toolTip = path
        return cell
    }
}

/// ↩ opens, like the field's own action. Needed because focus can be in the
/// table after a click.
@MainActor
public final class QuickOpenTableView: NSTableView {
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            sendAction(doubleAction, to: target)
            return
        }
        super.keyDown(with: event)
    }
}
