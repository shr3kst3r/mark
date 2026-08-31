import AppKit
import Foundation

/// What kind of blank a blank is.
///
/// Five marks rather than one, because the reason to draw a space at all is to
/// tell it apart from the space beside it. A markdown document that renders
/// wrongly for no visible reason is nearly always one of the bottom three: a
/// no-break space where an indent should be, an en quad pasted out of a PDF, a
/// zero-width joiner left behind by a chat client. A single uniform dot says
/// "there is whitespace here", which the reader already knew.
///
/// The grouping is by *consequence*, not by code point. `U+202F NARROW NO-BREAK
/// SPACE` is drawn like `U+00A0` because the thing worth knowing about both is
/// that they do not break; the seven quads and the ideographic space share a
/// mark because the thing worth knowing about all of them is "this is not the
/// space you typed".
public enum InvisibleMark: String, Equatable, Sendable, CaseIterable {

    /// `U+0020`. A dot at the middle of the advance.
    case space

    /// `U+0009`. An arrow spanning the advance, so the mark says how wide the
    /// tab actually is — the one question a fixed-width glyph could not answer.
    case tab

    /// `U+00A0`, `U+202F`, `U+2007`: the spaces that refuse to break. Drawn as
    /// an open ring — a dot that has been circled.
    case noBreakSpace

    /// The quads, the thin and hair spaces, `U+205F`, `U+1680`, and the
    /// full-width `U+3000`. Drawn as a small open diamond.
    case exoticSpace

    /// `U+200B`, `U+200C`, `U+200D`, `U+2060`, `U+FEFF`, `U+180E`. Zero advance,
    /// so there is no cell to mark: drawn as a thin upright bar between the two
    /// characters it hides between.
    case zeroWidth

    /// Whether this mark is one of the three that usually arrived by accident.
    ///
    /// Drives the colour, and only the colour: the tinted three are the ones
    /// worth *noticing*, while a space and a tab are worth being able to count.
    public var isUnexpected: Bool {
        switch self {
        case .space, .tab: return false
        case .noBreakSpace, .exoticSpace, .zeroWidth: return true
        }
    }
}

/// The editor's invisibles: which characters get a mark, and whether marks are
/// being drawn at all.
///
/// The classification is a pure function of one UTF-16 unit and lives here
/// rather than in the view, for the reason ``ChangeRuler/marksForTesting``
/// exists: drawing needs a window and a laid-out text container, and a test
/// without one asserts on nothing. What can be tested without a window is
/// *which* characters are marked and *what* they are marked as, so that is
/// separated out and tested directly.
public enum Invisibles {

    /// The mark for one UTF-16 code unit, or `nil` for a character that draws
    /// its own ink.
    ///
    /// Takes a code unit rather than a `Character` because that is what the
    /// drawing loop has: `NSTextLineFragment` positions characters by UTF-16
    /// index, and every character listed here is in the BMP, so no surrogate
    /// pair is ever split by asking one unit at a time.
    ///
    /// Newlines are deliberately absent. A line ending is already drawn — by
    /// the line ending — and a pilcrow at the end of every line in a markdown
    /// document is the invasive version of this feature, not the useful one:
    /// markdown's two trailing spaces are worth seeing, and this shows them.
    public static func mark(forUTF16 unit: UTF16.CodeUnit) -> InvisibleMark? {
        switch unit {
        case 0x0020: return .space
        case 0x0009: return .tab
        case 0x00A0, 0x2007, 0x202F: return .noBreakSpace
        case 0x1680, 0x2000...0x200A, 0x205F, 0x3000: return .exoticSpace
        case 0x180E, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: return .zeroWidth
        default: return nil
        }
    }

    /// Every mark in `text`, by UTF-16 offset, in order.
    ///
    /// The testable shape of what the overlay draws: the view walks a laid-out
    /// line fragment and this walks a string, but both ask
    /// ``mark(forUTF16:)`` the same question about the same units.
    public static func marks(in text: String) -> [(offset: Int, mark: InvisibleMark)] {
        var result: [(offset: Int, mark: InvisibleMark)] = []
        for (offset, unit) in text.utf16.enumerated() {
            if let mark = mark(forUTF16: unit) { result.append((offset, mark)) }
        }
        return result
    }

