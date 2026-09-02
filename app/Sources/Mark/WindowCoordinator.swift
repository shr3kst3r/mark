import AppKit
import Foundation

/// Every window the app has, and the session file they share.
///
/// `2026-08-26-multiple-windows-and-split-panes` made `MainWindowController`
/// multi-instance. This is what stopped being implicit when it did: with one
/// window, "the window", "the key window" and "the window the session
/// describes" were the same object and no code had to choose between them.
///
/// A type rather than a handful of `AppDelegate` properties, because all of it
/// — the ordering, the pop-out move, the app-wide snapshot — is testable
/// without an `NSApplication`, and none of it is testable through the delegate.
@MainActor
public final class WindowCoordinator {

    /// Windows in creation order. The first is the one commands fall back to.
    public private(set) var controllers: [MainWindowController] = []

    /// ADR-4's own JSON file, now describing all of them.
    private let session: Session

    /// The application's opened-file history
    /// (`2026-08-26-opened-file-history`).
    ///
    /// **Owned here rather than in an `OpenHistory.shared`**, and the default
    /// is a fresh instance rather than a shared one. This is the type that owns
    /// the session file, so it is the type that owns the state the session file
    /// records; and a shared default would mean a coordinator built in a test —
    /// which, with the default `Session()`, writes the developer's own
    /// `session.json` — recording fixture paths into the developer's real
    /// history. ``OpenHistory`` says more about that.
    ///
    /// There is one coordinator in a running app, so one history. Windows
    /// record *into* it; nothing else writes it.
    public let history: OpenHistory

    /// Injectable so tests can build windows without one.
    public init(session: Session = Session(), history: OpenHistory = OpenHistory()) {
        self.session = session
        self.history = history
        // A recorded open is a session change like any other, and it goes
        // through the same debounce — one write for the burst that opening a
        // document produces, rather than one per notification.
        history.onChange = { [weak self] _ in self?.saveSoon() }
    }

    public var count: Int { controllers.count }
    public var isEmpty: Bool { controllers.isEmpty }

    /// Which window a socket command or a Finder open acts on.
    ///
    /// > Commands act on the **key window**, falling back to the first window
    /// > when none is key.
    ///
    /// The fallback is not defensive: an app with no key window is the ordinary
    /// state when a CLI drives it while the user is in their terminal, which is
    /// most of the time `mark open` is called.
    public var keyController: MainWindowController? {
        if let key = NSApp?.keyWindow?.windowController as? MainWindowController,
            controllers.contains(where: { $0 === key })
        {
            return key
        }
        // `mainWindow` rather than nothing: an app that is running but not
        // frontmost still has one, and it is a better answer than "the first
        // window I ever made" for someone who has since opened three.
        if let main = NSApp?.mainWindow?.windowController as? MainWindowController,
            controllers.contains(where: { $0 === main })
        {
            return main
        }
        return controllers.first
    }

    /// Which window a tab lives in, for `mark tab list`.
    public func index(of controller: MainWindowController) -> Int? {
        controllers.firstIndex { $0 === controller }
    }

    public func controller(holding tab: DocumentTab) -> MainWindowController? {
        controllers.first { $0.groups.index(of: tab) != nil }
    }

    // MARK: - Making and losing windows

    @discardableResult
    public func makeWindow(root: URL, collapsedSidebar: Bool = false) -> MainWindowController {
        let controller = MainWindowController(root: root, session: session, history: history)
        controller.windows = self
        controllers.append(controller)
        if collapsedSidebar {
            controller.setSidebarCollapsed(true)
        }
        // Every window after the first is offset, so a popped-out window does
        // not land exactly on top of the one it came from and read as "nothing
        // happened".
        if let previous = controllers.dropLast().last?.window, let window = controller.window {
            window.setFrameOrigin(previous.cascadeTopLeft(from: .zero))
            window.cascadeTopLeft(from: previous.frame.origin)
        }
        Log.app.info("window \(self.controllers.count - 1) opened (\(self.controllers.count) total)")
        return controller
    }

