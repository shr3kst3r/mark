import Foundation
import Testing

@testable import MarkKit

/// ADR-2's tunable, and the prefix/tail split that prefix-then-fill rests on.
@Suite("ProgressiveRenderer — ADR-2's first-paint tunable")
struct ProgressiveRendererTests {

    // MARK: - The regression test ADR-2 names explicitly

    /// > **The first-paint block count (~40) is a tunable, not a constant** —
    /// > it should be derived from viewport height at runtime rather than
    /// > hardcoded forever.
    ///
    /// 40 was a research figure measured on one window at one size. This is the
    /// test that fails if someone "simplifies" the derivation back into a
    /// literal.
    @Test("the block count is derived from viewport height, not a constant")
    func viewportDerived() {
        let height = ProgressiveRenderer.initialBlockHeight
        let counts = [300.0, 600.0, 900.0, 1400.0, 2000.0].map {
            ProgressiveRenderer.prefixBlockCount(viewportHeight: $0, blockHeight: height)
        }
        // The property that matters: different viewports, different answers.
        #expect(Set(counts).count == counts.count, "counts \(counts) do not vary with height")
        // And in the right direction.
        #expect(counts == counts.sorted(), "counts \(counts) are not monotonic in height")
        // A taller viewport asks for strictly more, not "40 either way".
        #expect(counts.last! > counts.first! * 2)
    }

    @Test("no viewport height in the plausible range produces the research figure by luck")
    func fortyIsNotSpecial() {
        // Not a claim that 40 is wrong — a claim that it is not *baked in*. If
        // the derivation were `return 40`, every height below would give 40.
        let counts = stride(from: 200.0, through: 2400.0, by: 100.0).map {
            ProgressiveRenderer.prefixBlockCount(
                viewportHeight: $0, blockHeight: ProgressiveRenderer.initialBlockHeight)
        }
        #expect(Set(counts).count > 10, "only \(Set(counts).count) distinct counts across 23 heights")
    }

    @Test("the count scales with the measured block height, not only the viewport")
    func blockHeightMatters() {
        let short = ProgressiveRenderer.prefixBlockCount(viewportHeight: 900, blockHeight: 20)
        let tall = ProgressiveRenderer.prefixBlockCount(viewportHeight: 900, blockHeight: 200)
        #expect(short > tall)
    }

    @Test("a degenerate viewport still yields a usable floor")
    func degenerateViewport() {
        for height in [0.0, -100.0, .nan, .infinity] {
            let count = ProgressiveRenderer.prefixBlockCount(
                viewportHeight: height, blockHeight: ProgressiveRenderer.initialBlockHeight)
            #expect(count >= ProgressiveRenderer.minimumBlocks)
            #expect(count <= ProgressiveRenderer.maximumBlocks)
        }
    }

    @Test("a degenerate block height cannot divide by zero")
    func degenerateBlockHeight() {
        for blockHeight in [0.0, -1.0, .nan] {
            #expect(
                ProgressiveRenderer.prefixBlockCount(viewportHeight: 900, blockHeight: blockHeight)
                    == ProgressiveRenderer.minimumBlocks)
        }
    }

    @Test("observing real geometry moves the estimate toward it")
    func feedback() {
        let renderer = ProgressiveRenderer()
        let before = renderer.prefixBlockCount(viewportHeight: 900)
        // A document of tall blocks — code fences, tables — needs fewer of them
        // to fill the same viewport.
        for _ in 0..<8 { renderer.observe(meanBlockHeight: 200) }
        let after = renderer.prefixBlockCount(viewportHeight: 900)
        #expect(after < before)
        #expect(renderer.blockHeight > 150)
    }

    @Test("nonsense geometry from the page is ignored rather than absorbed")
    func feedbackIgnoresNonsense() {
        let renderer = ProgressiveRenderer()
        let before = renderer.blockHeight
        renderer.observe(meanBlockHeight: 0)
        renderer.observe(meanBlockHeight: .nan)
        renderer.observe(meanBlockHeight: -12)
        #expect(renderer.blockHeight == before)
    }

    // MARK: - The prefix/tail split

    /// The property that makes `tail(full:prefix:)` sound rather than lucky:
    /// blocks render independently and in document order, so the prefix render
    /// is a byte-for-byte prefix of the full render. If the core ever stops
    /// guaranteeing that, this fails here rather than as a silently duplicated
    /// or missing block in the document.
    @Test("a prefix render is a byte-prefix of the full render")
    func prefixProperty() throws {
        let source = Self.mixedDocument
        let full = try MarkCore.renderHTML(source: source, prefixBlocks: 0)
        for count in 1...6 {
            let prefix = try MarkCore.renderHTML(source: source, prefixBlocks: count)
            #expect(full.hasPrefix(prefix), "prefix of \(count) blocks is not a prefix of the whole")
            let tail = try #require(ProgressiveRenderer.tail(full: full, prefix: prefix))
            #expect(prefix + tail == full)
        }
    }

    @Test("the tail is empty when the prefix was the whole document")
    func emptyTail() throws {
        let source = "one\n\ntwo\n"
        let full = try MarkCore.renderHTML(source: source, prefixBlocks: 0)
        let prefix = try MarkCore.renderHTML(source: source, prefixBlocks: 2)
        #expect(ProgressiveRenderer.tail(full: full, prefix: prefix) == "")
    }

    @Test("a prefix that is not a prefix returns nil rather than a wrong tail")
    func nonPrefixIsRefused() {
        // The failure this guards is silent corruption, not a crash: appending
        // a tail computed from a mismatched prefix would duplicate or drop
        // blocks, which ADR-2 calls out as the hard-to-notice failure mode.
        #expect(ProgressiveRenderer.tail(full: "<div>a</div>", prefix: "<div>b</div>") == nil)
        #expect(ProgressiveRenderer.tail(full: "short", prefix: "much longer prefix") == nil)
        #expect(ProgressiveRenderer.tail(full: "abc", prefix: "") == "abc")
    }

    @Test("the split is byte-exact across multi-byte characters")
    func unicodeTail() throws {
        let source = "# Ünïcödé — “quoted” 🎉\n\nsecond block with émojis 🚀\n\nthird\n"
        let full = try MarkCore.renderHTML(source: source, prefixBlocks: 0)
        let prefix = try MarkCore.renderHTML(source: source, prefixBlocks: 1)
        let tail = try #require(ProgressiveRenderer.tail(full: full, prefix: prefix))
        #expect(prefix + tail == full)
        #expect(tail.contains("🚀"))
    }

    /// A document with the constructs whose rendering could plausibly depend on
    /// how many blocks are being emitted: headings (anchors are deduplicated
    /// document-wide), tasks (indices are document-order), and code (memoized).
    static let mixedDocument = """
        # Heading

        A paragraph.

        - [ ] first task
        - [x] second task

        ```rust
        fn main() { println!("hello"); }
        ```

        ## Heading

        | a | b |
        |---|---|
        | 1 | 2 |

        Final paragraph.
        """
}
