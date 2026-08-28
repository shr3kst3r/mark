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
    ///
    /// Exposed because the *mapping* is the testable half — the drawing needs a
    /// window, and a view without one reports a zero viewport, so a pixel
    /// assertion here would assert on nothing. `mark-bench` has a window.
    var marksForTesting: [Int: LineHunkKind] { marks }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
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
        guard
            let firstVisible = layoutManager.textLayoutFragment(
                for: CGPoint(x: 0, y: visible.minY))
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
                    let bar = NSRect(
                        x: 2.5, y: y, width: 3,
                        height: max(2, lineFrame.height - 1))
                    Self.color(for: kind).setFill()
                    NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
                }
                line += 1
            }
            return true
        }
    }

    /// Zero-based line number of a document location.
    ///
    /// Called **once** per draw, for the first visible fragment only. It does
    /// scan from the start of the document, and that is the one place a scan is
    /// affordable: one pass over the text before the viewport, against a draw
    /// that would otherwise be O(document × fragments).
    private func lineNumber(
        of location: NSTextLocation, in contentManager: NSTextContentManager,
        textView: NSTextView
    ) -> Int {
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: location)
        guard offset > 0 else { return 0 }
        let text = textView.string as NSString
        let upto = text.substring(to: min(offset, text.length))
        var count = 0
        for character in upto.utf16 where character == 10 { count += 1 }
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
