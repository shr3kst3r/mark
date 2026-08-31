import AppKit
import Foundation

/// **File ▸ Today** — the day's work and every project's open items, in a
/// window of its own.
///
/// `2026-08-31-today-page`. Modelled on ``HelpWindowController``, which is the
/// nearest thing the app already has: one `DocumentView`, one
/// ``DocumentFinder``, no sidebar, no tab bar, no editor, no entry in the
/// session file, and its web view counted against the application's residency
/// budget because it is ~52 MB whether or not it is a tab.
///
/// Three things about it are not the reference's.
///
/// **The document it shows has no file.** It is assembled from the journal
/// every time it is built. That is the one place this feature sits against
/// `2026-08-26-new-documents-are-files-on-disk`, and having no `DocumentTab` is
/// what keeps the two from meeting: ⌥⌘E cannot aim an editor and an 800 ms
/// autosave at a document that is not in a tab, so there is no path by which
/// the synthesized page could be written anywhere.
///
/// **Its checkboxes are copies.** Each line came from some other file, and a
/// click here would have to be routed back to whichever one. It is given a
/// ``RefusingTaskWriter`` — the click is refused, logged with that reason, and
/// the box goes back to what the page says. Following the item's link and
/// ticking it in the file it lives in is the supported way round.
///
/// **It re-reads itself.** A ``FileWatcher`` over exactly the files the page
/// was built from re-renders it through ``DocumentView/apply(source:)``, which
/// is ADR-2's block patch and therefore keeps the reader's scroll position.
/// Becoming the key window rebuilds from scratch as well, which is what picks
/// up a project that did not exist when the window opened — and what makes the
/// page say "Tuesday" the morning after it was left open.
@MainActor
public final class TodayWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation
{

    /// The one that is open, or `nil`. There is never a second.
    ///
    /// **Strong, for ``HelpWindowController/shared``'s documented reason:**
    /// `NSWindow` does not retain its `windowController` and nothing else in
    /// the app holds this one, so a weak reference would deallocate the
    /// controller the instant the menu action returned and take the window with
    /// it. ``tearDown()`` is what releases it.
    public private(set) static var shared: TodayWindowController?

