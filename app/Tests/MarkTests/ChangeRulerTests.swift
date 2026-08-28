import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The editor's change gutter.
///
/// What is asserted here is the **mapping** — which lines get a bar, of what
/// kind — and not the drawing. Geometry needs a window, and a view with no
/// window reports a zero viewport, so a test that asserted on pixels here would
/// be asserting on nothing. `mark-bench` has a window and owns that half.
///
/// The mapping is worth its own tests because it is where an off-by-one lives:
/// the core reports zero-based half-open line ranges, the gutter draws
/// zero-based lines, and a removal has no line of its own at all.
@Suite("The editor's change gutter")
@MainActor
struct ChangeRulerTests {

    private func ruler() -> ChangeRuler {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = NSTextView(usingTextLayoutManager: true)
        return ChangeRuler(scrollView: scrollView)
    }

    private func hunk(
        old: (Int, Int), new: (Int, Int), kind: LineHunkKind
    ) -> LineHunk {
        // Decoded rather than constructed: `LineHunk` is a wire type with no
        // memberwise initialiser, and going through JSON is also a check that
        // the keys the core emits are the keys Swift reads.
        let json = """
            {"old":{"start":\(old.0),"end":\(old.1)},
             "new":{"start":\(new.0),"end":\(new.1)},
             "newBytes":{"start":0,"end":0},
             "kind":"\(kind.rawValue)"}
            """
        return try! JSONDecoder().decode(LineHunk.self, from: Data(json.utf8))
    }

    private func diff(_ hunks: [LineHunk], coarse: Bool = false) -> LineDiff {
        let added = hunks.reduce(0) { $0 + $1.new.count }
        let removed = hunks.reduce(0) { $0 + $1.old.count }
        let encoded = try! JSONEncoder().encode(
            Wire(hunks: hunks, added: added, removed: removed, coarse: coarse))
        return try! JSONDecoder().decode(LineDiff.self, from: encoded)
    }

    private struct Wire: Encodable {
        struct Span: Encodable {
            let start: Int
            let end: Int
        }
        struct Hunk: Encodable {
            let old: Span
            let new: Span
            let newBytes: Span
            let kind: String
        }
        let hunks: [Hunk]
        let added: Int
        let removed: Int
        let coarse: Bool

        init(hunks source: [LineHunk], added: Int, removed: Int, coarse: Bool) {
            self.hunks = source.map {
                Hunk(
                    old: Span(start: $0.old.start, end: $0.old.end),
                    new: Span(start: $0.new.start, end: $0.new.end),
                    newBytes: Span(start: $0.newBytes.start, end: $0.newBytes.end),
                    kind: $0.kind.rawValue)
            }
            self.added = added
            self.removed = removed
            self.coarse = coarse
        }
    }

    // MARK: - Nothing to show

    @Test("a clean document draws no gutter at all")
    func aCleanDocumentIsEmpty() {
        let ruler = ruler()
        ruler.show(diff([]))
        #expect(ruler.isEmpty, "an empty diff must leave the margin off")
    }

    @Test("nil clears whatever was there")
    func nilClears() {
        let ruler = ruler()
        ruler.show(diff([hunk(old: (0, 1), new: (0, 1), kind: .changed)]))
        #expect(!ruler.isEmpty)
        ruler.show(nil)
        #expect(ruler.isEmpty)
        #expect(ruler.diff == nil)
    }

    /// A bar spanning hundreds of lines says less than no bar, and implies a
    /// precision the core has explicitly disclaimed.
    @Test("a coarse diff draws nothing rather than one enormous bar")
    func aCoarseDiffDrawsNothing() {
        let ruler = ruler()
        ruler.show(diff([hunk(old: (0, 900), new: (0, 900), kind: .changed)], coarse: true))
        #expect(ruler.isEmpty)
        // But it is still remembered, so a caller can say why nothing is drawn.
        #expect(ruler.diff?.coarse == true)
    }

    // MARK: - The mapping

    @Test("a changed run marks exactly its own lines")
    func aChangedRunMarksItsLines() {
        let ruler = ruler()
        ruler.show(diff([hunk(old: (3, 6), new: (3, 6), kind: .changed)]))
        #expect(!ruler.isEmpty)
        #expect(ruler.marksForTesting == [3: .changed, 4: .changed, 5: .changed])
    }

    @Test("an added run is marked as added, and the line after it is not")
    func anAddedRunStopsWhereItStops() {
        let ruler = ruler()
        // Half-open: `new` 1..3 is lines 1 and 2, and line 3 is untouched.
        ruler.show(diff([hunk(old: (1, 1), new: (1, 3), kind: .added)]))
        #expect(ruler.marksForTesting == [1: .added, 2: .added])
    }

    /// A removal has no line of its own in the new document, so it marks the
    /// line it sits in front of. Without this a deletion would be invisible in
    /// the gutter, which is the one change a reader most wants to be told about.
    @Test("a removal marks the line it sits in front of")
    func aRemovalMarksItsBoundary() {
        let ruler = ruler()
        ruler.show(diff([hunk(old: (4, 7), new: (4, 4), kind: .removed)]))
        #expect(ruler.marksForTesting == [4: .removed])
    }

    @Test("two separate edits are two separate marks")
    func twoEditsTwoMarks() {
        let ruler = ruler()
        ruler.show(
            diff([
                hunk(old: (0, 1), new: (0, 1), kind: .changed),
                hunk(old: (9, 9), new: (9, 11), kind: .added),
            ]))
        #expect(ruler.marksForTesting == [0: .changed, 9: .added, 10: .added])
    }

    /// A removal landing on a line that a later hunk also covers must not
    /// overwrite the real change: the reader cares more that content *changed*
    /// there than that something was also dropped.
    @Test("a removal does not overwrite a change on the same line")
    func aRemovalYieldsToAChange() {
        let ruler = ruler()
        ruler.show(
            diff([
                hunk(old: (2, 4), new: (2, 2), kind: .removed),
                hunk(old: (4, 5), new: (2, 3), kind: .changed),
            ]))
        #expect(ruler.marksForTesting[2] == .changed, "the change should win the line")
    }

    // MARK: - End to end, against the real core

    /// The mapping fed by the real line diff rather than a hand-built one, so a
    /// change to what the core reports cannot silently stop lining up with what
    /// the gutter draws.
    @Test("the real core's diff maps onto the lines a reader would count")
    func theRealDiffMapsCorrectly() throws {
        let base = "alpha\nbravo\ncharlie\ndelta\n"
        let now = "alpha\nBRAVO\ncharlie\ndelta\necho\n"
        let diff = try MarkCore.lineDiff(old: base, new: now)

        let ruler = ruler()
        ruler.show(diff)

        // Line 1 (zero-based) is `bravo` → `BRAVO`; line 4 is the appended
        // `echo`. Lines 0, 2 and 3 are untouched.
        #expect(ruler.marksForTesting[1] == .changed, "\(ruler.marksForTesting)")
        #expect(ruler.marksForTesting[4] == .added, "\(ruler.marksForTesting)")
        #expect(ruler.marksForTesting[0] == nil)
        #expect(ruler.marksForTesting[2] == nil)
        #expect(ruler.marksForTesting[3] == nil)
    }

    @Test("every colour is distinct, so the three kinds are tellable apart")
    func coloursAreDistinct() {
        let colours = [
            ChangeRuler.color(for: .added),
            ChangeRuler.color(for: .removed),
            ChangeRuler.color(for: .changed),
        ]
        #expect(Set(colours.map(\.description)).count == 3)
    }
}
