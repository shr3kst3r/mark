import Foundation

/// The Swift half of ADR-2's prefix-then-fill: how many blocks to paint first,
/// and how to split the core's output into "what the reader sees now" and
/// "everything else".
///
/// The load-bearing constraint from ADR-2's Consequences is:
///
/// > **The first-paint block count (~40) is a tunable, not a constant** — it
/// > should be derived from viewport height at runtime rather than hardcoded
/// > forever.
///
/// So 40 appears nowhere in this file. ``prefixBlockCount(viewportHeight:)``
/// computes a count from the viewport, and ``observe(meanBlockHeight:)`` feeds
/// the *measured* mean block height of the last painted prefix back in, so the
/// estimate converges on the document actually being read instead of staying at
/// a guess. `MarkTests.ProgressiveRendererTests` asserts both properties.
public final class ProgressiveRenderer {

    /// How many viewports of content to paint before handing over to the pump.
    ///
    /// More than one, so a flick of the scroll wheel immediately after open
    /// does not outrun the fill; not much more, because every extra block is
    /// layout on the critical path. Not a measured optimum — a tunable, same
    /// as the block count.
    public static let overscanViewports: Double = 1.5

    /// Below this, prefix-then-fill costs more in round trips than it saves.
    public static let minimumBlocks = 8

    /// Above this, we are no longer painting "the visible prefix"; a viewport
    /// tall enough to want more blocks than this is better served by the pump.
    public static let maximumBlocks = 256

    /// Starting estimate for a top-level block's laid-out height, in points.
    ///
    /// Only used until the first real measurement arrives. A paragraph at
    /// 16px/1.6 with a 1 rem bottom margin is ~42 pt; the corpus mixes in
    /// headings, tables, and code fences, which are taller.
    public static let initialBlockHeight: Double = 44

    /// The running estimate, updated from what the shell actually laid out.
    public private(set) var blockHeight: Double

    public init(blockHeight: Double = ProgressiveRenderer.initialBlockHeight) {
        self.blockHeight = max(1, blockHeight)
    }

    /// How many top-level blocks to render before first paint, for a viewport
    /// this tall.
    ///
    /// - Parameter viewportHeight: the document area's height in points. A
    ///   zero or negative height (a window not yet laid out) still yields a
    ///   usable floor rather than an empty document.
    public func prefixBlockCount(viewportHeight: Double) -> Int {
        Self.prefixBlockCount(viewportHeight: viewportHeight, blockHeight: blockHeight)
    }

    /// The pure form, so the property that matters — the count moves with the
    /// viewport — can be tested without an instance or a web view.
    public static func prefixBlockCount(viewportHeight: Double, blockHeight: Double) -> Int {
        guard viewportHeight.isFinite, blockHeight.isFinite, blockHeight > 0 else {
            return minimumBlocks
        }
        let wanted = (max(0, viewportHeight) * overscanViewports / blockHeight).rounded(.up)
        guard wanted.isFinite else { return minimumBlocks }
        return min(maximumBlocks, max(minimumBlocks, Int(wanted)))
    }

    /// Feed back the mean laid-out block height the shell just measured.
    ///
    /// Smoothed rather than replaced outright so one unusual document — a page
    /// of one-line list items, say — does not whipsaw the next one's estimate.
    public func observe(meanBlockHeight: Double) {
        guard meanBlockHeight.isFinite, meanBlockHeight > 1 else { return }
        blockHeight = blockHeight * 0.5 + meanBlockHeight * 0.5
    }

    /// The tail of `full` that is not already in `prefix`.
    ///
    /// This exists because the C ABI exposes `mark_render_html(source,
    /// prefix_blocks)` and nothing that renders an arbitrary block *range* —
    /// `render_range` is Rust-side only. Blocks render independently of one
    /// another and in document order, so the prefix render is a byte-for-byte
    /// prefix of the full render, and the tail is what is left after it. That
    /// property is asserted in `ProgressiveRendererTests`, and it is the reason
    /// this is safe rather than a coincidence.
    ///
    /// - Returns: the tail, `""` when the prefix was the whole document, or
    ///   `nil` when the property does not hold — in which case the caller must
    ///   replace the document wholesale rather than append a wrong tail.
    public static func tail(full: String, prefix: String) -> String? {
        if prefix.isEmpty { return full }
        guard full.utf8.count >= prefix.utf8.count else { return nil }
        guard full.utf8.starts(with: prefix.utf8) else { return nil }
        let start = full.utf8.index(full.utf8.startIndex, offsetBy: prefix.utf8.count)
        return String(decoding: full.utf8[start...], as: UTF8.self)
    }
}
