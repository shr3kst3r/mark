import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// A real window controller — tab store, hydration, file watcher — over a
/// throwaway directory.
///
/// The whole M5 loop is only testable here: the click handler is in the page,
/// the write is in the core, the notification is in the kernel, and the patch
/// is back in the page. Any stub in that chain would test the stub.
@MainActor
final class RoundTripHarness {

    let fixture: PatchFixture
    let controller: MainWindowController

    init(residentLimit: Int = TabStore.defaultResidentLimit) throws {
        fixture = try PatchFixture()
        controller = MainWindowController(
            root: fixture.directory,
            session: Session(
                url: fixture.directory.appendingPathComponent("session.json"), debounce: 0.05)
        )
        controller.tabs.residentLimit = residentLimit
    }

    @discardableResult
    func open(_ source: String, named name: String) async throws -> DocumentTab {
        let url = try fixture.write(source, to: name)
        controller.open(url)
        let tab = try #require(controller.tabs.tab(for: url))
        await tab.documentView?.awaitReady()
        await tab.documentView?.ensureFullyRendered()
        return tab
    }

    /// A save the way vim does it: temp file, then rename over the target, so
    /// the inode changes.
    func saveAtomically(_ source: String, to name: String) throws {
        let temp = fixture.directory.appendingPathComponent(".\(name).swp-\(UUID().uuidString)")
        try source.write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(
            fixture.directory.appendingPathComponent(name), withItemAt: temp)
    }

    func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(10),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for \(what)")
        return false
    }

    func settle(_ duration: Duration = .milliseconds(500)) async {
        try? await _Concurrency.Task.sleep(for: duration)
    }

    /// Click a checkbox the way a reader does: a real click event in the page,
    /// through `shell.js`'s listener and the script bridge.
    ///
    /// `position` is the box's place **in document order on screen**, not its
    /// `data-mk-idx`. That distinction is the whole point: a reader clicks the
    /// third box they can see, and whether the app writes the third task
    /// depends entirely on the attribute the patch left on it. Selecting by
    /// `data-mk-idx` here would quietly make the trap untestable — a page with
    /// stale attributes has no box with the index the test asked for, so the
    /// click would find nothing and the test would fail for the wrong reason.
    func clickCheckbox(at position: Int, in tab: DocumentTab) async throws {
        let view = try #require(tab.documentView)
        let clicked = try await view.call(
            """
            var boxes = document.querySelectorAll('#mk-doc input.mk-task');
            if (!boxes[at]) return false;
            boxes[at].click();
            return true;
            """,
            arguments: ["at": position]
        )
        #expect((clicked as? Bool) == true, "the document has no checkbox at position \(position)")
    }

    func contents(of name: String) throws -> String {
        try String(
            contentsOf: fixture.directory.appendingPathComponent(name), encoding: .utf8)
    }
}

@Suite("The M5 round trip — click, write, watch, patch")
@MainActor
struct WatchRoundTripTests {

    /// **Gate 1.** Click a checkbox in the GUI → the file on disk changes by
    /// exactly one byte → the watcher fires → the document patches.
    ///
    /// Nothing here flips the box optimistically: `shell.js` calls
    /// `preventDefault`, so what the reader ends up looking at is what the file
    /// says, arrived at by re-reading the file.
    @Test("clicking a checkbox writes one byte and the watcher patches the document")
    func theRoundTrip() async throws {
        let harness = try RoundTripHarness()
        let source = "# Tasks\n\n- [ ] first\n\nnote\n\n- [ ] second\n"
        let tab = try await harness.open(source, named: "tasks.md")
        let before = try Data(contentsOf: tab.url)

        try await harness.clickCheckbox(at: 1, in: tab)

        #expect(
            await harness.waitUntil("the file to change") {
                (try? Data(contentsOf: tab.url)) != before
            })
        let after = try Data(contentsOf: tab.url)
        #expect(after.count == before.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 1, "more than one byte changed")
        #expect(try harness.contents(of: "tasks.md") == "# Tasks\n\n- [ ] first\n\nnote\n\n- [x] second\n")

