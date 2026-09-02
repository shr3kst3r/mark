import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The markdown the editor knows about.
///
/// `2026-08-25-flock-write-locking` chose `NSTextView` to inherit the system's
/// undo, spellcheck and Find & Replace rather than reimplementing them, and the
/// cost was that ⏎ in the middle of a list started a paragraph and there was no
/// ⌘B. These pin the language half without needing a text view for any of it.
@Suite("Markdown editing")
struct MarkdownEditingTests {

    // ---- reading a list item ----------------------------------------------

    @Test("the ordinary markers are recognised")
    func markersAreRecognised() throws {
        for line in ["- item", "* item", "+ item", "1. item", "12) item"] {
            #expect(MarkdownEditing.listPrefix(of: line) != nil, "\(line) was not a list item")
        }
    }

    @Test("a marker with no space after it is not a list")
    func aMarkerNeedsItsSpace() {
        // GFM's rule, and the same one `tasks.rs` applies to `- [x]nospace`.
        #expect(MarkdownEditing.listPrefix(of: "-text") == nil)
        #expect(MarkdownEditing.listPrefix(of: "1.text") == nil)
        #expect(MarkdownEditing.listPrefix(of: "not a list") == nil)
        #expect(MarkdownEditing.listPrefix(of: "1234 no delimiter") == nil)
    }

    @Test("indentation is kept exactly")
    func indentationSurvives() throws {
        // Markdown's nesting rules count these, so a continuation that
        // re-indents silently changes the structure.
        let prefix = try #require(MarkdownEditing.listPrefix(of: "    - nested"))
        #expect(prefix.indent == "    ")
        #expect(prefix.continuation == "    - ")

        let tabbed = try #require(MarkdownEditing.listPrefix(of: "\t- tabbed"))
        #expect(tabbed.continuation == "\t- ")
    }

    @Test("an ordered list counts on, keeping the delimiter it was written with")
    func orderedListsCount() throws {
        #expect(try #require(MarkdownEditing.listPrefix(of: "3. third")).continuation == "4. ")
        // `)` is legal too, and switching it is a change the reader did not
        // make.
        #expect(try #require(MarkdownEditing.listPrefix(of: "3) third")).continuation == "4) ")
    }

    @Test("a task continues as an open task, whatever state it was in")
    func tasksContinueOpen() throws {
        for line in ["- [x] done", "- [/] doing", "- [-] dropped", "- [?] blocked"] {
            let prefix = try #require(MarkdownEditing.listPrefix(of: line))
            #expect(
                prefix.continuation == "- [ ] ",
                "\(line) continued as something already finished")
        }
    }

    // ---- what Return does --------------------------------------------------

    @Test("return in a list item starts the next one")
    func returnContinues() {
        #expect(MarkdownEditing.newlineAction(forLine: "- item") == .insert("\n- "))
        #expect(MarkdownEditing.newlineAction(forLine: "2. item") == .insert("\n3. "))
        #expect(MarkdownEditing.newlineAction(forLine: "  - [ ] task") == .insert("\n  - [ ] "))
    }

    @Test("return in an empty item ends the list rather than making another")
    func returnEndsAnEmptyItem() {
        // The reason ⏎⏎ ends a list instead of producing bullets forever.
        #expect(MarkdownEditing.newlineAction(forLine: "- ") == .clearLine(""))
        #expect(MarkdownEditing.newlineAction(forLine: "  - [ ] ") == .clearLine("  "))
    }

    @Test("return anywhere else is the system's")
    func returnIsOtherwiseInherited() {
        // `nil` is what hands the key back to NSTextView, which is the whole
        // shape of this feature: inherit everything, override the one case.
        #expect(MarkdownEditing.newlineAction(forLine: "just a paragraph") == nil)
        #expect(MarkdownEditing.newlineAction(forLine: "") == nil)
        #expect(MarkdownEditing.newlineAction(forLine: "# A heading") == nil)
    }

    // ---- wrapping ----------------------------------------------------------

    private func wrap(_ text: String, _ selected: String, _ marker: String) -> (String, String) {
        let range = text.range(of: selected)!
        let result = MarkdownEditing.toggleWrap(text, range: range, marker: marker)
        return (result.text, String(result.text[result.selection]))
    }

    @Test("bold wraps the selection and selects what is inside")
    func boldWraps() {
        let (text, selection) = wrap("make this bold", "this", "**")
        #expect(text == "make **this** bold")
        #expect(selection == "this", "the selection should survive the wrap")
    }

    @Test("bold on an already-bold selection unwraps it")
    func boldUnwraps() {
        // Both spellings: markers inside the selection, and markers around it.
        #expect(wrap("make **this** bold", "**this**", "**").0 == "make this bold")
        #expect(wrap("make **this** bold", "this", "**").0 == "make this bold")
    }

    @Test("a trailing space stays outside the markers")
    func trailingSpaceStaysOut() {
        // `**word **` is not even bold in GFM — emphasis will not open before
        // a space — and a double-click often hands you the trailing one.
        let (text, _) = wrap("make this bold", "this ", "**")
        #expect(text == "make **this** bold")
    }

    @Test("an empty selection inserts the pair and sits between them")
    func emptySelectionInserts() {
        let text = "type here: "
        let at = text.endIndex
        let result = MarkdownEditing.toggleWrap(text, range: at..<at, marker: "**")
        #expect(result.text == "type here: ****")
        #expect(result.selection.isEmpty)
        // So that typing next lands inside the markers.
        #expect(result.text.distance(from: result.text.startIndex, to: result.selection.lowerBound) == 13)
    }

    @Test("the same machinery does italic, code, and strikethrough")
    func otherMarkers() {
        #expect(wrap("a b c", "b", "*").0 == "a *b* c")
        #expect(wrap("a b c", "b", "`").0 == "a `b` c")
        #expect(wrap("a b c", "b", "~~").0 == "a ~~b~~ c")
    }

    // ---- links -------------------------------------------------------------

    @Test("a link wraps the selection and puts the caret in the parentheses")
    func linkWithNoURL() {
        let text = "see the runbook"
        let range = text.range(of: "the runbook")!
        let result = MarkdownEditing.makeLink(text, range: range)
        #expect(result.text == "see [the runbook]()")
        #expect(result.selection.isEmpty)
        // Between the parens, so a URL can be typed straight in.
        #expect(result.text[result.selection.lowerBound...] == ")")
    }

    @Test("a URL on the pasteboard goes straight in, and the text is selected")
    func linkWithURL() {
        let text = "see the runbook"
        let range = text.range(of: "the runbook")!
        let result = MarkdownEditing.makeLink(text, range: range, url: "https://x.test")
        #expect(result.text == "see [the runbook](https://x.test)")
        #expect(String(result.text[result.selection]) == "the runbook")
    }

    // ---- headings ----------------------------------------------------------

    @Test("a heading level is set, replaced, and removed")
    func headings() {
        #expect(MarkdownEditing.setHeading("Title", level: 1) == "# Title")
        // Replaced, never stacked.
        #expect(MarkdownEditing.setHeading("# Title", level: 2) == "## Title")
        #expect(MarkdownEditing.setHeading("### Title", level: 1) == "# Title")
        #expect(MarkdownEditing.setHeading("## Title", level: 0) == "Title")
        // Applying the same level twice is a no-op, not a double.
        #expect(MarkdownEditing.setHeading(MarkdownEditing.setHeading("T", level: 3), level: 3) == "### T")
    }

    @Test("prose that starts with hashes is not a heading and is left alone")
    func hashesWithoutASpace() {
        // `#tag` in a note is prose. Rewriting it would change a document
        // nobody asked to change.
        #expect(MarkdownEditing.headingLevel(of: "#hashtag") == 0)
        #expect(MarkdownEditing.setHeading("#hashtag", level: 2) == "## #hashtag")
        #expect(MarkdownEditing.headingLevel(of: "## Real") == 2)
        #expect(MarkdownEditing.headingLevel(of: "Not a heading") == 0)
    }

    @Test("a heading cannot go past six")
    func headingsStopAtSix() {
        #expect(MarkdownEditing.setHeading("T", level: 9) == "###### T")
        #expect(MarkdownEditing.headingLevel(of: "####### too many") == 0)
    }
}

