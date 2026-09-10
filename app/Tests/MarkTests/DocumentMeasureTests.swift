import Foundation
import Testing

@testable import MarkKit

/// The measure — the width a line of prose is held to — and the one block that
/// is allowed past it.
///
/// Every test here reads laid-out geometry, so every test needs
/// ``WindowedHarness``: a `DocumentView` with no window reports
/// `clientWidth` 0 and a zero-width rect for every block, which would make
/// each of these assertions pass or fail for reasons that have nothing to do
/// with the stylesheet. `PatchHarness` says the same thing from the other
/// side — it has no window and asserts nothing about geometry.
///
/// The regression being pinned: the measure used to cap `.mk-container`, which
/// made it a cap on the widest table as well. A fourteen-column table had
/// 43rem to live in however wide the window was, so it scrolled sideways
/// inside a column with a few hundred empty pixels either side of it — the
/// window was big enough and the table still would not fit.
@Suite("The measure")
@MainActor
struct DocumentMeasureTests {

    /// A fourteen-column table, wider than the harness's 900pt window, so both
    /// halves of the contract are exercised at once: the block takes the whole
    /// window, and what still does not fit scrolls inside that block.
    private static let wide: String = {
        let columns = (1...14).map { "column heading number \($0)" }
        let cells = (1...14).map { "value \($0)" }
        return """
            | \(columns.joined(separator: " | ")) |
            |\(String(repeating: " --- |", count: 14))
            | \(cells.joined(separator: " | ")) |
            """
    }()

    private static let document = """
        # A document

        A paragraph of prose, which is what the measure is for.

        \(wide)

        | Key | Value |
        | --- | --- |
        | Rebalance | monthly |

        > \(wide.split(separator: "\n").joined(separator: "\n> "))
        """

    /// Every width this suite asks about, in one round trip.
    private struct Geometry: Decodable {
        let clientWidth: Double
        let documentScrollWidth: Double
        let containerContentWidth: Double
        let paragraphWidth: Double
        let paragraphLeft: Double
        let wideBlockWidth: Double
        let wideBlockScrollWidth: Double
        let wideTableWidth: Double
        let smallTableWidth: Double
        let smallTableLeft: Double
    }

    private func geometry() async throws -> Geometry {
        let harness = try await WindowedHarness(Self.document)
        let json = try await harness.view.call(
            """
            var tables = document.querySelectorAll('.mk-blk.mk-table');
            var paragraph = document.querySelector('.mk-blk.mk-paragraph');
            function rect(el) { return el.getBoundingClientRect(); }
            /* The box the blocks actually get: `clientWidth` includes the
               container's own gutters, and a full-width block does not. */
            function contentWidth(el) {
              var style = getComputedStyle(el);
              return el.clientWidth
                - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
            }
            return JSON.stringify({
              clientWidth: document.documentElement.clientWidth,
              documentScrollWidth: document.documentElement.scrollWidth,
              containerContentWidth: contentWidth(document.getElementById('mk-doc')),
              paragraphWidth: rect(paragraph).width,
              paragraphLeft: rect(paragraph).left,
              wideBlockWidth: rect(tables[0]).width,
              wideBlockScrollWidth: tables[0].scrollWidth,
              wideTableWidth: rect(tables[0].querySelector('table')).width,
              smallTableWidth: rect(tables[1].querySelector('table')).width,
              smallTableLeft: rect(tables[1].querySelector('table')).left
            });
            """)
        let text = try #require(json as? String, "the page returned no geometry")
        let geometry = try JSONDecoder().decode(
            Geometry.self, from: try #require(text.data(using: .utf8)))
        // The window is 900pt wide. If this is 0 the view never got a window
        // and nothing below means anything, so it is asserted rather than
        // assumed.
        #expect(geometry.clientWidth > 0, "the harness view has no laid-out width")
        return geometry
    }

    @Test("prose is held to the measure, which is narrower than the window")
    func proseKeepsTheMeasure() async throws {
        let g = try await geometry()
        #expect(g.paragraphWidth < g.containerContentWidth)
        // Centred in the window: the gutter on the left is the one on the right.
        let right = g.clientWidth - (g.paragraphLeft + g.paragraphWidth)
        #expect(abs(g.paragraphLeft - right) < 1)
    }

    @Test("a table gets the whole window, not the measure")
    func aWideTableTakesTheWindow() async throws {
        let g = try await geometry()
        // The block spans the container: this is the assertion that fails if
        // the measure moves back onto `.mk-container`.
        #expect(g.wideBlockWidth > g.paragraphWidth)
        #expect(abs(g.wideBlockWidth - g.containerContentWidth) < 1)
        // And the table inside it actually used the room.
        #expect(g.wideTableWidth > g.paragraphWidth)
    }

    @Test("what still does not fit scrolls inside the block, not the page")
    func overflowScrollsInTheBlockNotThePage() async throws {
        let g = try await geometry()
        // This fixture is deliberately wider than the window, so the block is
        // a scroll container with something to scroll...
        #expect(g.wideTableWidth > g.wideBlockWidth, "the fixture stopped being wider than 900pt")
        #expect(g.wideBlockScrollWidth > g.wideBlockWidth)
        // ...and the document itself does not scroll sideways. A table nested
        // in the blockquote at the end of the fixture is covered by this too:
        // it is not a block of its own, so it has to scroll inside the quote
        // rather than push the page out.
        #expect(g.documentScrollWidth == g.clientWidth)
    }

    @Test("a table narrower than the measure still lines up with the prose")
    func aSmallTableKeepsTheProseMargin() async throws {
        let g = try await geometry()
        #expect(abs(g.smallTableLeft - g.paragraphLeft) < 1)
        #expect(abs(g.smallTableWidth - g.paragraphWidth) < 1)
    }
}
