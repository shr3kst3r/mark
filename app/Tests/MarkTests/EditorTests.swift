import AppKit
import Foundation
import Testing

@testable import MarkKit

/// A throwaway directory with a document in it, and a buffer over it.
///
/// The debounces are shortened — 50 ms for the autosave, 20 ms for the preview
/// — because what these tests are about is *ordering* (nothing before the
/// debounce, everything after it), and 800 ms per assertion would buy nothing
/// but a slow suite. The production values are asserted separately, in
/// ``EditorTests/theDebounceIsTheOneTheADRNames()``.
@MainActor
final class BufferFixture {
    let directory: URL
    let url: URL

    init(_ source: String = "# Doc\n\n- [ ] one\n\nbody\n", named name: String = "doc.md") throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func buffer(autosave: TimeInterval = 0.05, preview: TimeInterval = 0.02) throws -> Buffer {
        try Buffer.open(url: url, autosaveDelay: autosave, previewDelay: preview)
    }

    func contents() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// A save the way vim does it: temp file, then rename over the target.
    func saveExternally(_ source: String) throws {
        let temp = directory.appendingPathComponent(".swap-\(UUID().uuidString)")
        try source.write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Files in the directory that are not the document — a leaked temp file
    /// from the atomic write would show up here, and in the user's `git status`.
    func strayFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != url.lastPathComponent }
    }

    func settle(_ duration: Duration = .milliseconds(200)) async {
        try? await _Concurrency.Task.sleep(for: duration)
    }

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
}

@Suite("Buffer — the source of truth while dirty")
@MainActor
struct EditorTests {

    /// The numbers the ADR states, asserted so a "tuning" commit has to argue
    /// with it rather than with a comment.
    @Test("the autosave debounce is the 800 ms the ADR names")
    func theDebounceIsTheOneTheADRNames() {
        #expect(Buffer.autosaveDebounce == 0.800)
        // Not in the ADR — the ADR leaves the preview's cadence open — but it
        // must be well under the autosave's, or the preview is only as live as
        // the file.
        #expect(Buffer.previewDebounce < Buffer.autosaveDebounce)
    }

