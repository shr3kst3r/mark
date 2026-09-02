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
    /// be some — and one of **each of the five states**, because the page shows
    /// a table of all five and then demonstrates them. A state that stopped
    /// being recognised would leave that section teaching something false while
    /// every other test still passed.
    @Test("its task-list section really contains tasks, in every state")
    func tasksAreReal() throws {
        let source = try #require(MarkdownReference.source)
        let tasks = try MarkCore.tasks(source: source)
        #expect(tasks.contains { $0.checked })
        #expect(tasks.contains { !$0.checked })
        for state in TaskState.allCases {
            #expect(
                tasks.contains { $0.state == state },
                "the reference documents \(state.rawValue) and demonstrates no such task")
        }
    }

    /// The metadata section is the same kind of claim: it shows tags, dates and
    /// a priority in a live list, and a reader has to be able to see the chips.
    /// It also demonstrates the code-span rule, which means the page must
    /// contain a `@due(...)` that is deliberately *not* metadata.
    @Test("its metadata section demonstrates tags, dates, priority — and the code-span rule")
    func metadataIsReal() throws {
        let source = try #require(MarkdownReference.source)
        let tasks = try MarkCore.tasks(source: source)
        #expect(tasks.contains { $0.due != nil }, "no @due(...) survives in the page")
        #expect(tasks.contains { $0.startDate != nil })
        #expect(tasks.contains { $0.done != nil })
        #expect(tasks.contains { $0.priority > 0 })
        #expect(tasks.contains { $0.tags.contains { $0.name == "work" } })
        // The label is what a human-facing list shows: the tokens come out of
        // it, and `text` keeps them.
        let tagged = try #require(tasks.first { $0.tags.contains { $0.name == "work" } })
        #expect(!tagged.label.contains("@work"))
        #expect(tagged.text.contains("@work"))

        let html = try MarkCore.renderHTML(source: source)
        #expect(html.contains("class=\"mk-tag\""), "the chips are not being drawn")
        #expect(html.contains("data-mk-due="))
        // The renderer may not read a clock, so nothing on this page can be
        // coloured by one (`2026-08-27-inline-task-metadata`).
        #expect(!html.contains("mk-overdue"))
    }

    /// Every state is drawn, and drawn by us: `data-mk-state` on an
    /// `input.mk-task`, with `checked` emitted for done alone. A cancelled item
    /// is terminal in the JSON and must still not arrive ticked.
    @Test("the rendered reference carries a data-mk-state for every state it shows")
    func everyStateReachesTheMarkup() throws {
        let source = try #require(MarkdownReference.source)
        let html = try MarkCore.renderHTML(source: source)
        for state in TaskState.allCases {
            #expect(
                html.contains("data-mk-state=\"\(state.rawValue)\""),
                "\(state.rawValue) is documented and not rendered")
        }
        // One `checked` per done task, and none anywhere else.
        let tasks = try MarkCore.tasks(source: source)
        let done = tasks.filter { $0.state == .done }.count
        #expect(html.components(separatedBy: "\" checked>").count - 1 == done)
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

/// The one picture the reference shows, and whether it actually arrives.
///
/// `2026-09-01-document-images-over-a-scoped-scheme` records why this is a
/// separate suite rather than one more assertion above: images were the single
/// construct whose failure the reference could not demonstrate, because the
/// Images section only quoted the syntax in a fenced block. It quotes *and*
/// shows one now, so a regression in the asset path takes the reference page
/// down with it — visibly — the way a regression in tables or math already
/// does.
@Suite("The markdown reference's picture")
@MainActor
struct MarkdownReferenceImageTests {

    @Test("the image it points at ships beside it")
    func theImageShips() throws {
        let reference = try #require(MarkdownReference.url)
        let image = reference
            .deletingLastPathComponent()
            .appendingPathComponent("markdown-reference-image.png")
        #expect(
            FileManager.default.fileExists(atPath: image.path),
            """
            markdown-reference.md points at markdown-reference-image.png, which is \
            not next to it — check Package.swift and scripts/assemble-bundle.sh
            """)
    }

    @Test("the Images section shows a picture rather than only quoting the syntax")
    func theSectionShowsOne() throws {
        let source = try #require(MarkdownReference.source)
        let images = try MarkCore.links(source: source, images: true)
        #expect(
            !images.isEmpty,
            "the Images section demonstrates nothing a reader can see it fail at")
    }

    @Test("it loads in the reference window")
    func itLoadsInTheWindow() async throws {
        // Failable: it returns nil when the resource is missing, which
        // `theImageShips` above already reports more precisely.
        let controller = try #require(HelpWindowController())
        defer { controller.tearDown() }
        await controller.documentView.awaitReady()
        await controller.documentView.ensureFullyRendered()

        let width = try await controller.documentView.call(
            """
            var img = document.querySelector('#mk-doc img');
            if (!img) return -1;
            if (img.complete) return img.naturalWidth;
            return await new Promise(function (resolve) {
              img.addEventListener('load', function () { resolve(img.naturalWidth); });
              img.addEventListener('error', function () { resolve(0); });
              setTimeout(function () { resolve(img.naturalWidth); }, 3000);
            });
            """)
        let pixels = (width as? Int) ?? Int((width as? Double) ?? -1)
        #expect(pixels == 320, "the reference's own picture did not load; got \(pixels)")
    }
}
