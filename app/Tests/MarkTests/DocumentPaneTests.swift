import AppKit
import Foundation
import Testing

@testable import MarkKit

/// A `UserDefaults` domain that exists for one test and is removed afterwards.
///
/// The pane's tab is a real preference (`2026-08-28-tabbed-document-pane`), so
/// the production default is `UserDefaults.standard` — and a test run that wrote
/// there would change which tab the developer's own window opens on. Every test
/// here injects one of these instead.
final class VolatileDefaults {

    let name = "dev.mark.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name) ?? .standard
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: name)
    }
}

/// A task as the core would emit one. Only the fields the pane reads are
/// meaningful; the rest are left at values a test cannot pass by coincidence.
private func task(
    _ index: Int, _ state: TaskState, _ text: String, label: String? = nil,
    start: Int = 0, priority: Int = 0, due: String? = nil
) -> Task {
    Task(
        index: index,
        state: state,
        checked: state.isTerminal,
        start: start == 0 ? 100 + index * 20 : start,
        end: (start == 0 ? 100 + index * 20 : start) + 3,
        line: index + 2,
        text: text,
        label: label ?? text,
        tags: [],
        due: due,
        startDate: nil,
        done: nil,
        priority: priority
    )
}

@Suite("The document pane")
@MainActor
struct DocumentPaneTests {

    // MARK: The mode, and where it is remembered

    @Test("a pane with nothing remembered opens on the outline")
    func defaultModeIsContents() {
        let preferences = VolatileDefaults()
        let pane = DocumentPaneController(
            contents: TableOfContentsViewController(), taskList: TaskListViewController(),
            backlinks: BacklinksViewController(), defaults: preferences.defaults)
        _ = pane.view
        #expect(pane.mode == .contents)
        #expect(pane.activeChild === pane.contents)
    }

    @Test("the tab is remembered across panes")
    func modeSurvivesRebuild() {
        let preferences = VolatileDefaults()
        let first = DocumentPaneController(
            contents: TableOfContentsViewController(), taskList: TaskListViewController(),
            backlinks: BacklinksViewController(), defaults: preferences.defaults)
        _ = first.view
        first.mode = .tasks

        let second = DocumentPaneController(
            contents: TableOfContentsViewController(), taskList: TaskListViewController(),
            backlinks: BacklinksViewController(), defaults: preferences.defaults)
        _ = second.view
        #expect(second.mode == .tasks)
        #expect(second.activeChild === second.taskList)
    }

    /// A preference file is a thing other software, other builds and a
    /// `defaults write` can put anything into. Anything but a known tab reads as
    /// the outline rather than crashing or blanking the pane.
    @Test("an unknown remembered tab reads as the outline")
    func unknownStoredModeReadsAsContents() {
        let preferences = VolatileDefaults()
        preferences.defaults.set("outline-v2", forKey: DocumentPaneController.modeDefaultsKey)
        let pane = DocumentPaneController(
            contents: TableOfContentsViewController(), taskList: TaskListViewController(),
            backlinks: BacklinksViewController(), defaults: preferences.defaults)
        _ = pane.view
        #expect(pane.mode == .contents)
    }

    /// Out of the hierarchy, not hidden: a hidden `NSScrollView` still lays out
    /// and still answers hit tests, and two outline views in one rectangle is
    /// exactly what this repo cannot see.
    @Test("switching the tab installs one child and removes the other")
    func switchingModeSwapsTheChildView() throws {
        let preferences = VolatileDefaults()
        let pane = DocumentPaneController(
            contents: TableOfContentsViewController(), taskList: TaskListViewController(),
            backlinks: BacklinksViewController(), defaults: preferences.defaults)
        let container = try #require(pane.view as? DocumentPaneContainerView)

        #expect(pane.contents.view.superview === container)
        #expect(pane.taskList.view.superview == nil)

        pane.mode = .tasks
        #expect(pane.taskList.view.superview === container)
        #expect(pane.contents.view.superview == nil)
        #expect(container.selectedIndex == 1)

        pane.mode = .contents
        #expect(pane.contents.view.superview === container)
        #expect(pane.taskList.view.superview == nil)
        #expect(container.selectedIndex == 0)
    }

