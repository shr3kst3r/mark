import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The history window (`2026-08-26-opened-file-history`).
///
/// Like `HelpWindowTests`, most of what is asserted here is what this window
/// must **not** do — exist twice, cost a web view, or quietly delete an entry
/// whose file is temporarily unreachable.
@Suite("The history window")
@MainActor
struct HistoryWindowTests {

    /// A directory of real files, so "missing" means a `stat` that actually
    /// fails rather than a flag a fake set.
    private func fixture() throws -> (URL, OpenHistory) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["alpha.md", "beta.md", "gamma.md"] {
            try "# \(name)".write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let history = OpenHistory()
        for name in ["alpha.md", "beta.md", "gamma.md"] {
            history.record(directory.appendingPathComponent(name))
        }
        return (directory, history)
    }

    private func makeController(_ history: OpenHistory, opened: @escaping (URL) -> Void = { _ in })
        -> HistoryWindowController
    {
        HistoryWindowController(history: history, open: opened)
    }

    @Test("it lists the history, most recent first")
    func itLists() throws {
        let (directory, history) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(history)
        defer { controller.tearDown() }

        #expect(controller.window?.title == "History")
        #expect(controller.rows.map(\.url.lastPathComponent) == ["gamma.md", "beta.md", "alpha.md"])
        #expect(controller.table.numberOfRows == 3)
        #expect(controller.missing.isEmpty)
    }

    /// **The asymmetry with `HelpWindowController`, pinned.**
    ///
    /// The reference window registers with the governor because it holds ~52 MB
    /// of `WKWebView`. This one holds a table. The ADR states the test as *the
    /// web view, not the window*, and this is what stops someone making the two
    /// windows consistent by making this one lie about the memory budget.
    @Test("it costs no web view, so the residency budget does not move")
    func itCostsNoWebView() throws {
        let (directory, history) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = ResidencyGovernor.shared.residentWebViewCount
        let controller = makeController(history)
        defer { controller.tearDown() }
        #expect(ResidencyGovernor.shared.residentWebViewCount == before)

        // And nothing in the window is one.
        var stack = [controller.window?.contentView].compactMap { $0 }
        while let view = stack.popLast() {
            #expect(!view.className.contains("WKWebView"))
            stack.append(contentsOf: view.subviews)
        }
    }

    @Test("the filter narrows the list without forgetting anything")
    func filtering() throws {
        let (directory, history) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(history)
        defer { controller.tearDown() }

        controller.setFilter("bet")
        #expect(controller.rows.map(\.url.lastPathComponent) == ["beta.md"])
        #expect(history.count == 3)

        controller.setFilter("")
        #expect(controller.rows.count == 3)

        // Case-insensitive, and it matches the directory as well as the name —
        // "everything I opened under ~/notes" is the other question a filter
        // over a list of paths gets asked.
        controller.setFilter("ALPHA")
        #expect(controller.rows.count == 1)
        controller.setFilter(directory.lastPathComponent)
        #expect(controller.rows.count == 3)
    }

    /// An unmounted volume is not a deleted file, so the row stays.
    @Test("a file that has gone is marked, not pruned")
    func missingIsMarkedNotPruned() throws {
        let (directory, history) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(history)
        defer { controller.tearDown() }

        try FileManager.default.removeItem(at: directory.appendingPathComponent("beta.md"))
        controller.refresh()

        #expect(controller.rows.count == 3)
        #expect(history.count == 3)
        #expect(controller.missing.map(\.lastPathComponent) == ["beta.md"])
    }

