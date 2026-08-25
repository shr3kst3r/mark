import AppKit
import Foundation

/// Byte offsets from the core, as UTF-16 offsets for `NSTextStorage`.
///
/// The core speaks UTF-8 byte offsets — that is the whole point of ADR-1's
/// choice of `pulldown-cmark`, and every `data-mk-start` in the app is one.
/// `NSTextStorage` speaks UTF-16. On an all-ASCII document the two agree, and
/// on a document with one emoji in it they do not, from that emoji to the end.
///
/// Converting each offset independently would be `O(n)` per offset — 60
/// visible blocks on a 1 MB document is 120 walks of a megabyte. This walks
/// once, in ascending order, which is what makes highlighting affordable at
/// typing cadence.
enum SourceOffsets {

    /// Convert `byteOffsets`, which **must be sorted ascending**, in one pass.
    ///
    /// Offsets past the end of the text clamp to its length rather than
    /// throwing: a stale block list racing an edit is an ordinary event here,
    /// and the answer to it is a slightly wrong highlight for one frame, not a
    /// crash.
    static func utf16(of byteOffsets: [Int], in text: String) -> [Int] {
        guard !byteOffsets.isEmpty else { return [] }
        let utf16Length = text.utf16.count
        // The fast path, and the common one: no multi-byte scalars at all, so
        // the two coordinate systems are the same numbers.
        if text.utf8.count == utf16Length {
            return byteOffsets.map { min(max(0, $0), utf16Length) }
        }

        var result: [Int] = []
        result.reserveCapacity(byteOffsets.count)
        var byteCursor = 0
        var utf16Cursor = 0
        var scalars = text.unicodeScalars.makeIterator()
        var next = scalars.next()

        for target in byteOffsets {
            let clamped = max(0, target)
            while byteCursor < clamped, let scalar = next {
                byteCursor += UTF8.width(scalar)
                utf16Cursor += UTF16.width(scalar)
                next = scalars.next()
            }
            result.append(min(utf16Cursor, utf16Length))
        }
        return result
    }
}

/// The third pane: a plain-text markdown editor.
///
/// `2026-08-24-editing-pane-and-autosave`:
///
/// > The editor is an **`NSTextView` backed by TextKit 2**. We do not
/// > reimplement undo, find, spellcheck, or text substitution; we inherit them.
/// > Markdown *source* highlighting in the editor is driven by the core's
/// > existing block byte ranges, not by a second parser.
///
/// Everything inherited is inherited by *not writing it*: `allowsUndo`,
/// `usesFindBar`, `isContinuousSpellCheckingEnabled` and
/// `isAutomaticTextReplacementEnabled` are AppKit's, and the Edit menu items
/// that drive them target the responder chain rather than this class. The one
/// deviation is documented at ``configure(_:)``.
///
/// Two structural decisions the ADR leaves open, made here:
///
/// * **One text view, rebound per tab**, not one per tab. A `WKWebView` costs
///   ~52 MB and is worth pooling; an `NSTextView` costs kilobytes, but its
///   *undo stack* is per-view and would let ⌘Z in one document undo an edit
///   made in another. So the view is shared and the `UndoManager` is per
///   buffer, handed over by ``undoManager(for:)``.
/// * **The pane never reads the file.** It is bound to a ``Buffer`` and
///   nothing else, which is what makes ADR-6's "the buffer is the source of
///   truth" true by construction rather than by discipline. It also means the
///   pane does not care whether the tab's `WKWebView` exists — ADR-6's last
///   constraint.
@MainActor
public final class EditorPane: NSView, NSTextViewDelegate, @MainActor NSTextStorageDelegate {

    /// The text view. `public` so `mark-bench` can type into it the way a
    /// person would, through `insertText(_:replacementRange:)`.
    public let textView: NSTextView

    private let scrollView: NSScrollView

    public private(set) var buffer: Buffer?

