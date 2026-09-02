import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Getting a document *out* of mark — onto paper, into a PDF, into a file
/// someone else can open.
///
/// mark could render sixteen themes, math, and diagrams, and had no way to
/// produce any of it anywhere but its own window: no ⌘P, no export, nothing.
/// For a viewer that is the odd gap, and the machinery was already there —
/// `mark render --html` has emitted a self-contained document since M1.
///
/// ## What gets printed
///
/// The **preview**, never the editor. Paper wants the rendered document, and
/// the source pane is a working view. `WKWebView.printOperation(with:)` is what
/// does it, so what comes out is what WebKit laid out — including the
/// `@media print` rules in `shell.css`, which drop the themed background and
/// the chrome that only makes sense on screen.
///
/// ## Why export goes through the core rather than through the web view
///
/// `File ▸ Export as HTML…` asks the core for a standalone render rather than
/// asking the page for its `innerHTML`. Three reasons, in order of how much
/// they matter: the page holds only the blocks that have been *painted* so far
/// (ADR-2 fills the tail behind first paint, and a dehydrated tab has none of
/// it); the page's DOM carries `data-blk` and the find highlights and other
/// things that are ours rather than the document's; and going through the core
/// means an exported file is byte-identical to what `mark render --html` would
/// have written, which is the property that keeps the app and the CLI from
/// drifting.
@MainActor
public enum DocumentOutput {

    /// The rendered document, as a complete HTML file.
    ///
    /// Source comes from the caller rather than being read here, because the
    /// buffer is the truth while a tab is dirty and the file is the truth when
    /// it is clean — the rule every feature that touches document bytes has to
    /// obey, and not one this type gets to decide for itself.
    public static func html(source: String, title: String?) throws -> String {
        try MarkCore.renderHTML(
            source: source,
            theme: ThemeController.shared.name,
            standalone: true)
    }

    /// The name to put in the save panel: the document's, with the extension
    /// swapped. A document with no file behind it — the Today page — falls back
    /// to its title.
    public static func suggestedName(for url: URL?, title: String?, extension ext: String)
        -> String
    {
        let base =
            url.map { $0.deletingPathExtension().lastPathComponent }
            ?? title.map(sanitizedFilename) ?? "document"
        return "\(base).\(ext)"
    }

    /// A title is a heading, not a filename: it can hold a slash, which would
    /// silently make a save panel name a *directory*.
    static func sanitizedFilename(_ title: String) -> String {
        let cleaned = title.map { character -> Character in
            character == "/" || character == ":" ? "-" : character
        }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "document" : trimmed
    }

    /// A print operation for a rendered document.
    ///
    /// Returns `nil` when there is no page to print — a dehydrated tab, or a
    /// window showing nothing. The caller reports that; this does not put up a
    /// dialog of its own.
    public static func printOperation(for webView: WKWebView, jobName: String)
        -> NSPrintOperation
    {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        // Margins in points. WebKit's own default is zero, which prints text
        // into the edge of the paper on every printer that cannot reach it.
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let operation = webView.printOperation(with: info)
        operation.jobTitle = jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    /// The same operation, aimed at a PDF file instead of a printer.
    ///
    /// `File ▸ Export as PDF…` rather than "print to PDF" because the print
    /// panel's own PDF menu is a place people do not find, and because a
    /// document viewer that cannot produce a PDF is missing the format most
    /// often asked for.
    public static func pdfOperation(for webView: WKWebView, writingTo url: URL)
        -> NSPrintOperation
    {
        let operation = printOperation(for: webView, jobName: url.lastPathComponent)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let info = operation.printInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        return operation
    }
}