    // MARK: - The app-wide switch

    /// Posted when ``isShowing`` changes, so every open editor repaints.
    ///
    /// A notification rather than a call into ``WindowCoordinator``, because
    /// this is a property of the *editor* and every window has one: the menu
    /// item reaches the focused window through the responder chain, and a
    /// second window whose spaces were still drawn would read as the toggle
    /// half-working. ``ThemeController`` reaches the other windows' pages a
    /// different way only because a page is not an `NSView`.
    public static let didChangeNotification = Notification.Name("dev.mark.invisiblesDidChange")

    /// Whether the editor draws marks for whitespace.
    ///
    /// **On by default**, which is the one defensible default for a feature
    /// whose whole content is "show me what is there". It is app-wide and
    /// persisted (`SessionState.editorInvisibles`), like the theme and for the
    /// same reason: two editors in two windows disagreeing about whether a
    /// space is visible is not a state anyone means to be in.
    @MainActor
    public static var isShowing: Bool = true {
        didSet {
            guard isShowing != oldValue else { return }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Adopt a persisted value at launch. Absent — a session file written
    /// before this existed — leaves the default alone.
    @MainActor
    public static func restore(_ showing: Bool?) {
        guard let showing else { return }
        isShowing = showing
    }
}

/// The marks themselves, drawn over the editor's text.
///
/// # Why a subview and not a subclass
///
/// The alternative was overriding `draw(_:)` on the text view. This is a
/// sibling of the text's glyphs instead, for the same reason
/// ``ChangeRuler`` is an `NSRulerView`: it cannot change how the text lays
/// out, and it cannot change what `NSTextView` does. ADR-6 chose an
/// `NSTextView` *"precisely so that undo, Find & Replace, spellcheck and text
/// substitution come for free"*, and every one of those is a behaviour of the
/// class we would then be subclassing. Nothing here touches the text storage
/// either — an attribute that substituted a visible glyph for a space would be
/// an edit to the document's own attributes, and would put a mark into anything
/// copied out of the pane.
///
/// It is a subview of the text view rather than of the scroll view, so it
/// scrolls with the document with no observer keeping it aligned — the bug a
/// hand-placed overlay has, and one that only appears under momentum scrolling.
///
/// # Cost
///
/// `draw(_:)` is called on every scroll and after every keystroke, so it must
/// not iterate the document. It walks the line fragments that intersect the
/// dirty rectangle — via the same TextKit 2 enumeration ``ChangeRuler`` uses —
/// and asks each one where its own characters are. The work is bounded by the
/// height of the pane, which is the bound every recurring draw in this app is
/// held to.
@MainActor
public final class InvisiblesOverlay: NSView {

    private weak var textView: NSTextView?

    /// How many marks the last draw put on screen, for `mark-bench` and the
    /// tests. Zero after a draw with the feature off, which is the cheap way to
    /// assert the switch does something.
    public private(set) var lastDrawnCount = 0

    /// What the last draw cost, in seconds.
    ///
    /// Instrumented rather than assumed, for the reason
    /// ``EditorPane/lastKeystrokeSeconds`` is: this draw is on the typing path,
    /// and "it is only the viewport" is a claim about a number.
    ///
    /// Measured at **1.2 ms** for a pathological viewport — 800×600 of solid
    /// prose, 407 marks on screen, every one of them a path appended and
    /// filled. That is 7% of a 60 Hz frame, and it is paid *per frame* rather
    /// than per keystroke: the pane marks the overlay dirty on every edit, and
    /// AppKit coalesces those into one draw before the next frame, so typing
    /// quickly does not draw quickly. A real pane is half that wide.
    ///
    /// It is not on the highlight throttle for the same reason: a space you
    /// have just typed has to get its dot on the same frame as its cell, and
    /// waiting 200 ms for it would make the marks visibly lag the caret.
    public private(set) var lastDrawSeconds: Double = 0

    public init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: textView.bounds)
        self.autoresizingMask = [.width, .height]
        // Chrome over a document, not content: it must never take a click away
        // from the text view, and VoiceOver must not find a second copy of the
        // document's whitespace in it.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InvisiblesOverlay is created in code, not from a nib")
    }