    /// Per-buffer undo, so ⌘Z never crosses a document boundary. Keyed by the
    /// buffer's identity, dropped when the tab closes.
    private var undoManagers: [ObjectIdentifier: UndoManager] = [:]

    /// Editor scroll position and selection per buffer, restored on rebind so
    /// switching tabs and coming back does not put the caret at the top.
    private var places: [ObjectIdentifier: (selection: NSRange, scroll: CGFloat)] = [:]

    /// The most recent parse of the buffer, in UTF-16 coordinates. Recomputed
    /// off the main actor and applied to the visible range only.
    private var highlightRanges: [(range: NSRange, kind: String, level: Int?)] = []

    /// Bumped on every edit and every rebind, so a highlight computed for text
    /// that has since changed is dropped instead of applied to the wrong bytes.
    private var parseGeneration = 0

    /// Set while the pane is writing into the text storage itself, so
    /// ``textDidChange(_:)`` does not report the pane's own work back to the
    /// buffer as if the user had typed it.
    private var isApplyingExternalText = false

    /// How often, at most, the source is re-parsed for highlighting while
    /// someone is typing.
    ///
    /// Measured rather than guessed. One pass on the 1 MB corpus costs 7.7 ms
    /// in the core and another 11.7 ms decoding its JSON — 19.4 ms in total,
    /// off the main actor. At an 80 ms throttle that is a quarter of a core
    /// spent re-parsing a document nobody has finished editing, and the
    /// contention showed up as a **median keystroke of 14.8 ms**. At 200 ms it
    /// is ~10%, the median keystroke is back under 6 ms, and the highlight
    /// still lands well inside the time it takes to type the next word.
    public static let highlightDebounce: TimeInterval = 0.200
    private var highlightWork: DispatchWorkItem?

    /// A parse is running off the main actor right now, and whether another
    /// edit arrived while it was.
    private var isParsing = false
    private var parseAgainWhenIdle = false

    /// Instrumentation for the typing-latency gate: how long the last
    /// highlight pass took, end to end, and how many have run.
    public private(set) var lastHighlightSeconds: Double = 0
    public private(set) var highlightPasses = 0

    /// What the last keystroke cost the main thread, in seconds: the splice
    /// into the buffer and the bookkeeping around it, but not the parse, which
    /// is not on this thread.
    public private(set) var lastKeystrokeSeconds: Double = 0

    /// The two halves of it: reading the edited characters out of the storage,
    /// and splicing them into the buffer. Split because they have failed
    /// differently and would again — see the comments at each.
    public private(set) var lastSubstringSeconds: Double = 0
    public private(set) var lastSpliceSeconds: Double = 0

    /// How many times the buffer and the text view had to be resynchronised.
    ///
    /// Expected to be zero forever. Counted rather than merely logged because
    /// it is the one number that says "the two copies of the document drifted
    /// apart", and a `mark-bench` run asserts on it.
    public private(set) var resynchronisations = 0

    public override init(frame: NSRect) {
        textView = NSTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView(frame: frame)
        super.init(frame: frame)

        Self.configure(textView)
        textView.delegate = self
        textView.textStorage?.delegate = self

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Highlighting is applied to the visible range only, so scrolling has
        // to re-apply it. The alternative — attributing a whole 1 MB document —
        // is a multi-hundred-millisecond stall on every keystroke.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleRegionChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        applyThemeColours()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorPane is created in code, not from a nib")
    }

    /// Everything AppKit gives us for free, switched on — and the one thing
    /// switched off.
    ///
    /// **Smart quotes and smart dashes are disabled.** They rewrite `"` as `"`
    /// and `--` as `—` *in the source*, which silently changes the bytes inside
    /// a fenced code block and breaks reference links. This is not a
    /// re-implementation of text substitution and does not conflict with the
    /// ADR's "we inherit them": the user's own Text Replacements
    /// (`isAutomaticTextReplacementEnabled`) stay on, as do spellcheck,
    /// grammar, undo, and Find & Replace. Only the two typographic rewrites
    /// that corrupt markdown source are off.
    private static func configure(_ textView: NSTextView) {
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = Self.bodyFont
        textView.setAccessibilityLabel("Markdown source")
        textView.setAccessibilityRoleDescription("markdown editor")
    }