        // The watcher, not the click, is what moved the DOM.
        //
        // Selected on `data-mk-state`, not on `[checked]`: the two agree for
        // done, but `checked` in the core's JSON means "terminal" and so is
        // true for a cancelled marker that draws unticked
        // (`2026-08-27-five-task-states`). Asserting on the attribute the
        // stylesheet actually paints from is the assertion that stays true.
        #expect(
            await harness.waitUntil("the DOM to catch up") {
                let done = try? await tab.documentView?.call(
                    "return document.querySelectorAll('#mk-doc input.mk-task[data-mk-state=\"done\"]').length;"
                )
                return ((done as? NSNumber)?.intValue ?? 0) == 1
            })
        #expect(tab.documentView?.renderedSource == (try harness.contents(of: "tasks.md")))
    }

    /// A plain click on a marker that is not open or done ticks it, derived in
    /// the page rather than read off a property the browser can no longer
    /// compute. All three extended markers, through one page.
    @Test("a plain click on an extended marker ticks it")
    func plainClickTicksAnExtendedMarker() async throws {
        let harness = try RoundTripHarness()
        let tab = try await harness.open("- [/] one\n\n***\n\n- [?] two\n\n***\n\n- [-] three\n", named: "x.md")

        for position in 0..<3 {
            try await harness.clickCheckbox(at: position, in: tab)
            #expect(
                await harness.waitUntil("task \(position) to be ticked") {
                    let tasks = try? MarkCore.tasks(source: harness.contents(of: "x.md"))
                    return tasks?[position].state == .done
                },
                "clicking \(position) left \((try? harness.contents(of: "x.md")) ?? "?")")
        }
    }

    /// The right-click state picker, end to end: the page reports the marker
    /// and where it was clicked, the app builds a five-item menu, and picking
    /// an item goes down the same write path a plain click takes — one byte,
    /// no second writer.
    ///
    /// `2026-08-27-five-task-states`: *"reaching any other state is explicit:
    /// ⌥-click or the context menu in the app."*
    @Test("right-clicking a checkbox offers five states, and picking one writes it")
    func rightClickPicksAState() async throws {
        let harness = try RoundTripHarness()
        let source = "# Tasks\n\n- [/] started\n"
        let tab = try await harness.open(source, named: "tasks.md")
        let view = try #require(tab.documentView)

        // `NSMenu.popUp` is modal, so the menu is captured rather than shown.
        var captured: (menu: NSMenu, point: NSPoint)?
        view.presentMenu = { menu, point in captured = (menu, point) }

        let dispatched = try await view.call(
            """
            var box = document.querySelector('#mk-doc input.mk-task');
            if (!box) return false;
            box.dispatchEvent(new MouseEvent("contextmenu", {
              bubbles: true, cancelable: true, clientX: 40, clientY: 120
            }));
            return true;
            """)
        #expect((dispatched as? Bool) == true)

        #expect(await harness.waitUntil("the menu to be built") { captured != nil })
        let menu = try #require(captured?.menu)
        #expect(menu.items.count == 5, "one item per state")
        #expect(
            menu.items.map(\.title) == TaskState.allCases.map(DocumentView.menuTitle(for:)))
        // The state the marker is already in is ticked and not re-pickable.
        let current = try #require(menu.items.first { $0.state == .on })
        #expect(current.title == DocumentView.menuTitle(for: .inProgress))
        #expect(!current.isEnabled)
        #expect(menu.items.filter(\.isEnabled).count == 4)
        // Page coordinates grow downwards, the view's upwards.
        #expect(captured?.point.y == view.webView.bounds.height - 120)

        // Picking "Cancelled" writes the one byte, from the state the page
        // reported rather than from anything re-queried.
        let cancelled = try #require(
            menu.items.first { $0.title == DocumentView.menuTitle(for: .cancelled) })
        NSApp.sendAction(cancelled.action!, to: cancelled.target, from: cancelled)
        #expect(
            await harness.waitUntil("the file to take the picked state") {
                (try? harness.contents(of: "tasks.md")) == "# Tasks\n\n- [-] started\n"
            })
    }

    /// ⌥-click, the shortcut `2026-08-27-five-task-states` gives cancelled, all
    /// the way through: the page derives the state, one byte reaches the file,
    /// and the patch that comes back paints the box cancelled rather than
    /// ticked — even though the core's `checked` says the item is terminal.
    @Test("⌥-clicking a checkbox cancels it, in one byte")
    func altClickCancels() async throws {
        let harness = try RoundTripHarness()
        let source = "# Tasks\n\n- [ ] first\n\nnote\n\n- [ ] second\n"
        let tab = try await harness.open(source, named: "tasks.md")
        let before = try Data(contentsOf: tab.url)
        let view = try #require(tab.documentView)

        // A real click, with the modifier the reader would hold. `.click()`
        // cannot carry one, so the event is constructed — this is the only
        // place in the suite that needs to.
        let clicked = try await view.call(
            """
            var boxes = document.querySelectorAll('#mk-doc input.mk-task');
            if (!boxes[1]) return false;
            boxes[1].dispatchEvent(new MouseEvent("click", { bubbles: true, altKey: true }));
            return true;
            """)
        #expect((clicked as? Bool) == true)

        #expect(
            await harness.waitUntil("the file to change") {
                (try? Data(contentsOf: tab.url)) != before
            })
        let after = try Data(contentsOf: tab.url)
        #expect(after.count == before.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 1, "more than one byte changed")
        #expect(
            try harness.contents(of: "tasks.md")
                == "# Tasks\n\n- [ ] first\n\nnote\n\n- [-] second\n")

        #expect(
            await harness.waitUntil("the DOM to catch up") {
                let cancelled = try? await view.call(
                    "return document.querySelectorAll('#mk-doc input.mk-task[data-mk-state=\"cancelled\"]').length;"
                )
                return ((cancelled as? NSNumber)?.intValue ?? 0) == 1
            })
        let ticked = try await view.call(
            "return document.querySelectorAll('#mk-doc input.mk-task[checked]').length;")
        #expect(
            (ticked as? NSNumber)?.intValue == 0,
            "a cancelled box must not draw ticked, whatever `checked` says in the JSON")
    }

    /// **Gate 4.** One visible change, not two.
    ///
    /// A write that patched *and* re-rendered would look identical in a
    /// screenshot, so this is asserted from the page's own counters: one block
    /// patch, no document injections, no whole-document replacements.
    @Test("a GUI toggle produces exactly one patch and no re-render")
    func noDoubleRender() async throws {
        let harness = try RoundTripHarness()
        let tab = try await harness.open(
            "# Tasks\n\n- [ ] first\n\nnote\n\n- [ ] second\n", named: "tasks.md")
        let view = try #require(tab.documentView)
        let before = try #require(await view.stats())

        try await harness.clickCheckbox(at: 0, in: tab)
        #expect(
            await harness.waitUntil("the patch") {
                ((await view.stats())?.patches ?? 0) > before.patches
            })
        await harness.settle()

        let after = try #require(await view.stats())
        #expect(after.patches == before.patches + 1, "the document was patched more than once")
        #expect(after.documents == before.documents, "the document was re-injected")
        #expect(after.replacements == before.replacements, "the document was replaced wholesale")
        // One block out, one block in: the list item that changed.
        #expect(after.patchedBlocks - before.patchedBlocks == 2)
        #expect(after.blocks == before.blocks)
    }

    /// **Gate 2, and the one that matters most.**
    ///
    /// An external edit inserts a task *above* one the diff keeps. The kept
    /// block is never re-rendered — that is ADR-2 working as designed — so its
    /// checkbox is left carrying `data-mk-idx="0"` and the old byte span unless
    /// the patch re-stamps it. Clicking that checkbox then writes the task
    /// *above* it: the wrong line silently flips, in the feature the app is
    /// named for.
    ///
    /// The write path cannot catch this on its own; `TaskWriterTests`'s
    /// `spanCheckAloneIsNotEnough` shows the stale span colliding exactly with
    /// the new task 0's. The re-stamp is the whole defence, and this is it
    /// end to end.
    @Test("a checkbox in a block the patch left untouched writes the task the user clicked")
    func theTrap() async throws {
        let harness = try RoundTripHarness()
        let old = "- [ ] second\n\ntrailing\n"
        let new = "- [ ] first\n\n***\n\n- [ ] second\n\ntrailing\n"
        let tab = try await harness.open(old, named: "trap.md")
        let view = try #require(tab.documentView)

        // Tag the block that must survive the patch, so "untouched" is asserted
        // rather than assumed.
        _ = try await view.call(
            "document.querySelector('#mk-doc [data-blk]').__witness = 1; return true;")

        try harness.saveAtomically(new, to: "trap.md")
        #expect(
            await harness.waitUntil("the external edit to be patched in") {
                view.renderedSource == new
            })
        let witness = try await view.call(
            "var b = document.querySelectorAll('#mk-doc [data-blk]');"
                + "return b[b.length - 2].__witness;")
        #expect(
            (witness as? NSNumber)?.intValue == 1,
            "the block below the edit was re-rendered, so this test is no longer about the trap")

        // Click the checkbox in that untouched block. In the *new* document it
        // is task 1; a page that had not been re-stamped would still call it
        // task 0 and send the byte span of "first".
        try await harness.clickCheckbox(at: 1, in: tab)
        #expect(
            await harness.waitUntil("the write") {
                (try? harness.contents(of: "trap.md")) != new
            })

        let written = try harness.contents(of: "trap.md")
        #expect(
            written == "- [ ] first\n\n***\n\n- [x] second\n\ntrailing\n",
            "the wrong task was written: \(written.debugDescription)")
    }

    /// **Gate 3.** A `vim`-style save while the document is open: temp file,
    /// then `rename(2)`, so the inode changes underneath the watcher.
    @Test("an external atomic-rename save updates the open document")
    func externalSaveDuringView() async throws {
        let harness = try RoundTripHarness()
        let tab = try await harness.open("# Notes\n\nbefore\n", named: "notes.md")
        let view = try #require(tab.documentView)
        let inodeBefore = try inode(of: tab.url)

        try harness.saveAtomically("# Notes\n\nafter\n", to: "notes.md")
        #expect(try inode(of: tab.url) != inodeBefore, "the save did not swap the inode")
        #expect(
            await harness.waitUntil("the document to update") {
                view.renderedSource == "# Notes\n\nafter\n"
            })
        let text = try await view.call("return document.getElementById('mk-doc').textContent;")
        #expect((text as? String)?.contains("after") == true)
        #expect((text as? String)?.contains("before") == false)
    }

    /// **Gate 7.** ADR-4: *"no feature may assume a tab's web view exists"*, and
    /// a dehydrated tab has none. Its badge still has to be right, so the
    /// change is absorbed through the core against the file — and the tab must
    /// **not** be hydrated to do it, because that would spend ~52 MB on a
    /// document nobody is looking at.
    @Test("a watcher event for a dehydrated tab updates its badge without hydrating it")
    func dehydratedTabBadge() async throws {
        let harness = try RoundTripHarness(residentLimit: 1)
        let background = try await harness.open("# A\n\n- [ ] one\n", named: "a.md")
        _ = try await harness.open("# B\n\nnothing\n", named: "b.md")

        #expect(
            await harness.waitUntil("the first tab to be evicted") {
                background.state == .dehydrated
            })
        #expect(background.documentView == nil)
        #expect(
            await harness.waitUntil("the initial badge") { background.metadata != nil })
        #expect(background.metadata?.tasks == TaskCounts(open: 1, total: 1))

        // The rewrite drops one item and starts another, so the badge has to
        // move for two reasons at once: `[-]` leaves the denominator and `[/]`
        // stays in the numerator (`2026-08-27-five-task-states`).
        try harness.saveAtomically(
            "# A\n\n- [ ] one\n- [/] two\n- [x] three\n- [-] four\n", to: "a.md")
        #expect(
            await harness.waitUntil("the badge to follow the file") {
                background.metadata?.tasks
                    == TaskCounts(
                        open: 1, inProgress: 1, done: 1, cancelled: 1, blocked: 0, total: 4)
            })
        #expect(background.openTaskCount == 2, "open + in-progress")
        #expect(background.metadata?.tasks.active == 3, "the dropped item left the denominator")
        #expect(background.state == .dehydrated, "the watcher hydrated a tab nobody is looking at")
        #expect(background.documentView == nil)
    }

    /// A tab that has been closed is no longer watched. Left in, every document
    /// ever opened would keep costing a file read on every save in its
    /// directory for the life of the process.
    @Test("closing a tab stops watching its file")
    func closingStopsWatching() async throws {
        let harness = try RoundTripHarness()
        let tab = try await harness.open("# A\n\nbody\n", named: "a.md")
        _ = try await harness.open("# B\n\nbody\n", named: "b.md")
        harness.controller.tabs.close(tab)
        await harness.settle(.milliseconds(100))

        // Nothing to assert on the DOM — the tab is gone — so this asserts on
        // the change never being delivered anywhere, by way of the file being
        // rewritten and nothing crashing or reopening it.
        try harness.saveAtomically("# A\n\nedited\n", to: "a.md")
        await harness.settle()
        #expect(harness.controller.tabs.tab(for: tab.url) == nil)
        #expect(harness.controller.tabs.count == 1)
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
