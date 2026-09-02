import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// Getting a document out of mark — ⌘P, Export as HTML, Export as PDF.
///
/// The gap these close: mark could render sixteen themes, math and diagrams,
/// and had no way to produce any of it anywhere but its own window, while
/// `mark render --html` had emitted a self-contained document since M1.
@Suite("Getting a document out")
@MainActor
struct DocumentOutputTests {

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // ---- Export as HTML ---------------------------------------------------

    @Test("the export is a complete document, not the fragments the shell injects")
    func exportIsStandalone() throws {
        let html = try DocumentOutput.html(source: "# Title\n\nsome text\n", title: "Title")
        #expect(html.hasPrefix("<!DOCTYPE html>"), "not a document: \(html.prefix(60))")
        #expect(html.contains("<style>"), "styles must be inline")
        #expect(html.contains("some text"))
    }

    @Test("the export carries no script, whoever wrote the markdown")
    func exportCarriesNoScript() throws {
        // The other half of `2026-09-01-filter-embedded-html`: an export is a
        // file handed to someone else, so it is the last place a document's
        // script should survive.
        let html = try DocumentOutput.html(
            source: "# Notes\n\n<script>alert(1)</script>\n\n[x](javascript:alert(1))\n",
            title: "Notes")
        #expect(!html.contains("<script>alert"), "a script survived the export")
        #expect(!html.lowercased().contains("javascript:"))
    }

    @Test("it carries print rules, because an export is a thing people print")
    func exportCarriesPrintRules() throws {
        let html = try DocumentOutput.html(source: "# Title\n", title: "Title")
        #expect(html.contains("@media print"), "a dark theme would print as a page of toner")
    }

    @Test("the export is what the CLI would have written")
    func exportMatchesTheCLI() throws {
        // The property that keeps the app and the CLI from drifting — ADR-5's
        // rule, applied to output rather than to parsing. Both go through
        // `mark_render_html` with the same flag, so this compares the whole
        // string rather than sampling it.
        let source = "# Title\n\n- [ ] a task\n\n`code`\n\n$x^2$\n"
        let viaApp = try DocumentOutput.html(source: source, title: nil)
        let viaCore = try MarkCore.renderHTML(
            source: source, theme: ThemeController.shared.name, standalone: true)
        #expect(viaApp == viaCore)
    }

    // ---- the name in the save panel ---------------------------------------

    @Test("the suggested name is the document's, with the extension swapped")
    func suggestedNameFollowsTheFile() {
        let url = URL(fileURLWithPath: "/notes/2026/quarterly review.md")
        #expect(
            DocumentOutput.suggestedName(for: url, title: "Ignored", extension: "pdf")
                == "quarterly review.pdf")
        #expect(
            DocumentOutput.suggestedName(for: url, title: nil, extension: "html")
                == "quarterly review.html")
    }

    @Test("a document with no file behind it falls back to its title")
    func suggestedNameFallsBackToTheTitle() {
        // The Today page, which is assembled rather than read.
        #expect(
            DocumentOutput.suggestedName(for: nil, title: "Today", extension: "pdf")
                == "Today.pdf")
        #expect(
            DocumentOutput.suggestedName(for: nil, title: nil, extension: "pdf")
                == "document.pdf")
    }

    @Test("a title with a slash in it does not become a directory")
    func aTitleIsNotAPath() {
        // A heading is prose and may hold anything. `NSSavePanel` reads a `/`
        // in `nameFieldStringValue` as a path separator.
        #expect(
            DocumentOutput.suggestedName(for: nil, title: "Q3/Q4 plan", extension: "html")
                == "Q3-Q4 plan.html")
        #expect(
            DocumentOutput.suggestedName(for: nil, title: "   ", extension: "html")
                == "document.html")
    }

    // ---- printing ---------------------------------------------------------

    @Test("a print operation prints the preview, with margins")
    func printOperationHasMargins() async throws {
        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        defer { view.tearDown() }
        let webView = try #require(view.webView)

        let operation = DocumentOutput.printOperation(for: webView, jobName: "notes.md")
        #expect(operation.jobTitle == "notes.md")
        // WebKit's own default is zero, which prints into the edge of the paper
        // on every printer that cannot reach it.
        #expect(operation.printInfo.topMargin > 0)
        #expect(operation.printInfo.leftMargin > 0)
    }

    @Test("the PDF operation writes to a file instead of asking for a printer")
    func pdfOperationSavesToAFile() async throws {
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("out.pdf")

        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        defer { view.tearDown() }
        let webView = try #require(view.webView)

        let operation = DocumentOutput.pdfOperation(for: webView, writingTo: target)
        #expect(operation.printInfo.jobDisposition == .save)
        #expect(!operation.showsPrintPanel, "an export must not put up a print dialog")
        let saved = operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL]
        #expect((saved as? URL) == target)
    }
}