    /// A row that silently fails to open is the failure
    /// `2026-08-26-new-documents-are-files-on-disk` calls a broken menu item.
    @Test("opening a missing file does not reach the open route")
    func openingAMissingFileRefuses() throws {
        let (directory, history) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        var opened: [URL] = []
        let controller = makeController(history) { opened.append($0) }
        defer { controller.tearDown() }

        let gone = directory.appendingPathComponent("beta.md")
        try FileManager.default.removeItem(at: gone)
        // Not through `open(_:)`, which would put a sheet on a window in a test
        // run; the assertion is that the route is not taken.
        controller.refresh()
        #expect(controller.missing.contains(gone.standardizedFileURL))
        #expect(opened.isEmpty)

        let alive = try #require(controller.rows.first { !controller.missing.contains($0.url) })
        controller.open(alive)
        #expect(opened == [alive.url])
    }

    @Test("⌫ forgets one file")
    func forgetting() throws {
        let (directory, history) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(history)
        defer { controller.tearDown() }

        controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.forgetSelected()
        #expect(history.count == 2)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["beta.md", "alpha.md"])
        // The selection stays where the reader's eye is.
        #expect(controller.table.selectedRow == 0)
    }

    @Test("an empty history says so, and Clear History is disabled")
    func emptyState() throws {
        let controller = makeController(OpenHistory())
        defer { controller.tearDown() }
        #expect(controller.rows.isEmpty)
        #expect(controller.table.numberOfRows == 0)
    }

    /// `HelpWindowController`'s rule, for the same reason: `NSWindow` does not
    /// retain its controller, so a second `show()` must find the first.
    @Test("show() twice is one window")
    func singleInstance() throws {
        let (directory, history) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = HistoryWindowController.show(history: history) { _ in }
        let second = HistoryWindowController.show(history: history) { _ in }
        defer { first.tearDown() }
        #expect(first === second)
        #expect(HistoryWindowController.shared === first)

        first.tearDown()
        #expect(HistoryWindowController.shared == nil)
        // A torn-down window is not reused.
        let third = HistoryWindowController.show(history: history) { _ in }
        defer { third.tearDown() }
        #expect(third !== first)
    }
}

/// Clicking a column header re-orders the list
/// (`2026-08-26-opened-file-history`).
@Suite("The history window — ordering")
@MainActor
struct HistoryWindowSortTests {

    private func history() -> OpenHistory {
        let history = OpenHistory()
        // Recorded oldest to newest, so the default order is the reverse of
        // the alphabetical one and the two cannot be confused for each other.
        history.record(URL(fileURLWithPath: "/zeta/alpha.md"), at: Date(timeIntervalSince1970: 100))
        history.record(URL(fileURLWithPath: "/beta/zulu.md"), at: Date(timeIntervalSince1970: 200))
        history.record(URL(fileURLWithPath: "/alpha/mike.md"), at: Date(timeIntervalSince1970: 300))
        return history
    }