    @Test("typing makes the tab dirty and nothing is written until the debounce fires")
    func typingIsDebounced() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.25)
        let original = try fixture.contents()

        buffer.replaceContents(original + "typed\n")
        #expect(buffer.isDirty)
        #expect(buffer.hasPendingSave)
        // Immediately after the keystroke: still the old file, byte for byte.
        #expect(try fixture.contents() == original)

        #expect(await fixture.waitUntil("the autosave to land") { !buffer.isDirty })
        #expect(try fixture.contents() == original + "typed\n")
        #expect(try fixture.strayFiles().isEmpty, "a temp file from the atomic write leaked")
    }

    @Test("a burst of keystrokes writes once, 800 ms after the last one")
    func aBurstWritesOnce() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.15)
        var saves = 0
        buffer.onSaved = { _ in saves += 1 }

        var text = try fixture.contents()
        for index in 0..<20 {
            text += "line \(index)\n"
            buffer.replaceContents(text)
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        #expect(saves == 0, "the debounce restarted \(saves) times too few")
        #expect(await fixture.waitUntil("the autosave to land") { !buffer.isDirty })
        #expect(saves == 1)
        #expect(try fixture.contents() == text)
    }

    /// **Gate 5.** The M1 review's bug, now on a path that runs every 800 ms:
    /// `rename(2)` replaces the *name*, so a save through a symlink must
    /// resolve it first or the link is destroyed and the real note keeps the
    /// old bytes.
    @Test("autosave through a symlink writes the real file and leaves the link intact")
    func autosaveThroughASymlink() async throws {
        let fixture = try BufferFixture("# Real\n\nbody\n", named: "real.md")
        let link = fixture.directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url)

        let buffer = try Buffer.open(url: link, autosaveDelay: 0.05, previewDelay: 0.02)
        buffer.replaceContents("# Real\n\nedited through the link\n")
        #expect(await fixture.waitUntil("the autosave to land") { !buffer.isDirty })

        #expect(try fixture.contents() == "# Real\n\nedited through the link\n")
        #expect(
            try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
                == .typeSymbolicLink,
            "the symlink was replaced by a regular file"
        )
        #expect(try String(contentsOf: link, encoding: .utf8) == "# Real\n\nedited through the link\n")
    }

    /// **Gate 6, first half.** The app dies mid-debounce: the last keystrokes
    /// are lost, and that is the documented cost — but the file must be a
    /// *complete previous version*, never a truncated one.
    @Test("dropping a buffer mid-debounce loses the edit and never truncates the file")
    func killedMidDebounce() async throws {
        let fixture = try BufferFixture()
        let original = try fixture.contents()
        do {
            let buffer = try fixture.buffer(autosave: 5.0)
            buffer.replaceContents(original + "typed but never saved\n")
            #expect(buffer.hasPendingSave)
            // Scope ends: the buffer is gone with its debounce unfired, which
            // is what SIGKILL looks like from the file's point of view.
        }
        await fixture.settle(.milliseconds(100))
        let after = try fixture.contents()
        #expect(after == original, "the file changed even though no save ran")
        #expect(try MarkCore.tasks(source: after).count == 1, "the file is not a whole document")
        #expect(try fixture.strayFiles().isEmpty)
    }

    /// **Gate 6, second half.** The quit path: a pending debounce is written,
    /// so what is lost is bounded by the debounce and not by the session.
    @Test("flushing at quit writes the pending edit")
    func flushingAtQuitWrites() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)
        buffer.replaceContents("# Doc\n\n- [ ] one\n\nedited at the last moment\n")
        #expect(buffer.hasPendingSave)
        #expect(buffer.save())
        #expect(try fixture.contents() == "# Doc\n\n- [ ] one\n\nedited at the last moment\n")
        #expect(!buffer.isDirty)
    }

    /// "Never truncates" as a reader would experience it: the document is
    /// rewritten repeatedly while something else reads it, and every read is a
    /// whole document. That is what temp-file-plus-rename buys, and it is the
    /// property autosave leans on hardest.
    @Test("a concurrent reader never sees a partial document")
    func aReaderNeverSeesAPartialDocument() async throws {
        let body = String(repeating: "a paragraph of text that is long enough to matter.\n\n", count: 2_000)
        let fixture = try BufferFixture("# Big\n\n" + body, named: "big.md")
        let buffer = try fixture.buffer(autosave: 0.01)
        let expected = ["# Big\n\n" + body, "# Big\n\n" + body + "tail\n"]

        let reading = _Concurrency.Task.detached(priority: .userInitiated) { () -> Int in
            var bad = 0
            for _ in 0..<400 {
                guard let text = try? String(contentsOf: fixture.url, encoding: .utf8) else {
                    bad += 1
                    continue
                }
                if !expected.contains(text) { bad += 1 }
            }
            return bad
        }
        for index in 0..<20 {
            buffer.replaceContents(expected[index % 2])
            buffer.save()
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        #expect(await reading.value == 0, "a reader saw bytes that were not a complete document")
    }

    // MARK: - The disk changing underneath

    @Test("an external change to a clean tab is adopted, not a conflict")
    func externalChangeWhileClean() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer()
        let theirs = "# Doc\n\n- [x] one\n\nbody\n"

        let outcome = buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))
        #expect(outcome == .adopted)
        #expect(buffer.text == theirs)
        #expect(!buffer.isDirty)
        #expect(buffer.conflict == nil)
    }

    @Test("a change matching content we wrote is recognised as ours")
    func ourOwnWriteIsRecognised() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.03)
        let mine = "# Doc\n\n- [ ] one\n\nmine\n"
        buffer.replaceContents(mine)
        #expect(await fixture.waitUntil("the autosave to land") { !buffer.isDirty })

        // The watcher reports our own bytes back at us — which it should not,
        // but this is the second line of defence and it has to hold.
        let outcome = buffer.fileChanged(source: mine, hash: DocumentSource.hash(mine))
        #expect(outcome == .ours)
        #expect(buffer.conflict == nil)
    }

    @Test("someone else writing exactly what we hold makes the tab clean, not conflicted")
    func convergence() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)
        let mine = "# Doc\n\n- [ ] one\n\nboth of us typed this\n"
        buffer.replaceContents(mine)
        #expect(buffer.isDirty)

        let outcome = buffer.fileChanged(source: mine, hash: DocumentSource.hash(mine))
        #expect(outcome == .converged)
        #expect(!buffer.isDirty)
        #expect(!buffer.hasPendingSave)
    }

    /// The ADR's conflict rule, and the part that matters most: **nothing is
    /// written** until the user answers.
    @Test("an external save while dirty raises a conflict and pauses autosave")
    func externalSaveWhileDirtyConflicts() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.05)
        var conflicts: [Conflict] = []
        buffer.onConflict = { conflicts.append($0) }

        buffer.replaceContents("# Doc\n\n- [ ] one\n\nmy unsaved words\n")
        let theirs = "# Doc\n\n- [ ] one\n\ntheir words from vim\n"
        try fixture.saveExternally(theirs)
        let outcome = buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))

        guard case .conflicted(let conflict) = outcome else {
            Issue.record("expected a conflict, got \(outcome)")
            return
        }
        #expect(conflicts.count == 1)
        #expect(conflict.theirs == theirs)
        #expect(conflict.mine == "# Doc\n\n- [ ] one\n\nmy unsaved words\n")
        #expect(buffer.isConflicted)
        #expect(!buffer.hasPendingSave, "autosave is still scheduled during a conflict")

        // Well past the debounce, and still their bytes on disk.
        await fixture.settle(.milliseconds(250))
        #expect(try fixture.contents() == theirs, "autosave wrote while a conflict was open")

        // An explicit save is refused too, with a reason.
        var failures: [BufferError] = []
        buffer.onSaveFailed = { failures.append($0) }
        #expect(buffer.save() == false)
        #expect(failures.count == 1)
        #expect(try fixture.contents() == theirs)
    }

    @Test("keep-mine resumes autosave and the buffer wins")
    func keepMine() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.05)
        let mine = "# Doc\n\n- [ ] one\n\nmine\n"
        buffer.replaceContents(mine)
        let theirs = "# Doc\n\n- [ ] one\n\ntheirs\n"
        try fixture.saveExternally(theirs)
        buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))

        buffer.resolve(.keepMine)
        #expect(!buffer.isConflicted)
        #expect(await fixture.waitUntil("the resumed autosave") { !buffer.isDirty })
        #expect(try fixture.contents() == mine)
    }

    /// "Take theirs" is the resolution that must never write: the file already
    /// holds what the user chose.
    @Test("take-theirs adopts the file and writes nothing")
    func takeTheirs() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.05)
        buffer.replaceContents("# Doc\n\n- [ ] one\n\nmine\n")
        let theirs = "# Doc\n\n- [ ] one\n\ntheirs\n"
        try fixture.saveExternally(theirs)
        buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))

        var wrote = 0
        buffer.onWillWrite = { _ in wrote += 1 }
        buffer.resolve(.takeTheirs)

        #expect(buffer.text == theirs)
        #expect(!buffer.isDirty)
        #expect(!buffer.isConflicted)
        await fixture.settle(.milliseconds(150))
        #expect(wrote == 0, "resolving a conflict wrote to the file")
        #expect(try fixture.contents() == theirs)
    }

    /// vim emits two or three FSEvents per `:w`, so the same external content
    /// arrives more than once. The second must not raise a second prompt for a
    /// conflict the user has already answered.
    @Test("answering a conflict stops the same external save raising it again")
    func oneConflictPerExternalSave() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)
        var raised = 0
        buffer.onConflict = { _ in raised += 1 }

        buffer.replaceContents("# Doc\n\n- [ ] one\n\nmine\n")
        let theirs = "# Doc\n\n- [ ] one\n\ntheirs\n"
        buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))
        buffer.resolve(.keepMine)
        buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))

        #expect(raised == 1, "the same external save raised \(raised) prompts")
    }
}

