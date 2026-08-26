import AppKit
import Foundation

/// Find-in-document: the bar, the query, and the four `NSTextFinder` actions
/// that drive them.
///
/// This is M8's find, lifted out of ``MainWindowController`` unchanged when
/// `2026-08-26-markdown-reference-window` added a second window that shows a
/// document. It knows about exactly one thing — a ``DocumentView`` it is handed
/// on demand — and nothing about tabs, panes, editors or windows. Those arrive
/// as closures, because they are the parts the two hosts do not share.
///
/// **It does not own the document view.** ``documentView`` is asked freshly at
/// every use rather than stored, because in a tabbed window the answer changes
/// with the selection and with ADR-4's dehydration: a held reference would go
/// on searching a web view that had been torn down.
///
/// The generation counter is the reason this is a type rather than a handful of
/// methods. Every search is a round trip into the page, they can land out of
/// order, and a stale answer overwriting a newer one shows up as a match count
/// that is wrong by one keystroke — a race that is only reproducible under
/// load. There should be one of these, not one per window that shows a
/// document.
@MainActor
public final class DocumentFinder {

    /// The bar itself, for the host to put in its view hierarchy.
    public let bar: FindBar

    /// The document to search. Asked at every use; see the note above.
    public var documentView: (() -> DocumentView?)?

    /// Whether there is a document at all, for menu validation.
    ///
    /// Separate from ``documentView`` because a tabbed window answers "yes"
    /// for a selected tab whose web view has not painted yet, and greying ⌘F
    /// out for the width of a first paint would be a flicker rather than an
    /// answer.
    public var hasDocument: (() -> Bool)?

    /// The bar appeared or disappeared. The host relays out the chrome around
    /// it, and decides where the keyboard goes when it closes.
    public var onVisibilityChanged: ((Bool) -> Void)?

    /// The string the preview is currently showing matches for.
    public private(set) var query = ""

    /// Bumped on every search, so a slow answer for a query the reader has
    /// already typed past cannot overwrite a newer one.
    private var generation = 0

    public init(width: CGFloat = 900) {
        bar = FindBar(frame: NSRect(x: 0, y: 0, width: width, height: FindBar.barHeight))
        bar.isHidden = true
        bar.onQueryChanged = { [weak self] query in self?.search(query) }
        bar.onNext = { [weak self] in self?.next() }
        bar.onPrevious = { [weak self] in self?.previous() }
        bar.onClose = { [weak self] in self?.setVisible(false) }
    }

    // MARK: - Visibility

    public var isVisible: Bool { !bar.isHidden }

    /// Show or hide ⌘F's bar.
    ///
    /// Hiding it drops the highlights as well as the bar. Leaving twelve
    /// yellow words behind after the bar has gone would look like the document
    /// had been marked up rather than searched.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        bar.isHidden = !visible
        bar.needsLayout = true
        bar.needsDisplay = true
        onVisibilityChanged?(visible)
        guard !visible else { return }
        query = ""
        generation += 1
        bar.query = ""
        bar.report(nil)
        if let view = documentView?() {
            _Concurrency.Task { @MainActor in await view.clearFind() }
        }
    }

    /// ⌘F.
    public func show() {
        setVisible(true)
        bar.focus()
    }

    // MARK: - Searching

    /// ⌘G, ↩, and the bar's down arrow.
    public func next() { advance(forward: true) }

    /// ⇧⌘G, ⇧↩, and the bar's up arrow.
    public func previous() { advance(forward: false) }

    /// Move to the next or previous match, wrapping at both ends.
    ///
    /// A step through ranges the page has already built, not another search —
    /// which is what makes holding ⌘G down feel like cycling rather than like
    /// re-running a query twelve times.
    private func advance(forward: Bool) {
        guard isVisible, !query.isEmpty else {
            // ⌘G with nothing to repeat is a request for the bar, not a beep.
            show()
            return
        }
        guard let view = documentView?() else { return }
        generation += 1
        let generation = self.generation
        _Concurrency.Task { @MainActor [weak self] in
            let result = await view.stepFind(forward: forward)
            guard let self, generation == self.generation else { return }
            self.bar.report(result)
        }
    }

    /// ⌘E — take the query from what the reader has selected in the preview.
    public func useSelection() {
        guard let view = documentView?() else { return }
        _Concurrency.Task { @MainActor [weak self] in
            let selection = await view.selectedText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !selection.isEmpty else { return }
            self.setVisible(true)
            self.bar.query = selection
            self.search(selection)
        }
    }

    /// Search the preview, highlight every match, and report the position.
    private func search(_ text: String) {
        query = text
        generation += 1
        let generation = self.generation
        guard let view = documentView?() else {
            bar.report(text.isEmpty ? nil : FindResult.empty)
            return
        }
        guard !text.isEmpty else {
            bar.report(nil)
            _Concurrency.Task { @MainActor in await view.clearFind() }
            return
        }
        _Concurrency.Task { @MainActor [weak self] in
            let result = await view.find(text)
            guard let self, generation == self.generation else { return }
            self.bar.report(result)
        }
    }

    /// Run the current search again, because the document underneath it moved.
    ///
    /// Every range the page holds points into a block element, and a patch
    /// replaces block elements — so an edit, an external change, or a tab
    /// switch leaves the highlights stale. `shell.js` drops them on every
    /// document mutation; this is what puts them back.
    public func refresh() {
        guard isVisible, !query.isEmpty else { return }
        search(query)
    }

    // MARK: - Menu

    /// One of the Edit ▸ Find items, once the host has decided this finder is
    /// the one that should answer it.
    ///
    /// - Returns: `false` for an action the preview cannot do — Replace and its
    ///   relatives — so the host can beep, or hand it somewhere else.
    @discardableResult
    public func perform(_ action: NSTextFinder.Action) -> Bool {
        switch action {
        case .showFindInterface: show()
        case .hideFindInterface: setVisible(false)
        case .nextMatch: next()
        case .previousMatch: previous()
        case .setSearchString: useSelection()
        default:
            // Replace and its relatives belong to a text view. The preview is
            // rendered output; there is nothing there to write through to.
            return false
        }
        return true
    }

    /// Whether `action` should be enabled in the menu.
    public func validate(_ action: NSTextFinder.Action) -> Bool {
        let hasDocument = self.hasDocument?() ?? (documentView?() != nil)
        switch action {
        case .showFindInterface, .setSearchString:
            return hasDocument
        case .nextMatch, .previousMatch:
            return hasDocument && !query.isEmpty
        case .hideFindInterface:
            return isVisible
        default:
            return false
        }
    }
}
