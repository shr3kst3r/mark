import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

@Suite("Find in document")
@MainActor
struct FindTests {

    // MARK: The bar

    @Test("the bar says which match the reader is on")
    func status() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: FindBar.barHeight))

        // Nothing searched for yet is not the same fact as "not found", and a
        // bar that opened saying "Not found" would be lying about a search it
        // has not run.
        bar.report(nil)
        #expect(bar.statusLabel.stringValue == "")

        bar.report(FindResult.empty)
        #expect(bar.statusLabel.stringValue == "Not found")
        #expect(bar.statusLabel.textColor == .systemRed)

        bar.report(FindResult(total: 12, index: 2, highlightsAll: true))
        #expect(bar.statusLabel.stringValue == "3 of 12")
        #expect(bar.statusLabel.textColor == .secondaryLabelColor)

        // Matches with none of them current — the page has ranges but has not
        // settled on one. Counting them is still worth saying.
        bar.report(FindResult(total: 1, index: nil, highlightsAll: true))
        #expect(bar.statusLabel.stringValue == "1 match")
        bar.report(FindResult(total: 4, index: nil, highlightsAll: true))
        #expect(bar.statusLabel.stringValue == "4 matches")
    }

    @Test("the page's -1 for \"no current match\" becomes nil")
    func decoding() {
        let decoded = FindResult(["total": 3, "index": -1, "highlightsAll": true])
        #expect(decoded == FindResult(total: 3, index: nil, highlightsAll: true))
        #expect(FindResult(nil) == FindResult.empty)
    }

    @Test("↩ is next, ⇧↩ is previous, and ⎋ closes")
    func keys() {
        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: FindBar.barHeight))
        var events: [String] = []
        bar.onNext = { events.append("next") }
        bar.onPrevious = { events.append("previous") }
        bar.onClose = { events.append("close") }

        let editor = NSTextView()
        #expect(
            bar.control(
                bar.searchField, textView: editor,
                doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(
            bar.control(
                bar.searchField, textView: editor,
                doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(
            bar.control(
                bar.searchField, textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        // Anything else is the field editor's business and must be handed back.
        #expect(
            !bar.control(
                bar.searchField, textView: editor,
                doCommandBy: #selector(NSResponder.moveLeft(_:))))

        #expect(events == ["next", "previous", "close"])
    }

    // MARK: The search itself

    @Test("every match is found, counted, and highlighted")
    func findsAndCounts() async throws {
        let harness = try await PatchHarness(
            """
            # Alpha

            Alpha appears here, and alpha appears again in lower case.

            Beta appears once.
            """)

        // Case-insensitive by default: three "alpha"s, one of them the heading.
        let alpha = await harness.view.find("alpha")
        #expect(alpha.total == 3)
        #expect(alpha.index == 0)

        let beta = await harness.view.find("beta")
        #expect(beta.total == 1)

        let sensitive = await harness.view.find("Alpha", caseSensitive: true)
        #expect(sensitive.total == 2)
    }

    /// The point of the whole exercise: `WKWebView.find` highlights one match,
    /// so it could not be the engine here. The page uses the CSS Custom
    /// Highlight API, which paints ranges without adding a node to the
    /// document — and therefore without the patcher noticing.
    @Test("all matches are painted, and nothing is added to the document")
    func highlightsWithoutTouchingTheDOM() async throws {
        let harness = try await PatchHarness("# Alpha\n\nalpha alpha alpha.\n")
        let before = try await harness.documentHTML()

        let result = await harness.view.find("alpha")
        #expect(result.total == 4)
        try #require(
            result.highlightsAll,
            "this WebKit has no CSS Custom Highlight API; the rest of this test cannot mean anything")

        let painted = try await harness.view.call(
            "return CSS.highlights.get('mk-find') ? CSS.highlights.get('mk-find').size : 0;")
        #expect((painted as? NSNumber)?.intValue == 4)
        #expect(try await harness.documentHTML() == before, "the highlight changed the DOM")

        await harness.view.clearFind()
        let cleared = try await harness.view.call("return CSS.highlights.has('mk-find');")
        #expect((cleared as? NSNumber)?.boolValue == false)
    }

    @Test("stepping cycles through the matches and wraps at both ends")
    func cycling() async throws {
        let harness = try await PatchHarness("# Alpha\n\nalpha alpha.\n")
        #expect(await harness.view.find("alpha").index == 0)

        #expect(await harness.view.stepFind(forward: true).index == 1)
        #expect(await harness.view.stepFind(forward: true).index == 2)
        // Wraps forward…
        #expect(await harness.view.stepFind(forward: true).index == 0)
        // …and backward.
        #expect(await harness.view.stepFind(forward: false).index == 2)
    }

    @Test("stepping with nothing found is not a crash and not a match")
    func steppingWithNoMatches() async throws {
        let harness = try await PatchHarness("# Alpha\n\nJust the one word.\n")
        #expect(await harness.view.find("gamma").total == 0)
        let stepped = await harness.view.stepFind(forward: true)
        #expect(stepped.total == 0)
        #expect(stepped.index == nil)
    }

    @Test("text that is not in the document is not found")
    func notFound() async throws {
        let harness = try await PatchHarness("# Alpha\n\nJust the one word.\n")
        let result = await harness.view.find("gamma")
        #expect(result.total == 0)
        #expect(result.index == nil)
    }

    /// The reader is searching what is on screen, not what is in the file. A
    /// search over the source would count 2 here and highlight 1.
    @Test("matches are found in the rendered text, not the source")
    func searchesRenderedText() async throws {
        let harness = try await PatchHarness("# Title\n\nSee the [docs](./docs.md) for more.\n")
        #expect(await harness.view.find("docs").total == 1)
    }

    /// ADR-2: *"nothing may depend on the whole document being in the DOM
    /// without first awaiting or forcing completion of the background fill."*
    /// A find that only looked at the painted prefix would report "not found"
    /// for text that is plainly in the file.
    @Test("a match past the painted prefix is still found")
    func findsPastThePrefix() async throws {
        var source = "# Long\n\n"
        for index in 0..<400 {
            source += "Paragraph \(index) of a document far longer than one viewport.\n\n"
        }
        source += "The needle is at the very bottom.\n"
        let harness = try await PatchHarness(source)
        #expect(await harness.view.find("needle").total == 1)
    }

    /// The other half of the same constraint, and the bug the test above found.
    ///
    /// The fill has two halves: the core renders the tail on a background task,
    /// and only then is it handed to the page's pump. `ensureFullyRendered`
    /// used to force the second half without awaiting the first, so it could
    /// drain a pump that had been given nothing yet and report — truthfully —
    /// that it had forced nothing. Every ADR-2 caller inherited that: search,
    /// `mark goto`, and print could all miss text that was plainly in the file.
    @Test("ensureFullyRendered means the whole document, not just the pump")
    func fullyMeansFully() async throws {
        let fixture = try PatchFixture()
        var source = "# Long\n\n"
        for index in 0..<400 {
            source += "Paragraph \(index) of a document far longer than one viewport.\n\n"
        }
        let url = try fixture.write(source)

        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.open(url)
        await view.awaitReady()
        await view.ensureFullyRendered()

        let filling = try await view.call("return window.mark.isFilling();")
        #expect((filling as? NSNumber)?.boolValue == false)
        let blocks = try await view.call(
            "return document.getElementById('mk-doc').childElementCount;")
        #expect((blocks as? NSNumber)?.intValue == 401, "the heading and 400 paragraphs")
    }

    @Test("an empty query finds nothing")
    func emptyQuery() async throws {
        let harness = try await PatchHarness("# Alpha\n\nSomething.\n")
        #expect(await harness.view.find("").total == 0)
    }

    /// A patch replaces block elements, so every range the page is holding
    /// points at a node that is no longer in the tree. `shell.js` drops them on
    /// every document mutation rather than leaving them to be painted.
    @Test("an edit drops the highlights instead of painting stale ranges")
    func editDropsHighlights() async throws {
        let harness = try await PatchHarness("# Alpha\n\nalpha alpha.\n")
        #expect(await harness.view.find("alpha").total == 3)

        await harness.view.apply(source: "# Alpha\n\nalpha alpha alpha.\n")
        let state = await harness.view.findState()
        #expect(state.total == 0)
        #expect(state.index == nil)
    }

    /// The highlight is not a selection when the Custom Highlight API is
    /// there, but "Use Selection for Find" still has to be able to read one.
    @Test("the reader's selection is readable")
    func selection() async throws {
        let harness = try await PatchHarness("# Alpha\n\nBeta gamma delta.\n")
        #expect(await harness.view.selectedText().isEmpty)
        _ = try await harness.view.call(
            """
            var range = document.createRange();
            range.selectNodeContents(document.getElementById('mk-doc').lastElementChild);
            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
            """)
        #expect(await harness.view.selectedText() == "Beta gamma delta.")
    }
}

// MARK: - In the window

@Suite("The find bar in the window")
@MainActor
struct FindBarWindowTests {

    @Test("the find bar sits along the bottom of the preview, above the web views")
    func placement() throws {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        #expect(controller.editorSplit.subviews.first === controller.previewPane)
        #expect(!controller.isFindBarVisible, "the bar is not there until it is asked for")

        // Order is the load-bearing part. A `WKWebView` is layer-hosted and
        // paints over any sibling added before it — the find bar drew nothing
        // at all on screen while rendering perfectly offscreen until this was
        // the other way round.
        let panes = controller.previewPane.subviews
        let container = try #require(panes.firstIndex { $0 === controller.documentContainer })
        let bar = try #require(panes.firstIndex { $0 === controller.findBar })
        #expect(bar > container, "the find bar is under the web view in z-order")

        controller.window?.setContentSize(NSSize(width: 1168, height: 700))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.showFindBar()
        controller.previewPane.layoutSubtreeIfNeeded()
        let pane = controller.previewPane.bounds
        #expect(controller.findBar.frame.maxY == pane.maxY, "the bar is on the bottom edge")
        #expect(
            controller.documentContainer.frame.maxY == controller.findBar.frame.minY,
            "the document ends where the bar begins")
    }

    @Test("⌘F shows the bar and Done hides it")
    func showAndHide() {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        controller.performFindAction(item(.showFindInterface))
        #expect(controller.isFindBarVisible)

        controller.performFindAction(item(.hideFindInterface))
        #expect(!controller.isFindBarVisible)
    }

    /// ⌘G with nothing to repeat is a request for the bar. Beeping at someone
    /// who pressed "find again" before "find" is a lecture, not an answer.
    @Test("Find Next with no query open opens the bar")
    func findNextOpensTheBar() {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        controller.performFindAction(item(.nextMatch))
        #expect(controller.isFindBarVisible)
    }

    @Test("closing the bar clears the query")
    func closingClears() {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        controller.showFindBar()
        controller.findBar.query = "alpha"
        controller.setFindBarVisible(false)
        #expect(controller.findBar.query == "")
        #expect(controller.findBar.statusLabel.stringValue == "")
    }

    /// The preview is rendered output. Replace has nothing to write through to,
    /// so the item is greyed out rather than beeping when it is chosen.
    @Test("Replace is offered to the editor and to nothing else")
    func replaceIsEditorOnly() async throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.tabs.open(fixture.file(named: "a.md"))
        #expect(!controller.editorHasFocus)
        #expect(!controller.validateMenuItem(item(.replace)))
        #expect(controller.validateMenuItem(item(.showFindInterface)))
        #expect(controller.validateMenuItem(item(.setSearchString)))
    }

    @Test("Find Next is offered only once there is something to find again")
    func findNextNeedsAQuery() async throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        controller.tabs.open(fixture.file(named: "a.md"))
        #expect(!controller.validateMenuItem(item(.nextMatch)))

        controller.showFindBar()
        controller.findBar.onQueryChanged?("task")
        #expect(controller.validateMenuItem(item(.nextMatch)))
        #expect(controller.validateMenuItem(item(.previousMatch)))
    }

    @Test("with no document open there is nothing to find in")
    func nothingOpen() {
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))
        #expect(!controller.validateMenuItem(item(.showFindInterface)))
    }

    private func item(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Find", action: #selector(MainWindowController.performFindAction(_:)),
            keyEquivalent: "")
        item.tag = action.rawValue
        return item
    }
}