    /// Take an existing controller under management.
    ///
    /// For a window built directly rather than through ``makeWindow(root:collapsedSidebar:)``
    /// — `mark-bench` builds its own, and so do the tests. Without this there
    /// is no way to give an already-constructed window the coordinator it needs
    /// before asking it to move a tab.
    public func adopt(_ controller: MainWindowController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controller.windows = self
        // A window built elsewhere — `mark-bench` and the tests build their own
        // — records into this coordinator's history once adopted, so an adopted
        // window is not quietly the one window whose opens go unrecorded.
        controller.history = history
        controllers.append(controller)
    }

    /// A window is closing: write its unsaved work and forget it.
    public func windowWillClose(_ controller: MainWindowController) {
        guard let index = self.index(of: controller) else { return }
        // The window is going away and its tabs with it, so this is the last
        // moment its buffers can be written — `applicationWillTerminate` will
        // never see them.
        controller.flushDirtyBuffers()
        controllers.remove(at: index)
        Log.app.info("window \(index) closed (\(self.controllers.count) left)")
        saveSoon()
    }

    // MARK: - Recently closed

    /// Documents that were closed, most recent first.
    ///
    /// Application-wide rather than per window, for the same reason the
    /// residency budget is (`2026-08-26-editor-groups-per-pane-tab-bars`): a
    /// tab closed in one window and a window closed entirely are the same loss
    /// to the reader, and a per-window stack would lose the second case
    /// completely.
    ///
    /// URLs and nothing else. Restoring scroll position too was considered and
    /// dropped: the session file already carries scroll for tabs that are
    /// *open*, and a stack that also remembered where you were would have to
    /// invalidate itself when the file changed on disk. Reopening at the top of
    /// the document is honest and needs no invalidation.
    public private(set) var recentlyClosed: [URL] = []

    /// How many closes are remembered. Ten is more than anyone walks back
    /// through and small enough that the list is not a record of the session.
    public static let recentlyClosedLimit = 10

    /// Remember a document that was just closed.
    public func rememberClosed(_ url: URL) {
        // Deduplicated, so opening and closing the same file four times leaves
        // one entry rather than four identical ones to press ⌥⌘T through.
        recentlyClosed.removeAll { $0 == url }
        recentlyClosed.insert(url, at: 0)
        if recentlyClosed.count > Self.recentlyClosedLimit {
            recentlyClosed.removeLast(recentlyClosed.count - Self.recentlyClosedLimit)
        }
    }