// MARK: - Checkboxes on a dirty tab

@Suite("Checkbox writes — buffer while dirty, file while clean")
@MainActor
struct BufferTaskWriterTests {

    private func toggle(
        _ index: Int, in source: String, desired: TaskState
    ) throws -> TaskToggle {
        let task = try MarkCore.tasks(source: source)[index]
        return TaskToggle(
            index: index, span: task.start..<task.end, rendered: task.state, desired: desired)
    }

    /// **Gate 4.** The click lands in the buffer, and the file is not touched
    /// until autosave gets to it.
    @Test("a checkbox click on a dirty tab writes the buffer, not the file")
    func dirtyClickWritesTheBuffer() async throws {
        let fixture = try BufferFixture("- [ ] alpha\n- [ ] bravo\n")
        let buffer = try fixture.buffer(autosave: 5.0)
        let writer = BufferTaskWriter(buffer: buffer)

        buffer.replaceContents("- [ ] alpha\n- [ ] bravo\n\nand a line I typed\n")
        let onDisk = try fixture.contents()

        let result = try writer.apply(
            try toggle(1, in: buffer.text, desired: .done), to: fixture.url)
        #expect(result.checked)
        #expect(buffer.text == "- [ ] alpha\n- [x] bravo\n\nand a line I typed\n")
        #expect(try fixture.contents() == onDisk, "the click wrote the file behind autosave's back")
        #expect(buffer.isDirty)
    }