    @Test("the header's control picks the tab")
    func headerControlPicksTheMode() throws {
        let preferences = VolatileDefaults()
        let pane = DocumentPaneController(
            contents: TableOfContentsViewController(), taskList: TaskListViewController(),
            backlinks: BacklinksViewController(), defaults: preferences.defaults)
        let container = try #require(pane.view as? DocumentPaneContainerView)
        #expect(container.tabs.segmentCount == 3)
        #expect(container.tabs.label(forSegment: 0) == "Contents")
        #expect(container.tabs.label(forSegment: 1) == "Tasks")

        container.tabs.selectedSegment = 1
        container.onSelect?(1)
        #expect(pane.mode == .tasks)
    }

    // MARK: The menu rule

    /// One rule for both items: show the pane on this tab, or hide the pane if
    /// this tab is already showing. It is what makes the pair read as a choice.
    @Test("each menu item shows its tab, or hides the pane if that tab is showing")
    func menuRule() {
        let preferences = VolatileDefaults()
        let controller = MainWindowController(
            root: URL(fileURLWithPath: "/tmp"), preferences: preferences.defaults)
        _ = controller.sidebarPane.view
        #expect(controller.documentPaneIsShowing(.contents))

        // ⌃⌘Y from the outline switches tab rather than hiding anything.
        controller.toggleTaskList(nil)
        #expect(controller.documentPaneIsShowing(.tasks))
        #expect(!controller.documentPaneIsShowing(.contents))

        // ⌃⌘Y again hides the pane, because tasks was already the one showing.
        controller.toggleTaskList(nil)
        #expect(!controller.sidebarPane.isDocumentPaneVisible)
        #expect(!controller.documentPaneIsShowing(.tasks))

        // ⌃⌘T from hidden brings the pane back on the outline.
        controller.toggleTableOfContents(nil)
        #expect(controller.documentPaneIsShowing(.contents))
        // And the tree is never what these items hide.
        #expect(!controller.sidebar.view.isHidden)
    }

