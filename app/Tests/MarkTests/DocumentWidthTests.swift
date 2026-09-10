import AppKit
import Foundation
import Testing

@testable import MarkKit

/// `View ▸ Use Full Window Width` — the measure, switched off.
///
/// The four things that make it a *setting* rather than a per-window control,
/// which is what these pin: one page-level class does the whole job, every open
/// page hears about a change, a page opened afterwards comes up already
/// applied, and it survives a relaunch.
///
/// `.serialized`, and every test hands the state back the way it found it:
/// ``DocumentWidth/isFull`` is process-wide, so otherwise this suite's own
/// order decides what the next assertion sees — and so does every other suite
/// that opens a document.
@Suite("Full window width", .serialized)
@MainActor
struct DocumentWidthTests {

    private static let document = """
        A paragraph of prose, which is what the measure is for.

        | Key | Value |
        | --- | --- |
        | Rebalance | monthly |
        """

    private func withDefault(_ body: () throws -> Void) rethrows {
        DocumentWidth.isFull = false
        defer { DocumentWidth.isFull = false }
        try body()
    }

    private func withDefault(_ body: () async throws -> Void) async rethrows {
        DocumentWidth.isFull = false
        defer { DocumentWidth.isFull = false }
        try await body()
    }

    // MARK: - The switch

    @Test("it starts with the measure")
    func startsWithTheMeasure() {
        withDefault {
            #expect(!DocumentWidth.isFull)
        }
    }

    @Test("a change is announced, because a menu item only reaches one window")
    func aChangeIsAnnounced() {
        withDefault {
            var heard: [Bool] = []
            let token = NotificationCenter.default.addObserver(
                forName: DocumentWidth.didChangeNotification, object: nil, queue: nil
            ) { note in
                heard.append((note.object as? Bool) ?? false)
            }
            defer { NotificationCenter.default.removeObserver(token) }

            DocumentWidth.isFull = true
            DocumentWidth.isFull = true  // idempotent: no second post
            DocumentWidth.isFull = false
            #expect(heard == [true, false])
        }
    }

    // MARK: - Persistence

    @Test("the measure persists as nothing at all")
    func theDefaultWritesNothing() {
        withDefault {
            #expect(DocumentWidth.persisted == nil)
            DocumentWidth.isFull = true
            #expect(DocumentWidth.persisted == true)
        }
    }

    @Test("a session file written before this existed leaves the default alone")
    func absentMeansDefault() {
        withDefault {
            DocumentWidth.restore(nil)
            #expect(!DocumentWidth.isFull)
        }
    }

    @Test("the setting survives a session round trip through JSON")
    func roundTrip() throws {
        try withDefault {
            DocumentWidth.isFull = true
            var state = SessionState()
            state.documentFullWidth = DocumentWidth.persisted

            let encoded = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(SessionState.self, from: encoded)
            #expect(decoded.documentFullWidth == true)
            // And the version does not move for an additive field, or the file
            // this was written into would be refused wholesale on the way back.
            #expect(decoded.version == SessionState.currentVersion)

            DocumentWidth.isFull = false
            DocumentWidth.restore(decoded.documentFullWidth)
            #expect(DocumentWidth.isFull)
        }
    }

    // MARK: - The page

    /// The `max-width` the page resolved for its first block, once it has
    /// settled.
    ///
    /// Polled, because the setting reaches the page through an async
    /// `evaluateJavaScript` — the same reason ``WindowedHarness/pageIsDark(waitingFor:)``
    /// polls. Returns as soon as the answer is `wanted`, so a passing run waits
    /// milliseconds and only a failing one waits the timeout.
    private func blockMaxWidth(of harness: WindowedHarness, waitingFor wanted: String) async
        -> String?
    {
        let deadline = ContinuousClock.now + .seconds(2)
        var answer: String?
        repeat {
            answer =
                try? await harness.view.call(
                    """
                    var block = document.getElementById('mk-doc').firstElementChild;
                    return block ? window.getComputedStyle(block).maxWidth : '';
                    """) as? String
            if answer == wanted { return answer }
            try? await _Concurrency.Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        return answer
    }

    @Test("an open document follows a change made from another window")
    func anOpenDocumentFollows() async throws {
        try await withDefault {
            let harness = try await WindowedHarness(Self.document)
            #expect(
                await blockMaxWidth(of: harness, waitingFor: "688px") == "688px",
                "the measure was not in force to begin with")

            DocumentWidth.isFull = true
            #expect(
                await blockMaxWidth(of: harness, waitingFor: "none") == "none",
                "the page did not hear the app-wide change")

            DocumentWidth.isFull = false
            #expect(
                await blockMaxWidth(of: harness, waitingFor: "688px") == "688px",
                "the measure did not come back")
        }
    }

    @Test("a document opened afterwards comes up already full width")
    func aNewDocumentStartsFullWidth() async throws {
        try await withDefault {
            DocumentWidth.isFull = true
            // Created *after* the setting, which is the rehydration path: a tab
            // whose web view was evicted has a fresh `<body>` and no memory of
            // anything, so the `ready` handler has to apply this the way it
            // applies the theme.
            let harness = try await WindowedHarness(Self.document)
            #expect(await blockMaxWidth(of: harness, waitingFor: "none") == "none")
        }
    }

    @Test("with no measure, blocks take the window and a small table stops being padded out")
    func geometryWithNoMeasure() async throws {
        try await withDefault {
            DocumentWidth.isFull = true
            let harness = try await WindowedHarness(Self.document)
            _ = await blockMaxWidth(of: harness, waitingFor: "none")

            let json = try await harness.view.call(
                """
                function rect(el) { return el.getBoundingClientRect(); }
                var container = document.getElementById('mk-doc');
                var style = window.getComputedStyle(container);
                var paragraph = document.querySelector('.mk-blk.mk-paragraph');
                var table = document.querySelector('.mk-blk.mk-table > table');
                return JSON.stringify({
                  content: container.clientWidth
                    - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
                  paragraph: rect(paragraph).width,
                  paragraphLeft: rect(paragraph).left,
                  table: rect(table).width,
                  tableLeft: rect(table).left,
                  documentScrollWidth: document.documentElement.scrollWidth,
                  clientWidth: document.documentElement.clientWidth
                });
                """)
            let text = try #require(json as? String)
            let g = try JSONDecoder().decode(
                [String: Double].self, from: try #require(text.data(using: .utf8)))

            let content = try #require(g["content"])
            #expect(content > 0, "the harness view has no laid-out width")
            // The prose takes the window, which is the setting.
            #expect(abs(try #require(g["paragraph"]) - content) < 1)
            // A two-column table is no longer floored at the measure — it takes
            // its columns and the prose's left edge, rather than being padded
            // out to 43rem and centred on a column that is not there any more.
            #expect(try #require(g["table"]) < content)
            #expect(abs(try #require(g["tableLeft"]) - #require(g["paragraphLeft"])) < 1)
            // And none of it pushes the page sideways.
            #expect(g["documentScrollWidth"] == g["clientWidth"])
        }
    }
}