    @Test("a checkbox click on a clean tab still writes the file, unchanged")
    func cleanClickWritesTheFile() async throws {
        let fixture = try BufferFixture("- [ ] alpha\n- [ ] bravo\n")
        let buffer = try fixture.buffer(autosave: 5.0)
        let writer = BufferTaskWriter(buffer: buffer)

        let result = try writer.apply(
            try toggle(0, in: buffer.text, desired: .done), to: fixture.url)
        #expect(result.checked)
        #expect(try fixture.contents() == "- [x] alpha\n- [ ] bravo\n")
    }

    /// The dirty-tab path takes the same five states as the clean one — an
    /// ⌥-click while editing has to mean what it means the rest of the time —
    /// and the state comes back off the core's receipt rather than being
    /// assumed from what was asked for.
    @Test("every state reaches the buffer, and the receipt names the one that landed")
    func dirtyClickReachesEveryState() async throws {
        let bytes: [TaskState: String] = [
            .open: " ", .inProgress: "/", .done: "x", .cancelled: "-", .blocked: "?",
        ]
        for state in TaskState.allCases {
            let fixture = try BufferFixture("- [ ] alpha\n")
            let buffer = try fixture.buffer(autosave: 5.0)
            let writer = BufferTaskWriter(buffer: buffer)
            buffer.replaceContents("- [ ] alpha\n\nand a line I typed\n")
            let onDisk = try fixture.contents()

            let result = try writer.apply(
                try toggle(0, in: buffer.text, desired: state), to: fixture.url)
            #expect(result.state == state, "\(state.rawValue)")
            #expect(result.checked == state.isTerminal, "\(state.rawValue)")
            #expect(
                buffer.text == "- [\(bytes[state] ?? "?")] alpha\n\nand a line I typed\n",
                "\(state.rawValue)")
            #expect(try fixture.contents() == onDisk, "the click wrote the file while dirty")
        }
    }

    /// The buffer path keeps the span check `FileTaskWriter` makes. It is the
    /// second line of defence — `TaskWriterTests.spanCheckAloneIsNotEnough`
    /// shows why it cannot be the first — but a stale span that *did* move is
    /// still refused rather than written.
    @Test("a span that has moved is refused rather than written to the buffer")
    func aMovedSpanIsRefused() async throws {
        let fixture = try BufferFixture("- [ ] alpha\n")
        let buffer = try fixture.buffer(autosave: 5.0)
        let writer = BufferTaskWriter(buffer: buffer)
        let stale = try toggle(0, in: buffer.text, desired: .done)

        buffer.replaceContents("a paragraph inserted above\n\n- [ ] alpha\n")
        #expect(throws: TaskWriteRefusal.self) {
            try writer.apply(stale, to: fixture.url)
        }
        #expect(buffer.text == "a paragraph inserted above\n\n- [ ] alpha\n")
    }

    @Test("an index past the end of the buffer is refused")
    func aBadIndexIsRefused() async throws {
        let fixture = try BufferFixture("- [ ] alpha\n")
        let buffer = try fixture.buffer(autosave: 5.0)
        buffer.replaceContents("- [ ] alpha\n\ntyped\n")
        let writer = BufferTaskWriter(buffer: buffer)
        #expect(throws: TaskWriteRefusal.self) {
            try writer.apply(
                TaskToggle(index: 4, span: 2..<5, rendered: .open, desired: .done),
                to: fixture.url)
        }
    }
}

// MARK: - The editor pane

@Suite("EditorPane — TextKit 2, inherited behaviour, core-driven highlighting")
@MainActor
struct EditorPaneTests {

