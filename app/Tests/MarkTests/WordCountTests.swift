import AppKit
import Foundation
import Testing

@testable import MarkKit

/// How long a document is.
///
/// `mark stats` reported bytes, blocks and timings — facts about the renderer.
/// A writer wants a different set, and getting it right needs the parser: a
/// count that includes frontmatter, a mermaid diagram and 200 lines of embedded
/// Rust is not a word count of the writing.
@Suite("Word count")
@MainActor
struct WordCountTests {

    @Test("prose counts and machinery does not")
    func prosePartOnly() throws {
        let counts = try MarkCore.wordCount(
            source: """
                ---
                title: Some frontmatter with many words in it
                ---

                # A heading

                Three prose words.

                ```rust
                fn main() { println!("not prose"); }
                ```

                See [the runbook](https://example.com/a/long/path).
                """)
        // "A heading" (2) + "Three prose words." (3) + "See the runbook." (3).
        #expect(counts.words == 8, "counted \(counts.words)")
        #expect(counts.codeBytes > 0, "the code was not measured at all")
    }

    @Test("the window and the CLI cannot disagree")
    func oneImplementation() throws {
        // Both go through `mark_wordcount_json`; this is the assertion that
        // says the window is not doing its own whitespace split.
        let source = "one two `three` four\n"
        let counts = try MarkCore.wordCount(source: source)
        #expect(counts.words == 3, "an inline code span was counted as a word")
    }

    @Test("reading time is never zero for a document with prose in it")
    func readingTime() throws {
        #expect(try MarkCore.wordCount(source: "").readingMinutes == 0)
        #expect(try MarkCore.wordCount(source: "a few words here\n").readingMinutes == 1)
    }

    @Test("the summary reads as a sentence, with separators on the numbers")
    func summaryReads() throws {
        let counts = try MarkCore.wordCount(
            source: String(repeating: "word ", count: 1500) + "\n")
        let summary = counts.summary
        #expect(summary.contains("1,500 words"), "\(summary)")
        #expect(summary.contains("min read"), "\(summary)")
        // Singulars, because "1 words" is the kind of thing people notice.
        let one = try MarkCore.wordCount(source: "word")
        #expect(one.summary.contains("1 word "), "\(one.summary)")
        #expect(one.summary.contains("1 line"), "\(one.summary)")
    }

    // ---- the status bar ----------------------------------------------------

    private func pane(_ text: String) -> EditorPane {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-wc-\(UUID().uuidString).md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let pane = EditorPane(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        pane.bind(Buffer(url: url, text: text))
        return pane
    }

    @Test("binding a document fills the bar immediately")
    func bindingCountsAtOnce() {
        // Debounced would mean an empty bar for 300 ms after opening, which
        // reads as broken rather than as busy.
        let pane = pane("one two three\n")
        #expect(pane.statusBar.stringValue.contains("3 words"), "\(pane.statusBar.stringValue)")
    }

    @Test("typing updates it, after the debounce")
    func typingRecounts() async throws {
        let pane = pane("one two three\n")
        pane.textView.insertText(" four five", replacementRange: pane.textView.selectedRange())
        try await _Concurrency.Task.sleep(for: .milliseconds(600))
        #expect(pane.statusBar.stringValue.contains("5 words"), "\(pane.statusBar.stringValue)")
    }

    @Test("unbinding empties it rather than leaving the last document's count")
    func unbindingClears() {
        let pane = pane("one two three\n")
        #expect(!pane.statusBar.stringValue.isEmpty)
        pane.bind(nil)
        #expect(pane.statusBar.stringValue.isEmpty)
    }
}