/// The same commands, driven through a real `NSTextView`.
///
/// The pure functions above cannot catch a command that never reaches the
/// buffer, or one that reaches it without going through the undo manager.
@Suite("Markdown editing in the pane")
@MainActor
struct MarkdownEditingPaneTests {

    /// A pane with a real ``Buffer`` behind it.
    ///
    /// Bound rather than bare, because the pane vends the *buffer's* undo
    /// manager — ADR-6 makes the buffer the source of truth, and the pane never
    /// reads a file — so an unbound pane has no undo to assert on.
    private func pane(_ text: String, select: String? = nil) -> (EditorPane, Buffer) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-editing-\(UUID().uuidString).md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let buffer = Buffer(url: url, text: text)

        let pane = EditorPane(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.bind(buffer)
        if let select, let range = text.range(of: select) {
            pane.textView.setSelectedRange(NSRange(range, in: text))
        }
        return (pane, buffer)
    }

    @Test("bold reaches the buffer")
    func boldEdits() {
        let (pane, _) = pane("make this bold", select: "this")
        pane.wrapSelection(with: "**")
        #expect(pane.textView.string == "make **this** bold")
    }

    @Test("a formatting command is one undo step")
    func formattingIsUndoable() {
        // Through `shouldChangeText`/`didChangeText`, or ⌘Z would not see it
        // and neither would autosave.
        let (pane, buffer) = pane("make this bold", select: "this")
        pane.wrapSelection(with: "**")
        #expect(pane.textView.string == "make **this** bold")
        #expect(buffer.isDirty, "the edit never reached the buffer")

        // The pane vends the undo manager through the delegate — it is the
        // buffer's, not the text view's own — so a test that reaches for
        // `textView.undoManager` is asking the wrong object.
        let undo = pane.undoManager(for: pane.textView)
        #expect(undo != nil, "the pane vends no undo manager")
        undo?.undo()
        #expect(pane.textView.string == "make this bold", "the edit was not undoable")
    }

    @Test("a heading is applied to the line the caret is on")
    func headingOnCaretLine() {
        let (pane, _) = pane("first\nsecond\nthird")
        let text = pane.textView.string
        let range = text.range(of: "second")!
        pane.textView.setSelectedRange(NSRange(range, in: text))

        pane.setHeading(level: 2)
        #expect(pane.textView.string == "first\n## second\nthird")
    }

    @Test("a heading is applied to every line a selection touches")
    func headingAcrossASelection() {
        let (pane, _) = pane("one\ntwo\nthree")
        let text = pane.textView.string
        let range = text.range(of: "one\ntwo")!
        pane.textView.setSelectedRange(NSRange(range, in: text))

        pane.setHeading(level: 3)
        #expect(pane.textView.string == "### one\n### two\nthree")
    }
}
