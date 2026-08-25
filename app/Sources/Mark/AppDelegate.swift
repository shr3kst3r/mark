import AppKit
import Foundation

/// Application lifecycle.
///
/// M4 adds ADR-3's two entry paths and owns their lifetimes: the Unix-socket
/// server is bound after the window exists and unlinked on quit, and `mark://`
/// URLs arrive through `application(_:open:)`. Both feed the same
/// ``CommandRouter``, which is the ADR's "the two entry paths must not drift"
/// constraint made structural. There is no competing use of the `mark` scheme —
/// the shell's assets are served over `mark-asset` (``ShellAssets/scheme``) for
/// exactly this reason.
///
/// M3 adds the two lifecycle halves of ADR-4's session file: read it at launch,
/// write it at quit. Neither goes through `NSWindowRestoration`, and nothing
/// here writes `NSQuitAlwaysKeepsWindows`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    public private(set) var mainWindowController: MainWindowController?

    /// ADR-3's command surface. One router, two entry paths.
    public private(set) var router: CommandRouter?

    /// `$TMPDIR/mark-$UID.sock`. `nil` only when ``socketsEnabled`` is off.
    public private(set) var socketServer: SocketServer?

    /// `MARK_NO_IPC=1` skips binding the socket.
    ///
    /// For `mark-bench` and for any test that launches a second copy of the app
    /// while the developer's own is running: ADR-3's stale-socket rule means
    /// the newcomer takes the path over, and a benchmark that silently stole
    /// the CLI's socket would be a nasty thing to debug.
    private let socketsEnabled: Bool

    /// Files named on the command line, before `NSApplication` starts.
    private let launchFiles: [URL]

    /// URLs that arrived before there was a window to put them in.
    ///
    /// This is not defensive: it is the ordinary order of a Finder or `open(1)`
    /// launch. `NSApplication.finishLaunching` posts
    /// `applicationWillFinishLaunching`, **then** dispatches the queued
    /// `kAEOpenDocuments` Apple event — which is what
    /// ``application(_:open:)`` is — and only then posts
    /// `applicationDidFinishLaunching`, where this app builds its window. So on
    /// every cold `open README.md` the file arrived, found
    /// ``mainWindowController`` still `nil`, and was dropped on the floor: the
    /// window came up on yesterday's restored session with the requested
    /// document nowhere in it.
    private(set) var pendingURLs: [URL] = []

    /// ADR-4's own JSON file. Injectable so tests and `mark-bench` do not
    /// touch the developer's real session.
    private let session: Session

    /// Set by `MARK_NO_SESSION=1`, so `just run FILE` and the benchmark do not
    /// resurrect twenty tabs from yesterday over the file being examined.
    private let restoresSession: Bool

    public init(launchFiles: [URL] = [], session: Session = Session()) {
        self.launchFiles = launchFiles
        self.session = session
        let environment = ProcessInfo.processInfo.environment
        let disabled = environment["MARK_NO_SESSION"]
        self.restoresSession = !(disabled == "1" || disabled == "true")
        let noIPC = environment["MARK_NO_IPC"]
        self.socketsEnabled = !(noIPC == "1" || noIPC == "true")
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let state = Log.signposter.beginInterval("didFinishLaunching")

        // The first line in the log of every launch, so a report that arrives
        // with a log attached says which build produced it.
        Log.app.info("mark \(BuildInfo.summary, privacy: .public)")
        let core = (try? MarkCore.version()) ?? "unavailable"
        Log.app.info("mark-core \(core, privacy: .public)")

        let restored = restoresSession ? session.loadOrLogging() : nil
        // Files from the command line *and* files from the launch Apple event:
        // `open README.md` delivers the second, and until they were treated
        // alike only the first could choose the sidebar's root.
        let requested = launchFiles + pendingURLs.filter(\.isFileURL)
        let root =
            requested.first.map { $0.deletingLastPathComponent() }
            ?? restored?.sidebarRoot.map { URL(fileURLWithPath: $0) }.flatMap(Self.existing)
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let controller = MainWindowController(root: root, session: session)
        mainWindowController = controller
        installMainMenu(for: controller)
        controller.showWindow(activating: true)

        if let restored {
            Log.app.info("restoring \(restored.tabs.count) tabs from the session file")
            controller.restore(
                restored, sidebarRoot: requested.isEmpty ? nil : root)
        }

        for url in launchFiles {
            controller.open(url)
        }

        router = CommandRouter(target: controller)
        startCommandSocket()

        // After the router exists, because a queued `mark://` URL is routed
        // through it. Draining is last so that a launch-event document opens
        // *over* the restored session rather than under it.
        let held = pendingURLs
        pendingURLs = []
        open(held, into: controller)

        Log.signposter.endInterval("didFinishLaunching", state)
    }

    /// Opening from Finder, `open -a`, a drag onto the Dock icon — and
    /// `mark://`, ADR-3's cold-launch entry point.
    ///
    /// > We also register a `mark://` URL scheme in `CFBundleURLTypes` and
    /// > handle it in `application(_:open:)`. It carries the initial request
    /// > atomically on cold launch, and it is the entry point for Finder,
    /// > browsers, and other applications.
    ///
    /// A `mark://` URL is routed through the same ``CommandRouter`` the socket
    /// feeds, so the two cannot drift. A `file:` URL keeps M2's behaviour
    /// exactly, including activating: a double-click in Finder is a person
    /// asking to look at something now.
    public func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller = mainWindowController else {
            // The cold-launch order, not an error: hold them until
            // `applicationDidFinishLaunching` has a window to open them in.
            pendingURLs.append(contentsOf: urls)
            Log.app.info("holding \(urls.count) launch URL(s) until the window exists")
            return
        }
        open(urls, into: controller)
    }

    /// - Parameter controller: passed in rather than read from
    ///   ``mainWindowController``, so that the launch drain — which runs while
    ///   the property is being set up — cannot take the queueing branch above
    ///   and put back what it is draining.
    private func open(_ urls: [URL], into controller: MainWindowController) {
        var openedFile = false
        for url in urls {
            if url.isFileURL {
                controller.open(url)
                openedFile = true
            } else if url.scheme?.lowercased() == MarkProtocol.urlScheme {
                let router = self.router
                _Concurrency.Task { @MainActor in
                    await router?.handle(url: url)
                }
            } else {
                Log.ipc.error("ignoring \(url.absoluteString, privacy: .public)")
            }
        }
        if openedFile {
            controller.showWindow(activating: true)
        }
    }

    /// `url` if it is still there, else its nearest existing ancestor, else nil.
    ///
    /// Only ever applied to a root read back out of the session file, and only
    /// there. ``Navigator`` deliberately *"never checks that a root exists"* —
    /// a listing of nothing is the honest answer for a directory you navigated
    /// to and then deleted. A root restored from a previous launch is the one
    /// case where that reads as the app having lost its place instead: the
    /// worktree it pointed at was deleted weeks ago, and the window comes back
    /// rooted at a path with nothing in it and no way to tell why.
    static func existing(_ url: URL) -> URL? {
        let manager = FileManager.default
        var candidate = url.standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            // `/`'s parent is `/`, which is the loop's only exit besides a hit.
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }

    /// The standard About panel, told which build it is describing.
    ///
    /// Not `orderFrontStandardAboutPanel(_:)` directly: left to itself the
    /// panel pairs `CFBundleShortVersionString` with `CFBundleVersion`, which
    /// this bundle sets to the same string — *"Version 0.2.0 (0.2.0)"*, on
    /// every build ever made from that version, which is precisely the question
    /// the app could not answer. The two option keys are AppKit's own:
    /// `applicationVersion` is the one after "Version", `version` the
    /// parenthesised build beside it. Filling the second with the commit is the
    /// whole change.
    @objc private func about(_ sender: Any?) {
        NSApplication.shared.orderFrontStandardAboutPanel(options: Self.aboutOptions)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Separated from ``about(_:)`` so it can be asserted on: what the panel
    /// then does with these is AppKit's business, but *which build they name*
    /// is this app's.
    static var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [
            .applicationVersion: BuildInfo.version,
            .version: "\(BuildInfo.commit) \(BuildInfo.date)",
        ]
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // One window (ADR-4), so closing it means quitting.
        true
    }

    /// The session write that has to happen synchronously.
    ///
    /// It can, because scroll offsets are pushed from each page on a throttle
    /// and cached in ``DocumentTab/scrollOffset``; nothing here has to ask a
    /// web view anything.
    public func applicationWillTerminate(_ notification: Notification) {
        // Unsaved buffers first, and synchronously.
        // `2026-08-24-editing-pane-and-autosave` bounds the loss to "the last
        // 800 ms" only if the pending debounce is written when the app goes
        // away — and `applicationWillTerminate` has no runloop left to await
        // on, which is why `Buffer.save()` is synchronous.
        mainWindowController?.flushDirtyBuffers()
        mainWindowController?.saveSessionNow()
        socketServer?.stop()
    }

    // MARK: - The socket (ADR-3)

    /// Bind `$TMPDIR/mark-$UID.sock`, or fail loudly.
    ///
    /// The path-length branch is not defensive programming, it is the ADR's
    /// instruction:
    ///
    /// > **The full socket path must stay under 104 bytes.** Assert this at
    /// > startup rather than discovering it via a truncated path.
    ///
    /// A truncated `sun_path` binds *successfully* — on a path no client will
    /// ever compute — so the failure would otherwise present as "the CLI hangs
    /// and then launches a second app", days later, with nothing in the log.
    /// Exiting is what "assert" means: a `mark` that cannot be driven from the
    /// CLI is not the product, and the message says exactly which knob to turn.
    private func startCommandSocket() {
        guard socketsEnabled else {
            Log.ipc.notice("MARK_NO_IPC is set; not binding a socket")
            return
        }
        guard let router else { return }

        let path: String
        do {
            path = try SocketPath.resolve()
        } catch {
            Self.failStartup("\(error)")
        }

        let server = SocketServer(path: path) { line in
            await router.handle(line: line)
        }
        do {
            try server.start()
            socketServer = server
        } catch {
            // Binding failed for a reason that is *not* the length trap —
            // a read-only $TMPDIR, a descriptor limit. The GUI still works, so
            // this is loud but not fatal.
            Log.ipc.fault(
                "the command socket is unavailable: \(String(describing: error), privacy: .public)")
            FileHandle.standardError.write(
                Data("mark: the command socket is unavailable: \(error)\n".utf8))
        }
    }

    /// Report and exit. `EX_CONFIG` (78) because the environment, not the code,
    /// is what is wrong — and because an exit code an integration check can
    /// assert on is worth more than a `fatalError` crash report.
    private static func failStartup(_ message: String) -> Never {
        Log.ipc.fault("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("mark: \(message)\n".utf8))
        exit(78)
    }

    // MARK: - Menu

    /// A minimal menu bar, built in code because there is no nib.
    ///
    /// Without this the app has no ⌘Q, no ⌘W, and no edit-menu shortcuts —
    /// which reads as "broken app" long before anyone thinks "missing menu".
    ///
    /// The tab items are ADR-4's bill coming due: *"we hand-build the tab bar
    /// and own what native tabbing would have given us: […] ⌘T / ⌘W / ⌃⇥ /
    /// ⌘1–9 key equivalents, Window-menu items"*. With native tabbing AppKit
    /// supplies and validates all of these; here they are ordinary menu items
    /// targeting the responder chain, validated by
    /// ``MainWindowController/validateMenuItem(_:)``.
    private func installMainMenu(for controller: MainWindowController) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About mark", action: #selector(about(_:)), keyEquivalent: ""
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide mark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Quit mark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "New Tab…", action: #selector(MainWindowController.newTab(_:)),
            keyEquivalent: "t")
        fileMenu.addItem(
            withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o"
        ).target = self
        fileMenu.addItem(
            withTitle: "Reload", action: #selector(MainWindowController.reloadDocument(_:)),
            keyEquivalent: "r")
        // Autosave writes 800 ms after typing stops, so this is rarely the
        // thing that saves the file — but an editor with no ⌘S feels broken
        // even while it is saving, and it is the only way to write *now*.
        fileMenu.addItem(
            withTitle: "Save", action: #selector(MainWindowController.saveDocument(_:)),
            keyEquivalent: "s")
        fileMenu.addItem(.separator())
        // ⌘W is the tab, ⇧⌘W is the window — the platform convention, and the
        // one place where "we own the tab bar" is visible in the menu bar.
        fileMenu.addItem(
            withTitle: "Close Tab", action: #selector(MainWindowController.closeTab(_:)),
            keyEquivalent: "w")
        fileMenu.addItem(
            withTitle: "Close Other Tabs",
            action: #selector(MainWindowController.closeOtherTabs(_:)), keyEquivalent: "")
        let closeWindow = fileMenu.addItem(
            withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // The Edit menu is M9's other half, and it is deliberately all
        // *inherited* behaviour: `2026-08-24-editing-pane-and-autosave` chose
        // `NSTextView` precisely so that undo, Find & Replace, spellcheck and
        // text substitution come for free, and "for free" means these items
        // target the responder chain rather than any code in this app. Without
        // them the machinery exists and is unreachable — ⌘Z and ⌘F would simply
        // do nothing, which reads as "the editor is broken".
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        // `tag` is how the action is told *which* find this is; without it
        // every item would mean "show the find bar".
        //
        // The selector is `MainWindowController`'s, not `NSTextView`'s, and
        // that is the one deliberate exception to this menu being all
        // inherited behaviour. There are two find bars now — the editor's,
        // which is `NSTextView`'s and free, and the preview's, which searches
        // a `WKWebView` and cannot be. `performFindPanelAction:` would be
        // swallowed by whichever text view happened to hold the focus (the
        // find field's own field editor included), so the fork is made once,
        // explicitly, in `performFindAction(_:)`, which hands the editor's
        // items straight back to `NSTextView`.
        let findActions: [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] = [
            ("Find…", "f", [.command], .showFindInterface),
            ("Find Next", "g", [.command], .nextMatch),
            ("Find Previous", "G", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", [.command], .setSearchString),
            ("Replace…", "f", [.command, .option], .replace),
        ]
        for (title, key, modifiers, action) in findActions {
            let item = findMenu.addItem(
                withTitle: title,
                action: #selector(MainWindowController.performFindAction(_:)),
                keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = action.rawValue
        }
        findItem.submenu = findMenu
        editMenu.addItem(findItem)

        let spellingItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: "Spelling and Grammar")
        spellingMenu.addItem(
            withTitle: "Show Spelling and Grammar",
            action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spellingMenu.addItem(
            withTitle: "Check Document Now",
            action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        spellingMenu.addItem(.separator())
        spellingMenu.addItem(
            withTitle: "Check Spelling While Typing",
            action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        spellingItem.submenu = spellingMenu
        editMenu.addItem(spellingItem)

        let substitutionsItem = NSMenuItem(title: "Substitutions", action: nil, keyEquivalent: "")
        let substitutionsMenu = NSMenu(title: "Substitutions")
        substitutionsMenu.addItem(
            withTitle: "Text Replacement",
            action: #selector(NSTextView.toggleAutomaticTextReplacement(_:)), keyEquivalent: "")
        substitutionsMenu.addItem(
            withTitle: "Smart Quotes",
            action: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), keyEquivalent: "")
        substitutionsMenu.addItem(
            withTitle: "Smart Dashes",
            action: #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), keyEquivalent: "")
        substitutionsItem.submenu = substitutionsMenu
        editMenu.addItem(substitutionsItem)

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            withTitle: "Toggle Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s"
        ).keyEquivalentModifierMask = [.command, .control]
        // M9's third pane. Hidden by default (ADR-6), so this is how a reader
        // becomes an editor.
        viewMenu.addItem(
            withTitle: "Show Editor",
            action: #selector(MainWindowController.toggleEditorPane(_:)), keyEquivalent: "e"
        ).keyEquivalentModifierMask = [.command, .option]
        // The sidebar's lower half. A toggle rather than a preference because
        // it is a thing you want for a long document and not for a short one,
        // and ⌃⌘S — which hides the whole sidebar — is too coarse to be the
        // only answer.
        viewMenu.addItem(
            withTitle: "Show Table of Contents",
            action: #selector(MainWindowController.toggleTableOfContents(_:)), keyEquivalent: "t"
        ).keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())

        // M7's catalogue, in the menu bar. A group of its own because it is the
        // one item in this menu that changes how the *document* looks rather
        // than which panes are around it. Its contents are built when it opens
        // (``ThemeMenu``), so a theme dropped into `~/.config/mark/themes` is
        // listed without a relaunch — the same promise the renderer makes.
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = ThemeMenu()
        viewMenu.addItem(themeItem)
        viewMenu.addItem(.separator())

        // M8's sidebar toggles. Both are `NSMenuItem`s with a checkmark rather
        // than a preference pane, because both are things a reader flips for
        // one folder and flips back — and both are persisted, so the state has
        // to be visible somewhere.
        viewMenu.addItem(
            withTitle: "Show Non-Markdown Files",
            action: #selector(MainWindowController.toggleShowsNonMarkdownFiles(_:)),
            keyEquivalent: "")
        viewMenu.addItem(
            withTitle: "Show Hidden Files",
            action: #selector(MainWindowController.toggleShowsHiddenFiles(_:)),
            keyEquivalent: "")

        let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort By")
        for (index, sort) in TreeSort.allCases.enumerated() {
            let item = NSMenuItem(
                title: sort.menuTitle, action: #selector(MainWindowController.sortSidebar(_:)),
                keyEquivalent: "")
            item.tag = index
            sortMenu.addItem(item)
        }
        sortItem.submenu = sortMenu
        viewMenu.addItem(sortItem)

        viewMenu.addItem(
            withTitle: "Filter Files…",
            action: #selector(MainWindowController.focusSidebarFilter(_:)), keyEquivalent: "f"
        ).keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(
            withTitle: "Refresh Sidebar",
            action: #selector(MainWindowController.refreshSidebar(_:)), keyEquivalent: "")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // M8's navigator, in a Go menu — the same place Finder and every
        // browser put Back, Forward, and Enclosing Folder, so the shortcuts are
        // discoverable rather than folklore.
        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(
            withTitle: "Back", action: #selector(MainWindowController.navigateBack(_:)),
            keyEquivalent: "[")
        goMenu.addItem(
            withTitle: "Forward", action: #selector(MainWindowController.navigateForward(_:)),
            keyEquivalent: "]")
        goMenu.addItem(
            withTitle: "Enclosing Folder",
            action: #selector(MainWindowController.navigateToParent(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        goMenu.addItem(.separator())
        goMenu.addItem(
            withTitle: "Focus Path Bar",
            action: #selector(MainWindowController.focusPathBar(_:)), keyEquivalent: "p"
        ).keyEquivalentModifierMask = [.command, .option]
        goMenu.addItem(.separator())
        goMenu.addItem(
            withTitle: "Reveal in Sidebar",
            action: #selector(MainWindowController.revealInSidebar(_:)), keyEquivalent: "O"
        ).keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(
            withTitle: "Reveal in Finder",
            action: #selector(MainWindowController.revealInFinder(_:)), keyEquivalent: "r"
        ).keyEquivalentModifierMask = [.command, .option]
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let windowItem = NSMenuItem()
        let windowMenu = WindowMenu()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        WindowMenu.shared = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        windowMenu.update(with: controller.tabs)
    }

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mainWindowController?.open(url)
    }
}

/// The Window menu, including ADR-4's per-tab items.
///
/// The nine ⌘1–⌘9 items are **permanent and hidden**, not created on demand.
/// AppKit matches key equivalents against the menu's items without ever
/// opening the menu, so items conjured in `menuNeedsUpdate:` would draw
/// correctly and never fire — a bug that is invisible until someone actually
/// presses ⌘3. Hidden items are skipped by key-equivalent matching, which is
/// exactly the behaviour wanted for a position with no tab in it.
@MainActor
public final class WindowMenu: NSMenu {

    /// There is one window and therefore one Window menu (ADR-4).
    public static weak var shared: WindowMenu?

    /// The ⌘1–⌘9 block, in order.
    public private(set) var tabItems: [NSMenuItem] = []

    /// - Parameter positions: how many ⌘-number slots to reserve. Nine,
    ///   always; it is a parameter only because `init()` would override
    ///   `NSMenu.init()`, which is `nonisolated`, and this class is
    ///   `@MainActor`.
    @MainActor
    public init(positions: Int = 9) {
        super.init(title: "Window")
        addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        addItem(.separator())

        let next = addItem(
            withTitle: "Show Next Tab", action: #selector(MainWindowController.selectNextTab(_:)),
            keyEquivalent: "\t")
        next.keyEquivalentModifierMask = [.control]
        let previous = addItem(
            withTitle: "Show Previous Tab",
            action: #selector(MainWindowController.selectPreviousTab(_:)), keyEquivalent: "\t")
        previous.keyEquivalentModifierMask = [.control, .shift]
        addItem(.separator())

        for number in 1...max(1, positions) {
            let item = NSMenuItem(
                title: "Tab \(number)",
                action: #selector(MainWindowController.selectTabByNumber(_:)),
                keyEquivalent: "\(number)")
            item.tag = number
            item.isHidden = true
            addItem(item)
            tabItems.append(item)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("WindowMenu is created in code, not from a nib")
    }

    /// Retitle and show/hide the ⌘1–⌘9 block for the current tabs.
    ///
    /// ⌘9 is the **last** tab rather than the ninth, matching Safari and every
    /// browser; with fewer than nine tabs the two coincide, which is why the
    /// difference is easy to miss and worth stating.
    public func update(with store: TabStore) {
        for (offset, item) in tabItems.enumerated() {
            let number = offset + 1
            let tab: DocumentTab?
            if number == 9 {
                tab = store.count >= 9 ? store.tabs.last : nil
            } else {
                tab = store.tabs.indices.contains(offset) ? store.tabs[offset] : nil
            }
            item.isHidden = tab == nil
            item.title = tab.map { TabBarView.menuTitle(for: $0) } ?? "Tab \(number)"
            item.state = (tab != nil && tab == store.selected) ? .on : .off
        }
    }
}
