import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// A real window controller with a real file watcher, a real `WKWebView`
/// running the shipped `shell.js`, and a real editor pane.
///
/// The M9 loop is only testable here, for the same reason M5's was: the
/// keystroke is in an `NSTextView`, the write is in the core, the notification
/// is in the kernel, and the patch is back in the page. A stub anywhere in that
/// chain tests the stub — and the two properties this milestone can get wrong
/// silently, self-write suppression and checkbox identity, both live in the
/// gaps *between* those components.
@MainActor
final class EditorHarness {

    let fixture: PatchFixture
    let controller: MainWindowController

    init(autosave: TimeInterval = 0.08, preview: TimeInterval = 0.03) throws {
        fixture = try PatchFixture()
        controller = MainWindowController(
            root: fixture.directory,
            session: Session(
                url: fixture.directory.appendingPathComponent("session.json"), debounce: 0.05)
        )
        controller.bufferDebounces = (autosave, preview)
    }

    @discardableResult
    func open(_ source: String, named name: String = "doc.md") async throws -> DocumentTab {
        let url = try fixture.write(source, to: name)
        controller.open(url)
        let tab = try #require(controller.tabs.tab(for: url))
        await tab.documentView?.awaitReady()
        await tab.documentView?.ensureFullyRendered()
        return tab
    }

    /// Open the editor pane on the selected tab, the way ⌥⌘E does.
    @discardableResult
    func edit(_ tab: DocumentTab) throws -> Buffer {
        controller.setEditorVisible(true)
        return try #require(tab.buffer)
    }

    /// Simulate the page reporting a scroll, through the real bridge path, so
    /// what the editor pane does about it is the production path and not a
    /// call to `follow(previewByte:)` written by the test.
    func reportScroll(_ y: Double, source: Int? = nil, on tab: DocumentTab) {
        guard let view = tab.documentView else { return }
        view.scriptBridge(ScriptBridge(), didReceive: .scroll(y: y, source: source))
    }