    private func pane() -> EditorPane {
        EditorPane(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test("the text view is backed by TextKit 2")
    func textKit2() {
        let editor = pane()
        #expect(editor.textView.textLayoutManager != nil, "this is a TextKit 1 text view")
    }

    /// The ADR chose `NSTextView` *for* these. A commit that switches one off
    /// should have to change this test and explain itself.
    @Test("undo, find, and spellcheck are inherited rather than reimplemented")
    func inheritedBehaviour() {
        let editor = pane()
        #expect(editor.textView.allowsUndo)
        #expect(editor.textView.usesFindBar)
        #expect(editor.textView.isIncrementalSearchingEnabled)
        #expect(editor.textView.isContinuousSpellCheckingEnabled)
        // The user's own Text Replacements stay on…
        #expect(editor.textView.isAutomaticTextReplacementEnabled)
        // …while the two typographic rewrites that corrupt markdown source are
        // off. See `EditorPane.configure`.
        #expect(!editor.textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.textView.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.textView.isRichText, "a rich-text editor would paste styling into markdown")
    }

    @Test("typing in the pane reaches the buffer")
    func typingReachesTheBuffer() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)
        let editor = pane()
        editor.bind(buffer)

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))

        #expect(buffer.isDirty)
        #expect(buffer.text.hasPrefix("typed # Doc"))
        #expect(buffer.text == editor.textView.string)
    }

    /// One shared text view would mean one shared undo stack, and ⌘Z after a
    /// tab switch would undo an edit in the document you are no longer looking
    /// at. Per-buffer `UndoManager`s are what prevent it.
    @Test("undo is per buffer, not per text view")
    func undoIsPerBuffer() async throws {
        let first = try BufferFixture("# First\n", named: "first.md")
        let second = try BufferFixture("# Second\n", named: "second.md")
        let editor = pane()
        let a = try first.buffer()
        let b = try second.buffer()

        editor.bind(a)
        let managerA = editor.undoManager(for: editor.textView)
        editor.bind(b)
        let managerB = editor.undoManager(for: editor.textView)

        #expect(managerA !== managerB)
        editor.bind(a)
        #expect(editor.undoManager(for: editor.textView) === managerA, "A's undo history was lost")
    }

    /// Highlighting is driven by the core's block byte ranges from a **fresh
    /// parse of the buffer** — never from the DOM, where a kept block's
    /// `data-mk-start` goes stale (M5,
    /// `DocumentPatchTests.blockByteSpansStayStaleOnKeptBlocks`). This pane has
    /// no web view at all, which is the strongest possible form of that
    /// assertion: there is no DOM to read.
    @Test("source highlighting comes from a fresh parse of the buffer")
    func highlightingFromTheCore() async throws {
        let fixture = try BufferFixture("# Heading\n\nplain paragraph\n")
        let buffer = try fixture.buffer(autosave: 5.0)
        let editor = pane()
        editor.bind(buffer)
        #expect(await fixture.waitUntil("the first highlight pass") { editor.highlightPasses > 0 })

        let storage = try #require(editor.textView.textStorage)
        let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        let paragraphFont = storage.attribute(.font, at: 15, effectiveRange: nil) as? NSFont
        #expect(headingFont != nil && paragraphFont != nil)
        #expect(headingFont != paragraphFont, "the heading is drawn like body text")
        #expect((headingFont?.pointSize ?? 0) > (paragraphFont?.pointSize ?? 0))
    }

    @Test("editing re-parses, so the highlight follows the new bytes")
    func highlightingFollowsEdits() async throws {
        let fixture = try BufferFixture("plain paragraph\n")
        let buffer = try fixture.buffer(autosave: 5.0)
        let editor = pane()
        editor.bind(buffer)
        #expect(await fixture.waitUntil("the first pass") { editor.highlightPasses > 0 })
        let passes = editor.highlightPasses

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        #expect(await fixture.waitUntil("a second pass") { editor.highlightPasses > passes })

        let storage = try #require(editor.textView.textStorage)
        let font = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize ?? 0 > EditorPane.bodyFont.pointSize, "the new heading is not styled")
    }

    /// The core speaks UTF-8 byte offsets and `NSTextStorage` speaks UTF-16.
    /// Getting this wrong shifts every highlight after the first non-ASCII
    /// character, which looks like a highlighting bug and is a units bug.
    @Test("byte offsets convert to UTF-16 offsets across multi-byte text")
    func offsetsConvert() {
        let ascii = "# Title\n\nbody\n"
        #expect(SourceOffsets.utf16(of: [0, 7, 9], in: ascii) == [0, 7, 9])

        // "# é 🙂 x": é is 2 bytes / 1 UTF-16 unit, 🙂 is 4 bytes / 2 units.
        let mixed = "# é 🙂 x"
        let bytes = Array(mixed.utf8).count
        #expect(bytes == 11, "\"# \" 2 + é 2 + space 1 + 🙂 4 + space 1 + x 1")
        #expect(SourceOffsets.utf16(of: [0, 2, 4, 5, bytes], in: mixed) == [0, 2, 3, 4, 8])
        // Past the end clamps rather than trapping.
        #expect(SourceOffsets.utf16(of: [bytes + 99], in: mixed) == [8])
    }

    /// Every mutation of the text storage has to reach the buffer, not just
    /// the ones a `shouldChangeText` hook would hear about. Typing, deleting,
    /// pasting and undoing all go through the storage, and each of them leaving
    /// the buffer behind would autosave a document the reader is not looking
    /// at.
    @Test("typing, deleting, pasting and undoing all keep the buffer in step")
    func everyEditReachesTheBuffer() async throws {
        let fixture = try BufferFixture("alpha bravo charlie\n")
        let buffer = try fixture.buffer(autosave: 5.0)
        let editor = pane()
        editor.bind(buffer)
        let view = editor.textView

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("one ", replacementRange: NSRange(location: 0, length: 0))
        #expect(buffer.text == view.string)

        // A deletion.
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.delete(nil)
        #expect(buffer.text == view.string)
        #expect(buffer.text == "alpha bravo charlie\n")

        // A multi-character replacement, which is what a paste is.
        view.insertText("REPLACED", replacementRange: NSRange(location: 0, length: 5))
        #expect(buffer.text == view.string)
        #expect(buffer.text.hasPrefix("REPLACED bravo"))

        // And an undo, which mutates the storage without anyone typing.
        editor.undoManager(for: view)?.undo()
        #expect(buffer.text == view.string)
        #expect(editor.resynchronisations == 0, "the incremental path fell back to a full resync")
    }

    /// The incremental splice is a performance fix — 86–108 ms per keystroke
    /// became 0.06 ms — and its risk is divergence: the buffer and the text
    /// view holding different documents, with autosave writing the buffer's.
    /// So the buffer refuses an edit that does not fit, and the pane
    /// resynchronises rather than carrying on.
    @Test("an edit that does not fit is refused, and the pane resynchronises")
    func divergenceIsCaught() async throws {
        let fixture = try BufferFixture("a short document\n")
        let buffer = try fixture.buffer(autosave: 5.0)

        #expect(buffer.applyEdit(replacing: NSRange(location: 0, length: 3), with: "A") == true)
        #expect(buffer.text == "Ahort document\n")
        #expect(buffer.utf16Length == buffer.text.utf16.count)

        // Past the end: refused, and nothing changed.
        #expect(buffer.applyEdit(replacing: NSRange(location: 900, length: 2), with: "x") == false)
        #expect(buffer.text == "Ahort document\n")
        // Negative and inverted ranges are refusals, not traps.
        #expect(buffer.applyEdit(replacing: NSRange(location: -1, length: 2), with: "x") == false)
        #expect(buffer.applyEdit(replacing: NSRange(location: 0, length: -2), with: "x") == false)
    }

    /// The trap `FileWatcher` documents on its own scan scheduling, in the
    /// editor: a *trailing* debounce that restarts on every keystroke never
    /// fires at all while someone types steadily, so a "live" preview would
    /// freeze for exactly as long as the user kept going. Found by measuring —
    /// the first version of this code updated the preview twice in 8 seconds of
    /// continuous typing.
    @Test("the preview updates while typing continues, rather than only when it stops")
    func thePreviewIsThrottledNotDebounced() async throws {
        let fixture = try BufferFixture("start\n")
        let buffer = try fixture.buffer(autosave: 5.0, preview: 0.03)
        var previews = 0
        buffer.onPreviewDue = { _ in previews += 1 }

        // Twenty "keystrokes" at 10 ms, i.e. faster than the preview window,
        // for twice as long as that window.
        var text = "start\n"
        for index in 0..<20 {
            text += "\(index)"
            buffer.replaceContents(text)
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
        }
        #expect(
            previews >= 2,
            "the preview fired \(previews) times during 200 ms of continuous typing at a 30 ms window"
        )
    }

    /// Autosave is the opposite, and deliberately: ADR-6 says *"autosave writes
    /// 800 ms after typing stops"*, so continuous typing must **not** produce a
    /// stream of writes. That is the "fixed-interval autosave" alternative the
    /// ADR rejects for writing mid-word.
    @Test("autosave stays a trailing debounce: continuous typing writes nothing")
    func autosaveIsDebouncedNotThrottled() async throws {
        let fixture = try BufferFixture("start\n")
        let buffer = try fixture.buffer(autosave: 0.12, preview: 0.03)
        var saves = 0
        buffer.onSaved = { _ in saves += 1 }

        var text = "start\n"
        for index in 0..<20 {
            text += "\(index)"
            buffer.replaceContents(text)
            try? await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        #expect(saves == 0, "typing for 400 ms with a 120 ms debounce wrote \(saves) time(s)")
        #expect(await fixture.waitUntil("the write after typing stops") { !buffer.isDirty })
        #expect(saves == 1)
    }

    @Test("binding to nothing leaves an empty, uneditable pane")
    func unbound() {
        let editor = pane()
        editor.bind(nil)
        #expect(editor.textView.string.isEmpty)
        #expect(!editor.textView.isEditable)
    }
}