    @Test("the two items are validated as a choice, not as two toggles")
    func menuValidation() throws {
        let preferences = VolatileDefaults()
        let controller = MainWindowController(
            root: URL(fileURLWithPath: "/tmp"), preferences: preferences.defaults)
        _ = controller.sidebarPane.view

        let contentsItem = NSMenuItem(
            title: "Show Table of Contents",
            action: #selector(MainWindowController.toggleTableOfContents(_:)), keyEquivalent: "t")
        let tasksItem = NSMenuItem(
            title: "Show Tasks", action: #selector(MainWindowController.toggleTaskList(_:)),
            keyEquivalent: "y")

        #expect(controller.validateMenuItem(contentsItem))
        #expect(controller.validateMenuItem(tasksItem))
        #expect(contentsItem.state == .on)
        #expect(tasksItem.state == .off)

        controller.toggleTaskList(nil)
        _ = controller.validateMenuItem(contentsItem)
        _ = controller.validateMenuItem(tasksItem)
        #expect(contentsItem.state == .off)
        #expect(tasksItem.state == .on)

        // Hidden pane: neither is ticked, and both still work.
        controller.toggleTaskList(nil)
        _ = controller.validateMenuItem(contentsItem)
        _ = controller.validateMenuItem(tasksItem)
        #expect(contentsItem.state == .off)
        #expect(tasksItem.state == .off)
    }

    // MARK: Grouping

    private static let sample: [Task] = [
        task(0, .open, "open one"),
        task(1, .open, "open two"),
        task(2, .inProgress, "in progress"),
        task(3, .done, "done"),
        task(4, .cancelled, "cancelled"),
        task(5, .blocked, "blocked"),
    ]

    /// Outstanding first, in marker order, then the two that are finished with —
    /// deliberately not `TaskState.allCases`, which would put done between
    /// in-progress and blocked.
    @Test("groups are outstanding first, and a state with no tasks builds no group")
    func groupsAreOutstandingFirstAndSkipEmptyStates() {
        let groups = TaskListViewController.group(Self.sample)
        #expect(groups.map(\.state) == [.open, .inProgress, .blocked, .done, .cancelled])
        #expect(groups.map(\.count) == [2, 1, 1, 1, 1])
        #expect(groups[0].title == "Open (2)")
        #expect(groups[2].title == "Blocked (1)")

        let onlyOpen = TaskListViewController.group([task(0, .open, "just this")])
        #expect(onlyOpen.map(\.state) == [.open])
    }

    @Test("document order is kept inside a group")
    func documentOrderWithinAGroup() {
        let groups = TaskListViewController.group([
            task(0, .open, "first", start: 10),
            task(1, .done, "middle", start: 30),
            task(2, .open, "second", start: 50),
        ])
        let open = try? #require(groups.first { $0.state == .open })
        #expect(open?.rows.map(\.label) == ["first", "second"])
        #expect(open?.rows.map(\.task.start) == [10, 50])
    }

    // MARK: The summary line

    /// Both numbers come from `TaskCounts`. The pane must not re-derive the
    /// arithmetic `2026-08-27-five-task-states` fixed — outstanding is open +
    /// in-progress + blocked, and cancelled is the only state that leaves the
    /// denominator.
    @Test("the summary is the badge's arithmetic and a breakdown of what is there")
    func summaryComesFromTaskCounts() {
        let pane = TaskListViewController()
        _ = pane.view
        pane.show(
            Self.sample, counts: TaskCounts(Self.sample),
            for: URL(fileURLWithPath: "/tmp/a.md"))

        let summary = pane.summary
        #expect(summary?.hasPrefix("4 of 5 outstanding") == true)
        #expect(summary?.contains("2 open") == true)
        #expect(summary?.contains("1 in progress") == true)
        #expect(summary?.contains("1 blocked") == true)
        #expect(summary?.contains("1 done") == true)
        #expect(summary?.contains("1 cancelled") == true)
        // Every state is counted from the counts, never from the groups.
        #expect(pane.count(of: .cancelled) == 1)
    }

    @Test("a state with no tasks is left out of the breakdown rather than shown as zero")
    func summaryOmitsZeroes() {
        let tasks = [task(0, .open, "a"), task(1, .open, "b")]
        let pane = TaskListViewController()
        _ = pane.view
        pane.show(tasks, counts: TaskCounts(tasks), for: URL(fileURLWithPath: "/tmp/a.md"))
        #expect(pane.summary == "2 of 2 outstanding\n2 open")
        #expect(pane.summary?.contains("cancelled") == false)
    }

    @Test("a document whose every task was cancelled has no denominator to talk about")
    func summaryWithNothingActive() {
        let tasks = [task(0, .cancelled, "dropped")]
        let pane = TaskListViewController()
        _ = pane.view
        pane.show(tasks, counts: TaskCounts(tasks), for: URL(fileURLWithPath: "/tmp/a.md"))
        // `active` is zero, so "0 of 0 outstanding" would be noise.
        #expect(pane.summary == "1 cancelled")
    }

    // MARK: Rows

    /// `2026-08-27-inline-task-metadata`: the tokens are still in the document
    /// and still in the preview. A row shows the stripped label and puts the
    /// priority where a person can see it without reading `!!` in the text.
    @Test("a row shows the label, not the raw text")
    func rowsShowLabelNotText() {
        let node = TaskRowNode(
            task(0, .open, "ship it @work !!", label: "ship it", priority: 2, due: "2026-09-01"))
        #expect(node.label == "ship it")
        #expect(node.decoration == "!!  2026-09-01")
    }

    @Test("a task with no metadata has nothing trailing it")
    func rowWithoutDecoration() {
        #expect(TaskRowNode(task(0, .open, "plain")).decoration == nil)
    }

    // MARK: The cell, as laid out

    /// A row 32 pt tall in a 260 pt sidebar — the outline view's own row height
    /// and the width `dev.mark.SidebarSplit` restores.
    private static func laidOutCell(
        _ configure: (TaskCellView) -> Void, width: CGFloat = 260
    ) -> (cell: TaskCellView, rects: [NSRect]) {
        let cell = TaskCellView(identifier: NSUserInterfaceItemIdentifier("TaskCell"))
        configure(cell)
        cell.frame = NSRect(x: 0, y: 0, width: width, height: 32)
        cell.layoutSubtreeIfNeeded()
        // Alignment rects rather than frames: a label's frame carries a couple
        // of points of bleed on each side that no one can see, and asserting on
        // it would fail for a row that looks perfect.
        return (cell, cell.fields.map { $0.alignmentRect(forFrame: $0.frame) })
    }

    /// The regression this whole cell exists to hold: the marker, the text and
    /// the decoration in three columns, none of them over another and none of
    /// them outside the row. They overlapped because the frames were set in
    /// `layout()`, where `NSTableCellView` puts its own `textField` back.
    @Test("a row's marker, title and decoration sit side by side, inside the row")
    func rowFieldsDoNotOverlap() {
        let (_, rects) = Self.laidOutCell {
            $0.show(
                TaskRowNode(
                    task(
                        0, .open, "a task long enough that it has to be truncated in a sidebar",
                        priority: 2, due: "2026-09-01")))
        }
        let (marker, title, trailing) = (rects[0], rects[1], rects[2])
        #expect(marker.minX >= 0)
        #expect(marker.maxX <= title.minX, "the marker is drawn over the first letters")
        #expect(title.maxX <= trailing.minX, "the title runs under the due date")
        #expect(trailing.maxX <= 260)
        for rect in rects {
            #expect(rect.minY >= 0 && rect.maxY <= 32, "\(rect) leaves the row")
        }
    }

    /// One line, truncated at the tail. The paragraph style is the assertion
    /// because it is the thing that was missing: `lineBreakMode` on the field is
    /// discarded by `attributedStringValue`, and the row wrapped to two lines
    /// and drew over the row below it.
    @Test("a long task truncates on one line rather than wrapping")
    func longTaskTruncatesRatherThanWrapping() throws {
        let (cell, rects) = Self.laidOutCell {
            $0.show(
                TaskRowNode(
                    task(0, .open, String(repeating: "an unreasonably long task ", count: 8))))
        }
        let title = cell.fields[1]
        let style = try #require(
            title.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle)
        #expect(style.lineBreakMode == .byTruncatingTail)
        #expect(title.maximumNumberOfLines == 1)
        #expect(rects[1].height <= 20, "the title is taller than one line, so it wrapped")
    }