    /// Open the page, or bring the open one forward — rebuilding it either way,
    /// because the answer to "show me today" is never a stale page.
    @discardableResult
    public static func show(
        startingFrom start: URL,
        open: @escaping (URL, String?) -> Void,
        now: @escaping () -> Date = { Date() }
    ) -> TodayWindowController {
        if let existing = Self.shared, !existing.isTornDown {
            existing.startingPoint = start
            existing.refreshSoon()
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = TodayWindowController(startingFrom: start, open: open, now: now)
        Self.shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    // MARK: - State

    /// The rendered page.
    public let documentView: DocumentView

    /// ⌘F, over ``documentView`` and nothing else.
    public let finder: DocumentFinder

    private let pane: PreviewPaneView
    private let governor: ResidencyGovernor

    /// How an item becomes an open document, optionally scrolled to the heading
    /// it sits under. A closure rather than a reference to
    /// ``WindowCoordinator``, for ``HistoryWindowController``'s reason: the
    /// route in is the caller's to supply, and this window is testable without
    /// one.
    private let openDocument: (URL, String?) -> Void

    /// What "today" is. Injected so a test can ask for a fixed day; the app
    /// passes `Date.init`.
    private let now: () -> Date

    /// Where the search for a journal starts — the sidebar's root when the
    /// window was opened, and updated when it is re-opened from a window rooted
    /// somewhere else.
    public private(set) var startingPoint: URL

    /// The journal that was found, or `nil` when there is none above
    /// ``startingPoint``.
    public private(set) var journal: JournalRoot?

    /// The last digest built. `nil` until the first ``refresh()``, and whenever
    /// there is no journal.
    public private(set) var digest: TodayDigest?

    /// The markdown the page was last rendered from. Read by the tests, which
    /// assert on the page rather than on the DOM.
    public private(set) var markdown: String?

    /// Whether a document has been put into the view yet, which is what decides
    /// between `open` and the patching `apply`.
    private var hasPresented = false

    private var watcher: FileWatcher?

    public private(set) var isTornDown = false

    // MARK: - Lifecycle

    public init(
        startingFrom start: URL,
        open: @escaping (URL, String?) -> Void,
        now: @escaping () -> Date = { Date() },
        governor: ResidencyGovernor = .shared
    ) {
        self.startingPoint = start
        self.openDocument = open
        self.now = now
        self.governor = governor

        documentView = DocumentView(frame: NSRect(x: 0, y: 0, width: 760, height: 840))
        documentView.taskWriter = RefusingTaskWriter(
            reason: "the Today page shows copies of items from other files and is never written to")

        finder = DocumentFinder(width: 760)

        // The bar *after* the document view, which is `PreviewPaneView`'s own
        // documented constraint: a `WKWebView` is layer-hosted and paints over
        // any sibling added before it.
        pane = PreviewPaneView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 880),
            findBar: finder.bar,
            container: documentView
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = pane
        window.title = "Today"
        window.minSize = NSSize(width: 460, height: 320)
        window.setFrameAutosaveName("dev.mark.TodayWindow")
        // Session state is ours, in our own file, and this window is
        // deliberately not in it — the position both other auxiliary windows
        // take.
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

        // A link on this page is the reader naming a file, so it opens in the
        // document window exactly as a link in any other document does. The
        // fragment variant is why `DocumentView.onFollowFragment` exists: a
        // task's link carries the heading it sits under, and arriving at the
        // top of a 200-line daily would be arriving in the wrong place.
        documentView.onFollow = { [weak self] url in
            self?.openDocument(url, nil)
        }
        documentView.onFollowFragment = { [weak self] url, anchor in
            self?.openDocument(url, anchor)
        }

        governor.registerAuxiliaryWebView()
        Log.app.info("today page opened")
        refreshSoon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TodayWindowController is created in code, not from a nib")
    }

    // MARK: - Building the page

    /// Rebuild from the journal and put the result on screen, without waiting.
    public func refreshSoon() {
        _Concurrency.Task { @MainActor in await self.refresh() }
    }

    /// Rebuild from the journal and put the result on screen.
    ///
    /// The first render is an `open`; every one after it is
    /// ``DocumentView/apply(source:)``, which diffs the two documents and
    /// patches the blocks that changed. That is what keeps the reader's scroll
    /// position across a save in a file the page happens to be showing — the
    /// same reason the watcher patches a tab rather than reloading it.
    public func refresh() async {
        guard !isTornDown else { return }

        let journal = JournalRoot.find(from: startingPoint)
        self.journal = journal

        let source: String
        let url: URL
        if let journal {
            let digest = TodayDigest.build(root: journal, on: now())
            self.digest = digest
            source = TodayPage.markdown(for: digest)
            url = TodayPage.url(in: journal)
            watch(digest.sourceFiles)
            window?.subtitle = journal.url.lastPathComponent
        } else {
            self.digest = nil
            source = TodayPage.notAJournal(startingFrom: startingPoint)
            // Still inside the directory that was searched, so the page's own
            // relative links — it has none, but the next revision might —
            // resolve somewhere sensible rather than at `/`.
            url = startingPoint.appendingPathComponent(TodayPage.name)
            watch([])
            window?.subtitle = ""
        }

        guard source != markdown || !hasPresented else { return }
        markdown = source

        if hasPresented, documentView.url == url {
            _ = await documentView.apply(source: source)
        } else {
            documentView.open(url, source: source)
            hasPresented = true
        }
    }

    /// Re-read when any file the page was built from changes.
    ///
    /// The set is exactly the digest's sources, so a save anywhere else in the
    /// journal costs nothing. A file that appears — a project created while the
    /// window is open — is not in the set and is picked up when the window next
    /// becomes key, which is the cheap answer to a question that would
    /// otherwise need a recursive watch on the whole tree.
    private func watch(_ files: Set<URL>) {
        guard !files.isEmpty else {
            watcher?.stop()
            return
        }
        if watcher == nil {
            watcher = FileWatcher { [weak self] _ in
                self?.refreshSoon()
            }
        }
        watcher?.setWatched(files)
    }

    // MARK: - Window

    /// Rebuild when the window comes forward.
    ///
    /// Two things this catches that the watcher cannot: a project directory
    /// created since the page was built, and midnight — a window left open
    /// overnight is showing yesterday until something asks it again.
    public func windowDidBecomeKey(_ notification: Notification) {
        refreshSoon()
    }

    // MARK: - Theme

    /// Re-colour the page, and re-render it when the colours are baked in.
    ///
    /// The same two steps ``HelpWindowController/applyTheme(_:previous:)``
    /// takes, and for the same reasons — a diagram's palette and a code scope
    /// map are baked into the HTML at render time. This page has neither today,
    /// but an item's text is copied verbatim from a file that may well contain
    /// a fenced code span, so it asks rather than assuming.
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

    /// Give the web view back and stop watching.
    ///
    /// Idempotent, because `windowWillClose` and an explicit close from a test
    /// can both arrive, and releasing a `WKWebView` twice would unbalance the
    /// script router's routing table.
    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        watcher?.stop()
        watcher = nil
        documentView.tearDown()
        governor.unregisterAuxiliaryWebView()
        if Self.shared === self {
            let released = Self.shared
            Self.shared = nil
            // The usual caller is `windowWillClose`, so AppKit is inside a
            // delegate call *on this object*: dropping the last reference here
            // would deallocate the receiver out from under the stack. Clearing
            // `shared` synchronously keeps the state honest; the hop is only
            // about when the memory goes.
            DispatchQueue.main.async { _ = released }
        }
        Log.app.info("today page closed")
    }
}