    // MARK: - Binding

    /// Show `buffer`, or nothing.
    ///
    /// Rebinding is cheap and lossless: the outgoing buffer's caret and scroll
    /// position are kept, and its undo stack goes on living in
    /// ``undoManagers`` so ⌘Z after a tab switch undoes *that* document's last
    /// edit.
    public func bind(_ buffer: Buffer?) {
        if let current = self.buffer {
            places[ObjectIdentifier(current)] = (textView.selectedRange(), currentScroll)
        }
        self.buffer = buffer
        parseGeneration += 1
        guard let buffer else {
            replaceText(with: "")
            textView.isEditable = false
            highlightRanges = []
            return
        }
        textView.isEditable = true
        replaceText(with: buffer.text)
        if let place = places[ObjectIdentifier(buffer)] {
            let length = (textView.string as NSString).length
            let selection = NSRange(
                location: min(place.selection.location, length),
                length: min(place.selection.length, max(0, length - place.selection.location))
            )
            textView.setSelectedRange(selection)
            scroll(to: place.scroll)
        }
        scheduleHighlight(immediately: true)
    }

    /// Forget everything remembered about `buffer` — its undo stack and its
    /// caret. Called when the tab closes, not when it is merely switched away
    /// from.
    public func forget(_ buffer: Buffer) {
        let key = ObjectIdentifier(buffer)
        undoManagers.removeValue(forKey: key)
        places.removeValue(forKey: key)
        if self.buffer === buffer { bind(nil) }
    }

    /// Put text into the view *without* it counting as an edit.
    ///
    /// Used by "take theirs" and by a clean tab following an external change.
    /// The caret is kept where it was if it still exists, because the reader
    /// is usually still looking at the same place.
    public func adoptExternalText(_ text: String) {
        let caret = textView.selectedRange()
        replaceText(with: text)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
        scheduleHighlight(immediately: true)
    }

    private func replaceText(with text: String) {
        isApplyingExternalText = true
        defer { isApplyingExternalText = false }
        // Through the text storage rather than `string = …` so TextKit 2's
        // layout is invalidated once for the whole change rather than per
        // paragraph, and so the undo manager does not see it as an edit.
        let storage = textView.textStorage
        storage?.beginEditing()
        storage?.replaceCharacters(
            in: NSRange(location: 0, length: storage?.length ?? 0), with: text)
        storage?.setAttributes(Self.baseAttributes, range: NSRange(location: 0, length: (text as NSString).length))
        storage?.endEditing()
    }

    // MARK: - NSTextViewDelegate

    /// Per-buffer undo. Without this, one shared text view means one shared
    /// undo stack, and ⌘Z after a tab switch edits the document you are not
    /// looking at.
    public func undoManager(for view: NSTextView) -> UndoManager? {
        guard let buffer else { return nil }
        let key = ObjectIdentifier(buffer)
        if let existing = undoManagers[key] { return existing }
        let manager = UndoManager()
        undoManagers[key] = manager
        return manager
    }

