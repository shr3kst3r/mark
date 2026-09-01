import AppKit
import Foundation

/// The editor's margin: a coloured bar against every line that differs from git
/// `HEAD`.
///
/// `2026-08-28-git-differences-by-running-git` is why this needs a *line* diff
/// rather than the block diff ADR-2 already had:
///
/// > `core/src/diff.rs`'s block diff drives the rendered display; a new line
/// > diff drives the editor gutter […] Neither is derived from the other.
///
/// A block spans many lines and its identity is a content hash, so it cannot
/// say which line moved. This is the thing that could not be built on it.
///
/// # Why an `NSRulerView` and not a subview
///
/// The ruler is owned by the scroll view, so it scrolls with the text for free
/// and needs no observer to keep it aligned — which is the bug a hand-placed
/// margin view has, and it only shows up under momentum scrolling. It also sits
/// outside the text container, so nothing here can change how the text lays
/// out.
///
/// # Cost
///
/// `drawHashMarksAndLabels` is called on every scroll, so it must not iterate
/// the document. It walks the **visible** line fragments only, via TextKit 2's
/// `enumerateTextLayoutFragments`, and looks each line number up in a
/// dictionary. That keeps the draw bounded by the height of the pane, which is
/// the same bound `TaskBadgeService` and the sidebar poll are held to.
@MainActor
public final class ChangeRuler: NSRulerView {

    /// Width of the margin. Just enough for a 3-point bar and air on both
    /// sides; this is not a line-number gutter and should not read as one.
    public static let thickness: CGFloat = 8

    /// Line number (**zero-based**, as the core reports) → what happened to it.
    ///
    /// Zero-based deliberately, all the way to the point of drawing: the core
    /// speaks zero-based offsets everywhere, and converting at the boundary
    /// rather than at display is how off-by-one bugs get in.
    private var marks: [Int: LineHunkKind] = [:]

    /// Byte-offset ranges are not used for drawing — line numbers are — but the
    /// diff is kept so a caller can ask what it is showing.
    public private(set) var diff: LineDiff?

    public init(scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = scrollView.documentView
        ruleThickness = Self.thickness
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ChangeRuler is created in code, not from a nib")
    }

    /// Show `diff`, or nothing when it is `nil`.
    ///
    /// A coarse diff is shown as nothing rather than as one bar spanning half
    /// the document: `LineDiff/coarse` means "the changed region was too big to
    /// diff precisely", and a bar covering hundreds of lines tells the reader
    /// less than no bar at all while implying precision it does not have.
    public func show(_ diff: LineDiff?) {
        self.diff = diff
        guard let diff, !diff.coarse else {
            if !marks.isEmpty {
                marks = [:]
                needsDisplay = true
            }
            return
        }

        var next: [Int: LineHunkKind] = [:]
        next.reserveCapacity(diff.hunks.count * 2)
        for hunk in diff.hunks {
            if hunk.new.isEmpty {
                // A removal has no line of its own, so it marks the line it
                // sits in front of. `min` because a removal at the end of the
                // document points one past the last line.
                next[hunk.new.start] = next[hunk.new.start] ?? .removed
            } else {
                for line in hunk.new.start..<hunk.new.end { next[line] = hunk.kind }
            }
        }
        guard next != marks else { return }
        marks = next
        needsDisplay = true
    }

    /// Whether anything is being drawn, so the pane can hide the margin
    /// entirely for a clean document rather than leaving an empty strip.
    public var isEmpty: Bool { marks.isEmpty }

    /// The line-to-kind mapping, for tests.
    var marksForTesting: [Int: LineHunkKind] { marks }