    /// Scroll the editor pane the way a hand on a trackpad does: move the clip
    /// view and let the bounds-change notification carry it from there.
    ///
    /// Deliberately *not* ``EditorPane/scroll(to:)``, which is the path the
    /// preview drives and the one that suppresses the report. The whole
    /// question these tests ask is whether the pane can tell those two apart.
    func scrollEditor(to y: CGFloat) {
        let pane = controller.editor
        guard let scrollView = pane.textView.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The text of the first block the page is showing at or below its viewport
    /// top — the preview's answer to "which paragraph am I on", read out of the
    /// DOM rather than out of the mapping under test.
    func previewTopBlock(in tab: DocumentTab) async throws -> String {
        guard let view = tab.documentView else { return "" }
        let text = try await view.call(
            """
            var blocks = document.getElementById('mk-doc').children;
            for (var i = 0; i < blocks.length; i++) {
              if (blocks[i].getBoundingClientRect().bottom > 0) {
                return blocks[i].textContent;
              }
            }
            return '';
            """)
        return ((text as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the page is, in its own pixels.
    func previewOffset(in tab: DocumentTab) async throws -> Double {
        guard let view = tab.documentView else { return 0 }
        let y = try await view.call("return window.mark.scrollPosition().y;")
        return (y as? Double) ?? 0
    }

    /// Type, through the real text view and its delegate.
    func type(_ text: String, at location: Int) {
        let view = controller.editor.textView
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.insertText(text, replacementRange: NSRange(location: location, length: 0))
    }

    /// A save the way vim does it: temp file, then rename over the target.
    func saveExternally(_ source: String, to name: String = "doc.md") throws {
        let temp = fixture.directory.appendingPathComponent(".\(name).swp-\(UUID().uuidString)")
        try source.write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(
            fixture.directory.appendingPathComponent(name), withItemAt: temp)
    }

    /// Wait for something the editor does off the main actor — the background
    /// parse behind its highlighting is the one this file needs.
    func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
        return false
    }

    func contents(of name: String = "doc.md") throws -> String {
        try String(contentsOf: fixture.directory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Click a checkbox by its **position on screen**, not by `data-mk-idx`.
    ///
    /// The distinction is the whole point, and M5 made it first: a reader
    /// clicks the third box they can see, and whether the app toggles the third
    /// task depends entirely on the attribute the patch left on that node.
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
        #expect((clicked as? Bool) == true, "no checkbox at position \(position)")
    }

    /// Every checkbox in the DOM as `idx:start:end:state`.
    ///
    /// The last field is `data-mk-state` and **not** the `checked` attribute:
    /// since `2026-08-27-five-task-states` the core's `checked` means "the
    /// state is terminal", which is true for a cancelled marker that the page
    /// deliberately draws unticked. Comparing `hasAttribute('checked')` against
    /// it therefore reports a disagreement that is not one — and, worse, would
    /// call two genuinely different states equal.
    func domTasks(in tab: DocumentTab) async throws -> [String] {
        let view = try #require(tab.documentView)
        let value = try await view.call(
            """
            var out = [];
            var boxes = document.querySelectorAll('#mk-doc input.mk-task');
            for (var i = 0; i < boxes.length; i++) {
              out.push([boxes[i].getAttribute('data-mk-idx'),
                        boxes[i].getAttribute('data-mk-start'),
                        boxes[i].getAttribute('data-mk-end'),
                        boxes[i].getAttribute('data-mk-state')].join(':'));
            }
            return out;
            """)
        return (value as? [String]) ?? []
    }

    func coreTasks(of source: String) throws -> [String] {
        try MarkCore.tasks(source: source).map {
            "\($0.index):\($0.start):\($0.end):\($0.state.rawValue)"
        }
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

    func settle(_ duration: Duration = .milliseconds(700)) async {
        try? await _Concurrency.Task.sleep(for: duration)
    }
}

@Suite("The M9 round trip — type, autosave, watch, patch")
@MainActor
struct EditorRoundTripTests {

    /// **Gate 2.** Our own autosave never triggers a re-render.
    ///
    /// Asserted at the *watcher*, not at the page: a patch counter cannot tell
    /// "the event was suppressed" from "the event arrived and produced a patch
    /// identical to the one typing already produced", and only the first of
    /// those satisfies the ADR. The suppression itself is
    /// `FileWatcher.noteWrittenContent`, wired from `Buffer.onWillWrite` in
    /// ``MainWindowController/buffer(for:)``.
    ///
    /// Its control is ``anUnsuppressedWriteDoesReachTheWatcher()``, which
    /// removes exactly that wire and asserts the watcher *does* report — so a
    /// pass here means suppression, rather than a watcher that was never going
    /// to fire.
    @Test("our own autosave never reaches the watcher")
    func autosaveIsSuppressed() async throws {
        let harness = try EditorHarness()
        let tab = try await harness.open("# Doc\n\n- [ ] one\n\nbody\n")
        let buffer = try harness.edit(tab)
        // Watching is armed synchronously by `setWatched`, but the tab was
        // opened before the buffer existed; let any opening events drain.
        await harness.settle(.milliseconds(400))
        let before = harness.controller.externalChangesSeen

        harness.type("typed by a human. ", at: 0)
        #expect(await harness.waitUntil("the autosave to land") { !buffer.isDirty })
        #expect(try harness.contents().hasPrefix("typed by a human. # Doc"))

        // Well past the watcher's 30 ms debounce and its retry budget.
        await harness.settle(.milliseconds(800))
        #expect(
            harness.controller.externalChangesSeen == before,
            "the watcher reported \(harness.controller.externalChangesSeen - before) change(s) for our own write"
        )
        // And the page still holds what the buffer holds.
        #expect(tab.documentView?.renderedSource == buffer.text)
    }

    /// The control for the gate above: the same sequence with the suppression
    /// hook removed. If this stops reporting, the gate above has stopped
    /// meaning anything.
    @Test("without the suppression hook the watcher does report our write")
    func anUnsuppressedWriteDoesReachTheWatcher() async throws {
        let harness = try EditorHarness()
        let tab = try await harness.open("# Doc\n\n- [ ] one\n\nbody\n")
        let buffer = try harness.edit(tab)
        await harness.settle(.milliseconds(400))
        let before = harness.controller.externalChangesSeen

        // The sabotage: exactly the wire ADR-6 requires, cut.
        buffer.onWillWrite = nil

        harness.type("typed by a human. ", at: 0)
        #expect(await harness.waitUntil("the autosave to land") { !buffer.isDirty })
        #expect(
            await harness.waitUntil("the watcher to report the unsuppressed write") {
                harness.controller.externalChangesSeen > before
            },
            "the watcher never fires, so the suppression gate proves nothing"
        )
    }

    /// **Gate 4.** A checkbox click on a dirty tab writes the buffer, and the
    /// preview and the buffer never disagree about task indices.
    ///
    /// The edit is M5's trap, moved onto the buffer path: a task is inserted
    /// **above** an existing one, so the lower task's block is content-identical
    /// and the diff keeps its DOM node — with `data-mk-idx="0"` on it — while
    /// in the new document that task is index 1. Clicking the second box on
    /// screen must toggle *that* task in the buffer, not its neighbour.
    @Test("a checkbox click on a dirty tab writes the buffer, at the index the user clicked")
    func dirtyCheckboxHitsTheRightTask() async throws {
        let harness = try EditorHarness(autosave: 5.0, preview: 0.03)
        let tab = try await harness.open("- [ ] second\n")
        let buffer = try harness.edit(tab)
        let onDisk = try harness.contents()

        harness.type("- [ ] first\n", at: 0)
        #expect(buffer.text == "- [ ] first\n- [ ] second\n")
        #expect(
            await harness.waitUntil("the preview to patch from the buffer") {
                tab.documentView?.renderedSource == buffer.text
            })

        // The preview's checkbox attributes agree with the *buffer*, which is
        // what the click handler will read back to us.
        let dom = try await harness.domTasks(in: tab)
        #expect(dom == (try harness.coreTasks(of: buffer.text)), "the preview and the buffer disagree")

        try await harness.clickCheckbox(at: 1, in: tab)
        #expect(
            await harness.waitUntil("the buffer to take the toggle") {
                buffer.text == "- [ ] first\n- [x] second\n"
            },
            "the click toggled \(buffer.text.debugDescription)"
        )
        // The file has not been touched: autosave is 5 s away in this test.
        #expect(try harness.contents() == onDisk)
        #expect(buffer.isDirty)

        // And the preview caught up to the buffer again, still agreeing.
        #expect(
            await harness.waitUntil("the preview to show the toggle") {
                tab.documentView?.renderedSource == buffer.text
            })
        #expect((try await harness.domTasks(in: tab)) == (try harness.coreTasks(of: buffer.text)))
    }

