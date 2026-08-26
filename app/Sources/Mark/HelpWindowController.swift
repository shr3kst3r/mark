import AppKit
import Foundation

/// **Help ▸ Markdown Reference** — the shipped reference, in a window of its
/// own.
///
/// `2026-08-26-markdown-reference-window`. One `DocumentView`, one
/// ``DocumentFinder``, and nothing else: no sidebar, no tab bar, no editor, no
/// entry in the session file. The whole of what it is, is one document that
/// never changes.
///
/// Three things are worth reading before touching it.
///
/// **It is not a tab, and that is the point.** A `DocumentTab` can be selected,
/// and `2026-08-25-flock-write-locking` makes ⌥⌘E open an editor and an 800 ms
/// autosave on whatever is selected. The reference lives inside
/// `mark.app/Contents/Resources`; a write there succeeds on a locally built
/// bundle (silently editing the shipped reference) and fails on a signed one
/// (breaking the seal). Having no tab is what makes both unreachable, rather
/// than a guard somebody has to remember.
///
/// **Its web view is still ~52 MB.** `2026-08-26-editor-groups-per-pane-tab-bars`
/// makes the residency budget the *application's*, and a governor that only
/// counted tabs would under-report by exactly one web view — the same shape of
/// mistake the superseded residency ADR exists to record. So this registers
/// with ``ResidencyGovernor`` while it is open, which both puts it in
/// `mark doctor`'s arithmetic and makes opening it displace a background tab
/// rather than raise the ceiling.
///
/// **Nothing else can find it to re-theme it.**
/// ``MainWindowController/applyTheme(named:appearance:)`` walks tab stores, and
/// this is not in one. It calls ``applyTheme(_:)`` here explicitly; a reference
/// page left on the old palette while every document changed reads as a
/// rendering bug with a very unhelpful shape.
@MainActor
public final class HelpWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation
{

    /// The one that is open, or `nil`. There is never a second.
    ///
    /// **Strong, and it has to be.** `NSWindow` does not retain its
    /// `windowController`, and nothing else in the app holds this one — the
    /// menu action discards what ``show()`` returns. Weak here would
    /// deallocate the controller the instant the menu item finished, taking
    /// the window with it, and the only test that could catch it would be one
    /// holding a strong reference of its own. ``tearDown()`` is what releases
    /// it.
    public private(set) static var shared: HelpWindowController?