    /// The text view's coordinates are flipped, and this draws in them.
    public override var isFlipped: Bool { true }

    /// Clicks, drags, and the I-beam belong to the text underneath.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The marks. Thin enough to read as texture rather than as text.
    ///
    /// Sizes are in points and deliberately sub-pixel-ish: a 2-point dot at 13
    /// point monospace is about a sixth of the advance, which is visible when
    /// you look at the indentation and gone when you are reading the words.
    private enum Metric {
        static let dotDiameter: CGFloat = 2
        static let ringDiameter: CGFloat = 4
        static let diamondSide: CGFloat = 4.5
        static let barWidth: CGFloat = 1.5
        static let hairline: CGFloat = 0.75
        /// Air left at each end of a tab's arrow, so two adjacent tabs read as
        /// two arrows rather than one long rule.
        static let arrowInset: CGFloat = 1.5
        static let arrowHead: CGFloat = 2.5
    }

    public override func draw(_ dirtyRect: NSRect) {
        let began = DispatchTime.now().uptimeNanoseconds
        defer {
            lastDrawSeconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
        }
        lastDrawnCount = 0
        guard Invisibles.isShowing,
            let textView,
            let layoutManager = textView.textLayoutManager
        else { return }

        // Container coordinates: the fragment frames TextKit hands back are
        // relative to the text container, and this view is the size of the text
        // view, which is the container plus its inset.
        let inset = textView.textContainerInset
        let top = max(0, dirtyRect.minY - inset.height)
        let bottom = dirtyRect.maxY - inset.height
        guard bottom > 0 else { return }
        // Clamped into laid-out text for the reason
        // ``EditorPane/visibleCharacterRange(padding:length:)`` documents:
        // `textLayoutFragment(for:)` answers `nil` below the last line rather
        // than answering "the end", and a `nil` here would draw nothing at all
        // while the reader was looking at the bottom of the document.
        let laidOut = layoutManager.usageBoundsForTextContainer.maxY
        guard laidOut > 0,
            let first = layoutManager.textLayoutFragment(
                for: CGPoint(x: 0, y: min(top, laidOut - 1)))
        else { return }

        let theme = ThemeController.shared
        let ordinary = Self.ink(theme.editorColor(of: "muted", fallback: .tertiaryLabelColor), 0.55)
        let unexpected = Self.ink(theme.editorColor(of: "warning", fallback: .systemOrange), 0.7)

        // Two paths per colour, filled and stroked, so a screenful of marks is
        // four `NSBezierPath` fills rather than several hundred.
        let fills = (ordinary: NSBezierPath(), unexpected: NSBezierPath())
        let strokes = (ordinary: NSBezierPath(), unexpected: NSBezierPath())
        var drawn = 0

        layoutManager.enumerateTextLayoutFragments(from: first.rangeInElement.location) {
            fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > bottom { return false }

            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                let originX = frame.minX + bounds.minX + inset.width
                let originY = frame.minY + bounds.minY + inset.height
                if originY > bottom || originY + bounds.height < top { continue }
                let baseline = originY + line.glyphOrigin.y

                let string = line.attributedString.string as NSString
                let range = line.characterRange
                guard range.length > 0, NSMaxRange(range) <= string.length else { continue }
                // One font lookup per line fragment, not per character: a
                // heading's spaces are marked at the heading's x-height, and a
                // line has one font in this editor because the highlighting is
                // block-level (ADR-6).
                let font =
                    line.attributedString.attribute(.font, at: range.location, effectiveRange: nil)
                    as? NSFont ?? EditorPane.bodyFont
                let middle = baseline - font.xHeight / 2

                for index in range.location..<NSMaxRange(range) {
                    guard let mark = Invisibles.mark(forUTF16: string.character(at: index))
                    else { continue }
                    let x0 = originX + line.locationForCharacter(at: index).x
                    // The advance, read from where the *next* character sits.
                    // A character at the end of a wrapped line has no next
                    // character on this line, and one at the end of the
                    // paragraph has none at all, so both fall back to the
                    // font's own space width rather than to a negative width.
                    var x1 = x0
                    if index + 1 < string.length {
                        x1 = originX + line.locationForCharacter(at: index + 1).x
                    }
                    if x1 <= x0 { x1 = x0 + font.maximumAdvancement.width }

                    let fill = mark.isUnexpected ? fills.unexpected : fills.ordinary
                    let stroke = mark.isUnexpected ? strokes.unexpected : strokes.ordinary
                    Self.add(
                        mark, from: x0, to: x1, middle: middle, xHeight: font.xHeight,
                        fill: fill, stroke: stroke)
                    drawn += 1
                }
            }
            return true
        }