    /// A clean tab is M5's tab, unchanged: the click writes the file and the
    /// watcher patches the page.
    @Test("a checkbox click on a clean tab still writes the file")
    func cleanCheckboxStillWritesTheFile() async throws {
        let harness = try EditorHarness()
        let tab = try await harness.open("- [ ] alpha\n")
        _ = try harness.edit(tab)  // a buffer exists, but nothing has been typed

        try await harness.clickCheckbox(at: 0, in: tab)
        #expect(
            await harness.waitUntil("the file to change") {
                (try? harness.contents()) == "- [x] alpha\n"
            })
    }

    /// ADR-6: *"nothing may read the file for rendering […] on a dirty tab"*.
    /// Rehydration is a render, so it must come from the buffer.
    @Test("a dirty tab rehydrates from its buffer, not from the file")
    func dirtyRehydrationUsesTheBuffer() async throws {
        let harness = try EditorHarness(autosave: 5.0, preview: 0.03)
        let tab = try await harness.open("# Doc\n\nbody\n")
        let buffer = try harness.edit(tab)
        harness.type("unsaved. ", at: 0)
        #expect(buffer.isDirty)

        // Forced, because eviction will not do it — which is the *other* half
        // of the ADR and is asserted in `DirtyResidencyTests`.
        harness.controller.tabs.dehydrate(tab)
        #expect(!tab.state.isResident)
        harness.controller.tabs.select(tab)
        await tab.documentView?.awaitReady()

        #expect(tab.documentView?.renderedSource == buffer.text)
        #expect(tab.documentView?.renderedSource?.hasPrefix("unsaved. ") == true)
        #expect(try harness.contents().hasPrefix("# Doc"), "the file was written by a rehydration")
    }

    /// **Gate 1's conflict half**, without the 60 seconds: an external save
    /// while dirty raises the prompt, pauses autosave, and writes nothing until
    /// it is answered. The 60-second continuous-typing version is
    /// `mark-bench`'s M9 section, which has a window and a clock.
    @Test("an external save during editing prompts and writes nothing until answered")
    func externalSaveDuringEditing() async throws {
        let harness = try EditorHarness(autosave: 0.08, preview: 0.03)
        let tab = try await harness.open("# Doc\n\nbody\n")
        let buffer = try harness.edit(tab)
        await harness.settle(.milliseconds(400))

        var raised: [Conflict] = []
        let presenter = ConflictTests.ScriptedPresenter([])
        harness.controller.conflicts.use(presenter: presenter)
        buffer.onConflict = { conflict in
            raised.append(conflict)
            // Deliberately *not* answered here: the assertion is that nothing
            // is written while the question is open.
        }

        harness.type("mine. ", at: 0)
        let theirs = "# Doc\n\nsaved from vim\n"
        try harness.saveExternally(theirs)

        #expect(await harness.waitUntil("the conflict prompt") { !raised.isEmpty })
        #expect(buffer.isConflicted)
        #expect(buffer.text.hasPrefix("mine. "), "the buffer lost the user's typing")

        await harness.settle(.milliseconds(500))
        #expect(try harness.contents() == theirs, "autosave wrote over an unanswered conflict")

        // The preview is still showing the buffer, because the buffer is truth
        // while dirty — the file's version is rendered nowhere.
        #expect(tab.documentView?.renderedSource?.hasPrefix("mine. ") == true)

        // Answering "keep mine" lets the ordinary debounce write.
        buffer.resolve(.keepMine)
        #expect(await harness.waitUntil("the resumed autosave") { !buffer.isDirty })
        #expect(try harness.contents() == buffer.text)
    }

    /// `mark reload` and ⌘R both mean "re-read the file", which ADR-6 forbids
    /// on a dirty tab — doing it would replace the reader's unsaved text with
    /// the version on disk, which is the "reload-theirs" behaviour the ADR
    /// rejects by name. Refusing is the answer.
    @Test("reloading a dirty tab is refused rather than discarding the buffer")
    func reloadIsRefusedWhileDirty() async throws {
        let harness = try EditorHarness(autosave: 5.0, preview: 0.03)
        let tab = try await harness.open("# Doc\n\nbody\n")
        let buffer = try harness.edit(tab)
        harness.type("unsaved. ", at: 0)
        #expect(buffer.isDirty)

        await #expect(throws: CommandFailure.self) {
            _ = try await harness.controller.reloadSelectedDocument()
        }
        #expect(buffer.text.hasPrefix("unsaved. "))
        #expect(
            await harness.waitUntil("the preview to be showing the buffer") {
                tab.documentView?.renderedSource == buffer.text
            },
            "the refused reload left the preview showing something other than the buffer")

        // Once it is clean, a reload is an ordinary reload again.
        #expect(buffer.save())
        let blocks = try await harness.controller.reloadSelectedDocument()
        #expect(blocks >= 0)
    }

    /// A tab closed inside the debounce window still writes: autosave's promise
    /// is "at most the last 800 ms", and closing must not widen it.
    @Test("closing a tab writes its pending buffer")
    func closingWritesThePendingBuffer() async throws {
        let harness = try EditorHarness(autosave: 5.0, preview: 0.03)
        let tab = try await harness.open("# Doc\n\nbody\n")
        let buffer = try harness.edit(tab)
        harness.type("about to close. ", at: 0)
        #expect(buffer.hasPendingSave)

        harness.controller.tabs.close(tab)
        #expect(try harness.contents().hasPrefix("about to close. # Doc"))
    }

    /// The quit path, through the controller rather than the buffer.
    @Test("flushing at quit writes every dirty tab")
    func flushAtQuit() async throws {
        let harness = try EditorHarness(autosave: 5.0, preview: 0.03)
        let first = try await harness.open("# One\n", named: "one.md")
        let firstBuffer = try harness.edit(first)
        harness.type("edited one. ", at: 0)

        let second = try await harness.open("# Two\n", named: "two.md")
        let secondBuffer = try harness.edit(second)
        harness.type("edited two. ", at: 0)

        #expect(firstBuffer.isDirty && secondBuffer.isDirty)
        #expect(harness.controller.flushDirtyBuffers() == 2)
        #expect(try harness.contents(of: "one.md").hasPrefix("edited one. "))
        #expect(try harness.contents(of: "two.md").hasPrefix("edited two. "))
    }

    // MARK: - The editor follows the preview

    /// The line the editor is showing at the top of its viewport.
    ///
    /// The assertion is deliberately on **text**, not on a pixel offset: the
    /// property is "both panes are showing the same part of the document", and
    /// a y-coordinate compared against the same function that produced it would
    /// agree with itself and prove nothing.
    private func lineAtTop(of pane: EditorPane) -> String {
        guard let layoutManager = pane.textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return "" }
        let y = pane.scrollOffset - pane.textView.textContainerOrigin.y
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y))
        else { return "" }
        let start = contentManager.offset(
            from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        let end = contentManager.offset(
            from: contentManager.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard end > start else { return "" }
        return (pane.textView.string as NSString)
            .substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A document tall enough that both panes can scroll, whose every line says
    /// where it is.
    private func numberedParagraphs(_ count: Int) -> String {
        (0..<count).map { "Paragraph \($0) of the document.\n" }.joined(separator: "\n")
    }

    @Test("scrolling the preview scrolls the editor to the same line")
    func theEditorFollowsThePreview() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let tab = try await harness.open(source)
        _ = try harness.edit(tab)
        let pane = harness.controller.editor
        #expect(pane.scrollOffset == 0)

        // What the page reports when block 200 is under the top of the
        // viewport: its `data-mk-start`. Every byte here is ASCII, so the byte
        // offset and the UTF-16 offset agree — the case where they do not is
        // `SourceOffsets`' own, and is tested there.
        let target = (source as NSString).range(of: "Paragraph 200 of the document.").location
        harness.reportScroll(4_000, source: target, on: tab)

        #expect(lineAtTop(of: pane) == "Paragraph 200 of the document.")
        #expect(pane.scrollOffset > 0)

        // And back up, so this is following rather than a one-way jump.
        let earlier = (source as NSString).range(of: "Paragraph 40 of the document.").location
        harness.reportScroll(800, source: earlier, on: tab)
        #expect(lineAtTop(of: pane) == "Paragraph 40 of the document.")
    }

    /// A page that cannot say where it is says nothing, and nothing moves. The
    /// alternative — treating a missing position as byte 0 — would yank the
    /// editor to the top of the file every time a document could not be mapped.
    @Test("a scroll report with no source position leaves the editor where it is")
    func aReportWithNoSourceMovesNothing() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let tab = try await harness.open(source)
        _ = try harness.edit(tab)
        let pane = harness.controller.editor

        let target = (source as NSString).range(of: "Paragraph 200 of the document.").location
        harness.reportScroll(4_000, source: target, on: tab)
        let followed = pane.scrollOffset
        #expect(followed > 0)

        harness.reportScroll(6_000, on: tab)
        #expect(pane.scrollOffset == followed)
    }

    /// One editor pane, and a window can have two documents on screen. The pane
    /// follows the one it is bound to and ignores the other, which is what
    /// keeps a split from scrolling the source of a document nobody is editing.
    @Test("the editor ignores a scroll in a document it is not bound to")
    func theEditorFollowsOnlyItsOwnDocument() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let first = try await harness.open(source, named: "first.md")
        let second = try await harness.open(numberedParagraphs(400), named: "second.md")
        _ = try harness.edit(second)
        let pane = harness.controller.editor
        #expect(pane.buffer === second.buffer)

        let target = (source as NSString).range(of: "Paragraph 200 of the document.").location
        harness.reportScroll(4_000, source: target, on: first)
        #expect(pane.scrollOffset == 0, "the pane followed a document it is not showing")

        harness.reportScroll(4_000, source: target, on: second)
        #expect(pane.scrollOffset > 0)
    }

    /// `2026-08-28`: the editor pane ended in the middle of the document.
    ///
    /// Scroll the preview far enough into a file and the source beside it
    /// stopped, mid-paragraph, with blank space below the last line and no way
    /// to reach the rest. Reported against a daily note that is one long fenced
    /// block, and reproducible on any document taller than the pane.
    ///
    /// The fault was in ``EditorPane/visibleCharacterRange(padding:length:)``,
    /// not in the following. Its lower probe sits 2,000 points below the
    /// viewport; `textLayoutFragment(for:)` answers `nil` for a point below the
    /// last line rather than answering "the end"; so reading the last two
    /// screenfuls of *any* document missed and took the "cannot tell what is
    /// visible" branch, which attributed the first 20,000 characters. That is
    /// an attribute edit across most of the document, an attribute edit
    /// invalidates layout, and the text view sizes itself from that layout —
    /// so it shrank under the reader. Measured in the app on a 34 KB file:
    /// `usageBoundsForTextContainer` fell from 19,669 points to 8,256.
    ///
    /// The assertion is on the range rather than on the shrinking, and that is
    /// a limitation of the harness rather than a choice: the text view only
    /// resizes once AppKit runs a viewport layout pass, and a test window is
    /// never on screen. What is asserted is the property that failed — a pass
    /// meant to paint one screenful must not decide to paint the document.
    @Test("reading the end of a document does not make the editor guess at all of it")
    func theHighlightedRangeStaysBoundedAtTheEnd() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let tab = try await harness.open(source)
        _ = try harness.edit(tab)
        let pane = harness.controller.editor
        let parsed = await harness.waitUntil("the editor to parse its buffer") {
            pane.highlightPasses > 0
        }
        #expect(parsed)

        // Lay the document out, so the probes have real geometry to miss.
        let layoutManager = try #require(pane.textView.textLayoutManager)
        let contentManager = try #require(layoutManager.textContentManager)
        layoutManager.ensureLayout(for: contentManager.documentRange)

        // The reader scrolls the preview to the last paragraph; the editor
        // follows, which puts the viewport — and the 2,000 points of padding
        // below it — past the end of the text.
        let target = (source as NSString).range(of: "Paragraph 399 of the document.").location
        harness.reportScroll(40_000, source: target, on: tab)

        let length = (pane.textView.string as NSString).length
        let visible = pane.visibleCharacterRange(padding: 2_000, length: length)
        #expect(
            visible.length < length,
            "the pass would attribute the whole document (\(visible.length) of \(length))")
        #expect(
            visible.location > 0,
            "the pass would start at the top of a document the reader is at the bottom of")
    }

    /// `2026-08-31`: the editor shook, and the marks were left behind.
    ///
    /// Reported as three symptoms of one fault — the source pane jumping up
    /// and down while scrolling or typing, scrolling that would not stay
    /// smooth, and a stippled band of whitespace dots standing in blank space
    /// below the last line.
    ///
    /// ``EditorPane/applyHighlight()`` runs on every clip-view bounds change,
    /// which is every frame of every scroll, and it used to re-run the whole
    /// wipe-and-repaint each time. Its attributes are not cosmetic: a heading
    /// is 19-point where the body is 13. So every frame invalidated layout,
    /// every relayout resized the `isVerticallyResizable` text view, and
    /// resizing the document view posted the bounds change that started it —
    /// a loop with the reader's document inside it. Measured in the app on the
    /// 7.9 KB file it was reported against: one `goto` produced two passes
    /// 7 ms apart, and across the run the document view's height walked
    /// 4,083 → 4,040 → 4,024 → 4,004 → 3,907 points, at one point standing 153
    /// points taller than the text it held.
    ///
    /// The assertion is on ``EditorPane/highlightWrites`` rather than on the
    /// height, and for the same reason the test above asserts on a range: a
    /// test window is never on screen, so AppKit never runs the viewport
    /// layout pass that would resize the view. What is asserted is the cause —
    /// a scroll across text that is already painted must not touch the storage.
    @Test("scrolling the editor over painted text does not repaint it")
    func scrollingDoesNotRewriteTheAttributes() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let tab = try await harness.open(source)
        _ = try harness.edit(tab)
        let pane = harness.controller.editor
        let parsed = await harness.waitUntil("the editor to parse its buffer") {
            pane.highlightPasses > 0
        }
        #expect(parsed)

        let layoutManager = try #require(pane.textView.textLayoutManager)
        let contentManager = try #require(layoutManager.textContentManager)
        layoutManager.ensureLayout(for: contentManager.documentRange)

        // One scroll to settle the painted span, and to prove the pass still
        // happens at all — a highlight that never runs would pass the
        // assertion below for the wrong reason.
        let first = (source as NSString).range(of: "Paragraph 20 of the document.").location
        harness.reportScroll(400, source: first, on: tab)
        let painted = pane.highlightWrites
        #expect(painted > 0, "the editor never painted anything to begin with")

        // Now the reader scrolls about inside what is already painted. Every
        // one of these posts a bounds change; none of them exposes new text.
        for paragraph in [21, 22, 21, 20, 23, 20] {
            let target = (source as NSString)
                .range(of: "Paragraph \(paragraph) of the document.").location
            harness.reportScroll(Double(400 + paragraph), source: target, on: tab)
        }
        #expect(
            pane.highlightWrites == painted,
            "scrolling over painted text rewrote the storage \(pane.highlightWrites - painted) more times")

        // And new text still gets painted when it comes into view, so the
        // coverage check is not simply switching the highlighting off.
        let far = (source as NSString).range(of: "Paragraph 380 of the document.").location
        harness.reportScroll(20_000, source: far, on: tab)
        #expect(
            pane.highlightWrites > painted,
            "text scrolled into view for the first time was never highlighted")
    }

    // MARK: - The preview follows the editor

    /// The reverse mapping on its own: scroll the pane, and see what it says it
    /// is showing.
    ///
    /// Flushed rather than waited out. A test window is never on screen, so the
    /// text view never gets the viewport layout pass that would give it its
    /// real height, and a clip view scrolled over a document that does not know
    /// how tall it is snaps back to zero within a turn of the run loop — so
    /// sleeping through the pane's 120 ms throttle would assert on the harness
    /// rather than on the pane. See ``EditorPane/flushSourceReport()``.
    @Test("scrolling the editor reports the line it is showing")
    func theEditorReportsWhereItIs() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let tab = try await harness.open(source)
        _ = try harness.edit(tab)
        let pane = harness.controller.editor

        var reported: [Int] = []
        pane.onSourceTop = { reported.append($0) }

        let target = (source as NSString).range(of: "Paragraph 200 of the document.").location
        harness.scrollEditor(to: try #require(pane.sourceY(ofByte: target, in: source)))
        #expect(pane.flushSourceReport(), "the pane scheduled no report for a reader's scroll")
        #expect(reported == [target])

        // And back up, so this is leading rather than a one-way jump.
        let earlier = (source as NSString).range(of: "Paragraph 40 of the document.").location
        harness.scrollEditor(to: try #require(pane.sourceY(ofByte: earlier, in: source)))
        #expect(pane.flushSourceReport())
        #expect(reported == [target, earlier])
    }

    /// The two directions are now pointed at each other, and what keeps that
    /// from being a loop is that each pane stays quiet about the scroll the
    /// *other* one caused it to make.
    ///
    /// Not "the report was the same number, so nothing happened": a report is
    /// never scheduled at all. The distinction is the whole design — the two
    /// panes round through different geometry, so a suppression that relied on
    /// the numbers matching would leak exactly where the mapping is least
    /// exact.
    @Test("the editor reports nothing for a scroll the preview caused")
    func followingThePreviewIsNotReported() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let tab = try await harness.open(source)
        _ = try harness.edit(tab)
        let pane = harness.controller.editor

        var reported: [Int] = []
        pane.onSourceTop = { reported.append($0) }

        let target = (source as NSString).range(of: "Paragraph 200 of the document.").location
        harness.reportScroll(4_000, source: target, on: tab)
        #expect(pane.scrollOffset > 0, "the editor did not follow the preview at all")
        #expect(!pane.flushSourceReport(), "the pane reported the scroll the preview caused")
        #expect(reported.isEmpty)
    }

    /// Rebinding is the pane remembering, not the reader scrolling.
    ///
    /// Switching tabs restores the incoming document's caret and scroll
    /// position, and reopening the pane restores the one it already had.
    /// Reporting either would push a preview — which has its own remembered
    /// place — to wherever the pane happened to land. The case that bites is
    /// the pane being *reopened*: the reader closed it, read on in the
    /// preview, and reopening the source must not throw the page back to
    /// wherever the source was left.
    ///
    /// Bound directly, with nothing awaited in between, and that is the point
    /// rather than a shortcut. A test window never gets AppKit's viewport
    /// layout pass, so the text view never learns its real height and the clip
    /// view is constrained back towards zero on the next turn of the run loop
    /// — a move the pane is right to report and the harness is wrong to make.
    /// Everything asserted here happens inside ``EditorPane/bind(_:)``.
    @Test("rebinding the editor reports nothing")
    func rebindingIsNotReported() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let first = try await harness.open(source, named: "first.md")
        let firstBuffer = try harness.edit(first)
        let pane = harness.controller.editor
        let second = try await harness.open(source, named: "second.md")
        let secondBuffer = try harness.edit(second)

        // Leave the source half way down, so the rebinds below have a place to
        // restore rather than landing at the top either way.
        let target = (source as NSString).range(of: "Paragraph 200 of the document.").location
        harness.scrollEditor(to: try #require(pane.sourceY(ofByte: target, in: source)))
        #expect(pane.flushSourceReport())

        var reported: [Int] = []
        pane.onSourceTop = { reported.append($0) }

        pane.bind(firstBuffer)
        #expect(!pane.flushSourceReport(), "binding the editor to another document reported")
        pane.bind(secondBuffer)
        #expect(!pane.flushSourceReport(), "restoring the editor's remembered place reported")
        #expect(reported.isEmpty)
    }

    /// One editor pane, and a window can have two documents open. The pane
    /// leads the one it is bound to and leaves the other alone — the mirror of
    /// ``theEditorFollowsOnlyItsOwnDocument()``, and the same guard read the
    /// other way round.
    ///
    /// Asserted on the pages, because that is where the guard's failure would
    /// show: the byte offset is one number and it means two different places in
    /// two different documents.
    @Test("scrolling the editor leaves a document it is not bound to alone")
    func theEditorLeadsOnlyItsOwnDocument() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let first = try await harness.open(source, named: "first.md")
        let second = try await harness.open(source, named: "second.md")
        _ = try harness.edit(second)
        let pane = harness.controller.editor
        #expect(pane.buffer === second.buffer)

        let target = (source as NSString).range(of: "Paragraph 200 of the document.").location
        harness.scrollEditor(to: try #require(pane.sourceY(ofByte: target, in: source)))
        #expect(pane.flushSourceReport())

        let moved = await harness.waitUntil("the bound document's preview to follow") {
            ((try? await harness.previewOffset(in: second)) ?? 0) > 0
        }
        #expect(moved)
        #expect(
            try await harness.previewOffset(in: first) == 0,
            "the editor scrolled a document it is not bound to")
    }

    /// The page's half of the mapping, on its own and with real geometry: a
    /// byte offset in, that byte at the top of the viewport.
    ///
    /// The round trip is the assertion that matters. `sourceTop` and
    /// `scrollToSource` are inverses — the same block, the same span, the same
    /// interpolation, read in opposite directions — and if they ever stop being
    /// inverses the two panes drift apart by a little on every scroll instead
    /// of failing outright.
    @Test("the page puts a source byte at the top of its viewport, and back")
    func thePageScrollsToASourceByte() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let tab = try await harness.open(source)
        let view = try #require(tab.documentView)

        let target = (source as NSString).range(of: "Paragraph 200 of the document.").location
        let landed = try await view.call(
            "return window.mark.scrollToSource(byte);", arguments: ["byte": target])
        #expect((landed as? Bool) == true)
        #expect(try await harness.previewTopBlock(in: tab) == "Paragraph 200 of the document.")

        // The byte the page reports where it has just been sent is the byte it
        // was sent to. That is the round trip, and it is asserted in bytes
        // rather than in pixels because bytes are what crosses between the
        // panes: a block is taller than it has bytes in it, so a position that
        // survives as an integer offset can still land a pixel or so off, and
        // the pixel is the one that does not matter.
        let landedAt = try await view.call("return window.mark.sourceTop();")
        #expect(landedAt as? Int == target)

        // The same round trip starting from a scroll the page made on its own,
        // so this is the mapping and not one call agreeing with itself.
        _ = try await view.call("return window.mark.scrollTo(y);", arguments: ["y": 5_000.0])
        let reported = try await view.call("return window.mark.sourceTop();")
        let byte = try #require(reported as? Int)
        _ = try await view.call(
            "return window.mark.scrollToSource(byte);", arguments: ["byte": byte])
        #expect(
            try await view.call("return window.mark.sourceTop();") as? Int == byte,
            "the two halves of the mapping are not inverses")

        // A byte past the end of the document lands at the end of it rather
        // than nowhere: the reader scrolling their source to the last line
        // should see the last block, not a page that refused to move.
        _ = try await view.call("return window.mark.scrollTo(y);", arguments: ["y": 0.0])
        let past = try await view.call(
            "return window.mark.scrollToSource(byte);", arguments: ["byte": source.utf8.count + 1])
        #expect((past as? Bool) == true)
        #expect(try await harness.previewOffset(in: tab) > 0)

        // And a position that is not one is refused rather than rounded to the
        // top of the file.
        let negative = try await view.call(
            "return window.mark.scrollToSource(byte);", arguments: ["byte": -1])
        #expect((negative as? Bool) == false)
    }

    /// The anti-loop property from the preview's side, end to end and through
    /// both hops: the page really scrolls, really reports, the pane really
    /// follows — and then nothing more happens.
    ///
    /// Without the suppression in ``EditorPane/follow(previewByte:)`` the
    /// pane's arrival is reported straight back, and the page moves a second
    /// time to the position it just sent, rounded through two mappings.
    @Test("the preview does not move again once the editor has followed it")
    func followingThePreviewDoesNotBounceBack() async throws {
        let harness = try EditorHarness()
        let source = numberedParagraphs(400)
        let tab = try await harness.open(source)
        _ = try harness.edit(tab)
        let pane = harness.controller.editor
        let view = try #require(tab.documentView)

        _ = try await view.call("return window.mark.scrollTo(y);", arguments: ["y": 4_000.0])
        #expect(
            await harness.waitUntil("the editor to follow the preview") { pane.scrollOffset > 0 })

        // Long enough for the pane's 120 ms report and the page's 120 ms one
        // after it — the two hops a bounce would have to make.
        let settled = try await harness.previewOffset(in: tab)
        try? await _Concurrency.Task.sleep(for: .milliseconds(600))
        #expect(
            try await harness.previewOffset(in: tab) == settled,
            "the preview moved again after the editor followed it")
    }
}