    /// The bars that would be drawn, top to bottom, for tests.
    ///
    /// Colour and vertical position only. The drawing itself needs a window and
    /// stays `mark-bench`'s half; what a unit test can hold onto is the
    /// arithmetic that decides which line a bar lands against.
    var barsForTesting: [(kind: LineHunkKind, rect: NSRect)] {
        var bars: [(kind: LineHunkKind, rect: NSRect)] = []
        enumerateBars { bars.append((kind: $0, rect: $1)) }
        return bars
    }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        enumerateBars { kind, bar in
            Self.color(for: kind).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// Every bar the margin would draw right now, in this view's coordinates.
    ///
    /// Split out from the drawing so the geometry can be asserted on without a
    /// window: what goes wrong here is *which line* a bar lands against, and
    /// that is arithmetic, not pixels.
    private func enumerateBars(_ body: (LineHunkKind, NSRect) -> Void) {
        guard !marks.isEmpty,
            let textView = clientView as? NSTextView,
            let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return }

        let inset = textView.textContainerInset.height
        let visible = scrollView?.contentView.bounds ?? bounds

        // Which line each fragment starts on. Counting newlines from the top of
        // the document would be O(document) per draw, so the count is carried
        // forward from the first visible fragment instead: TextKit hands them
        // over in order, and the only thing needed up front is the line number
        // of the first one.
        //
        // `visible` is in the text view's coordinates and the layout is in the
        // container's, which the top inset separates. Asking at the wrong one
        // lands a fragment too far down and the topmost row loses its bar.
        guard
            let firstVisible = layoutManager.textLayoutFragment(
                for: CGPoint(x: 0, y: max(0, visible.minY - inset)))
        else { return }
        var line = lineNumber(
            of: firstVisible.rangeInElement.location, in: contentManager, textView: textView)

        layoutManager.enumerateTextLayoutFragments(from: firstVisible.rangeInElement.location) {
            fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }

            for lineFragment in fragment.textLineFragments {
                let lineFrame = lineFragment.typographicBounds.offsetBy(
                    dx: 0, dy: frame.minY)
                if let kind = marks[line] {
                    let y = lineFrame.minY + inset - visible.minY
                    body(
                        kind,
                        NSRect(
                            x: 2.5, y: y, width: 3,
                            height: max(2, lineFrame.height - 1)))
                }
                // A *visual* row, not a line: the editor soft-wraps, so one
                // line of the document can be several of these. Only a row
                // that ends at a real break moves the count on — a wrapped
                // row keeps it, which is also what puts a bar against every
                // row of a long changed line rather than just its first.
                if Self.endsLine(lineFragment) { line += 1 }
            }
            return true
        }
    }

    /// Whether this visual row ends its line of the document, rather than
    /// being broken off it by soft wrapping.
    ///
    /// Only the row's last character is looked at, which is the whole check: a
    /// row is broken *at* a line break, so a break can only ever be the last
    /// thing on one. The final row of a document that does not end in a
    /// newline reports `false` and nothing follows it to be shifted.
    private static func endsLine(_ lineFragment: NSTextLineFragment) -> Bool {
        let text = lineFragment.attributedString.string as NSString
        let range = lineFragment.characterRange
        guard range.length > 0, NSMaxRange(range) <= text.length else { return false }
        switch text.character(at: NSMaxRange(range) - 1) {
        // Line feed, carriage return, and Unicode's own line and paragraph
        // separators — the set `String.enumerateLines` breaks on.
        case 0x0A, 0x0D, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Zero-based line number of a document location.
    ///
    /// Called **once** per draw, for the first visible fragment only. It does
    /// scan from the start of the document, and that is the one place a scan is
    /// affordable: one pass over the text before the viewport, against a draw
    /// that would otherwise be O(document × fragments).
    ///
    /// The scan reads the text through one 4 KB buffer rather than taking a
    /// `substring(to:)`. This is on the scroll path — `drawHashMarksAndLabels`
    /// runs every frame — and the substring version allocated and copied a
    /// fresh `NSString` of everything above the viewport on each of them,
    /// which on a large document scrolled near its end is a megabyte of
    /// malloc-and-copy per frame for a number that fits in an `Int`. The pass
    /// is still `O(document)`; what it no longer is, is `O(document)` bytes of
    /// allocation.
    private func lineNumber(
        of location: NSTextLocation, in contentManager: NSTextContentManager,
        textView: NSTextView
    ) -> Int {
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: location)
        guard offset > 0 else { return 0 }
        let text = textView.string as NSString
        let end = min(offset, text.length)
        var count = 0
        var start = 0
        var chunk = [unichar](repeating: 0, count: 4_096)
        while start < end {
            let length = min(chunk.count, end - start)
            text.getCharacters(&chunk, range: NSRange(location: start, length: length))
            for index in 0..<length where chunk[index] == 10 { count += 1 }
            start += length
        }
        return count
    }

    /// Additions green, removals red, replacements amber — the same three the
    /// rendered diff view uses, so a bar in the margin means the same thing as a
    /// tint in the preview.
    ///
    /// System colours rather than the document theme's slots, matching
    /// ``TreeCellView/additionColor``: the editor is AppKit chrome and follows
    /// the system appearance, while a document's theme can be pinned per window.
    static func color(for kind: LineHunkKind) -> NSColor {
        switch kind {
        case .added: return .systemGreen
        case .removed: return .systemRed
        case .changed: return .systemOrange
        }
    }
}
