import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The markdown reference's window
/// (`2026-08-26-markdown-reference-window`).
///
/// Three of the four things asserted here are about what the window must
/// **not** do — write to the app bundle, exist twice, or leave a web view
/// behind — because those are the ways a second kind of window goes wrong in a
/// codebase whose every other window is a document window.
@Suite("The markdown reference window")
@MainActor
struct HelpWindowTests {

    /// A private governor, so a test that opens a reference window cannot
    /// change the resident count a suite running beside it is asserting on.
    private func makeController(governor: ResidencyGovernor) throws -> HelpWindowController {
        try #require(
            HelpWindowController(
                source: MarkdownReference.source,
                url: MarkdownReference.url,
                governor: governor))
    }

    @Test("it opens on the shipped reference, with a find bar and no other chrome")
    func itOpens() throws {
        let governor = ResidencyGovernor(limit: 3)
        let controller = try makeController(governor: governor)
        defer { controller.tearDown() }

        let window = try #require(controller.window)
        #expect(window.title == "Markdown Reference")
        #expect(controller.documentView.url?.lastPathComponent == MarkdownReference.resourceName)
        // Hidden until ⌘F, exactly as in a document window.
        #expect(!controller.finder.isVisible)
        // No tab bar, no sidebar, no editor: the content view is the preview
        // pane and nothing else.
        #expect(window.contentView is PreviewPaneView)
    }

    /// **The reason it is a window and not a tab.**
    ///
    /// The reference ships inside `mark.app/Contents/Resources`. A click on one
    /// of its example checkboxes must not reach the file: on a locally built
    /// bundle that write succeeds and edits the shipped reference, and on a
    /// signed one it fails and breaks the seal.
    @Test("its checkboxes are examples — a click writes nothing")
    func checkboxesDoNotWrite() throws {
        let governor = ResidencyGovernor(limit: 3)
        let controller = try makeController(governor: governor)
        defer { controller.tearDown() }

        let writer = try #require(controller.documentView.taskWriter as? RefusingTaskWriter)
        let url = try #require(MarkdownReference.url)
        let before = try Data(contentsOf: url)

        #expect(throws: TaskWriteRefusal.self) {
            _ = try writer.apply(
                TaskToggle(index: 0, span: 0..<3, rendered: false, desired: true), to: url)
        }
        let after = try Data(contentsOf: url)
        #expect(after == before, "the shipped reference was modified")
    }

    /// ⇧⌘/ twice is one window brought forward, not two windows — and ⇧⌘/
    /// after a close is a new one, not the torn-down husk of the old.
    @Test("there is only ever one of it, and a closed one is not reused")
    func singleInstance() throws {
        // Goes through the real `show()`, because the single-instance rule
        // lives there rather than in `init`.
        let first = try #require(HelpWindowController.show())
        let second = try #require(HelpWindowController.show())
        #expect(first === second)
        #expect(HelpWindowController.shared === first)

        first.tearDown()
        #expect(HelpWindowController.shared == nil)

        let third = try #require(HelpWindowController.show())
        defer { third.tearDown() }
        #expect(third !== first, "⇧⌘/ reopened a controller that had given its web view back")
    }

    /// **The reference is held by nothing else.**
    ///
    /// The menu action discards what `show()` returns and `NSWindow` does not
    /// retain its controller, so a weak ``HelpWindowController/shared`` would
    /// deallocate the window as the menu item finished. A test holding its own
    /// strong reference cannot see that; this one deliberately does not.
    @Test("nothing but `shared` keeps it alive, and that is enough")
    func sharedOwnsIt() throws {
        HelpWindowController.show()
        let controller = try #require(HelpWindowController.shared)
        defer { controller.tearDown() }
        #expect(controller.window?.contentView != nil)
        #expect(!controller.isTornDown)
    }

    /// Closing gives the ~52 MB back. Without this the window would be a leak
    /// that only shows up as WebContent processes accumulating.
    @Test("closing releases the web view and drops the shared instance")
    func closingTearsDown() throws {
        let routedBefore = WebViewFactory.routedWebViewCount
        let governor = ResidencyGovernor(limit: 3)
        let controller = try makeController(governor: governor)
        #expect(governor.auxiliaryWebViews == 1)
        #expect(WebViewFactory.routedWebViewCount == routedBefore + 1)
        #expect(controller.documentView.webView?.superview != nil)

        controller.tearDown()
        #expect(governor.auxiliaryWebViews == 0)
        // A leaked web view shows up as a routing-table entry;
        // ``WebViewFactory/release(_:)`` is the only thing that removes one.
        #expect(WebViewFactory.routedWebViewCount == routedBefore)
        #expect(controller.documentView.webView?.superview == nil)

        // Idempotent: `windowWillClose` and an explicit close can both arrive,
        // and releasing a web view twice would unbalance the routing table.
        controller.tearDown()
        #expect(governor.auxiliaryWebViews == 0)
        #expect(WebViewFactory.routedWebViewCount == routedBefore)
    }

    /// ⌘F searches **this** window's document.
    ///
    /// The whole reason `DocumentFinder` was extracted rather than copied. If
    /// the finder were pointed at the wrong view — or at none — every
    /// assertion above would still pass and ⌘F would silently find nothing.
    @Test("⌘F searches the reference")
    func findSearchesTheReference() async throws {
        let governor = ResidencyGovernor(limit: 3)
        let controller = try makeController(governor: governor)
        defer { controller.tearDown() }
        await controller.documentView.awaitReady()
        _ = await controller.documentView.ensureFullyRendered()

        #expect(controller.finder.documentView?() === controller.documentView)
        #expect(controller.finder.hasDocument?() == true)

        // A word the page uses throughout, so the count cannot be an accident
        // of one heading. `find` searches the *rendered* text.
        let found = await controller.documentView.find("markdown")
        #expect(found.total >= 5, "found \(found.total) matches for a word the page uses often")

        controller.finder.show()
        #expect(controller.finder.isVisible)
        #expect(controller.finder.bar.superview === controller.window?.contentView)

        controller.finder.setVisible(false)
        #expect(!controller.finder.isVisible)
        #expect(controller.finder.query.isEmpty)
    }

    /// **The defect writing the reference found, asserted in a real WebKit.**
    ///
    /// `ENABLE_GFM` has always parsed `> [!WARNING]`, pulldown-cmark has always
    /// emitted the class, and `shell.css` never had a rule for it — so every
    /// alert rendered as an ordinary quote *with its marker line deleted*. The
    /// output was well-formed HTML the whole time, which is why no test caught
    /// it and only rendering the page could.
    ///
    /// So this asks the page, not the stylesheet: does an alert have its label,
    /// and is its border a different colour from a plain quote's? Those two
    /// questions are the whole difference between the bug and the fix.
    @Test("an alert is drawn as an alert, not as a quote with its first line missing")
    func alertsAreDrawn() async throws {
        let governor = ResidencyGovernor(limit: 3)
        let controller = try makeController(governor: governor)
        defer { controller.tearDown() }
        await controller.documentView.awaitReady()
        _ = await controller.documentView.ensureFullyRendered()

        let answer = try await controller.documentView.call(
            """
            const kinds = ['note', 'tip', 'important', 'warning', 'caution'];
            const plain = document.querySelector('blockquote:not([class])');
            const out = {
              plain: plain ? getComputedStyle(plain).backgroundColor : null,
            };
            for (const kind of kinds) {
              const el = document.querySelector('.markdown-alert-' + kind);
              if (!el) { out[kind] = null; continue; }
              const style = getComputedStyle(el);
              out[kind] = {
                label: getComputedStyle(el, '::before').content,
                border: style.borderLeftColor,
                background: style.backgroundColor,
              };
            }
            return out;
            """)
        let styles = try #require(answer as? [String: Any])

        let plainBackground = try #require(styles["plain"] as? String)
        var borders: Set<String> = []
        for (kind, label) in [
            ("note", "Note"), ("tip", "Tip"), ("important", "Important"),
            ("warning", "Warning"), ("caution", "Caution"),
        ] {
            let alert = try #require(
                styles[kind] as? [String: Any], "the reference has no \(kind) alert to check")

            // **The regression check.** The parser ate the `[!NOTE]` line; this
            // is whether anything put it back.
            let content = try #require(alert["label"] as? String)
            #expect(
                content.contains(label),
                "the \(kind) alert draws \(content) where its consumed marker line should be")

            // …and whether it reads as a callout rather than as a quotation.
            let background = try #require(alert["background"] as? String)
            #expect(
                background != plainBackground,
                "the \(kind) alert has a plain quote's background — the rule is not applying")

            borders.insert(try #require(alert["border"] as? String))
        }
        // Five severities, five colours. `important` deliberately shares the
        // plain quote's accent — it is the palette's purple, and the label and
        // the background are what tell the two apart — so the borders are
        // checked against each other rather than against a quote's.
        #expect(borders.count == 5, "the five severities are not five colours: \(borders)")
    }
}
