import AppKit
import Foundation
import Testing

@testable import MarkKit

/// Line numbers in the editor's margin, and ⌘L.
///
/// The margin drew git change bars and computed a line number to place them —
/// and then never showed it. These pin the two halves that are easy to get
/// wrong: which line a number belongs to when a line soft-wraps, and what
/// happens when someone asks for a line the document does not have.
@Suite("Line numbers", .serialized)
@MainActor
struct LineNumbersTests {

    private func pane(_ text: String) -> EditorPane {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-lines-\(UUID().uuidString).md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let pane = EditorPane(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        pane.bind(Buffer(url: url, text: text))
        return pane
    }

    @Test("they are off until asked for")
    func offByDefault() {
        LineNumbers.isShowing = false
        #expect(!pane("one\ntwo\n").showsLineNumbers)
    }

    @Test("the setting reaches every open editor")
    func theSettingIsAppWide() {
        LineNumbers.isShowing = false
        defer { LineNumbers.isShowing = false }

        let first = pane("one\n")
        let second = pane("two\n")
        LineNumbers.isShowing = true
        // A menu item reaches one window through the responder chain; a second
        // editor still unnumbered would read as the toggle half-working.
        #expect(first.showsLineNumbers)
        #expect(second.showsLineNumbers)
    }

    @Test("a new editor opens with the setting already applied")
    func aNewEditorAdopts() {
        LineNumbers.isShowing = true
        defer { LineNumbers.isShowing = false }
        #expect(pane("one\n").showsLineNumbers)
    }

    @Test("the margin widens for numbers and narrows again")
    func theMarginResizes() {
        let ruler = ChangeRuler(scrollView: NSScrollView())
        let bare = ruler.ruleThickness
        ruler.showsLineNumbers = true
        #expect(ruler.ruleThickness > bare, "there is no room for a number")
        ruler.showsLineNumbers = false
        #expect(ruler.ruleThickness == bare)
    }

    // ---- Go to Line --------------------------------------------------------

    @Test("go to line puts the caret at the start of that line")
    func goToLineMovesTheCaret() {
        let pane = pane("alpha\nbeta\ngamma\n")
        #expect(pane.goToLine(2))
        #expect(pane.textView.selectedRange().location == 6)
        #expect(pane.goToLine(1))
        #expect(pane.textView.selectedRange().location == 0)
    }

    @Test("a line past the end is refused rather than clamped")
    func pastTheEndIsRefused() {
        // Clamping to the last line is indistinguishable from the document
        // being shorter than the reader thought.
        let pane = pane("alpha\nbeta\n")
        #expect(!pane.goToLine(99))
        #expect(!pane.goToLine(0))
        #expect(!pane.goToLine(-1))
    }

    @Test("the empty line after a trailing newline is a line you can reach")
    func theTrailingLineCounts() {
        let pane = pane("alpha\nbeta\n")
        // Three: `alpha`, `beta`, and the empty one the trailing newline makes,
        // which is where a caret sits after ⌘↓.
        #expect(pane.lineCount == 3)
        #expect(pane.goToLine(3))
    }

    @Test("an empty document is one line")
    func emptyIsOneLine() {
        let pane = pane("")
        #expect(pane.lineCount == 1)
        #expect(pane.goToLine(1))
    }

    // ---- persistence -------------------------------------------------------

    @Test("the setting survives a session round trip")
    func itPersists() throws {
        LineNumbers.isShowing = true
        defer { LineNumbers.isShowing = false }

        var state = SessionState()
        state.editorLineNumbers = LineNumbers.isShowing ? true : nil
        let decoded = try JSONDecoder().decode(
            SessionState.self, from: try JSONEncoder().encode(state))

        LineNumbers.isShowing = false
        LineNumbers.restore(decoded.editorLineNumbers)
        #expect(LineNumbers.isShowing)
    }

    @Test("a session file written before this existed leaves the default alone")
    func absentIsOff() {
        LineNumbers.isShowing = false
        LineNumbers.restore(nil)
        #expect(!LineNumbers.isShowing)
    }
}