    /// Open the reference, or bring the open one forward.
    ///
    /// - Returns: the controller, or `nil` when this build ships no reference —
    ///   which the menu item is validated against, so it should not happen.
    @discardableResult
    public static func show() -> HelpWindowController? {
        // A torn-down controller has given its web view back and cannot show
        // anything; the answer to ⇧⌘/ after a close is a new window.
        if let existing = shared, !existing.isTornDown {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        guard let controller = HelpWindowController() else { return nil }
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// The rendered reference.
    public let documentView: DocumentView

    /// ⌘F, over ``documentView`` and nothing else.
    public let finder: DocumentFinder

    private let pane: PreviewPaneView

    /// `nil` when the bundle has no `markdown-reference.md`. A build assembled
    /// without the resource should disable a menu item, not fail to launch.
    public init?(
        source: String? = MarkdownReference.source,
        url: URL? = MarkdownReference.url,
        governor: ResidencyGovernor = .shared
    ) {
        guard let source, let url else { return nil }
        self.governor = governor

        documentView = DocumentView(frame: NSRect(x: 0, y: 0, width: 780, height: 860))
        // The reference demonstrates task lists, so it has checkboxes in it.
        // See ``RefusingTaskWriter`` for why they are examples rather than
        // controls.
        documentView.taskWriter = RefusingTaskWriter()

        finder = DocumentFinder(width: 780)

        // The bar *after* the document view, which is `PreviewPaneView`'s own
        // documented constraint: a `WKWebView` is layer-hosted and paints over
        // any sibling added before it.
        pane = PreviewPaneView(
            frame: NSRect(x: 0, y: 0, width: 780, height: 900),
            findBar: finder.bar,
            container: documentView
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = pane
        window.title = "Markdown Reference"
        window.minSize = NSSize(width: 480, height: 320)
        window.setFrameAutosaveName("dev.mark.MarkdownReferenceWindow")
        // Same reasoning as the document window's: session state is ours, in
        // our own file, and this window is deliberately not in it.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // `windowWillClose` tears the web view down and drops ``shared``, so
        // the controller must still be alive to run it.
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        // The pane owns the frames; without this the document view keeps the
        // one it was constructed with and the window resizes around a
        // stationary page.
        pane.needsLayout = true

        finder.documentView = { [weak self] in self?.documentView }
        finder.hasDocument = { true }
        finder.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.pane.needsLayout = true
            self.pane.layoutSubtreeIfNeeded()
            if !visible, let webView = self.documentView.webView {
                self.window?.makeFirstResponder(webView)
            }
        }

        // Not read from disk. The bytes are already in hand, and the URL is
        // only wanted so `#anchor` links resolve and the log lines name
        // something — this is the same path a dirty tab rehydrates through.
        documentView.open(url, source: source)

        governor.registerAuxiliaryWebView()
        Log.app.info("markdown reference opened")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HelpWindowController is created in code, not from a nib")
    }

    private let governor: ResidencyGovernor

    /// Whether this window has already given its web view back.
    public private(set) var isTornDown = false

    // MARK: - Theme

    /// Re-colour the page, and re-render it when the colours are baked in.
    ///
    /// The same two-step ``MainWindowController/applyTheme(named:appearance:)``
    /// does for a tab, and for the same two reasons: a diagram carries
    /// `merman`'s palette inside its own SVG, and code tokens carry a scope
    /// map. The reference always contains a diagram, so a change of *theme*
    /// always re-renders it — a change of *appearance* still costs nothing,
    /// because both halves are already in the page.
    public func applyTheme(_ theme: ResolvedTheme, previous: ResolvedTheme?) async {
        _ = await documentView.applyTheme(theme).value
        guard let previous, theme != previous else { return }
        let stampChanged = theme.codeStamp != previous.codeStamp
        let hasDiagram = await documentView.containsDiagram()
        guard stampChanged || hasDiagram else { return }
        await documentView.rerenderForTheme()
        _ = await documentView.applyTheme(theme).value
    }

    // MARK: - Menu

    /// The Find items, when this window is the key one.
    @objc public func performFindAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag
        let action = tag.flatMap(NSTextFinder.Action.init(rawValue:)) ?? .showFindInterface
        // There is no editor here, so unlike the document window there is
        // nowhere for Replace to go.
        if !finder.perform(action) {
            NSSound.beep()
        }
    }

    /// `NSMenuItemValidation` rather than an override: `NSWindowController`
    /// does not declare this, so `override` does not compile and a method
    /// AppKit cannot see would silently never run.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performFindAction(_:)) {
            return finder.validate(NSTextFinder.Action(rawValue: item.tag) ?? .showFindInterface)
        }
        return true
    }

    // MARK: - Closing

    public func windowWillClose(_ notification: Notification) {
        tearDown()
    }

    /// Give the web view back.
    ///
    /// Idempotent, because `windowWillClose` and an explicit close from a test
    /// can both arrive, and releasing a `WKWebView` twice would unbalance the
    /// script router's routing table.
    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        documentView.tearDown()
        governor.unregisterAuxiliaryWebView()
        if HelpWindowController.shared === self {
            let released = HelpWindowController.shared
            HelpWindowController.shared = nil
            // The usual caller is `windowWillClose`, so AppKit is inside a
            // delegate call *on this object*: dropping the last reference here
            // would deallocate the receiver out from under the stack. Clearing
            // `shared` synchronously keeps the state honest; the hop is only
            // about when the memory goes.
            DispatchQueue.main.async { _ = released }
        }
        Log.app.info("markdown reference closed")
    }
}