    /// One edit in the text storage — a keystroke, a paste, a deletion, an
    /// undo, an autocorrection — spliced into the buffer.
    ///
    /// **Not `textDidChange`, and not `NSTextView.string`.** The obvious
    /// implementation takes the text view's whole contents and hands them to
    /// the buffer; measured on the 1 MB corpus that costs **86–108 ms per
    /// keystroke** on the main thread, because it bridges a megabyte of
    /// `NSString` and transcodes it to contiguous UTF-8 every time. Typing was
    /// visibly, unusably behind. The edit itself is a few characters, so the
    /// buffer takes the edit instead of the document.
    ///
    /// `NSTextStorageDelegate` rather than `textView(_:shouldChangeTextIn:)`
    /// because the storage sees **every** mutation, including the ones a
    /// `shouldChange` hook never hears about: marked text from an input
    /// method, an autocorrection applied after the fact, and a system Text
    /// Replacement. Missing one of those would leave the buffer holding
    /// something the reader is not looking at.
    public func textStorage(
        _ storage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isApplyingExternalText, let buffer
        else { return }
        let began = DispatchTime.now().uptimeNanoseconds
        // `editedRange` is in the *new* text; the range it replaced is the same
        // location, `delta` shorter.
        let replacedLength = editedRange.length - delta
        // `attributedSubstring(from:)`, **not** `mutableString.substring(with:)`.
        // The latter measured **8.7 ms per keystroke** on the 1 MB corpus:
        // `NSTextStorage.mutableString` hands back a proxy that reports its
        // accesses back into the storage's edit bookkeeping, and asking it for
        // a one-character substring from inside `didProcessEditing` is not the
        // cheap operation it looks like. This one is 0.06 ms.
        let substringStarted = DispatchTime.now().uptimeNanoseconds
        let replacement = storage.attributedSubstring(from: editedRange).string
        lastSubstringSeconds =
            Double(DispatchTime.now().uptimeNanoseconds - substringStarted) / 1_000_000_000
        let spliceStarted = DispatchTime.now().uptimeNanoseconds
        let applied =
            replacedLength >= 0
            && buffer.applyEdit(
                replacing: NSRange(location: editedRange.location, length: replacedLength),
                with: replacement)
        lastSpliceSeconds =
            Double(DispatchTime.now().uptimeNanoseconds - spliceStarted) / 1_000_000_000
        // The divergence check, in O(1): if the buffer's own idea of its length
        // has drifted from the storage's, the two copies of the document are no
        // longer the same document, and carrying on would mean autosaving bytes
        // the reader never typed.
        if !applied || buffer.utf16Length != storage.length {
            resynchroniseFromTextView(reason: applied ? "length drift" : "an edit that did not fit")
        }
        lastKeystrokeSeconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
        scheduleHighlight()
    }

    /// The escape hatch: take the text view's whole contents and replace the
    /// buffer with them.
    ///
    /// Expensive — this is the 86 ms path — and it should never run. It exists
    /// because the alternative to an expensive resynchronisation is an
    /// undetected divergence, and a divergence means autosaving a document
    /// nobody wrote.
    private func resynchroniseFromTextView(reason: String) {
        guard let buffer else { return }
        Log.core.error(
            "\(buffer.url.lastPathComponent, privacy: .public): the editor and its buffer diverged (\(reason, privacy: .public)); resynchronising from the text view"
        )
        var text = textView.string
        text.makeContiguousUTF8()
        buffer.replaceContents(text, origin: .typing)
        resynchronisations += 1
    }

    @objc private func visibleRegionChanged() {
        applyHighlight()
    }

    // MARK: - Highlighting

    /// Re-parse the buffer and recompute the block ranges.
    ///
    /// Off the main actor: the parse is ~2 ms/MB and the byte→UTF-16 walk is
    /// another pass over the text, and neither belongs between a keystroke and
    /// its glyph. The result is dropped if the text has moved on, which is what
    /// ``parseGeneration`` is for.
    public func scheduleHighlight(immediately: Bool = false) {
        guard immediately else {
            // A **throttle**, not a debounce, for the reason `Buffer` gives at
            // `schedulePreview`: a trailing debounce that restarts on every
            // keystroke never fires while someone types steadily, and the
            // editor's own highlighting would freeze for exactly as long as
            // they kept going.
            guard highlightWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.highlightWork = nil
                self?.scheduleHighlight(immediately: true)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.highlightDebounce, execute: work)
            return
        }
        highlightWork?.cancel()
        highlightWork = nil

