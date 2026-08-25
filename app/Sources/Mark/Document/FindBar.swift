import AppKit
import Foundation

/// Find-in-document, along the bottom of the preview.
///
/// A bar rather than the system find *panel*: a floating window that has to be
/// dismissed is the wrong shape for something you open, type three characters
/// into, and close, and `NSTextFinder`'s bar cannot be borrowed here because
/// its client protocol is written against `NSTextView` and the preview is a
/// `WKWebView`.
///
/// At the **bottom**, where Firefox and every terminal pager put it, rather
/// than at the top. It is the edge of the document nothing is anchored to: a
/// bar appearing under the tab bar pushes the text the reader is looking at
/// down by its own height at the exact moment they are trying to find
/// something in it.
///
/// Frame-based layout, like every other piece of chrome in this window: four
/// children in a row is two subtractions, and a constraint solver run on every
/// keystroke's `needsLayout` is a cost with nothing to show for it.
@MainActor
public final class FindBar: NSView {

    public static let barHeight: CGFloat = 30

    /// The search string changed. Fired per keystroke — the search itself is
    /// incremental, which is what every find bar on this platform does.
    public var onQueryChanged: ((String) -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onClose: (() -> Void)?

    public let searchField = NSSearchField()

    /// "3 of 12", "Not found", or nothing at all before the first search.
    public let statusLabel = NSTextField(labelWithString: "")

    private let steppers = NSSegmentedControl()
    private let doneButton = NSButton()

    public var query: String {
        get { searchField.stringValue }
        set {
            guard searchField.stringValue != newValue else { return }
            searchField.stringValue = newValue
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backed, like ``TabBarView``, and for the same reason: a bar
        // that paints its own background next to a `WKWebView` and is *not*
        // layer-backed gets its fill redrawn over its controls when the web
        // view repaints, and the bar ends up as an empty rectangle with a
        // focus ring in it.
        wantsLayer = true

        searchField.placeholderString = "Find in document"
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        // `controlTextDidChange` is the whole of it: setting `action` as well
        // would fire the search twice per keystroke, since
        // `sendsSearchStringImmediately` makes the field send both.
        searchField.delegate = self
        searchField.setAccessibilityLabel("Find in document")
        addSubview(searchField)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        steppers.segmentCount = 2
        steppers.segmentStyle = .separated
        steppers.trackingMode = .momentary
        steppers.controlSize = .small
        Self.configure(steppers, segment: 0, symbol: "chevron.up", fallback: "‹", label: "Previous match")
        Self.configure(steppers, segment: 1, symbol: "chevron.down", fallback: "›", label: "Next match")
        steppers.target = self
        steppers.action = #selector(stepperClicked)
        addSubview(steppers)

        doneButton.title = "Done"
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        addSubview(doneButton)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
        report(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FindBar is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    /// A hairline along the top, so the document above it does not look like it
    /// runs into the chrome.
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    public override func layout() {
        let inset: CGFloat = 8
        let gap: CGFloat = 6
        let height: CGFloat = 20
        let y = (bounds.height - height) / 2

        let doneWidth: CGFloat = 54
        let stepperWidth: CGFloat = 54
        // "128 of 1,024" fits; a document with more matches than that has
        // bigger problems than a truncated readout.
        let statusWidth: CGFloat = 96

        var right = bounds.width - inset
        doneButton.frame = NSRect(x: right - doneWidth, y: y, width: doneWidth, height: height)
        right -= doneWidth + gap
        steppers.frame = NSRect(x: right - stepperWidth, y: y, width: stepperWidth, height: height)
        right -= stepperWidth + gap
        let status = min(statusWidth, max(0, right - inset - 120))
        statusLabel.frame = NSRect(x: right - status, y: y, width: status, height: height)
        right -= status + gap
        searchField.frame = NSRect(x: inset, y: y, width: max(0, right - inset), height: height)
        super.layout()
    }

    // MARK: - State

    /// Say where the reader is in the matches.
    ///
    /// - Parameter result: `nil` before anything has been searched for, which
    ///   is not the same as a search that found nothing and must not read as
    ///   "Not found".
    public func report(_ result: FindResult?) {
        let text: String
        if let result {
            text = result.label ?? "Not found"
        } else {
            text = ""
        }
        statusLabel.stringValue = text
        statusLabel.textColor = (result?.total ?? 1) == 0 ? .systemRed : .secondaryLabelColor
        let enabled = (result?.total ?? 0) > 0
        steppers.setEnabled(enabled, forSegment: 0)
        steppers.setEnabled(enabled, forSegment: 1)
    }

    /// Put the caret in the field with the existing query selected, so typing
    /// replaces it and ⌘F twice does not mean "search for what I already
    /// searched for, twice".
    public func focus() {
        guard let window else { return }
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Whether the caret is in the search field right now.
    public var hasFocus: Bool {
        guard let window, let responder = window.firstResponder as? NSView else { return false }
        return responder === searchField || responder.isDescendant(of: searchField)
    }

    // MARK: - Actions

    @objc private func stepperClicked() {
        if steppers.selectedSegment == 0 { onPrevious?() } else { onNext?() }
    }

    @objc private func doneClicked() {
        onClose?()
    }

    private static func configure(
        _ control: NSSegmentedControl, segment: Int, symbol: String, fallback: String, label: String
    ) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            control.setImage(image, forSegment: segment)
        } else {
            control.setLabel(fallback, forSegment: segment)
        }
        control.setWidth(0, forSegment: segment)
        control.setToolTip(label, forSegment: segment)
    }
}

// MARK: - NSSearchFieldDelegate

extension FindBar: NSSearchFieldDelegate {

    public func controlTextDidChange(_ notification: Notification) {
        onQueryChanged?(searchField.stringValue)
    }

    /// ↩ for the next match, ⇧↩ for the previous, ⎋ to close.
    ///
    /// The keys every find bar on this platform uses, and the reason they are
    /// handled here rather than left to the Find menu: with the caret in this
    /// field the first responder is the field editor — an `NSTextView` — and
    /// ⌘G dispatched down the responder chain would stop there.
    public func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.shift) { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            onPrevious?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
