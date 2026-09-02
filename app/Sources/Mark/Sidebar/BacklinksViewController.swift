import AppKit
import Foundation

/// The sidebar's third document tab: **what points at this document**.
///
/// Contents answers "what is in this note" and Tasks answers "what is left in
/// it". Both are questions about the document alone, and both are free —
/// `2026-08-28-tabbed-document-pane` notes that neither costs an extra file
/// read, because the `toc` and `mark_tasks_json` calls behind them are ones the
/// tab badge already pays for.
///
/// This one is not free, and that is the whole design problem. "What points
/// here" needs every other note, which is one parse per markdown file below the
/// sidebar's root. So:
///
/// * It is computed **only when this tab is on screen**, through the same
///   `onNeedsContent` hook the other two use to stay lazy.
/// * It runs **off the main actor** and is cancelled when the document changes,
///   so switching tabs quickly never queues a pile of tree walks.
/// * It shows what it is doing, because on a large notes tree it is the one
///   thing in this pane that can take a visible moment.
///
/// A row is the linking document, the heading the link sits under, and the
/// link's own text — what the *other* document calls this one, which is more
/// useful than repeating the filename you are already looking at.
@MainActor
public final class BacklinksViewController: NSViewController {

    /// A backlink was picked. The window opens that document at that byte.
    public var onSelect: ((URL, Int) -> Void)?

    public private(set) var links: [Backlink] = []

    /// The document the list is about, and the root it was searched under.
    public private(set) var document: URL?
    public private(set) var root: URL?

    public private(set) var isSearching = false

    private var searchTask: _Concurrency.Task<Void, Never>?

    let table = BacklinksTableView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")

    public override func loadView() {
        let container = NSView()

        table.translatesAutoresizingMaskIntoConstraints = false
        table.headerView = nil
        table.rowHeight = 34
        table.allowsMultipleSelection = false
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onReturn = { [weak self] in self?.openSelected() }
        let column = NSTableColumn(identifier: .init("backlink"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        container.addSubview(scroll)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -12),
        ])
        view = container
        updateStatus()
    }

    /// Show the backlinks for `document`, searched under `root`.
    ///
    /// Cancels whatever was in flight. Called only while this tab is on screen.
    public func show(_ document: URL?, root: URL?) {
        searchTask?.cancel()
        self.document = document
        self.root = root
        links = []
        table.reloadData()

        guard let document, let root else {
            isSearching = false
            updateStatus()
            return
        }

        isSearching = true
        updateStatus()
        searchTask = _Concurrency.Task { @MainActor [weak self] in
            let found = await _Concurrency.Task.detached(priority: .userInitiated) {
                () -> [Backlink] in
                (try? MarkCore.backlinks(root: root.path, target: document.path)) ?? []
            }.value
            guard !_Concurrency.Task.isCancelled, let self else { return }
            // The document may have changed while the walk ran. Dropping the
            // answer is right: showing one note's backlinks under another's
            // name is worse than showing none.
            guard self.document == document else { return }
            self.links = found
            self.isSearching = false
            self.table.reloadData()
            self.updateStatus()
        }
    }

    /// Recompute for the document already showing — after an edit, or when the
    /// tab becomes visible again.
    public func refresh() {
        show(document, root: root)
    }

    private func updateStatus() {
        statusLabel.isHidden = !links.isEmpty
        if document == nil {
            statusLabel.stringValue = "No document."
        } else if isSearching {
            statusLabel.stringValue = "Looking…"
        } else if links.isEmpty {
            // Naming the folder, because "nothing links here" is only true of
            // somewhere, and the sidebar root is a thing the reader moves.
            let where_ = root?.lastPathComponent ?? "this folder"
            statusLabel.stringValue = "Nothing in \u{201C}\(where_)\u{201D} links here."
        } else {
            statusLabel.stringValue = ""
        }
    }

    @objc private func openSelected() {
        guard table.selectedRow >= 0, table.selectedRow < links.count else { return }
        let link = links[table.selectedRow]
        onSelect?(URL(fileURLWithPath: link.path), link.offset)
    }
}

extension BacklinksViewController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { links.count }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row < links.count else { return nil }
        let link = links[row]
        let identifier = NSUserInterfaceItemIdentifier("backlinkCell")

        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let title = NSTextField(labelWithString: "")
                title.translatesAutoresizingMaskIntoConstraints = false
                title.lineBreakMode = .byTruncatingTail
                title.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
                let detail = NSTextField(labelWithString: "")
                detail.translatesAutoresizingMaskIntoConstraints = false
                detail.lineBreakMode = .byTruncatingHead
                detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
                detail.textColor = .secondaryLabelColor
                detail.identifier = .init("detail")
                cell.addSubview(title)
                cell.addSubview(detail)
                cell.textField = title
                NSLayoutConstraint.activate([
                    title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
                    detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                    detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                    detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
                ])
                return cell
            }()

        // The link's own text, which is what the other document calls this one.
        // Falling back to the filename for an image or a bare link, where there
        // is no text to show.
        let label = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
        cell.textField?.stringValue =
            label.isEmpty ? (link.path as NSString).lastPathComponent : label

        let detail = cell.subviews.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "detail" }
        var parts = [(link.path as NSString).lastPathComponent]
        if !link.heading.isEmpty { parts.append(link.heading) }
        if let fragment = link.fragment { parts.append("#\(fragment)") }
        detail?.stringValue = parts.joined(separator: "  ·  ")
        cell.toolTip = "\(link.path):\(link.line)"
        return cell
    }
}

/// ↩ opens, like a double-click. The other two document tabs are keyboard-
/// navigable and this one has to be too.
@MainActor
public final class BacklinksTableView: NSTableView {
    public var onReturn: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