    /// The most recently closed document that is still on disk, removing
    /// anything that is not.
    ///
    /// Checked at the point of *use* rather than of closing, because a file can
    /// go away in between — and a ⌥⌘T that opens an error is worse than one
    /// that reaches past a file someone deleted.
    public func takeMostRecentlyClosed() -> URL? {
        while let candidate = recentlyClosed.first {
            recentlyClosed.removeFirst()
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Write every window's dirty buffers. The quit path.
    @discardableResult
    public func flushDirtyBuffers() -> Int {
        controllers.reduce(0) { $0 + $1.flushDirtyBuffers() }
    }

    // MARK: - Moving a tab between windows

    /// Move `tab` out of `source` and into a window of its own.
    ///
    /// The sequence matters and is the risky part of this whole change, so it
    /// is written once, here:
    ///
    /// 1. `source` gives up its claims on the tab — the conflict prompt, the
    ///    editor binding — **before** the tab leaves, while it can still be
    ///    found by url.
    /// 2. ``TabStore/detach(_:)`` removes it and hands back its live
    ///    `DocumentView`. Not `close`, which would write and discard the
    ///    `Buffer`.
    /// 3. The destination adopts both and re-wires every callback. This is
    ///    where `Buffer.onWillWrite` is re-pointed at the new window's
    ///    `FileWatcher`; miss it and the tab's next autosave looks like an
    ///    external edit to the window now showing it.
    /// 4. Both windows re-sync their watchers, so exactly one is watching the
    ///    file.
    @discardableResult
    public func popOut(_ tab: DocumentTab, from source: MainWindowController)
        -> MainWindowController?
    {
        // Whichever of the source window's groups holds it, not the focused
        // one: with two groups (`2026-08-26-editor-groups-per-pane-tab-bars`)
        // the tab bar's context menu can pop out a document from the half that
        // is not being acted on, and detaching from the wrong store would leave
        // the tab in one group and its view in another.
        guard let owner = source.groups.group(of: tab) else { return nil }

        let root = tab.url.deletingLastPathComponent()
        source.releaseClaims(on: tab)
        let moved = owner.detach(tab)
        source.syncWatchedFiles()

        let destination = makeWindow(root: root, collapsedSidebar: true)
        destination.tabs.adopt(moved.tab, view: moved.view)
        destination.syncWatchedFiles()
        destination.showWindow(activating: true)

        Log.tabs.info(
            "popped \(tab.title, privacy: .public) into window \(self.index(of: destination) ?? -1)"
        )
        saveSoon()
        return destination
    }

    // MARK: - Session

    /// Every window's state, in creation order.
    ///
    /// The flat top-level fields keep describing the **first** window, so a
    /// build without multi-window support restores one window instead of
    /// failing. See ``SessionState``.
    public func snapshot() -> SessionState {
        let windows = controllers.map { $0.windowSnapshot() }
        var state = SessionState(windows: windows)
        state.theme = ThemeController.shared.chosenName
        // App-wide, not per window: two windows showing two themes is not a
        // thing, and neither is one pinned light while the other follows the
        // system. Both fields sit on `SessionState` rather than
        // `SessionWindow` for that reason.
        state.themeAppearance = ThemeController.shared.appearance.rawValue
        // App-wide for the same reason again: the editor's whitespace marks are
        // one choice about how source looks, not one per window.
        state.editorInvisibles = Invisibles.isShowing
        state.textZoom = TextZoom.persistedScale
        state.editorLineNumbers = LineNumbers.isShowing ? true : nil
        // App-wide for the same reason, and written even when empty so that
        // clearing the history is a change the file records rather than one an
        // absent key leaves ambiguous.
        state.history = history.sessionEntries
        return state
    }

    public func saveSoon() {
        session.scheduleSave { [weak self] in
            self?.snapshot() ?? SessionState()
        }
    }

    public func saveNow() {
        session.saveNow(snapshot())
    }

    /// Rebuild the windows a previous run left behind.
    ///
    /// - Parameter sidebarRoot: overrides the *first* window's root. Set when
    ///   files were named on the command line — `mark notes/today.md` is an
    ///   explicit instruction about where to be, and it applies to the window
    ///   the documents are about to open in, not to all of them.
    public func restore(_ state: SessionState, sidebarRoot: URL? = nil) {
        ThemeController.shared.restore(
            named: state.theme,
            appearance: state.themeAppearance.flatMap(ThemeAppearance.init(argument:)))
        // Before the windows too, so the first editor to come up already draws
        // the marks rather than drawing itself twice.
        Invisibles.restore(state.editorInvisibles)
        TextZoom.restore(state.textZoom)
        LineNumbers.restore(state.editorLineNumbers)
        // Before the windows, so that a file named on the command line — which
        // opens as those windows come up — is recorded on *top* of the restored
        // history rather than underneath it.
        history.restore(session: state.history ?? [])
        let windows = state.effectiveWindows
        guard !windows.isEmpty else { return }
        for (index, window) in windows.enumerated() {
            let controller: MainWindowController
            if let existing = controllers.indices.contains(index) ? controllers[index] : nil {
                controller = existing
            } else {
                let root =
                    window.sidebarRoot.map { URL(fileURLWithPath: $0) }
                    ?? controllers.first?.sidebar.root
                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                controller = makeWindow(root: root)
            }
            controller.restore(window, sidebarRoot: index == 0 ? sidebarRoot : nil)
            controller.showWindow(activating: index == 0)
        }
    }
}