    /// Wrapping is just as wrong on a group heading, which is the same label
    /// with a different string in it.
    @Test("a group heading is one line too, and leaves the marker column out")
    func groupHeadingIsOneLine() throws {
        let (cell, rects) = Self.laidOutCell {
            $0.show(TaskGroupNode(state: .inProgress, tasks: [task(0, .inProgress, "one")]))
        }
        let title = cell.fields[1]
        let style = try #require(
            title.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle)
        #expect(style.lineBreakMode == .byTruncatingTail)
        #expect(title.stringValue == "In progress (1)")
        #expect(cell.fields[0].isHidden, "a group row has no marker")
        #expect(rects[1].minX <= 2, "the heading is indented into the marker's column")
    }

    /// The decoration is a hint about the row and the title is the row, so a
    /// narrow pane drops the date rather than shrinking `WEB-1890 …` to `WEB…`.
    /// It drops it whole: `2026-0…` is not a date.
    @Test("a narrow row keeps the priority and drops the due date")
    func decorationGivesWayToTheTitle() {
        let dated = TaskRowNode(
            task(0, .open, "WEB-1890 - fix the duplicated navigation links", priority: 2,
                due: "2026-09-01"))

        let (wide, _) = Self.laidOutCell({ $0.show(dated) }, width: 340)
        #expect(wide.fields[2].stringValue == "!!  2026-09-01")

        let (narrow, _) = Self.laidOutCell({ $0.show(dated) }, width: 200)
        #expect(narrow.fields[2].stringValue == "!!")

        // Nothing to fall back to: a date with no priority leaves the row
        // rather than taking two fifths of it. 150 pt is the sidebar dragged
        // about as narrow as it goes.
        let undated = TaskRowNode(
            task(1, .open, "Chase the printer for the proof copies", due: "2026-08-30"))
        let (bare, _) = Self.laidOutCell({ $0.show(undated) }, width: 150)
        #expect(bare.fields[2].stringValue == "")
        // …and the tooltip still has all of it, which is what makes the drop
        // safe: `outlineView(_:toolTipFor:…)` answers with `task.text`.
        #expect(undated.task.text.contains("printer"))
    }

    @Test("priority marks are coloured by level: gray, orange, red")
    func priorityMarksAreColoured() {
        let p1 = TaskRowNode(task(0, .open, "low priority", priority: 1, due: "2026-09-01"))
        let p2 = TaskRowNode(task(1, .open, "med priority", priority: 2, due: "2026-09-01"))
        let p3 = TaskRowNode(task(2, .open, "high priority", priority: 3, due: "2026-09-01"))

        let (cell1, _) = Self.laidOutCell({ $0.show(p1) }, width: 340)
        let (cell2, _) = Self.laidOutCell({ $0.show(p2) }, width: 340)
        let (cell3, _) = Self.laidOutCell({ $0.show(p3) }, width: 340)

        let color1 = cell1.fields[2].attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let color2 = cell2.fields[2].attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let color3 = cell3.fields[2].attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(color1 == NSColor.secondaryLabelColor)
        #expect(color2 == NSColor.systemOrange)
        #expect(color3 == NSColor.systemRed)

        // The date remains tertiaryLabelColor
        let dateColor = cell2.fields[2].attributedStringValue.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        #expect(dateColor == NSColor.tertiaryLabelColor)
    }

    // MARK: The summary line, as laid out

    /// The breakdown wraps past two lines in a narrow sidebar. It was capped at
    /// two while the container reserved room for all of them, so the pane drew a
    /// blank strip where the rest of the sentence should have been.
    @Test("the summary line has room for every line it draws")
    func summaryIsNotClipped() throws {
        let pane = TaskListViewController()
        let container = try #require(pane.view as? TaskListContainerView)
        pane.show(
            Self.sample, counts: TaskCounts(Self.sample),
            for: URL(fileURLWithPath: "/tmp/a.md"))

        for width in [180.0, 260.0, 420.0] {
            container.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            container.layoutSubtreeIfNeeded()
            let label = container.summaryField
            let needed = try #require(
                label.cell?.cellSize(
                    forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)
                ).height)
            #expect(
                label.maximumNumberOfLines == 0,
                "a cap on lines is a cap on the sentence")
            #expect(
                label.frame.height >= needed - 0.5,
                "at \(width) pt the summary has \(label.frame.height) pt for \(needed) pt of text")
            #expect(
                container.listView.frame.minY >= label.frame.maxY,
                "at \(width) pt the list starts inside the summary")
        }
    }

    // MARK: Empty states

    /// "No tasks in this document" and "no document open" are different facts,
    /// and one label for both reads as a bug the first time you see it.
    @Test("the empty state names which of the two nothings it is")
    func emptyStateNamesTheMode() throws {
        let pane = TaskListViewController()
        let container = try #require(pane.view as? TaskListContainerView)
        #expect(pane.emptyMessage == "No document open")
        #expect(container.emptyMessage == "No document open")

        pane.show([], counts: .empty, for: URL(fileURLWithPath: "/tmp/a.md"))
        #expect(pane.emptyMessage == "No tasks")
        #expect(container.emptyMessage == "No tasks")
        #expect(container.summary == nil, "nothing to summarise")

        pane.show(Self.sample, counts: TaskCounts(Self.sample), for: URL(fileURLWithPath: "/tmp/a.md"))
        #expect(pane.emptyMessage == nil)
        #expect(container.emptyMessage == nil)
    }

    // MARK: Rebuilding

    /// ``show(_:counts:for:)`` is called from `updateChrome()`, on every tab
    /// switch and every metadata load. A reload per call would drop the
    /// selection and the disclosure triangles under the reader's cursor.
    @Test("an unchanged document does not rebuild the list")
    func noRebuildWhenNothingChanged() {
        let pane = TaskListViewController()
        _ = pane.view
        let url = URL(fileURLWithPath: "/tmp/a.md")
        pane.show(Self.sample, counts: TaskCounts(Self.sample), for: url)
        let before = pane.groups
        pane.show(Self.sample, counts: TaskCounts(Self.sample), for: url)
        #expect(pane.groups.count == before.count)
        for (old, new) in zip(before, pane.groups) {
            #expect(old === new, "the nodes were rebuilt for an unchanged document")
        }
    }

    @Test("a changed document does rebuild")
    func rebuildsOnChange() {
        let pane = TaskListViewController()
        _ = pane.view
        let url = URL(fileURLWithPath: "/tmp/a.md")
        pane.show(Self.sample, counts: TaskCounts(Self.sample), for: url)
        let before = pane.groups

        // The click a reader just made in the preview: one open task is done.
        var changed = Self.sample
        changed[0] = task(0, .done, "open one")
        pane.show(changed, counts: TaskCounts(changed), for: url)
        #expect(pane.groups.first?.state == .open)
        #expect(pane.groups.first?.count == 1)
        #expect(pane.groups.first !== before.first)
        #expect(pane.summary?.hasPrefix("3 of 5 outstanding") == true)
    }

    /// Collapse is keyed by state rather than by node, because a refresh throws
    /// every node away — and by state rather than by document, because the five
    /// states are the same five everywhere.
    @Test("done and cancelled start collapsed, and a collapse survives a rebuild")
    func collapseSurvivesARebuild() {
        let pane = TaskListViewController()
        _ = pane.view
        let url = URL(fileURLWithPath: "/tmp/a.md")
        pane.show(Self.sample, counts: TaskCounts(Self.sample), for: url)

        let outline = pane.outlineView!
        let done = try? #require(pane.groups.first { $0.state == .done })
        let open = try? #require(pane.groups.first { $0.state == .open })
        #expect(done.map { outline.isItemExpanded($0) } == false)
        #expect(open.map { outline.isItemExpanded($0) } == true)

        // Collapse an outstanding group by hand, then change the document.
        if let open { outline.collapseItem(open) }
        var changed = Self.sample
        changed.append(task(6, .open, "open three"))
        pane.show(changed, counts: TaskCounts(changed), for: url)

        let openAgain = try? #require(pane.groups.first { $0.state == .open })
        #expect(openAgain.map { outline.isItemExpanded($0) } == false)
        #expect(openAgain?.count == 3)
    }

    // MARK: Navigating, and never writing

    @Test("clicking a task reports it, and the pane writes nothing")
    func selectionReportsTheTask() {
        let pane = TaskListViewController()
        _ = pane.view
        pane.show(
            Self.sample, counts: TaskCounts(Self.sample),
            for: URL(fileURLWithPath: "/tmp/a.md"))

        var picked: [Task] = []
        pane.onSelect = { picked.append($0) }

        // The row a reader clicks, reached the way the outline view reaches it.
        let blocked = pane.groups.first { $0.state == .blocked }?.rows.first
        pane.onSelect?(blocked!.task)
        #expect(picked.map(\.index) == [5])
        #expect(picked.first?.state == .blocked)
        // The byte offset is what the preview is scrolled by — an index alone
        // renumbers (`2026-08-28-tabbed-document-pane`).
        #expect(picked.first?.start == Self.sample[5].start)
    }

    /// The pane is a navigation control and nothing else. This is the
    /// source-level half of that: a future edit that reaches for a writer here
    /// trips this test rather than shipping a second caller of the locked
    /// one-byte write path.
    @Test("the Tasks pane's source mentions no task writer")
    func paneNeverWrites() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Mark/Sidebar/TaskListViewController.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for forbidden in ["TaskWriter", "taskWriter", "mark_toggle", "TaskToggle", "write("] {
            #expect(
                !text.contains(forbidden),
                "the Tasks pane must not write: found \(forbidden)")
        }
    }

    // MARK: Navigating a real page

    /// The link the click path rests on, asserted against a real `WKWebView`
    /// running the shipped `shell.js`: the byte offset the core reports for a
    /// task is the `data-mk-start` the rendered page carries, so the pane can
    /// scroll to it. A Swift-side model of the DOM would agree with itself.
    @Test("every task the pane lists is one the page can scroll to")
    func tasksResolveInThePage() async throws {
        var source = "# Tasks\n\n- [ ] first\n- [/] second\n- [?] third\n- [-] fourth\n\n"
        // Long enough that the last task is well below the fold, which is what
        // makes the background fill part of the test rather than an assumption.
        for index in 0..<200 {
            source += "Paragraph \(index) of filler.\n\n"
        }
        source += "- [x] last\n"

        let harness = try await PatchHarness(source)
        let tasks = try MarkCore.tasks(source: source)
        #expect(tasks.count == 5)
        for task in tasks {
            #expect(
                try await harness.view.scrollToTask(index: task.index, byteOffset: task.start),
                "the page has no task at byte \(task.start)")
        }

        // The honest answer for a task the page does not hold — the same shape
        // `mark goto` gives for a missing anchor, and what makes the window log
        // it rather than move the preview somewhere arbitrary.
        #expect(
            !(try await harness.view.scrollToTask(index: 99, byteOffset: 999_999)))

        // The byte offset wins over the index, which is the whole reason both
        // are passed: an index that names a *different* task still lands on the
        // one the offset names.
        let last = try #require(tasks.last)
        #expect(try await harness.view.scrollToTask(index: 0, byteOffset: last.start))
        let y = try await harness.view.call("return window.mark.scrollPosition().y;") as? Double
        #expect((y ?? 0) > 0, "the page scrolled to the task near the end, not to task 0")
    }

    // MARK: The window, end to end

    @Test("opening a document fills the tab on screen")
    func followsTheFrontDocument() async throws {
        let fixture = try TabFixture()
        let preferences = VolatileDefaults()
        let controller = MainWindowController(
            root: fixture.directory, session: fixture.session, preferences: preferences.defaults)
        _ = controller.sidebarPane.view
        let url = try fixture.makeExtendedDocument()
        let tab = controller.tabs.open(url)

        // Contents is the tab showing, so it is the one that fills.
        #expect(await waitFor { !controller.toc.headings.isEmpty })
        #expect(controller.taskList.tasks.isEmpty, "the off-screen tab is not built")

        controller.toggleTaskList(nil)
        // Three outstanding of four active, two cancelled out of the
        // denominator — the fixture exists for exactly that arithmetic.
        #expect(controller.taskList.counts == tab.metadata?.taskCounts)
        #expect(controller.taskList.counts.outstanding == 3)
        #expect(controller.taskList.counts.active == 4)
        #expect(controller.taskList.summary?.hasPrefix("3 of 4 outstanding") == true)
        #expect(
            controller.taskList.groups.map(\.state)
                == [.open, .inProgress, .blocked, .done, .cancelled])
    }

    /// The pane is fed lazily, and the rule is pinned here so a later "why not
    /// just feed both?" has an answer with a number in it: grouping the 1,787
    /// tasks in `bench/corpus/1mb.md` is 1.9 ms, before the outline reload of
    /// ~1,800 rows, and a tab switch would pay it for a tab nobody is looking
    /// at.
    ///
    /// Filled *before* the swap, so the tab that appears is never showing the
    /// document the reader was on two clicks ago.
    @Test("the tab that becomes visible is filled before it is installed")
    func theOffScreenTabIsFilledOnDemand() async throws {
        let fixture = try TabFixture()
        let preferences = VolatileDefaults()
        let controller = MainWindowController(
            root: fixture.directory, session: fixture.session, preferences: preferences.defaults)
        _ = controller.sidebarPane.view

        let first = try fixture.makeExtendedDocument(named: "first.md")
        controller.tabs.open(first)
        #expect(await waitFor { !controller.toc.headings.isEmpty })
        #expect(controller.taskList.tasks.isEmpty)

        // Switching to Tasks fills it from the document on screen…
        controller.toggleTaskList(nil)
        #expect(controller.taskList.tasks.count == 6)

        // …and switching document while Tasks is showing keeps it current,
        // while the outline is now the one left behind.
        let second = fixture.file(named: "a.md")
        let secondTab = controller.tabs.open(second)
        #expect(await waitFor { controller.taskList.counts.open == 3 })
        #expect(controller.taskList.counts == secondTab.metadata?.taskCounts)
    }

    /// The bug `2026-08-28-tabbed-document-pane` names, end to end and with
    /// nothing stubbed: a file edited by anything at all comes back through the
    /// watcher, which used to reload the tab bar and nothing else. The pane has
    /// to move with it, or ticking a box leaves it showing the state the reader
    /// just clicked away from.
    @Test("a file changed on disk moves the pane, not just the tab badge")
    func fileChangeReachesThePane() async throws {
        let harness = try RoundTripHarness()
        harness.controller.documentPane.mode = .tasks
        let tab = try await harness.open(
            "# A\n\n- [ ] one\n- [ ] two\n- [/] three\n", named: "a.md")
        let pane = harness.controller.taskList
        #expect(await harness.waitUntil("the pane to fill") { !pane.tasks.isEmpty })
        #expect(pane.counts.open == 2)
        #expect(pane.summary?.hasPrefix("3 of 3 outstanding") == true)

        // The bytes a `mark check` or another editor leaves behind.
        try harness.saveAtomically("# A\n\n- [x] one\n- [ ] two\n- [/] three\n", to: "a.md")
        #expect(await harness.waitUntil("the pane to follow the file") { pane.counts.open == 1 })
        #expect(pane.counts.done == 1)
        #expect(pane.groups.first { $0.state == .open }?.count == 1)
        #expect(pane.summary?.hasPrefix("2 of 3 outstanding") == true)
        #expect(tab.metadata?.taskCounts == pane.counts, "the badge and the pane agree")
    }

    /// The same loop from the other end: a real click on a real checkbox in the
    /// page, which is the gesture the pane exists alongside.
    @Test("clicking a checkbox in the preview moves the pane")
    func previewClickReachesThePane() async throws {
        let harness = try RoundTripHarness()
        harness.controller.documentPane.mode = .tasks
        _ = try await harness.open("# A\n\n- [ ] one\n- [ ] two\n", named: "a.md")
        let pane = harness.controller.taskList
        #expect(await harness.waitUntil("the pane to fill") { pane.counts.open == 2 })

        try await harness.clickCheckbox(at: 0, in: #require(harness.controller.tabs.selected))
        #expect(await harness.waitUntil("the pane to follow the click") { pane.counts.done == 1 })
        #expect(pane.counts.open == 1)
        #expect(pane.groups.map(\.state) == [.open, .done])
    }

    private func waitFor(
        timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