        guard let buffer else { return }
        // One parse at a time. The parse costs tens of milliseconds on a 1 MB
        // document, and stacking them behind a throttle that fires every 80 ms
        // would spend the machine on work whose result is thrown away by the
        // generation check anyway.
        guard !isParsing else {
            parseAgainWhenIdle = true
            return
        }
        isParsing = true
        parseGeneration += 1
        let generation = parseGeneration
        let text = buffer.text
        _Concurrency.Task.detached(priority: .userInitiated) {
            let started = DispatchTime.now().uptimeNanoseconds
            guard let structure = try? MarkCore.structure(source: text) else {
                Log.render.error("the editor could not parse its buffer for highlighting")
                await MainActor.run { [weak self] in self?.isParsing = false }
                return
            }
            // Blocks arrive in document order, so the boundaries are already
            // ascending — which is what lets the conversion be one walk.
            var offsets: [Int] = []
            offsets.reserveCapacity(structure.blocks.count * 2)
            for block in structure.blocks {
                offsets.append(block.start)
                offsets.append(block.end)
            }
            let converted = SourceOffsets.utf16(of: offsets, in: text)
            var ranges: [(range: NSRange, kind: String, level: Int?)] = []
            ranges.reserveCapacity(structure.blocks.count)
            for (index, block) in structure.blocks.enumerated() {
                let start = converted[index * 2]
                let end = converted[index * 2 + 1]
                guard end > start else { continue }
                ranges.append(
                    (NSRange(location: start, length: end - start), block.kind, block.level))
            }
            let seconds =
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isParsing = false
                defer {
                    if self.parseAgainWhenIdle {
                        self.parseAgainWhenIdle = false
                        self.scheduleHighlight()
                    }
                }
                guard generation == self.parseGeneration else { return }
                self.highlightRanges = ranges
                self.lastHighlightSeconds = seconds
                self.highlightPasses += 1
                Log.stage(
                    "editor parse", seconds,
                    detail: "blocks=\(ranges.count) bytes=\(text.utf8.count)")
                self.applyHighlight()
            }
        }
    }

    /// Paint the blocks that intersect the visible rectangle, and only those.
    ///
    /// The bound on the work is the viewport, not the document, which is what
    /// keeps a 1 MB file typeable. Blocks off screen are painted when they
    /// scroll into view.
    private func applyHighlight() {
        guard let storage = textView.textStorage, !highlightRanges.isEmpty else { return }
        let length = storage.length
        guard length > 0 else { return }

        let visible = visibleCharacterRange(padding: 2_000, length: length)
        guard visible.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes, range: visible)
        for entry in highlightRanges {
            guard NSIntersectionRange(entry.range, visible).length > 0 else { continue }
            guard entry.range.location + entry.range.length <= length else { continue }
            let clipped = NSIntersectionRange(entry.range, visible)
            storage.addAttributes(Self.attributes(for: entry.kind, level: entry.level), range: clipped)
        }
        storage.endEditing()
    }

    /// The character range on screen, plus a margin so a small scroll does not
    /// reveal unpainted text before the next pass.
    private func visibleCharacterRange(padding: CGFloat, length: Int) -> NSRange {
        guard let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else {
            return NSRange(location: 0, length: min(length, 20_000))
        }
        var rect = scrollView.documentVisibleRect.insetBy(dx: 0, dy: -padding)
        rect.origin.y = max(0, rect.origin.y)
        guard
            let start = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: rect.minY))?
                .rangeInElement.location,
            let end = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: rect.maxY))?
                .rangeInElement.endLocation
        else {
            return NSRange(location: 0, length: min(length, 20_000))
        }
        let location = contentManager.offset(from: contentManager.documentRange.location, to: start)
        let endOffset = contentManager.offset(from: contentManager.documentRange.location, to: end)
        let clampedLocation = min(max(0, location), length)
        let clampedEnd = min(max(clampedLocation, endOffset), length)
        return NSRange(location: clampedLocation, length: clampedEnd - clampedLocation)
    }

    private var currentScroll: CGFloat { scrollView.contentView.bounds.origin.y }

    private func scroll(to y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Appearance

    /// The editor's palette comes from the same theme the preview uses, so the
    /// two panes do not look like two applications. Resolved dynamically, so an
    /// appearance change re-colours with no code running — the property ADR-7's
    /// theming rests on.
    private func applyThemeColours() {
        let theme = ThemeController.shared
        textView.backgroundColor = theme.backgroundColor
        textView.textColor = theme.editorColor(of: "foreground", fallback: .textColor)
        textView.insertionPointColor = theme.editorColor(of: "accent", fallback: .textColor)
        textView.selectedTextAttributes = [
            .backgroundColor: theme.editorColor(of: "selection", fallback: .selectedTextBackgroundColor)
        ]
        scrollView.backgroundColor = theme.backgroundColor
        needsDisplay = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColours()
    }

    /// Called when the *theme* changes, as opposed to the appearance.
    public func themeChanged() {
        applyThemeColours()
        // Attributes carry resolved colours, so they are repainted rather than
        // re-derived.
        applyHighlight()
    }

    // MARK: - Type

    static let bodyFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let boldFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: ThemeController.shared.editorColor(
                of: "foreground", fallback: .textColor),
        ]
    }

    /// Block kind → how its *source* is drawn.
    ///
    /// Deliberately block-level only. ADR-6 says the highlighting is *"driven
    /// by the core's existing block byte ranges, not by a second parser"*, and
    /// inline emphasis is not in those ranges — colouring `**bold**` inside a
    /// paragraph would mean writing the inline scanner the ADR rules out.
    private static func attributes(for kind: String, level: Int?)
        -> [NSAttributedString.Key: Any]
    {
        let theme = ThemeController.shared
        switch kind {
        case "heading":
            let size = max(13.0, 19.0 - Double(level ?? 1) * 1.5)
            return [
                .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
                .foregroundColor: theme.editorColor(of: "heading", fallback: .textColor),
            ]
        case "code-block":
            return [
                .font: bodyFont,
                .foregroundColor: theme.editorColor(of: "success", fallback: .textColor),
                .backgroundColor: theme.editorColor(of: "surface", fallback: .clear),
            ]
        case "block-quote":
            return [
                .font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask),
                .foregroundColor: theme.editorColor(of: "muted", fallback: .secondaryLabelColor),
            ]
        case "list":
            return [
                .font: bodyFont,
                .foregroundColor: theme.editorColor(of: "foreground", fallback: .textColor),
            ]
        case "table":
            return [
                .font: bodyFont,
                .foregroundColor: theme.editorColor(of: "accent", fallback: .textColor),
            ]
        case "thematic-break", "html":
            return [
                .font: bodyFont,
                .foregroundColor: theme.editorColor(of: "muted", fallback: .secondaryLabelColor),
            ]
        default:
            return [
                .font: bodyFont,
                .foregroundColor: theme.editorColor(of: "foreground", fallback: .textColor),
            ]
        }
    }
}

extension ThemeController {
    /// A chrome colour that follows the system appearance by itself, for
    /// AppKit views that cannot use the page's CSS custom properties.
    ///
    /// The same mechanism as ``backgroundColor``: `NSColor(name:dynamicProvider:)`
    /// is re-evaluated by AppKit on an appearance change, so the editor tracks
    /// light/dark with no code running, exactly as the document does.
    public func editorColor(of key: String, fallback: NSColor) -> NSColor {
        let light = active.light.color(of: key)
        let dark = active.dark.color(of: key)
        guard light != nil || dark != nil else { return fallback }
        return NSColor(name: nil) { appearance in
            (appearance.isDark ? dark : light) ?? fallback
        }
    }
}