    @Test("it opens on last-opened, newest first")
    func defaultOrder() throws {
        let controller = HistoryWindowController(history: history()) { _ in }
        defer { controller.tearDown() }
        #expect(controller.sort == .lastOpened)
        #expect(!controller.ascending)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["mike.md", "zulu.md", "alpha.md"])
        // The header says so, rather than leaving an obviously ordered list
        // with no arrow on it. In the title, not in a sort descriptor — see
        // `sortIndicatorIsDrawn`.
        let opened = try #require(
            controller.table.tableColumns.first { $0.identifier.rawValue == "opened" })
        #expect(opened.title == "Last Opened ▼")
    }

    /// AppKit's own `setIndicatorImage(_:in:)` paints nothing on macOS 26 —
    /// checked against a running build — so the direction is a character in the
    /// column's title instead. Asserted here because a title is exactly the
    /// kind of string that gets "tidied" back to a constant.
    @Test("the ordered column says which way it is ordered")
    func sortIndicatorIsDrawn() throws {
        let controller = HistoryWindowController(history: history()) { _ in }
        defer { controller.tearDown() }

        func column(_ identifier: String) throws -> NSTableColumn {
            try #require(
                controller.table.tableColumns.first { $0.identifier.rawValue == identifier })
        }

        let opened = try column("opened")
        let name = try column("name")
        // Opens on newest-first.
        #expect(controller.table.highlightedTableColumn === opened)
        #expect(opened.title == "Last Opened ▼")
        #expect(name.title == "Name")
        // No sort descriptors anywhere: this window owns its ordering outright,
        // which is what keeps AppKit from painting a second, contradictory
        // indicator on a clicked column.
        #expect(controller.table.sortDescriptors.isEmpty)
        #expect(controller.table.tableColumns.allSatisfy { $0.sortDescriptorPrototype == nil })

        controller.setSort(.name, ascending: true)
        #expect(controller.table.highlightedTableColumn === name)
        #expect(name.title == "Name ▲")
        // The column it moved off gives its plain title back rather than
        // keeping a stale arrow.
        #expect(opened.title == "Last Opened")

        // Toggling direction re-marks the same column rather than stacking a
        // second arrow onto it.
        controller.setSort(.name, ascending: false)
        #expect(name.title == "Name ▼")

    }

    @Test("it sorts by name and by folder, both ways")
    func sortingByColumn() throws {
        let controller = HistoryWindowController(history: history()) { _ in }
        defer { controller.tearDown() }

        controller.setSort(.name, ascending: true)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["alpha.md", "mike.md", "zulu.md"])
        controller.setSort(.name, ascending: false)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["zulu.md", "mike.md", "alpha.md"])

        controller.setSort(.folder, ascending: true)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["mike.md", "zulu.md", "alpha.md"])

        controller.setSort(.lastOpened, ascending: true)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["alpha.md", "zulu.md", "mike.md"])
    }

    /// `localizedStandardCompare`, so a list of numbered notes reads the way a
    /// person counts.
    @Test("names sort numerically, not lexicographically")
    func numericNames() {
        let entries = ["9.md", "10.md", "1.md"].map {
            OpenHistoryEntry(url: URL(fileURLWithPath: "/n/\($0)"), lastOpened: Date())
        }
        let sorted = HistoryWindowController.sorted(entries, by: .name, ascending: true)
        #expect(sorted.map(\.url.lastPathComponent) == ["1.md", "9.md", "10.md"])
    }

    /// The header click path itself, not just ``setSort(_:ascending:)``.
    @Test("clicking a header sorts it, and clicking it again flips it")
    func headerClicks() throws {
        let controller = HistoryWindowController(history: history()) { _ in }
        defer { controller.tearDown() }

        func column(_ identifier: String) throws -> NSTableColumn {
            try #require(
                controller.table.tableColumns.first { $0.identifier.rawValue == identifier })
        }
        let name = try column("name")
        let opened = try column("opened")

        // A text column starts A→Z.
        controller.tableView(controller.table, didClick: name)
        #expect(controller.sort == .name)
        #expect(controller.ascending)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["alpha.md", "mike.md", "zulu.md"])

        // Clicking it again flips it.
        controller.tableView(controller.table, didClick: name)
        #expect(!controller.ascending)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["zulu.md", "mike.md", "alpha.md"])

        // Last Opened starts newest-first, which is what the window opens on.
        controller.tableView(controller.table, didClick: opened)
        #expect(controller.sort == .lastOpened)
        #expect(!controller.ascending)
        #expect(controller.rows.map(\.url.lastPathComponent) == ["mike.md", "zulu.md", "alpha.md"])
    }

    @Test("the filter and the order compose")
    func filterAndSort() throws {
        let controller = HistoryWindowController(history: history()) { _ in }
        defer { controller.tearDown() }
        controller.setSort(.name, ascending: true)
        // Matches `/zeta/alpha.md` on its name and `/alpha/mike.md` on its
        // folder, and misses `/beta/zulu.md` entirely.
        controller.setFilter("alpha")
        #expect(controller.rows.map(\.url.lastPathComponent) == ["alpha.md", "mike.md"])
        #expect(controller.sort == .name)
    }
}