        ordinary.setFill()
        fills.ordinary.fill()
        ordinary.setStroke()
        strokes.ordinary.lineWidth = Metric.hairline
        strokes.ordinary.stroke()
        unexpected.setFill()
        fills.unexpected.fill()
        unexpected.setStroke()
        strokes.unexpected.lineWidth = Metric.hairline
        strokes.unexpected.stroke()
        lastDrawnCount = drawn
    }

    /// One mark, appended to whichever path draws it.
    ///
    /// `nonisolated` and `static` because it is geometry: it reads nothing and
    /// changes nothing, which is what makes it readable next to the enumeration
    /// above rather than inside it.
    private nonisolated static func add(
        _ mark: InvisibleMark, from x0: CGFloat, to x1: CGFloat, middle: CGFloat,
        xHeight: CGFloat, fill: NSBezierPath, stroke: NSBezierPath
    ) {
        let centre = (x0 + x1) / 2
        switch mark {
        case .space:
            let r = Metric.dotDiameter / 2
            fill.appendOval(
                in: NSRect(x: centre - r, y: middle - r, width: r * 2, height: r * 2))
        case .noBreakSpace:
            let r = Metric.ringDiameter / 2
            stroke.appendOval(
                in: NSRect(x: centre - r, y: middle - r, width: r * 2, height: r * 2))
        case .exoticSpace:
            let r = Metric.diamondSide / 2
            stroke.move(to: NSPoint(x: centre, y: middle - r))
            stroke.line(to: NSPoint(x: centre + r, y: middle))
            stroke.line(to: NSPoint(x: centre, y: middle + r))
            stroke.line(to: NSPoint(x: centre - r, y: middle))
            stroke.close()
        case .zeroWidth:
            // Zero advance, so this sits *between* two visible characters
            // rather than in a cell of its own, and has no width to borrow a
            // shape from. It gets the full x-height instead: a character that
            // is invisible even to the caret is the one worth being able to see
            // from across the line, and a 4-point tick between two letters was
            // measurably easy to miss.
            let height = max(4, xHeight)
            fill.appendRect(
                NSRect(
                    x: x0 - Metric.barWidth / 2, y: middle - height / 2,
                    width: Metric.barWidth, height: height))
        case .tab:
            let left = x0 + Metric.arrowInset
            let right = max(left + Metric.arrowHead, x1 - Metric.arrowInset)
            stroke.move(to: NSPoint(x: left, y: middle))
            stroke.line(to: NSPoint(x: right, y: middle))
            stroke.move(to: NSPoint(x: right - Metric.arrowHead, y: middle - Metric.arrowHead))
            stroke.line(to: NSPoint(x: right, y: middle))
            stroke.line(to: NSPoint(x: right - Metric.arrowHead, y: middle + Metric.arrowHead))
        }
    }

    /// A theme colour at a fraction of its opacity, resolved for the appearance
    /// this draw is happening in.
    ///
    /// ``ThemeController/editorColor(of:fallback:)`` answers a *dynamic*
    /// `NSColor`, which is the point of it — the editor follows light and dark
    /// with no code running. `withAlphaComponent` on such a colour is not
    /// reliable, so it is resolved to a concrete sRGB colour first. Inside
    /// `draw(_:)` the current appearance is this view's, so resolving here is
    /// resolving against the appearance the marks are about to be drawn in.
    private nonisolated static func ink(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
        (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(alpha)
    }
}