// MARK: - Conflicts

@Suite("Conflicts — prompt, never guess")
@MainActor
struct ConflictTests {

    /// A presenter that answers from a script, so the state machine can be
    /// driven without a modal.
    final class ScriptedPresenter: ConflictPresenter {
        var answers: [ConflictChoice]
        private(set) var prompts = 0
        private(set) var diffsShown: [ConflictDiff] = []

        init(_ answers: [ConflictChoice]) { self.answers = answers }

        func presentConflict(
            _ conflict: Conflict, for url: URL, answer: @escaping (ConflictChoice) -> Void
        ) {
            prompts += 1
            answer(answers.isEmpty ? .keepMine : answers.removeFirst())
        }

        func presentDiff(_ diff: ConflictDiff, for url: URL, done: @escaping () -> Void) {
            diffsShown.append(diff)
            done()
        }
    }

    /// The shipped app's case, which every other test in this suite hides.
    ///
    /// ``MainWindowController`` constructs its ``AlertConflictPresenter``
    /// inline and hands it to ``ConflictController``, keeping no reference of
    /// its own — so if the controller's reference is weak the presenter is gone
    /// before the first conflict, and ADR-6's prompt never appears. A test that
    /// binds `let presenter = ...` retains it and passes either way, which is
    /// exactly how that survived M9. This one drops the caller's reference on
    /// purpose.
    @Test("the controller keeps its presenter alive after the caller lets go")
    func conflictControllerKeepsItsPresenterAlive() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)
        let controller = ConflictController()
        // Constructed and handed over in one expression, exactly as the window
        // does it: nothing outside the controller refers to it afterwards.
        controller.use(presenter: ScriptedPresenter([.keepMine]))
        buffer.onConflict = { controller.handle($0, for: buffer) }

        buffer.replaceContents("# Doc\n\n- [ ] one\n\nmine\n")
        let theirs = "# Doc\n\n- [ ] one\n\ntheirs\n"
        buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))

        #expect(controller.presenter != nil, "the presenter was deallocated on handover")
        let asked = (controller.presenter as? ScriptedPresenter)?.prompts ?? 0
        #expect(asked == 1, "the conflict was never put to the user")
        #expect(controller.resolutions == [.keepMine])
        #expect(!buffer.isConflicted)
    }

    @Test("show-diff shows the diff and then asks again")
    func showDiffAsksAgain() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)
        let presenter = ScriptedPresenter([.showDiff, .keepMine])
        let controller = ConflictController(presenter: presenter)
        buffer.onConflict = { controller.handle($0, for: buffer) }

        buffer.replaceContents("# Doc\n\n- [ ] one\n\nmine\n")
        let theirs = "# Doc\n\n- [ ] one\n\ntheirs\n"
        buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))

        #expect(presenter.prompts == 2, "showing the diff should not count as an answer")
        #expect(presenter.diffsShown.count == 1)
        #expect(controller.resolutions == [.keepMine])
        #expect(!buffer.isConflicted)
    }

    @Test("with no way to ask, autosave stays paused rather than guessing")
    func noPresenterMeansNoWrite() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.05)
        let controller = ConflictController()
        buffer.onConflict = { controller.handle($0, for: buffer) }

        buffer.replaceContents("# Doc\n\n- [ ] one\n\nmine\n")
        let theirs = "# Doc\n\n- [ ] one\n\ntheirs\n"
        try fixture.saveExternally(theirs)
        buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))

        await fixture.settle(.milliseconds(200))
        #expect(buffer.isConflicted)
        #expect(try fixture.contents() == theirs, "something wrote without an answer")
    }

    @Test("the diff names the lines that differ")
    func theDiff() {
        let diff = ConflictDiff.between(
            mine: "one\ntwo\nmine\nfour\n",
            theirs: "one\ntwo\ntheirs\nfour\n")
        #expect(diff.added == 1)
        #expect(diff.removed == 1)
        #expect(!diff.truncated)
        #expect(diff.lines.contains { $0.kind == .mine && $0.text == "mine" })
        #expect(diff.lines.contains { $0.kind == .theirs && $0.text == "theirs" })
        // "one", "two", "four", and the empty line after the trailing newline.
        #expect(diff.lines.filter { $0.kind == .same }.count == 4)
    }

    /// A quadratic LCS on two 100k-line documents would hang the dialog. Saying
    /// "too large to diff" is a worse answer than a diff and a much better one
    /// than a beachball.
    @Test("an enormous difference is reported as truncated rather than computed")
    func hugeDiff() {
        let mine = String(repeating: "a line of text\n", count: 5_000)
        let theirs = String(repeating: "a different line\n", count: 5_000)
        let diff = ConflictDiff.between(mine: mine, theirs: theirs)
        #expect(diff.truncated)
    }
}

