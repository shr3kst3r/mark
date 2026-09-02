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

    /// The inverse: the UTF-8 byte offset of a UTF-16 offset.
    ///
    /// One offset rather than a sorted run, because there is only ever one —
    /// the editor has one viewport top, and it is reported at most once per
    /// throttle window. That is why this walks from the start each time instead
    /// of carrying a cursor: the run-of-offsets shape above exists to make 60
    /// visible blocks affordable at typing cadence, and there is nothing here
    /// to amortise.
    ///
    /// An offset landing inside a surrogate pair rounds **down** to the scalar
    /// that contains it. A byte offset that split a character would be one the
    /// core could not use, and the character the reader is looking at is the
    /// one that starts before the viewport edge, not the one after it.
    static func byte(ofUTF16 utf16Offset: Int, in text: String) -> Int {
        let utf8Length = text.utf8.count
        let utf16Length = text.utf16.count
        let target = min(max(0, utf16Offset), utf16Length)
        // The same fast path, and the same common case: an all-ASCII document
        // is the same numbers in both systems.
        if utf8Length == utf16Length { return target }

        var byteCursor = 0
        var utf16Cursor = 0
        for scalar in text.unicodeScalars {
            let width = UTF16.width(scalar)
            if utf16Cursor + width > target { break }
            byteCursor += UTF8.width(scalar)
            utf16Cursor += width
        }
        return min(byteCursor, utf8Length)
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

    /// The change gutter. Owned by the scroll view, so it scrolls with the text
    /// without an observer keeping it aligned.
    let ruler: ChangeRuler

    /// The whitespace marks, drawn over the text. A subview of the text view,
    /// so it scrolls with the document for the same reason the ruler does.
    ///
    /// Not `private`: `InvisiblesTests` draws it into a bitmap, which is the
    /// only way to assert on a draw that needs a laid-out text container and
    /// has no window to be laid out in.
    let invisibles: InvisiblesOverlay

    /// `HEAD`'s bytes for the bound buffer's file, and the oid they came from.
    ///
    /// Cached because the read costs ~7 ms and cannot change while the oid does
    /// not — and this is recomputed at typing cadence, so paying it per keystroke
    /// would be the one thing a change gutter must not do.
    private var gutterBase: (path: String, head: String?, text: String)?

    /// Bumped whenever the buffer is rebound, so a base read for the previous
    /// document is dropped rather than diffed against this one.
    private var gutterGeneration = 0

    public private(set) var buffer: Buffer?

    /// Per-buffer undo, so ⌘Z never crosses a document boundary. Keyed by the
    /// buffer's identity, dropped when the tab closes.
    private var undoManagers: [ObjectIdentifier: UndoManager] = [:]

    /// Editor scroll position and selection per buffer, restored on rebind so
    /// switching tabs and coming back does not put the caret at the top.
    private var places: [ObjectIdentifier: (selection: NSRange, scroll: CGFloat)] = [:]

    /// Called with the source position at the top of this pane's viewport — a
    /// UTF-8 byte offset — each time the **reader** moves the pane.
    ///
    /// The mirror of ``DocumentView/onSourceTop``, and deliberately the same
    /// name: both mean "the top of my viewport, in the core's coordinates", and
    /// the sync is those two callbacks pointed at each other.
    ///
    /// "The reader" is the whole of it. A pane that reported every scroll would
    /// report the ones it made itself following the preview, and the two panes
    /// would chase each other for as long as the rounding kept changing the
    /// answer. See ``isMovingItself``.
    public var onSourceTop: ((Int) -> Void)?

    /// Set while the pane is scrolling itself for a reason that is not the
    /// reader: following the preview, or restoring a remembered place on
    /// rebind. Nothing is reported out of it.
    ///
    /// A flag rather than a comparison against the last position, because the
    /// two are not distinguishable after the fact — the pane ends up at the
    /// same coordinate whether the reader put it there or the preview did, and
    /// only the code that moved it knows which.
    private var isMovingItself = false

    /// Where the pane last put *itself*, or `nil` if it never has.
    ///
    /// The flag above covers the moment of the move, and it is not enough: the
    /// bounds change that arrives while a scroll is being made is only the
    /// first of them. The ones that follow are the settling — TextKit laying
    /// out what the move exposed, the highlight pass writing attributes into
    /// it, the text view resizing under both — and they arrive turns of the run
    /// loop later, long after any synchronous flag has been cleared.
    ///
    /// So the rule for those is positional: a bounds change that leaves the
    /// pane at the coordinate the pane itself chose is the document settling
    /// under a still viewport, and the reader has not gone anywhere. It is a
    /// coordinate and not a byte offset on purpose — the byte at the top *does*
    /// move when text above it reflows, and that is exactly the case this must
    /// stay quiet about.
    private var selfPositioned: CGFloat?

    /// How often, at most, the pane tells the preview where it is.
    ///
    /// The page's own number, from `reportScroll` in `shell.js`, and the same
    /// on purpose: each direction of the sync costs one process hop per report,
    /// and a pane reporting per frame would put 120 of them a second between
    /// the reader's trackpad and a `WKWebView` trying to keep up. Trailing
    /// edge, so a fling reports where it *ended* rather than where it passed.
    public static let sourceReportThrottle: TimeInterval = 0.120
    private var sourceReport: DispatchWorkItem?

    /// The last offset handed to ``onSourceTop``, so a scroll that does not
    /// change which byte is at the top costs nothing. Reset to "none" on
    /// rebind, where the same number means a different document.
    private var lastReportedSourceByte: Int?

    /// The most recent parse of the buffer, in UTF-16 coordinates. Recomputed
    /// off the main actor and applied to the visible range only.
    ///
    /// Assigning it drops ``highlightedRange``, because a new parse is exactly
    /// the event that makes the attributes already in the storage wrong.
    private var highlightRanges: [(range: NSRange, kind: String, level: Int?)] = [] {
        didSet { highlightedRange = NSRange(location: 0, length: 0) }
    }

    /// The span of the text storage already carrying ``highlightRanges``.
    ///
    /// The whole reason ``applyHighlight()`` can run on every scroll frame
    /// without re-laying out the document each time; see the comment there.
    private var highlightedRange = NSRange(location: 0, length: 0)

    /// Set while ``applyHighlight()`` is writing attributes, so the bounds
    /// change its own relayout provokes does not re-enter it.
    private var isHighlighting = false

    /// How far past the viewport, in points, the highlight reaches, so a small
    /// scroll does not reveal unpainted text before the next pass.
    private static let highlightPadding: CGFloat = 2_000

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

    /// How many times ``applyHighlight()`` has actually written attributes
    /// into the text storage — as opposed to being called and finding the
    /// screen already painted.
    ///
    /// Separate from ``highlightPasses``, which counts *parses*. This counts
    /// **layout invalidations**, and it is the number the scroll behaviour
    /// lives or dies by: every one of these re-lays out text and can resize
    /// the document view under the reader, and this used to tick once or twice
    /// per frame of every scroll.
    public private(set) var highlightWrites = 0

    /// What the last keystroke cost the main thread, in seconds: the splice
    /// into the buffer and the bookkeeping around it, but not the parse, which
    /// is not on this thread.
    public private(set) var lastKeystrokeSeconds: Double = 0

    /// The two halves of it: reading the edited characters out of the storage,
    /// and splicing them into the buffer. Split because they have failed
    /// differently and would again — see the comments at each.
    public private(set) var lastSubstringSeconds: Double = 0
    public private(set) var lastSpliceSeconds: Double = 0

    /// One line under the text: words, characters, lines, reading time.
    let statusBar = NSTextField(labelWithString: "")

    /// The count in flight, cancelled when another edit arrives.
    ///
    /// Counting parses the document, and this runs after every keystroke — so
    /// it is debounced and off the main actor, the same shape the search box
    /// uses. A status line is never worth a dropped frame.
    private var countTask: _Concurrency.Task<Void, Never>?

    /// How long the status bar waits after a keystroke before recounting.
    ///
    /// Longer than a frame and shorter than the autosave, so a burst of typing
    /// is one parse and the number is never visibly stale once you stop.
    static let countDebounce: Duration = .milliseconds(300)

    /// How many times the buffer and the text view had to be resynchronised.
    ///
    /// Expected to be zero forever. Counted rather than merely logged because
    /// it is the one number that says "the two copies of the document drifted
    /// apart", and a `mark-bench` run asserts on it.
    public private(set) var resynchronisations = 0

    public override init(frame: NSRect) {
        textView = NSTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView(frame: frame)
        ruler = ChangeRuler(scrollView: scrollView)
        invisibles = InvisiblesOverlay(textView: textView)
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
        // The ruler after `documentView`, because it takes its client view from
        // it.
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        // Off until there is something to draw: an empty 8-point strip beside
        // every clean document is chrome that says nothing.
        scrollView.rulersVisible = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // The status bar. Below the text rather than above it, and one line
        // tall, because it is a fact about the document rather than a control:
        // it should be findable and never in the way.
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.alignment = .right
        statusBar.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        statusBar.textColor = .secondaryLabelColor
        statusBar.lineBreakMode = .byTruncatingTail
        statusBar.isSelectable = false
        addSubview(statusBar)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
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
        // Over the glyphs, and inside the text view so it scrolls with them.
        // The overlay is repainted explicitly rather than left to AppKit: see
        // ``visibleRegionChanged()`` for why its own backing layer makes that
        // necessary.
        textView.addSubview(invisibles)
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(invisiblesSettingChanged),
            name: Invisibles.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(zoomChanged),
            name: TextZoom.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lineNumbersSettingChanged),
            name: LineNumbers.didChangeNotification,
            object: nil
        )
        ruler.showsLineNumbers = LineNumbers.isShowing
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
            places[ObjectIdentifier(current)] = (textView.selectedRange(), scrollOffset)
        }
        self.buffer = buffer
        parseGeneration += 1
        gutterGeneration += 1
        guard let buffer else {
            replaceText(with: "")
            textView.isEditable = false
            highlightRanges = []
            showGutter(nil)
            countTask?.cancel()
            statusBar.stringValue = ""
            return
        }
        // A different document: the same byte offset means something else now,
        // and everything below — the text going in, the clip view landing back
        // at the top, the remembered place being restored over it — is this
        // pane remembering rather than the reader going anywhere. Set before
        // the text, because replacing it moves the clip view too.
        lastReportedSourceByte = nil
        sourceReport?.cancel()
        sourceReport = nil
        isMovingItself = true
        defer { isMovingItself = false }
        textView.isEditable = true
        replaceText(with: buffer.text)
        // Immediately, not debounced: an empty status bar for 300 ms after
        // opening a document reads as broken rather than as busy.
        updateWordCountNow()
        if let place = places[ObjectIdentifier(buffer)] {
            let length = (textView.string as NSString).length
            let selection = NSRange(
                location: min(place.selection.location, length),
                length: min(place.selection.length, max(0, length - place.selection.location))
            )
            textView.setSelectedRange(selection)
            scroll(to: place.scroll)
        }
        // Whether a place was restored or the new document simply starts at the
        // top, this is where the pane has put itself — and everything the
        // rebind is about to provoke happens at that coordinate.
        selfPositioned = scrollOffset
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
        updateWordCountNow()
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
        // Every attribute in the storage has just been flattened back to the
        // body font, so nothing is painted any more.
        highlightedRange = NSRange(location: 0, length: 0)
        invisibles.needsDisplay = true
    }

    // MARK: - NSTextViewDelegate

    /// The one key this pane takes from `NSTextView`.
    ///
    /// `doCommandBy` rather than `keyDown`, because it is the hook that runs
    /// *after* input methods and key bindings have had their say — so ⏎ while a
    /// candidate window is up still commits the candidate, and a reader who has
    /// rebound Return keeps their binding. Returning `false` for everything
    /// else is what keeps the rest of `2026-08-25-flock-write-locking`'s
    /// "inherit the system's editing" intact.
    public func textView(
        _ view: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        return handleNewline()
    }

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
        // Debounced and off the main actor, so a status line never costs a
        // frame at typing cadence.
        scheduleWordCount()
        // Not on the throttle: a space you have just typed must get its dot on
        // the same frame as its cell, or the marks lag the caret. One
        // viewport-bounded draw is affordable at typing cadence; the parse the
        // throttle protects is not.
        invisibles.needsDisplay = true
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
        reportSourceTopSoon()
        // The marks are a *layer* over the glyphs, and that is literal: the
        // text view and the overlay each have their own backing layer —
        // checked, both `layer` are non-nil the first time the overlay draws.
        // So the text view repainting itself does not invalidate the
        // overlay's, and the previous frame's marks stay composited over text
        // that has since moved. That is the stippled band in the report: dots
        // standing where the lines used to be. Repainting here means that
        // whatever moved, the marks are redrawn from the geometry they are
        // actually over. It costs one viewport-bounded draw — 1.2 ms for a
        // pathological screenful, see ``InvisiblesOverlay/lastDrawSeconds`` —
        // against a frame that no longer spends anything re-laying out the
        // document.
        invisibles.needsDisplay = true
    }

    /// The text view resized: TextKit replaced an estimated height with a real
    /// one, or the pane changed width and the text rewrapped. Either way every
    /// mark below the change is somewhere else now.
    @objc private func textViewFrameChanged() {
        invisibles.needsDisplay = true
    }

    /// The app-wide switch moved. Every open editor gets this, which is the
    /// point of it being a notification.
    @objc private func invisiblesSettingChanged() {
        invisibles.needsDisplay = true
    }

    // MARK: - Markdown editing

    /// The text view's whole content and the current selection, as `String`
    /// and `String.Index` — which is what ``MarkdownEditing`` speaks, and what
    /// keeps every offset here away from `NSRange`'s UTF-16 units.
    private func currentSelection() -> (text: String, range: Range<String.Index>)? {
        let text = textView.string
        let nsRange = textView.selectedRange()
        guard let range = Range(nsRange, in: text) else { return nil }
        return (text, range)
    }

    /// Replace the whole buffer through the undo manager and restore a
    /// selection.
    ///
    /// `shouldChangeText` / `didChangeText` around the edit is what makes ⌘Z
    /// undo it as one step and what tells the highlighter and the autosave
    /// something moved. Skipping either is how an edit becomes invisible to the
    /// rest of the pane.
    private func apply(text: String, selection: Range<String.Index>) {
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: whole, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: whole, with: text)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(selection, in: text))
    }

    /// Recount the document and put the answer under it.
    ///
    /// Debounced and off the main actor: counting parses, and this is on the
    /// keystroke path.
    func scheduleWordCount() {
        countTask?.cancel()
        let source = textView.string
        countTask = _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(for: Self.countDebounce)
            guard !_Concurrency.Task.isCancelled, let self else { return }
            let counts = await _Concurrency.Task.detached(priority: .utility) {
                () -> WordCount? in
                try? MarkCore.wordCount(source: source)
            }.value
            guard !_Concurrency.Task.isCancelled else { return }
            self.statusBar.stringValue = counts?.summary ?? ""
        }
    }

    /// The same, immediately — for binding a document, where there is nothing
    /// to debounce and an empty bar for 300 ms reads as broken.
    func updateWordCountNow() {
        countTask?.cancel()
        let source = textView.string
        statusBar.stringValue = (try? MarkCore.wordCount(source: source))?.summary ?? ""
    }

    /// Whether the margin draws line numbers beside the change bars.
    public var showsLineNumbers: Bool {
        get { ruler.showsLineNumbers }
        set { ruler.showsLineNumbers = newValue }
    }

    /// Put the caret on `line` (1-based) and scroll it into view.
    ///
    /// Returns `false` for a line the document does not have, so the caller can
    /// say so rather than silently landing on the last one — which is what
    /// every "go to line" that clamps does, and it is indistinguishable from
    /// the document being shorter than you thought.
    @discardableResult
    public func goToLine(_ line: Int) -> Bool {
        guard line >= 1 else { return false }
        let text = textView.string
        var index = text.startIndex
        var remaining = line - 1
        while remaining > 0 {
            guard let newline = text[index...].firstIndex(of: "\n") else { return false }
            index = text.index(after: newline)
            remaining -= 1
            // A trailing newline makes an empty last line, which is a line the
            // reader can put a caret on.
            if index == text.endIndex && remaining > 0 { return false }
        }
        let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
        let range = NSRange(index..<lineEnd, in: text)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(textView)
        return true
    }

    /// How many lines the document has, for the Go to Line prompt.
    public var lineCount: Int {
        let text = textView.string
        if text.isEmpty { return 1 }
        return text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// Bold, italic, and inline code: wrap the selection, or unwrap it.
    public func wrapSelection(with marker: String) {
        guard let (text, range) = currentSelection() else { return }
        let result = MarkdownEditing.toggleWrap(text, range: range, marker: marker)
        apply(text: result.text, selection: result.selection)
    }

    /// ⌘K. A URL already on the pasteboard goes straight into the parentheses,
    /// which is the case this is most often reached for — copy a link, select
    /// the words, press ⌘K.
    public func makeLink() {
        guard let (text, range) = currentSelection() else { return }
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        let url = looksLikeURL(pasted) ? pasted : ""
        let result = MarkdownEditing.makeLink(text, range: range, url: url)
        apply(text: result.text, selection: result.selection)
    }

    private func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("\n") else {
            return false
        }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("mailto:")
    }

    /// Set the heading level of every line the selection touches. 0 clears it.
    public func setHeading(level: Int) {
        guard let (text, range) = currentSelection() else { return }
        // `lineRange(for:)` includes the trailing newline. Splitting on it with
        // the empty tail kept would hand `setHeading` an empty final line and
        // put a `###` on it — which then merges with the line *below* the
        // selection. So the newline is taken off first and put back after.
        var lineRange = text.lineRange(for: range)
        if text[lineRange].hasSuffix("\n") {
            lineRange = lineRange.lowerBound..<text.index(before: lineRange.upperBound)
        }

        let rewritten =
            text[lineRange]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { MarkdownEditing.setHeading(String($0), level: level) }
            .joined(separator: "\n")

        var out = text
        out.replaceSubrange(lineRange, with: rewritten)
        let end = out.index(lineRange.lowerBound, offsetBy: rewritten.count)
        apply(text: out, selection: lineRange.lowerBound..<end)
    }

    /// ⏎, with the list the caret is in continued.
    ///
    /// Returns `false` when there is nothing markdown-specific to do, so the
    /// caller hands the key back to `NSTextView` — which is the whole shape of
    /// this feature: inherit everything, override the one case.
    func handleNewline() -> Bool {
        guard let (text, range) = currentSelection(), range.isEmpty else { return false }
        let lineRange = text.lineRange(for: range)
        // `lineRange(for:)` includes the newline; the prefix parser wants the
        // line's own characters.
        var line = String(text[lineRange])
        if line.hasSuffix("\n") { line.removeLast() }

        guard let action = MarkdownEditing.newlineAction(forLine: line) else { return false }
        switch action {
        case .insert(let inserted):
            let nsRange = NSRange(range, in: text)
            guard textView.shouldChangeText(in: nsRange, replacementString: inserted) else {
                return true
            }
            textView.textStorage?.replaceCharacters(in: nsRange, with: inserted)
            textView.didChangeText()

        case .clearLine(let replacement):
            // The list is over. The marker goes, and the newline still
            // happens, so ⏎⏎ ends a list the way it does everywhere else.
            var lineOnly = lineRange
            if text[lineOnly].hasSuffix("\n") {
                lineOnly = lineOnly.lowerBound..<text.index(before: lineOnly.upperBound)
            }
            let nsRange = NSRange(lineOnly, in: text)
            let inserted = replacement + "\n"
            guard textView.shouldChangeText(in: nsRange, replacementString: inserted) else {
                return true
            }
            textView.textStorage?.replaceCharacters(in: nsRange, with: inserted)
            textView.didChangeText()
        }
        return true
    }

    /// The app-wide switch moved. Every open editor gets this.
    @objc private func lineNumbersSettingChanged() {
        ruler.showsLineNumbers = LineNumbers.isShowing
    }

    /// ⌘+ / ⌘− / ⌘0, from any window.
    ///
    /// A full repaint rather than an incremental one, for the reason
    /// ``themeChanged()`` gives: every attribute dictionary already applied
    /// carries the old size, so there is no such thing as a partial pass here.
    /// The whitespace marks are invalidated with it — they are drawn in points
    /// against the text's own metrics, so a dot sized for 13pt text is in the
    /// wrong place on 16pt text.
    @objc private func zoomChanged() {
        textView.font = Self.bodyFont
        highlightedRange = NSRange(location: 0, length: 0)
        applyHighlight()
        invisibles.needsDisplay = true
    }

    /// Whether this pane is drawing whitespace marks, and how many the last
    /// draw put on screen — for the tests and for `mark-bench`, which has the
    /// window a pixel assertion needs.
    public var invisibleMarksDrawn: Int { invisibles.lastDrawnCount }

    /// What the last whitespace-mark draw cost, in seconds. On the typing path,
    /// so `mark-bench` can see it alongside ``lastKeystrokeSeconds``.
    public var lastInvisiblesDrawSeconds: Double { invisibles.lastDrawSeconds }

    // MARK: - Highlighting

    /// Re-parse the buffer and recompute the block ranges.
    ///
    /// Off the main actor: the parse is ~2 ms/MB and the byte→UTF-16 walk is
    /// another pass over the text, and neither belongs between a keystroke and
    /// its glyph. The result is dropped if the text has moved on, which is what
    /// ``parseGeneration`` is for.
    // MARK: - The change gutter

    /// Recompute the margin's bars against git `HEAD`.
    ///
    /// Two hops off the main actor, and neither is on the keystroke path: the
    /// base read forks `git` (~7 ms, and cached against the oid), and the line
    /// diff is a parse of two documents.
    private func refreshGutter() {
        guard let buffer else {
            showGutter(nil)
            return
        }
        let path = buffer.url.path
        let text = buffer.text
        gutterGeneration += 1
        let generation = gutterGeneration

        if let cached = gutterBase, cached.path == path {
            diffGutter(base: cached.text, text: text, generation: generation)
            return
        }

        _Concurrency.Task.detached(priority: .utility) {
            let base = try? MarkCore.git(base: path)
            await MainActor.run { [weak self] in
                guard let self, generation == self.gutterGeneration else { return }
                guard let base, base.repo != nil else {
                    // Not in a repository, or git could not answer. No bars, no
                    // explanation — the ADR's degradation policy.
                    self.gutterBase = nil
                    self.showGutter(nil)
                    return
                }
                self.gutterBase = (path: path, head: base.head, text: base.base ?? "")
                self.diffGutter(base: base.base ?? "", text: text, generation: generation)
            }
        }
    }

    private func diffGutter(base: String, text: String, generation: Int) {
        _Concurrency.Task.detached(priority: .utility) {
            let diff = try? MarkCore.lineDiff(old: base, new: text)
            await MainActor.run { [weak self] in
                guard let self, generation == self.gutterGeneration else { return }
                self.showGutter(diff)
            }
        }
    }

    private func showGutter(_ diff: LineDiff?) {
        ruler.show(diff)
        // The strip appears and disappears with the bars, so a clean document
        // looks exactly as it did before this feature existed.
        scrollView.rulersVisible = !ruler.isEmpty
    }

    /// What the gutter is currently showing, for the tests and for `mark-bench`.
    public var gutterDiff: LineDiff? { ruler.diff }

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
        // Rides the same throttle as the source highlighting rather than having
        // its own: both are "the buffer settled, recompute what is derived from
        // it", and two independent timers over one buffer is how a keystroke
        // ends up paying for two parses.
        refreshGutter()
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

    /// Paint the blocks that intersect the visible rectangle, and only those —
    /// and only the ones that are not painted already.
    ///
    /// The bound on the work is the viewport, not the document, which is what
    /// keeps a 1 MB file typeable. Blocks off screen are painted when they
    /// scroll into view.
    ///
    /// # Why ``highlightedRange`` exists
    ///
    /// This runs on every clip-view bounds change, which is **every frame of
    /// every scroll**. Without the coverage check it re-ran the whole
    /// wipe-and-repaint each time, and the attributes it writes are not
    /// cosmetic: a heading is 19-point where the body is 13, and a code block
    /// carries a background. An attribute edit with different metrics
    /// invalidates layout, TextKit re-lays out, and `NSTextView` — which is
    /// `isVerticallyResizable` — resizes itself to the new
    /// `usageBoundsForTextContainer`. Resizing the document view changes the
    /// clip view's bounds, which posts the notification that started this.
    ///
    /// Measured on the 7.9 KB document the bug was reported against: one
    /// `goto` produced two passes 7 ms apart and the document view's height
    /// walked 4083 → 4040 → 4024 → 4004 → 3907 points across them, at one
    /// point standing 153 points taller than the text it contained — the blank
    /// band below the last line in the report, with the whitespace marks left
    /// stranded in it. The reader sees the document shift under the pointer
    /// and the scroll stutter, because every frame of it is spent re-laying
    /// out text that was already correct.
    ///
    /// So the span already carrying this parse's attributes is remembered, and
    /// a scroll inside it does no storage edit at all. Only the newly exposed
    /// slice is painted, which is the work the moving viewport actually
    /// created. The span is cleared — and the next pass repaints in full —
    /// whenever the attributes themselves stop being valid: a new parse, a
    /// theme change, or a wholesale replacement of the text.
    private func applyHighlight() {
        // Painting is what posts the bounds change that lands back here. The
        // coverage check below already makes that re-entry a no-op, but not
        // until it has re-read the layout mid-edit; this stops it at the door.
        guard !isHighlighting else { return }
        guard let storage = textView.textStorage, !highlightRanges.isEmpty else { return }
        let length = storage.length
        guard length > 0 else { return }
        // An edit can have shortened the storage since the last pass, so what
        // was painted is only what is still there.
        highlightedRange = NSIntersectionRange(
            highlightedRange, NSRange(location: 0, length: length))

        let visible = visibleCharacterRange(padding: Self.highlightPadding, length: length)
        guard visible.length > 0 else { return }
        // The common case while scrolling: everything on screen is painted, so
        // there is nothing to do and nothing to invalidate.
        let painted = highlightedRange
        if painted.length > 0, NSIntersectionRange(visible, painted) == visible { return }

        // Whether the two spans can be merged into one. Abutting counts:
        // scrolling by a line leaves a gap that ends exactly where the painted
        // span begins, and treating that as disjoint would throw the span away
        // once a frame.
        let adjoins =
            painted.length > 0 && visible.location <= NSMaxRange(painted)
            && painted.location <= NSMaxRange(visible)

        // The gaps only. Two of them at most: the viewport can move off either
        // end of what is painted, and a jump lands clear of it entirely.
        var gaps: [NSRange] = []
        if !adjoins {
            gaps = [visible]
        } else {
            if visible.location < painted.location {
                gaps.append(
                    NSRange(location: visible.location, length: painted.location - visible.location))
            }
            if NSMaxRange(visible) > NSMaxRange(painted) {
                gaps.append(
                    NSRange(
                        location: NSMaxRange(painted),
                        length: NSMaxRange(visible) - NSMaxRange(painted)))
            }
        }

        highlightWrites += 1
        isHighlighting = true
        storage.beginEditing()
        for gap in gaps {
            storage.setAttributes(Self.baseAttributes, range: gap)
            for entry in highlightRanges {
                guard entry.range.location + entry.range.length <= length else { continue }
                let clipped = NSIntersectionRange(entry.range, gap)
                guard clipped.length > 0 else { continue }
                storage.addAttributes(
                    Self.attributes(for: entry.kind, level: entry.level), range: clipped)
            }
        }
        storage.endEditing()
        isHighlighting = false
        // Contiguous by construction: a gap always abuts the painted span, and
        // a viewport that landed clear of it replaces it outright.
        highlightedRange = adjoins ? NSUnionRange(visible, painted) : visible
        // The marks are positioned from the laid-out text, and this pass has
        // just changed a heading's font size and a code block's background.
        // Repainting them here covers scrolling and re-parsing in one place.
        invisibles.needsDisplay = true
    }

    /// The character range on screen, plus a margin so a small scroll does not
    /// reveal unpainted text before the next pass.
    ///
    /// **Both probes are clamped into the text that has been laid out**, and
    /// that clamp is load-bearing rather than defensive.
    /// `textLayoutFragment(for:)` answers `nil` for a point below the last line
    /// rather than answering "the end", and `padding` puts the lower probe
    /// 2,000 points below the viewport — so reading the last two screenfuls of
    /// *any* document missed, took the "cannot tell what is visible" branch,
    /// and attributed the first 20,000 characters instead.
    ///
    /// That is an attribute edit across most of the document, and an attribute
    /// edit invalidates layout. Measured on a 34 KB file with the editor
    /// following the preview to the end: `usageBoundsForTextContainer` fell
    /// from 19,669 points to 8,256 in the same pass. The text view sizes itself
    /// from those bounds, so it shrank to match — and the reader's document
    /// ended in the middle of itself, with blank space below the last line and
    /// no way to scroll to the rest. Clamping the probes is what keeps this
    /// pass reading the layout rather than destroying it.
    ///
    /// Not `private`: `EditorRoundTripTests` reads it directly, because the
    /// consequence — a shrinking text view — only appears once AppKit runs a
    /// viewport layout pass, and a test window is never on screen.
    func visibleCharacterRange(padding: CGFloat, length: Int) -> NSRange {
        guard let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else {
            return NSRange(location: 0, length: min(length, 20_000))
        }
        // Nothing laid out yet — the first pass after a bind. A bounded prefix
        // is the right guess at what a fresh viewport shows, and there is no
        // layout for a wide attribute edit to throw away.
        let laidOut = layoutManager.usageBoundsForTextContainer.maxY
        guard laidOut > 0 else {
            return NSRange(location: 0, length: min(length, 20_000))
        }
        var rect = scrollView.documentVisibleRect.insetBy(dx: 0, dy: -padding)
        rect.origin.y = max(0, rect.origin.y)
        let lastLine = laidOut - 1
        let topProbe = min(max(0, rect.minY), lastLine)
        let bottomProbe = min(max(topProbe, rect.maxY), lastLine)
        guard
            let start = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: topProbe))?
                .rangeInElement.location,
            let end = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: bottomProbe))?
                .rangeInElement.endLocation
        else {
            // Both probes are inside laid-out text, so this is not the
            // "scrolled past the end" case any more and there is nothing left
            // to guess at. Painting nothing costs one unhighlighted frame; the
            // 20,000-character guess costs the document's layout.
            return NSRange(location: 0, length: 0)
        }
        let location = contentManager.offset(from: contentManager.documentRange.location, to: start)
        let endOffset = contentManager.offset(from: contentManager.documentRange.location, to: end)
        let clampedLocation = min(max(0, location), length)
        let clampedEnd = min(max(clampedLocation, endOffset), length)
        return NSRange(location: clampedLocation, length: clampedEnd - clampedLocation)
    }

    // MARK: - Following the preview

    /// Put the source at UTF-8 byte offset `byte` at the top of the editor's
    /// viewport.
    ///
    /// The preview pushes this on every scroll report (`ShellMessage/scroll`)
    /// while the pane is bound to the document being scrolled, which is what
    /// makes the two panes show the same part of the same document while the
    /// reader scrolls the rendered one.
    ///
    /// **The byte offset is the whole mapping, and it is the page's, not
    /// ours.** The alternative — scroll the editor to the same *fraction* of
    /// its height — is a line of code and is wrong on every document that is
    /// not uniform prose: a Mermaid diagram is one line of source and half a
    /// screen of picture, a wrapped table is the reverse. The page reads the
    /// byte span off the block under its viewport top, and this converts that
    /// to a position in the text view. Both halves are the core's offsets, so
    /// neither pane is guessing.
    ///
    /// A no-op when the pane has no buffer, when the offset does not land in
    /// the text, or when the editor is already there — the last of which is the
    /// common case for a fling that ends inside one long block.
    public func follow(previewByte byte: Int) {
        guard let buffer, byte >= 0 else { return }
        // This pane is about to move because the preview moved. Reporting that
        // back would be the pane telling the preview what the preview just told
        // it — harmless on the first hop and an argument about rounding on the
        // next, so the report is suppressed and the position is recorded as
        // already sent.
        isMovingItself = true
        defer { isMovingItself = false }
        sourceReport?.cancel()
        sourceReport = nil
        lastReportedSourceByte = byte
        // Measure, move, measure again — up to three times, and stopping as
        // soon as the answer stops moving.
        //
        // One pass is not enough, and the reason is TextKit 2's laziness rather
        // than a mistake in the arithmetic: the height of everything above the
        // target is an *estimate* until it is laid out, so the position this
        // resolves is an estimate too, and scrolling there is what makes the
        // layout real — which moves the target, by a line or two per pass.
        // `shell.js` solves the identical problem identically, at
        // `restoreAnchor`: record where the anchor is, move, measure the delta,
        // correct.
        for _ in 0..<3 {
            guard let y = sourceY(ofByte: byte, in: buffer.text) else { return }
            // Not clamped to the height of the text, deliberately: that
            // height is an estimate for the same reason, and clamping to it
            // would stop the editor short of wherever the reader is going.
            // A byte offset that is in the document names a line that is in
            // the document, so the furthest this can go is the last screenful
            // — where the preview is showing its own bottom padding anyway.
            let target = max(0, y)
            guard abs(target - scrollOffset) > 0.5 else { return }
            scroll(to: target)
        }
    }

    /// Where the source byte offset `byte` sits in the laid-out text, in the
    /// text view's coordinates, or `nil` if TextKit cannot place it.
    ///
    /// `text` is the buffer's, not ``NSTextView/string``: the buffer holds a
    /// native, contiguous UTF-8 `String`, where the text view's is a bridged
    /// `NSString` whose UTF-8 view has to be materialised before it can be
    /// counted. The two are the same characters by construction — the length
    /// check in ``textStorage(_:didProcessEditing:range:changeInLength:)`` is
    /// what keeps them so.
    ///
    /// Resolving a location deep in a document TextKit 2 has not laid out yet
    /// makes it lay out that far, which is the one expensive thing here. It is
    /// the same work the reader's own scrolling would have caused, it is bounded
    /// by the page's 120 ms scroll report rather than by the frame rate, and the
    /// alternative is an editor that follows the preview only over the part of
    /// the document it has already seen.
    func sourceY(ofByte byte: Int, in text: String) -> CGFloat? {
        guard let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager,
            let index = SourceOffsets.utf16(of: [byte], in: text).first
        else { return nil }
        guard
            let location = contentManager.location(
                contentManager.documentRange.location, offsetBy: index)
        else { return nil }
        // TextKit 2 lays out lazily, and asking for a fragment it has not laid
        // out yet does not return nil — it returns a frame at the top of the
        // document, which would silently pin the editor to line 1 for every
        // part of the file the reader has not already visited. That is the
        // normal case here, so the layout is asked for rather than assumed.
        if let range = NSTextRange(location: contentManager.documentRange.location, end: location) {
            layoutManager.ensureLayout(for: range)
        }
        guard let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }

        var y = fragment.layoutFragmentFrame.minY
        // A paragraph is **one** layout fragment however many screen lines it
        // wraps to. Stopping at the fragment would hold the editor still for
        // the whole of a long paragraph and then move it a paragraph at a time,
        // which is exactly the stepping the interpolation on the page side
        // exists to avoid. The line fragments inside it are what make the
        // follow continuous.
        let fragmentStart = contentManager.offset(
            from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        let within = index - fragmentStart
        for line in fragment.textLineFragments {
            // Line fragments ascend, so the last one that starts at or before
            // the offset is the one holding it.
            guard within >= line.characterRange.location else { break }
            y = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
        }
        return y + textView.textContainerOrigin.y
    }

    // MARK: - Leading the preview

    /// The other direction: tell whoever is listening where this pane's
    /// viewport top is, in the source.
    ///
    /// Trailing-edge throttled, because the notification behind it fires on
    /// every frame of every scroll and the consumer is a process hop away. The
    /// window's is 120 ms — the page's own — so a fling reports four or five
    /// times on the way rather than a hundred, and always once at the end.
    private func reportSourceTopSoon() {
        guard onSourceTop != nil, !isMovingItself, sourceReport == nil else { return }
        // Still where the pane put itself: the document moved, the viewport did
        // not, and nobody needs telling. See ``selfPositioned``.
        if let placed = selfPositioned, abs(scrollOffset - placed) < 0.5 { return }
        let work = DispatchWorkItem { [weak self] in self?.reportSourceTop() }
        sourceReport = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sourceReportThrottle, execute: work)
    }

    /// Fire the pending report now rather than at the end of the throttle
    /// window, and say whether there was one to fire.
    ///
    /// The tests' seam, and it exists because of a limitation they have already
    /// documented twice: a test window is never on screen, so AppKit never runs
    /// the viewport layout pass that gives the text view its real height — and
    /// a scroll position set on a clip view over a document that does not yet
    /// know how tall it is is constrained back to zero on the next turn of the
    /// run loop. Waiting out 120 ms of real time therefore measures the
    /// harness rather than the pane.
    ///
    /// The return value carries the half that matters: `false` means no report
    /// was ever *scheduled*, which is what the suppression tests assert.
    @discardableResult
    func flushSourceReport() -> Bool {
        guard let work = sourceReport else { return false }
        work.cancel()
        sourceReport = nil
        reportSourceTop()
        return true
    }

    private func reportSourceTop() {
        sourceReport = nil
        guard !isMovingItself, let byte = sourceTopByte else { return }
        // Scrolling inside one long block — a code fence, a wrapped table —
        // resolves to the same byte for many frames, and the preview is already
        // there.
        guard byte != lastReportedSourceByte else { return }
        lastReportedSourceByte = byte
        // The reader has left wherever the pane parked it, so the parked
        // coordinate has nothing left to say. Kept any longer it would silence
        // a genuine scroll that happened to come back to the same pixel.
        selfPositioned = nil
        onSourceTop?(byte)
    }

    /// Where the top of this pane's viewport is in the source, as a UTF-8 byte
    /// offset, or `nil` if TextKit cannot say.
    ///
    /// The exact inverse of ``sourceY(ofByte:in:)``, down to the line fragment:
    /// that walks a byte offset out to a coordinate, this walks a coordinate
    /// back to a byte offset, and both stop at the *line* inside a paragraph
    /// rather than at the paragraph. A paragraph is one layout fragment however
    /// many screen lines it wraps to, so stopping at the fragment would report
    /// the same offset for a whole screenful of a long paragraph and then jump
    /// — the stepping the page avoids by interpolating through a block's span,
    /// avoided here by reading the line.
    ///
    /// `nil`, never zero, when it cannot be resolved. The page holds the same
    /// distinction at `blockStart`, and for the same reason: "I do not know"
    /// and "the top of the file" would otherwise be the same message, and the
    /// preview would be yanked to line 1 by every document that could not be
    /// mapped.
    public var sourceTopByte: Int? {
        guard let buffer,
            let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return nil }
        // Rubber-banding puts the clip view above the top of the document, and
        // a negative y resolves to no fragment at all.
        let y = max(0, scrollOffset - textView.textContainerOrigin.y)
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y))
        else { return nil }
        let fragmentStart = contentManager.offset(
            from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        var index = fragmentStart
        let within = y - fragment.layoutFragmentFrame.minY
        for line in fragment.textLineFragments {
            // Line fragments ascend, so the last one starting at or above the
            // viewport top is the one the reader is looking at.
            guard line.typographicBounds.minY <= within else { break }
            index = fragmentStart + line.characterRange.location
        }
        return SourceOffsets.byte(ofUTF16: index, in: buffer.text)
    }

    /// Where the pane is scrolled to, in the text view's coordinates.
    ///
    /// `public` for the same reason ``textView`` is: `mark-bench` asserts on it
    /// from outside the module, and the preview's own position is readable the
    /// same way at ``DocumentView/scrollOffset``.
    public var scrollOffset: CGFloat { scrollView.contentView.bounds.origin.y }

    private func scroll(to y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // The one place the pane moves itself, so the one place that has to
        // record it. Read back rather than assumed: the clip view constrains to
        // the document's height, so where it *went* and where it was *sent* are
        // not always the same number.
        selfPositioned = scrollOffset
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
        // The marks are drawn in the theme's `muted` and `warning` slots, so
        // they change with it rather than with the appearance alone.
        invisibles.needsDisplay = true
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
        // re-derived — and every one of them is now stale, which is what makes
        // this a full repaint rather than the incremental pass a scroll gets.
        highlightedRange = NSRange(location: 0, length: 0)
        applyHighlight()
    }

    // MARK: - Type

    /// The editor's natural type size, before ``TextZoom``.
    static let baseFontSize: Double = 13

    /// Computed rather than a constant, so ⌘+ reaches it. Every attribute
    /// dictionary below is rebuilt on a repaint, and a repaint is what
    /// ``zoomChanged()`` forces — so scaling here is enough to move all of
    /// them, including the per-level heading sizes.
    static var bodyFont: NSFont {
        .monospacedSystemFont(ofSize: TextZoom.scale * baseFontSize, weight: .regular)
    }

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
            // Scaled from the same base, so a level-3 heading keeps its
            // relationship to body text at every zoom level.
            let natural = max(baseFontSize, 19.0 - Double(level ?? 1) * 1.5)
            let size = natural * TextZoom.scale
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
