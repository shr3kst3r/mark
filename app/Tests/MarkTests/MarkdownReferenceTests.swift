import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The shipped markdown reference — the document behind **Help ▸ Markdown
/// Reference**.
///
/// `2026-08-26-markdown-reference-window` names the cost these tests exist to
/// pay down:
///
/// > The reference is one more thing to keep true. It is a claim about the
/// > renderer's behaviour that lives outside the renderer's tests.
///
/// So this suite is not "does the file exist". It is: does the page still
/// *demonstrate* the things it says are supported. A construct that quietly
/// stops working takes a section of the reference down with it, and these
/// assertions are what turns that into a build failure instead of a screenshot
/// nobody takes.
@Suite("The markdown reference")
@MainActor
struct MarkdownReferenceTests {

    /// The whole feature rests on this: no resource, no help screen.
    ///
    /// It is the assertion most likely to fail for a boring reason — a
    /// resource dropped from `Package.swift`, or from
    /// `scripts/assemble-bundle.sh` — and the one whose failure is otherwise a
    /// menu item that does nothing.
    @Test("it ships, and it is found in whichever bundle is running")
    func resourceIsPresent() throws {
        #expect(MarkdownReference.isAvailable)
        let url = try #require(MarkdownReference.url)
        #expect(url.lastPathComponent == MarkdownReference.resourceName)
        let source = try #require(MarkdownReference.source)
        #expect(source.hasPrefix("# Markdown in mark"))
    }

    /// A document, not a fragment: an H1 to title the window, and the headings
    /// that are the only navigation the reference window has.
    @Test("it has an outline, and the anchors it documents are the ones it has")
    func outlineIsReal() throws {
        let source = try #require(MarkdownReference.source)
        let headings = try MarkCore.toc(source: source)

        #expect(headings.first?.level == 1)
        #expect(headings.count >= 15, "\(headings.count) headings is too few to be the reference")

        // The page prints an anchor table and tells the reader to use it with
        // `mark goto`. These are the four rows of that table: if `slugify`
        // changes, the reference is teaching something false.
        let anchors = Set(headings.map(\.anchor))
        for promised in ["headings", "task-lists", "math-mathml", "what-isnt-supported"] {
            #expect(anchors.contains(promised), "the reference promises #\(promised) and has no such heading")
        }
    }

    /// The task-list section claims clickable checkboxes, so there had better
    /// be some — and one of each state, since the page shows both.
    @Test("its task-list section really contains tasks")
    func tasksAreReal() throws {
        let source = try #require(MarkdownReference.source)
        let tasks = try MarkCore.tasks(source: source)
        #expect(tasks.contains { $0.checked })
        #expect(tasks.contains { !$0.checked })
    }

    /// The point of the whole design: the page is produced by the renderer it
    /// documents. If this throws, the help screen is blank.
    @Test("the core renders it")
    func itRenders() throws {
        let source = try #require(MarkdownReference.source)
        let html = try MarkCore.renderHTML(source: source)
        #expect(html.contains("<h1 id=\"markdown-in-mark\""))
    }

    /// Five constructs the reference *demonstrates* rather than describes,
    /// each asserted through the markup the renderer emits for it.
    ///
    /// This is the test that earns the suite. Any of these can stop working
    /// without breaking a single other test — the output stays well-formed
    /// HTML, and the only symptom is a section of the help screen quietly
    /// showing nothing.
    @Test("every construct it demonstrates still renders")
    func demonstrationsStillWork() throws {
        let source = try #require(MarkdownReference.source)
        let html = try MarkCore.renderHTML(source: source)

        #expect(html.contains("<input type=\"checkbox\" class=\"mk-task\""), "task lists")
        #expect(html.contains("<math"), "math — the `$…$` section renders nothing without it")
        #expect(html.contains("class=\"mk-diagram\""), "the Mermaid diagram")
        #expect(html.contains("<svg"), "the diagram rendered to SVG rather than falling back")
        #expect(html.contains("class=\"markdown-alert-warning\""), "GFM alerts")
        #expect(html.contains("footnote-definition"), "footnotes")
        #expect(html.contains("<table>"), "tables")
        #expect(html.contains("<del>"), "strikethrough")
        // A *highlighted* block, not merely a fenced one: the section lists the
        // languages syntect knows and `rust` is the example it shows.
        #expect(html.contains("data-lang=\"rust\""), "the highlighted Rust example")
        #expect(!html.contains("data-lang=\"rust\" data-plain=\"1\""), "…and it is highlighted")
    }

    /// The math section deliberately shows a **broken** expression, because
    /// ADR-5's design is that a failure is visible rather than silent. Pinned
    /// so that nobody removes the badge from the renderer and leaves the
    /// reference claiming it exists — and so nobody adds a *second*,
    /// accidental failure without noticing.
    @Test("it demonstrates the failure badge, exactly once")
    func oneDeliberateFailure() throws {
        let source = try #require(MarkdownReference.source)
        let html = try MarkCore.renderHTML(source: source)
        let badges = html.components(separatedBy: "mk-rich-error").count - 1
        #expect(badges == 1, "expected the one \\newcommand demonstration, found \(badges)")
    }

    /// The reference has no frontmatter of its own — a section demonstrates
    /// frontmatter in a fenced block instead, because a real one would be
    /// captured and invisible, and the page cannot show the reader something
    /// it has hidden.
    @Test("it has no frontmatter of its own")
    func noFrontmatter() throws {
        let source = try #require(MarkdownReference.source)
        #expect(!source.hasPrefix("---"))
    }
}