// MARK: - Residency

@Suite("Residency — a dirty tab is never dehydrated")
@MainActor
struct DirtyResidencyTests {

    /// **Gate 3.** ADR-6 exempts dirty tabs from ADR-4's MRU eviction, and
    /// ADR-7 records the cost: ~52 MB each. So this asserts the exemption *and*
    /// that clean tabs are still evicted — an exemption that quietly stopped
    /// evicting anything would pass a weaker test.
    @Test("a dirty tab stays resident at MRU position 30, while clean tabs are evicted")
    func aDirtyTabIsNeverEvicted() async throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.tabs.residentLimit = 3

        let dirtyURL = fixture.file(named: "a.md")
        controller.open(dirtyURL)
        let dirty = try #require(controller.tabs.tab(for: dirtyURL))
        let buffer = try #require(controller.buffer(for: dirty))
        buffer.replaceContents("# a.md\n\n- [ ] open task 0\n\nunsaved words\n")
        #expect(dirty.isDirty)
        #expect(dirty.state.isResident)

        // Thirty more documents, each selected in turn, so the dirty tab is the
        // least recently used by a wide margin.
        let others = try fixture.makeDocuments(count: 30, prefix: "other")
        for url in others { controller.open(url) }

        #expect(controller.tabs.mruOrder.last === dirty, "the dirty tab is not the LRU tab")
        #expect(dirty.state.isResident, "an unsaved tab was dehydrated")
        #expect(dirty.buffer?.text.contains("unsaved words") == true)

        // Clean tabs are still evicted around it: the exempt tab occupies one
        // of the resident slots rather than being extra, so the working set is
        // still the limit — it only overflows when there are more dirty tabs
        // than slots, which is the case ADR-7 prices at ~52 MB each.
        #expect(controller.tabs.residentCount == controller.tabs.residentLimit)
        #expect(controller.tabs.tabs.filter { $0.state.isResident }.contains { $0 === dirty })

        // And once it is clean it is an ordinary tab again: the next few
        // selections push it out exactly as they would any other LRU tab.
        #expect(buffer.save())
        #expect(!dirty.isDirty)
        for url in others.prefix(4) { controller.tabs.select(controller.tabs.tab(for: url)) }
        #expect(!dirty.state.isResident, "a saved tab is still exempt from eviction")
    }
}
