import AppKit
import Foundation

/// `mark`'s window. There is exactly one.
///
/// ADR-4 constraint, quoted because it is easy to violate by accident:
///
/// > **There is exactly one `NSWindow` and one `NSWindowController`.** Anything
/// > wanting a second top-level window (preferences, a detached document) is a
/// > new decision, not an extension of this one.
/// >
/// > **Never call `addTabbedWindow` or set `tabbingMode = .preferred`.** Mixing
/// > native tabbing into this design produces two competing tab bars. Set
/// > `tabbingMode = .disallowed` explicitly so AppKit does not add one.
///
/// M2 built the split view and the shared sidebar. M3 adds the document area's
/// other half: a ``TabBarView`` above a container of resident ``DocumentView``s,
/// one per hydrated tab, switched by show/hide. This controller is both the
/// ``TabStore``'s ``TabHydrator`` — the only place a tab's web view is made or
/// unmade — and its ``TabStoreDelegate``.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate {

    public let sidebar: TreeViewController

    /// The document pane's Contents tab: the front document's headings,
    /// clickable.
    public let toc: TableOfContentsViewController

    /// The document pane's Tasks tab: the front document's tasks, grouped by
    /// state and clickable (`2026-08-28-tabbed-document-pane`).
    public let taskList: TaskListViewController

    /// The two tabs, and the control that chooses between them.
    public let documentPane: DocumentPaneController

    /// The tree and the document pane, stacked. One sidebar still, as ADR-4
    /// requires.
    public let sidebarPane: SidebarPaneController

    /// This window's editor groups: one, or two when split
    /// (`2026-08-26-editor-groups-per-pane-tab-bars`).
    public let groups: TabGroups

    /// The focused group's documents.
    ///
    /// Deliberately still called `tabs`, and still the thing every menu item,
    /// the window title, the find bar, the editor binding and every socket
    /// command mean. With one group this is exactly what it always was; with
    /// two, "the tabs" is a question about the focused group and this is the
    /// answer. It is what keeps the ~40 call sites that ask for `tabs.selected`
    /// from each having to decide which group they meant.
    public var tabs: TabStore { groups.focused }

    /// The focused group's tab bar.
    public var tabBar: TabBarView { area(at: groups.focusIndex).tabBar }

    /// Where the focused group's resident web views live.
    public var documentContainer: DocumentContainerView { area(at: groups.focusIndex).container }

    /// One area per group: a tab bar with that group's documents under it.
    ///
    /// Parallel to ``TabGroups/groups`` by index, and rebuilt whenever the
    /// arrangement changes. Kept as its own array rather than hung off the
    /// stores so that a store — which knows nothing about AppKit — stays that
    /// way.
    public private(set) var areas: [DocumentAreaView] = []

    /// The areas side by side, with the divider between them.
    public let groupSplit: GroupSplitView

    /// ⌘F, for the document in the focused group.
    ///
    /// The query, the generation counter and the four `NSTextFinder` actions
    /// live in ``DocumentFinder`` since
    /// `2026-08-26-markdown-reference-window` gave the markdown reference its
    /// own window: two surfaces now show a document, and one copy of a race
    /// that only appears under load is enough.
    public let finder: DocumentFinder

    /// ⌘F's bar, along the bottom of the preview. Hidden until asked for.
    public var findBar: FindBar { finder.bar }

    /// The stacked web views with the find bar under them — the preview column
    /// of ``editorSplit``.
    public let previewPane: PreviewPaneView

    /// M9's third pane: the markdown source of the selected tab.
    ///
    /// One pane, rebound on every tab switch, rather than one per tab — see
    /// ``EditorPane`` for why, and for how per-document undo survives the
    /// sharing.
    public let editor: EditorPane

    /// The preview and the editor, side by side, below the tab bar.
    public let editorSplit: NSSplitView

    /// ADR-6's *"we prompt and never guess"*, and the state machine behind it.
    public let conflicts: ConflictController

    /// The two debounces every buffer this window makes is given.
    ///
    /// Overridable so a test can assert *ordering* — nothing before the
    /// debounce, everything after it — without spending 800 ms per assertion,
    /// and so `mark-bench` can run its 60-second typing gate at a realistic
    /// cadence rather than a punitive one. Production is ADR-6's 800 ms.
    public var bufferDebounces: (autosave: TimeInterval, preview: TimeInterval) = (
        Buffer.autosaveDebounce, Buffer.previewDebounce
    )

    /// How many external changes the watcher has delivered to this window.
    ///
    /// Instrumentation, and the only honest way to assert ADR-6's *"our own
    /// saves never trigger a re-render"*: the property is that the watcher
    /// **does not report** our write, and a counter of patches cannot tell
    /// "suppressed" from "reported and coalesced". Also the number to ask for
    /// when someone says the preview flickers while they type.
    public private(set) var externalChangesSeen = 0

    private let splitViewController: NSSplitViewController
    private let session: Session

    /// Where this window records the files it opens
    /// (`2026-08-26-opened-file-history`).
    ///
    /// A `var` rather than a `let`, so ``WindowCoordinator/adopt(_:)`` can
    /// re-point a window built directly at the coordinator's history — the same
    /// shape as ``TabStore``'s `governor`.
    ///
    /// **The default is a private history, not a shared one.** A window built
    /// outside a coordinator — `mark-bench`, most tests — records into
    /// something that goes nowhere, which is what keeps a test run out of the
    /// developer's real history; ``OpenHistory`` explains why that matters.
    /// Never optional, though: a window whose opens go unrecorded because a
    /// reference was `nil` is a bug that looks exactly like the feature not
    /// working.
    public var history: OpenHistory = OpenHistory()

    /// The other windows, and the shared session file.
    ///
    /// `nil` for a controller built directly rather than through
    /// ``WindowCoordinator/makeWindow(root:collapsedSidebar:)`` — `mark-bench`
    /// and most tests — which is why every use of it here has a single-window
    /// fallback. Weak: the coordinator owns the controllers, not the reverse.
    public weak var windows: WindowCoordinator?

    /// The sidebar's split item, kept so the pane can be collapsed on a
    /// popped-out window without going through the menu action.
    private let sidebarItem: NSSplitViewItem

    /// ADR-2's file watcher, for every open document at once.
    ///
    /// It lives here rather than on ``DocumentView`` for the reason ADR-4
    /// states as a constraint: *"no feature may assume a tab's web view
    /// exists"*. A dehydrated tab has no `DocumentView` to own a watcher, and
    /// its badge still has to be right — so the watcher is owned by the thing
    /// that outlives hydration, and a change to a dehydrated tab's file updates
    /// its metadata through the core without a DOM being involved at all.
    private var watcher: FileWatcher!

    /// The selected tab's view, or `nil` when nothing is open.
    ///
    /// Optional on purpose. In M2 this was a stored, always-present property;
    /// under ADR-4 there is no such thing, because a window with no tabs has no
    /// web view at all and a dehydrated tab has none either. Callers that
    /// force-unwrapped it would be the first instance of the "assumes a tab's
    /// web view exists" bug the ADR warns about.
    public var documentView: DocumentView? { tabs.selected?.documentView }

    /// - Parameter preferences: where the document pane's tab is remembered.
    ///   Injectable for the reason ``session`` is: it is a real user preference
    ///   (`2026-08-28-tabbed-document-pane`), and a test run must not rewrite
    ///   the developer's own.
    public init(
        root: URL, session: Session = Session(), history: OpenHistory = OpenHistory(),
        preferences: UserDefaults = .standard
    ) {
        self.session = session
        self.history = history
        sidebar = TreeViewController(root: root)
        toc = TableOfContentsViewController()
        taskList = TaskListViewController()
        documentPane = DocumentPaneController(
            contents: toc, taskList: taskList, defaults: preferences)
        sidebarPane = SidebarPaneController(tree: sidebar, documentPane: documentPane)
        groups = TabGroups()
        groupSplit = GroupSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

        editor = EditorPane(frame: NSRect(x: 0, y: 0, width: 380, height: 700))
        // Hidden by default: ADR-6 says *"the pane is collapsible and hidden by
        // default; a document opens read-only until the user asks to edit it"*.
        editor.isHidden = true
        conflicts = ConflictController()

        finder = DocumentFinder(width: 900)
        previewPane = PreviewPaneView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            findBar: finder.bar,
            container: groupSplit
        )

        editorSplit = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        editorSplit.isVertical = true
        editorSplit.dividerStyle = .thin
        editorSplit.addSubview(previewPane)
        editorSplit.addSubview(editor)

        let body = WindowBodyView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            content: editorSplit
        )

        let documentController = NSViewController()
        documentController.view = body

        let splitViewController = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarPane)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 480
        sidebarItem.canCollapse = true
        let documentItem = NSSplitViewItem(viewController: documentController)
        documentItem.minimumThickness = 320
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(documentItem)
        self.splitViewController = splitViewController
        self.sidebarItem = sidebarItem

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = splitViewController
        window.title = "mark"
        window.titlebarAppearsTransparent = false
        window.setFrameAutosaveName("dev.mark.MainWindow")
        window.minSize = NSSize(width: 640, height: 400)

        // ADR-4. Not `.automatic` (which lets a user's "Prefer tabs: always"
        // System Settings preference add a native tab bar), and never
        // `.preferred`.
        window.tabbingMode = .disallowed

        // ADR-4: *"Session state lives in our own file, not
        // `NSWindowRestoration`."* Turning AppKit's mechanism off is what makes
        // "deterministic regardless of the user's Close-windows-when-quitting
        // setting" true rather than merely intended — otherwise both mechanisms
        // restore, and which one wins depends on that very setting.
        //
        // The other half of that constraint — *"`NSQuitAlwaysKeepsWindows` is a
        // user preference we must not write"* — is enforced by not writing it,
        // here or anywhere, and asserted in `SessionTests`.
        window.isRestorable = false

        super.init(window: window)
        window.delegate = self
        editorSplit.delegate = self
        conflicts.use(presenter: AlertConflictPresenter(window: window))

        // Before the store gets a delegate, so no tab can exist — and therefore
        // no `tabStoreDidChangeTabs` can reach ``syncWatchedFiles()`` — while
        // this is still nil.
        watcher = FileWatcher { [weak self] change in
            self?.documentChangedOnDisk(change)
        }
        // Before any group can exist, so a store made by a split arrives wired
        // rather than being wired by whoever remembered to.
        groups.delegate = self
        groups.configureStore = { [weak self] store in
            store.delegate = self
            store.hydrator = self
        }
        groups.configureStore?(groups.focused)
        rebuildAreas()
        // Single click skims, double click keeps — VS Code's preview tab, and
        // the reason clicking down a directory of notes leaves one tab rather
        // than one per file. The two callbacks differ only in that flag; both
        // go through the same ``TabStore/open(_:preview:)``.
        sidebar.onSelect = { [weak self] url in
            self?.open(url, preview: true)
        }
        sidebar.onActivate = { [weak self] url in
            self?.open(url)
        }
        sidebar.onNewDocument = { [weak self] directory in
            self?.newDocument(in: directory)
        }
        // M8: the root, the history, and the two listing toggles all live in
        // the session file, so anything that moves them schedules a save.
        sidebar.onStateChange = { [weak self] in
            self?.saveSessionSoon()
        }
        // ADR-6: *"nothing may read the file for […] task counts […] on a
        // dirty tab"*. The sidebar's badge is a task count computed from a file
        // read, so it asks here first and counts the buffer's tasks instead.
        sidebar.badges.dirtySource = { [weak self] url in
            self?.tab(for: url)?.authoritativeSource
        }
        // The same hook, for the same rule, and it matters more here: `+12 −3`
        // claims to say how far this file is from what is committed, so
        // answering it from disk while the reader has unsaved edits answers a
        // different question. Bounded by the number of dirty tabs.
        sidebar.gitBadges.dirtySource = { [weak self] url in
            self?.tab(for: url)?.authoritativeSource
        }
        body.onDrop = { [weak self] urls in
            self?.sidebar.handleDrop(urls) ?? false
        }
        groupSplit.onSplitFractionChanged = { [weak self] fraction in
            self?.groups.splitFraction = fraction
            self?.saveSessionSoon()
        }
        // Picking a heading scrolls the preview to it — the sidebar's other
        // half answers "which file", this one answers "where in it".
        toc.onSelect = { [weak self] heading in
            self?.scrollToHeading(heading)
        }
        // The other tab of the same pane, answering the same question about the
        // same document: where in it. It navigates and never writes — ticking a
        // box stays in the preview and in `mark check`
        // (`2026-08-28-tabbed-document-pane`).
        taskList.onSelect = { [weak self] task in
            self?.scrollToTask(task)
        }
        // The tab that is about to appear has not been fed while it was off
        // screen — see ``updateDocumentPane()`` for the measurement that made
        // that the rule.
        documentPane.onNeedsContent = { [weak self] in
            self?.updateDocumentPane()
        }
        // The focused group's document, asked for freshly every time: which
        // one that is changes with the selection, with the focus moving between
        // panes, and with ADR-4 tearing a web view down underneath it.
        finder.documentView = { [weak self] in self?.documentView }
        finder.hasDocument = { [weak self] in self?.tabs.selected != nil }
        finder.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            // The bar is a child of the preview pane, and the pane gives it its
            // frame — so the pane is what has to lay out, synchronously, before
            // anything reads the bar's geometry or puts the caret in it.
            self.previewPane.needsLayout = true
            self.previewPane.layoutSubtreeIfNeeded()
            // Closing hands the keyboard back to the document rather than
            // leaving it on a field that is no longer on screen.
            if !visible, let webView = self.documentView?.webView {
                self.window?.makeFirstResponder(webView)
            }
        }
        tabBar.reload()
        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, not from a nib")
    }

    // MARK: - Documents

    /// Show a document: select the tab already on it, or open a new one.
    ///
    /// `preview` is the sidebar's single click and nothing else. Every other
    /// route in — ⌘T, a drop on the window, `mark open`, `mark://`, a double
    /// click in the tree — opens a permanent tab, because each of them is
    /// already the user naming a file rather than browsing past it.
    public func open(_ url: URL, preview: Bool = false) {
        Log.app.info(
            "open \(url.lastPathComponent, privacy: .public)\(preview ? " (preview)" : "", privacy: .public)"
        )
        openInFocusedGroup(url, preview: preview)
    }

    /// Open `url` in the focused group — unless it is already open in the other
    /// one, in which case go there.
    ///
    /// **The window-level half of "a document is open in at most one place"**
    /// (`2026-08-26-editor-groups-per-pane-tab-bars`). ``TabStore/open(_:)``
    /// re-selects a document it already holds, but a store only knows its own
    /// group: with two of them, every route in — the sidebar, ⌘T, a drop,
    /// `mark open`, `mark://`, a file opened by LaunchServices at launch —
    /// would otherwise make a second tab and a second `WKWebView` for a
    /// document already on screen in the other half of the window. That is
    /// ~52 MB and two DOMs for one file, which the ADR forbids outright.
    ///
    /// Found in the other group, this focuses it there rather than refusing:
    /// the reader asked to see a document, and it is already visible.
    @discardableResult
    func openInFocusedGroup(_ url: URL, preview: Bool = false) -> DocumentTab {
        let standardized = url.standardizedFileURL

        // **The one place the opened-file history is written**
        // (`2026-08-26-opened-file-history`). This method is the funnel every
        // route in already passes through — the sidebar, ⌘O and ⌘T's panel, a
        // drop, `mark open`, a `mark://` URL, LaunchServices at launch, File ▸
        // New Document — which is why the history costs one call rather than
        // one per route, and why a route added later records by construction.
        //
        // Two things about the placement are deliberate:
        //
        // * **`!preview`.** The sidebar's single click is a skim, and
        //   `TabStore.open` already models a skim as not the same act as
        //   opening. Clicking down forty files leaves one tab; it leaves no
        //   history. A double click, or `mark open` on the file being skimmed,
        //   arrives here with `preview: false` and *is* recorded — that is the
        //   moment the reader named the file.
        // * **Above the branch below, not after it.** Being sent to a document
        //   already open in the other group is still the reader asking to open
        //   it, so it moves to the front of the history like any other open.
        //
        // Session restore does **not** reach here — `TabStore.restore(_:)`
        // builds tabs directly — and `OpenHistory` explains why that is a rule
        // rather than an accident.
        if !preview { history.record(standardized) }

        if let existing = tab(for: standardized),
            groups.group(of: existing) !== groups.focused
        {
            Log.tabs.info(
                "\(existing.title, privacy: .public) is already open in the other group; going there"
            )
            select(existing)
            return existing
        }
        return tabs.open(url, preview: preview)
    }

    /// Move the focus to whichever group holds `tab`.
    ///
    /// The destination of ``DocumentView/onFocus``: the reader clicked into a
    /// document, and the window has to decide that document's group is now the
    /// one the menus, the find bar and the editor act on.
    func focusGroup(holding tab: DocumentTab) {
        guard let index = groups.index(of: tab) else { return }
        groups.focus(index)
    }

    /// The area for the group at `index`.
    ///
    /// Clamped rather than trapping: `areas` is rebuilt from ``groups`` on every
    /// arrangement change, and a caller asking during that rebuild should get
    /// the window's remaining group rather than a crash.
    func area(at index: Int) -> DocumentAreaView {
        areas[min(max(0, index), areas.count - 1)]
    }

    /// Select `tab` in whichever group holds it, and act on that group.
    ///
    /// The window-level counterpart to ``TabStore/select(_:)``: a command or a
    /// menu item naming a document in the other half of a split means "show me
    /// that", and showing it without moving the focus would leave the next
    /// action landing in the group the reader is no longer looking at.
    public func select(_ tab: DocumentTab) {
        guard let index = groups.index(of: tab) else { return }
        groups.focus(index)
        groups.groups[index].select(tab)
    }

    /// Close `tab` in whichever group holds it.
    public func close(_ tab: DocumentTab) {
        groups.group(of: tab)?.close(tab)
    }

    /// The tab open on `url` **anywhere in this window**, in either group.
    ///
    /// Every socket command, the sidebar's dirty-source lookup and the watcher
    /// all ask this rather than the focused group: a document open in the other
    /// half of a split is open in this window, and answering "no tab is open on
    /// that" about a document plainly on screen is the confusion
    /// `2026-08-26-editor-groups-per-pane-tab-bars` has to avoid.
    public func tab(for url: URL) -> DocumentTab? {
        let standardized = url.standardizedFileURL
        return groups.allTabs.first { $0.url == standardized }
    }

    /// The container the group holding `tab` draws into.
    func container(for tab: DocumentTab) -> DocumentContainerView {
        guard let index = groups.index(of: tab) else { return documentContainer }
        return area(at: index).container
    }

    /// Rebuild one area per group, keeping the areas that already exist.
    ///
    /// Kept rather than remade, because an area owns a
    /// ``DocumentContainerView`` full of resident web views: rebuilding it would
    /// dehydrate every document in the group to reparent them, which is ~4.7 ms
    /// each and loses their DOM — for a divider moving.
    private func rebuildAreas() {
        areas = groups.groups.map { store in
            if let existing = areas.first(where: { $0.tabBar.store === store }) { return existing }
            return makeArea(for: store)
        }
        groupSplit.show(areas)
        groupSplit.splitFraction = groups.splitFraction
        refreshAreas()
    }

    /// Point every area at its group's current selection and focus state.
    private func refreshAreas() {
        for (index, store) in groups.groups.enumerated() where areas.indices.contains(index) {
            let area = areas[index]
            area.tabBar.isActive = index == groups.focusIndex
            area.tabBar.reload()
            let bar = store.isEmpty
            if area.tabBar.isHidden != bar {
                area.tabBar.isHidden = bar
                area.needsLayout = true
            }
            area.container.show(store.selected?.documentView)
        }
        groupSplit.needsLayout = true
    }

    private func makeArea(for store: TabStore) -> DocumentAreaView {
        let bar = TabBarView(store: store)
        bar.onFocusRequested = { [weak self, weak store] in
            guard let self, let store else { return }
            self.groups.focus(store)
        }
        bar.onDragOut = { [weak self] tab, locationInWindow in
            self?.moveTabByDrag(tab, to: locationInWindow) ?? false
        }
        let container = DocumentContainerView(
            frame: NSRect(x: 0, y: 0, width: 450, height: 700))
        container.onFocusRequested = { [weak self, weak store] in
            guard let self, let store else { return }
            self.groups.focus(store)
        }
        return DocumentAreaView(tabBar: bar, container: container)
    }

    /// A tab dropped out of its bar. Moves it if the drop landed in the other
    /// group's half of the split.
    private func moveTabByDrag(_ tab: DocumentTab, to locationInWindow: NSPoint) -> Bool {
        guard groups.isSplit, let source = groups.index(of: tab) else { return false }
        let point = groupSplit.convert(locationInWindow, from: nil)
        guard let target = groupSplit.areaIndex(at: point), target != source else { return false }
        guard groups.moveToOtherGroup(tab) else { return false }
        saveSessionSoon()
        return true
    }

    /// Point the sidebar somewhere else, recording it in the history.
    public func setSidebarRoot(_ url: URL) {
        sidebar.navigate(to: url)
        saveSessionSoon()
    }

    public func showWindow(activating: Bool) {
        showWindow(nil)
        if activating {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Whether the sidebar pane is collapsed.
    public var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// Show or hide the sidebar without going through the menu action.
    ///
    /// A popped-out window starts collapsed: it exists to show one document,
    /// and arriving with a file tree open would make it a second copy of the
    /// window it came from rather than the detached view that was asked for.
    /// ⌃⌘S still brings it back, which is why this is a starting state rather
    /// than a property of the window.
    public func setSidebarCollapsed(_ collapsed: Bool) {
        sidebarItem.isCollapsed = collapsed
    }

    /// Give up everything this window holds on `tab`, short of its contents.
    ///
    /// Called before a tab is moved to another window. It does **not** touch
    /// the `Buffer`: that travels with the tab, unsaved text, `flock(2)` lock
    /// and all, which is the entire difference between moving a tab and closing
    /// one. What it drops is the machinery that is this *window's* — the
    /// conflict prompt that would otherwise be presented on a sheet over a
    /// window no longer showing the document, and the editor pane's binding to
    /// a buffer it is about to stop being responsible for.
    func releaseClaims(on tab: DocumentTab) {
        conflicts.cancel(for: tab.url)
        if let buffer = tab.buffer {
            editor.forget(buffer)
        }
    }

    // MARK: - Watching

    /// Watch exactly the files that are open, and nothing else.
    ///
    /// Driven from ``tabStoreDidChangeTabs(_:)`` rather than from open/close,
    /// so a tab that appears by any route — the sidebar, ⌘T, `mark open`,
    /// `mark://`, session restore — is watched by construction and there is no
    /// second list to forget to update.
    func syncWatchedFiles() {
        // Every group's documents, not the focused one's: a file open in the
        // other half of a split is on screen, and a window that stopped
        // watching it would show a stale document with no way to know.
        watcher.setWatched(Set(groups.allTabs.map(\.url)))
    }

    /// A watched file changed on disk.
    ///
    /// Two effects, and the split between them is ADR-4's constraint:
    ///
    /// * **The badge always updates**, through the core against the bytes on
    ///   disk. This works identically whether or not the tab has a web view,
    ///   which is the whole point — *"anything operating across all open
    ///   documents goes through the core against the file on disk"*.
    /// * **The document is patched only if it is hydrated.** A dehydrated tab
    ///   has no DOM to patch, and hydrating one because a file changed would
    ///   spend ~52 MB on a document nobody is looking at. It re-reads on
    ///   rehydration anyway.
    private func documentChangedOnDisk(_ change: FileChange) {
        externalChangesSeen += 1
        let url = change.url.standardizedFileURL
        let matching = groups.allTabs.filter { $0.url == url }
        guard !matching.isEmpty else {
            // The tab closed between the scan and this hop to the main actor.
            Log.watch.debug("change for \(url.lastPathComponent, privacy: .public); no tab open")
            return
        }

        switch change {
        case .vanished:
            // Not an error and not a close: the file may be mid-`git checkout`.
            // The tab keeps its last render and its last known badge.
            Log.watch.info(
                "\(url.lastPathComponent, privacy: .public) is gone; keeping the last render")

        case .changed(_, let source, let hash):
            Log.watch.info(
                "\(url.lastPathComponent, privacy: .public) changed on disk (\(source.utf8.count) bytes, \(hash.prefix(8), privacy: .public)); \(matching.count) tab(s)"
            )
            // The sidebar's badge for this file is now stale too, and it is a
            // different cache from the tab's: one is per open tab, the other is
            // per visible row, and a file can be in either, both, or neither.
            sidebar.invalidateBadge(for: url)
            for tab in matching {
                // M9's fork in the road, and the one place it can be got wrong
                // quietly. A tab with a buffer decides for itself what an
                // external change means: ours, adopted, converged, or a
                // conflict. A tab without one behaves exactly as it did in M5.
                if let buffer = tab.buffer {
                    let outcome = buffer.fileChanged(source: source, hash: hash)
                    switch outcome {
                    case .ours:
                        // Our own autosave, seen anyway — the watcher's
                        // suppression should already have eaten it, so this is
                        // the second line of defence and worth saying out loud.
                        Log.watch.info(
                            "\(url.lastPathComponent, privacy: .public): a change matching our own write reached the buffer; not re-rendering"
                        )
                        continue
                    case .conflicted:
                        // The preview keeps showing the buffer: while dirty,
                        // the buffer is truth, and the file's version is not
                        // rendered anywhere until the user asks for it.
                        tab.refreshMetadata { [weak self] in
                            self?.metadataDidChange(of: tab)
                        }
                        continue
                    case .adopted, .converged:
                        // `adopted` has already pushed the text into the editor
                        // through `onChange`; both need the preview and the
                        // badge brought up to date, which the code below does.
                        break
                    }
                }

                tab.refreshMetadata { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.metadataDidChange(of: tab)
                }
                guard let view = tab.documentView else {
                    Log.watch.debug(
                        "\(url.lastPathComponent, privacy: .public) is dehydrated; badge only, no DOM touched"
                    )
                    continue
                }
                _Concurrency.Task { @MainActor [weak self] in
                    await view.apply(source: source)
                    self?.refreshFind()
                }
            }
        }
    }

    // MARK: - Editing (M9)

    /// Whether the third pane is on screen.
    public var isEditorVisible: Bool { !editor.isHidden }

    /// Show or hide the editor for the selected tab.
    ///
    /// Opening it is what creates the tab's ``Buffer`` — ADR-6's *"a document
    /// opens read-only until the user asks to edit it"*. Hiding the pane does
    /// **not** discard the buffer: unsaved text does not stop existing because
    /// a view was collapsed, and the tab stays dirty, stays exempt from
    /// eviction, and keeps autosaving.
    public func setEditorVisible(_ visible: Bool) {
        guard visible != isEditorVisible else { return }
        editor.isHidden = !visible
        if visible {
            if let tab = tabs.selected {
                bindEditor(to: tab)
            }
            // A first opening with no divider position yet: give the editor a
            // sensible share rather than whatever `adjustSubviews` invents.
            if editor.frame.width < 80 {
                let width = editorSplit.bounds.width
                editorSplit.setPosition(width * 0.55, ofDividerAt: 0)
            }
        } else {
            editor.window?.makeFirstResponder(nil)
        }
        editorSplit.adjustSubviews()
        editorSplit.needsLayout = true
        Log.app.info("editor pane \(visible ? "shown" : "hidden")")
    }

    /// The buffer for `tab`, made on first use.
    ///
    /// Every wire between a buffer and the rest of the app is tied here, in one
    /// place, so "did we remember to tell the watcher about our own write?" has
    /// exactly one answer rather than one per call site.
    @discardableResult
    public func buffer(for tab: DocumentTab) -> Buffer? {
        if let existing = tab.buffer { return existing }
        let buffer: Buffer
        do {
            buffer = try Buffer.open(
                url: tab.url,
                autosaveDelay: bufferDebounces.autosave,
                previewDelay: bufferDebounces.preview
            )
        } catch {
            Log.core.error(
                "\(tab.url.lastPathComponent, privacy: .public) cannot be edited: \(String(describing: error), privacy: .public)"
            )
            return nil
        }

        tab.attach(buffer: buffer)
        wire(buffer, to: tab)
        // The checkbox seam: from here on a click on this tab's preview goes to
        // the buffer while dirty and to the file while clean, decided per
        // click rather than by a flag.
        tab.documentView?.taskWriter = BufferTaskWriter(buffer: buffer)
        Log.app.info(
            "editing \(tab.url.lastPathComponent, privacy: .public) (\(buffer.text.utf8.count) bytes)"
        )
        return buffer
    }

    /// Every wire between a buffer and this window, in one place.
    ///
    /// Extracted from ``buffer(for:)`` so that a tab arriving from another
    /// window through ``adopt(_:for:)`` is re-wired identically rather than
    /// through a second copy that can drift.
    ///
    /// **`onWillWrite` is the one that fails silently.** Every closure here
    /// captures `self`; miss the re-wire and most of them merely update the
    /// wrong window's chrome. That one tells the `FileWatcher` the hash of what
    /// we are about to write, and left pointing at the old window's watcher the
    /// new window sees its own autosave as an external change and re-renders
    /// the document under the reader's caret 800 ms after they stop typing.
    private func wire(_ buffer: Buffer, to tab: DocumentTab) {
        buffer.onWillWrite = { [weak self] contents in
            // ADR-6: *"Every write records its content hash, and the watcher
            // suppresses matches."* This is that. Before the write, so a fast
            // FSEvents delivery cannot arrive at a watcher that has not been
            // told yet — the failure mode is a re-render under the cursor.
            self?.watcher.noteWrittenContent(contents, to: tab.url)
        }
        buffer.onPreviewDue = { [weak self, weak tab] source in
            guard let self, let tab else { return }
            self.updatePreview(of: tab, from: source)
        }
        buffer.onDirtyChanged = { [weak self, weak tab] isDirty in
            guard let self, let tab else { return }
            // Typing into a preview tab keeps it. Anything else would let the
            // next click in the sidebar throw away a document the user is in
            // the middle of writing — and ADR-4 exempts a dirty tab from
            // eviction for the same reason, so a preview tab that stayed a
            // preview tab would be the one place that promise leaked.
            if isDirty { self.tabs.promote(tab) }
            self.tabBar.reload()
            // The sidebar's badge for this file now comes from the buffer (or
            // stops doing so), so the cached one is wrong either way.
            self.sidebar.invalidateBadge(for: tab.url)
            tab.refreshMetadata { [weak self] in self?.metadataDidChange(of: tab) }
        }
        buffer.onSaved = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            self.sidebar.invalidateBadge(for: tab.url)
            tab.refreshMetadata { [weak self] in self?.metadataDidChange(of: tab) }
        }
        buffer.onConflict = { [weak self, weak buffer] conflict in
            guard let self, let buffer else { return }
            self.conflicts.handle(conflict, for: buffer)
        }
        buffer.onChange = { [weak self, weak buffer] origin in
            guard let self, let buffer else { return }
            // "Take theirs" and a clean tab following the disk both replace the
            // text underneath the caret; the editor has to be told, and only
            // for the buffer it is actually showing.
            if origin == .external, self.editor.buffer === buffer {
                self.editor.adoptExternalText(buffer.text)
            }
        }
    }

    private func bindEditor(to tab: DocumentTab) {
        guard isEditorVisible else { return }
        guard let buffer = buffer(for: tab) else { return }
        editor.bind(buffer)
    }

    /// Bring the preview up to date from the buffer.
    ///
    /// The one place the preview is fed while a tab is dirty, and it feeds it
    /// the **buffer**, never the file.
    private func updatePreview(of tab: DocumentTab, from source: String) {
        // The document pane is a function of the document, so it has to move
        // when the document does. This is the only edit path that changes the
        // headings and the tasks without changing dirtiness — `onDirtyChanged`
        // catches the first keystroke and the save, and every keystroke in
        // between lands here. It costs the same background `mark_tasks_json`
        // call the tab bar's badge already pays for, against the buffer rather
        // than the file.
        tab.refreshMetadata { [weak self] in
            self?.metadataDidChange(of: tab)
        }
        guard let view = tab.documentView else {
            // ADR-6's last constraint: *"the editor pane must not assume a
            // `WKWebView` exists"*. There is nothing to patch, and the tab
            // re-renders from the buffer when it rehydrates.
            return
        }
        _Concurrency.Task { @MainActor [weak self] in
            await view.apply(source: source)
            // The patch replaced block elements, and every find range pointed
            // into one of them.
            self?.refreshFind()
        }
    }

    /// Write every dirty buffer now.
    ///
    /// The quit path, and ⌘S's "all documents" half. Synchronous, because
    /// `applicationWillTerminate` has no runloop left to await on: this is what
    /// bounds ADR-6's exposure to *"at most the last 800 ms"*.
    @discardableResult
    public func flushDirtyBuffers() -> Int {
        var saved = 0
        // Every group, because unsaved work is not a question about which half
        // of the window is being looked at.
        for tab in groups.allTabs {
            guard let buffer = tab.buffer, buffer.isDirty else { continue }
            if buffer.isConflicted {
                // Never resolve a conflict by writing — not even at quit.
                Log.core.error(
                    "\(tab.url.lastPathComponent, privacy: .public) has an unresolved conflict; leaving the file as it is"
                )
                continue
            }
            if buffer.save() { saved += 1 }
        }
        if saved > 0 { Log.core.info("flushed \(saved) dirty buffer(s)") }
        return saved
    }

    // MARK: - The document pane

    /// Whether the document pane is on screen showing `mode`.
    public func documentPaneIsShowing(_ mode: DocumentPaneController.Mode) -> Bool {
        sidebarPane.isDocumentPaneVisible && documentPane.mode == mode
    }

    /// Show the selected document in both tabs of the sidebar's lower half.
    ///
    /// Called from ``updateChrome()``, which is the one place that already runs
    /// on every tab switch, every tab-list change, and every metadata load —
    /// so there is no second list of "things that should also refresh the
    /// document pane" to forget to update. Both children compare before they
    /// rebuild, so calling this often costs two array comparisons rather than a
    /// reload.
    ///
    /// Only the tab on screen is fed, and the reason is measured: on
    /// `bench/corpus/1mb.md` (1,787 tasks) a rebuild of the Tasks tab costs
    /// 1.9 ms to group plus an outline reload of ~1,800 rows, and a tab switch
    /// would pay it whether or not anyone was looking at that tab. (It is *not*
    /// what makes `mark-bench`'s `full select` gate fail; that reads the same
    /// with either feeding strategy.) ``DocumentPaneController/onNeedsContent``
    /// fills the other tab at the moment it becomes visible — before it is
    /// installed, so no frame of the previous document is ever shown.
    private func updateDocumentPane() {
        let tab = tabs.selected
        switch documentPane.mode {
        case .contents:
            toc.show(tab?.metadata?.headings ?? [], for: tab?.url)
        case .tasks:
            taskList.show(
                tab?.metadata?.tasks ?? [],
                counts: tab?.metadata?.taskCounts ?? .empty,
                for: tab?.url)
        }
    }

    /// The one completion for a metadata refresh.
    ///
    /// Anything fed by `DocumentMetadata` is brought up to date here or it is
    /// brought up to date nowhere. `2026-08-28-tabbed-document-pane` names the
    /// five call sites that used to reload only the tab bar — the watcher, the
    /// buffer going dirty, the save, and ⌘R — and the Tasks tab going stale
    /// after a checkbox click is what turned that from a latent bug into a
    /// visible one: a click writes one byte to the file, and the pane's own
    /// numbers come back through the watcher.
    private func metadataDidChange(of tab: DocumentTab) {
        // The bar of the group that *owns* this tab, not the focused one: a
        // background tab in the other half of a split has a badge too, and
        // reloading the focused bar for it would redraw the wrong documents and
        // leave the right ones stale. A tab in no group has no badge anywhere,
        // so there is nothing to reload for it.
        if let index = groups.index(of: tab), areas.indices.contains(index) {
            areas[index].tabBar.reload()
        }
        // The pane draws the *selected* document, so a background tab's refresh
        // changes nothing in it.
        if tab === tabs.selected { updateDocumentPane() }
    }

    /// Scroll the preview to `heading`.
    ///
    /// The same path `mark goto` takes — `shell.js`'s `scrollToAnchor`, which
    /// forces ADR-2's background fill first, because a heading three quarters
    /// of the way down a long document is not in the DOM until it does.
    ///
    /// Focus deliberately stays where it was. Clicking a heading and having the
    /// window take the focus away would mean ↑/↓ stopped walking the outline
    /// after the first use, which is the opposite of what a table of contents
    /// is for.
    public func scrollToHeading(_ heading: Heading) {
        guard let view = documentView else { return }
        Log.app.info("goto #\(heading.anchor, privacy: .public)")
        _Concurrency.Task { @MainActor in
            _ = try? await view.scrollToAnchor(heading.anchor)
        }
    }

    /// Scroll the preview to `task`.
    ///
    /// Identified by its marker's byte offset, with the task index as the
    /// fallback (`2026-08-28-tabbed-document-pane`): the pane's list comes from
    /// the core's parse of the bytes and the page's `data-mk-idx` comes from the
    /// last render of them, and for the moment between a metadata refresh and a
    /// re-render those can be two different sets of bytes. The offset is the
    /// identity the write path already re-verifies against; an index alone would
    /// land on the wrong item exactly then.
    ///
    /// A dehydrated tab has no view and nothing to scroll — the pane still
    /// listed the task correctly, which is the point of feeding it from
    /// metadata. Focus stays in the pane, as it does for a heading.
    public func scrollToTask(_ task: Task) {
        guard let view = documentView else { return }
        Log.app.info("goto task \(task.index) @\(task.start)")
        _Concurrency.Task { @MainActor in
            let found = (try? await view.scrollToTask(index: task.index, byteOffset: task.start))
            if found != true {
                // Not an error: the page is rendered from bytes that no longer
                // hold this task, and the watcher is already on its way with
                // the ones that do.
                Log.app.info("task \(task.index) @\(task.start) is not in the rendered page")
            }
        }
    }

    // MARK: - Finding in the document

    /// Everything below forwards to ``finder``.
    ///
    /// Kept as this window's own surface rather than pushed onto callers,
    /// because `FindTests` is written against exactly these names and is the
    /// check that lifting the implementation out changed no behaviour.
    public var isFindBarVisible: Bool { finder.isVisible }

    /// Show or hide ⌘F's bar.
    public func setFindBarVisible(_ visible: Bool) {
        finder.setVisible(visible)
    }

    /// ⌘F.
    public func showFindBar() {
        finder.show()
    }

    /// ⌘G, ↩, and the bar's down arrow.
    public func findNext() {
        finder.next()
    }

    /// ⇧⌘G, ⇧↩, and the bar's up arrow.
    public func findPrevious() {
        finder.previous()
    }

    /// ⌘E — take the query from what the reader has selected in the preview.
    public func useSelectionForFind() {
        finder.useSelection()
    }

    /// Run the current search again, because the document underneath it moved.
    private func refreshFind() {
        finder.refresh()
    }

    /// Whether the caret is in the editor pane's text view.
    ///
    /// The fork every Find menu item takes. ADR-6 chose `NSTextView` for the
    /// editor *"precisely so that undo, Find & Replace, spellcheck and text
    /// substitution come for free"*, so when the editor has the focus its own
    /// find bar is the right answer and this window has nothing to add.
    var editorHasFocus: Bool {
        guard isEditorVisible, let responder = window?.firstResponder as? NSView else {
            return false
        }
        return responder === editor.textView || responder.isDescendant(of: editor.textView)
    }

    // MARK: - Session

    /// Everything ADR-4's session file records, right now.
    ///
    /// M8 adds the sidebar's half: the root was already here, and the back and
    /// forward stacks and the two listing toggles join it. Without the history
    /// a relaunch comes back in the right place with ⌘[ pointing at nothing,
    /// which reads as "it forgot where I had been" rather than as a missing
    /// feature.
    public func sessionSnapshot() -> SessionState {
        // One window's worth, mirrored into the flat fields. Still here because
        // a controller built without a ``WindowCoordinator`` — `mark-bench`,
        // most tests — is still a whole app as far as the session file is
        // concerned.
        var state = SessionState(windows: [windowSnapshot()])
        // The theme is the app's, not the window's, which is why it is set here
        // and not in ``windowSnapshot()``: two windows showing two themes is
        // not a thing, and `2026-08-26-multiple-windows-and-split-panes` did
        // not make it one.
        state.theme = ThemeController.shared.chosenName
        // Which half of the theme is pinned, for the same reason and with the
        // same scope: pinning is one choice for the app, not one per window.
        state.themeAppearance = ThemeController.shared.appearance.rawValue
        // The editor's whitespace marks, with the same scope for the same
        // reason — see ``SessionState/editorInvisibles``.
        state.editorInvisibles = Invisibles.isShowing
        return state
    }

    /// This window's state, for the coordinator to assemble with the others.
    public func windowSnapshot() -> SessionWindow {
        let sidebarState = sidebar.snapshot()
        // The groups, then this window's own chrome on top of them. The
        // duplication between `groups[0]` and the flat `tabs` field is
        // deliberate and lives in ``TabGroups/snapshotWindow(sidebarRoot:)``.
        var entry = groups.snapshotWindow(sidebarRoot: nil)
        return SessionWindow(
            tabs: entry.tabs,
            selectedIndex: entry.selectedIndex,
            focus: entry.focus,
            groups: entry.groups,
            splitFraction: entry.splitFraction,
            frame: window.map { NSStringFromRect($0.frame) },
            sidebarCollapsed: isSidebarCollapsed,
            sidebarRoot: sidebar.root.path,
            sidebarBack: sidebarState.back.map(\.path),
            sidebarForward: sidebarState.forward.map(\.path),
            sidebarOptions: SessionSidebarOptions(
                showsNonMarkdown: sidebarState.options.showsNonMarkdown,
                showsHidden: sidebarState.options.showsHidden,
                sort: sidebarState.sort.rawValue
            ),
            // M10. M9 shipped without this and a relaunch came back read-only,
            // which reads as the window forgetting rather than as ADR-6's
            // read-only default being honoured.
            editorVisible: isEditorVisible
        )
    }

    /// Restore a session. Only the selected tab is hydrated, so a 40-tab
    /// session costs one document to reopen, not forty.
    /// - Parameter sidebarRoot: overrides the session's root. Set when files
    ///   were named on the command line: `mark notes/today.md` is an explicit
    ///   instruction about where to be, and yesterday's saved root should not
    ///   win over it. The history still restores, so ⌘[ goes back to where the
    ///   last session left off rather than nowhere.
    public func restore(_ state: SessionState, sidebarRoot: URL? = nil) {
        // Before any tab is opened, so the first render is already themed
        // rather than being rendered once and re-rendered.
        ThemeController.shared.restore(
            named: state.theme,
            appearance: state.themeAppearance.flatMap(ThemeAppearance.init(argument:)))
        Invisibles.restore(state.editorInvisibles)
        guard let window = state.effectiveWindows.first else { return }
        restore(window, sidebarRoot: sidebarRoot)
    }

    /// Restore one window's worth of state.
    public func restore(_ state: SessionWindow, sidebarRoot: URL? = nil) {
        if let root = (sidebarRoot?.path ?? state.sidebarRoot) {
            let options = state.sidebarOptions ?? SessionSidebarOptions()
            sidebar.restore(
                SidebarState(
                    root: URL(fileURLWithPath: root),
                    back: (state.sidebarBack ?? []).map { URL(fileURLWithPath: $0) },
                    forward: (state.sidebarForward ?? []).map { URL(fileURLWithPath: $0) },
                    options: TreeListingOptions(
                        showsNonMarkdown: options.showsNonMarkdown,
                        showsHidden: options.showsHidden
                    ),
                    // An unrecognised sort name is not a reason to refuse a
                    // session; it is a reason to sort by name.
                    sort: TreeSort(rawValue: options.sort) ?? .name
                )
            )
        }
        restoreFrame(state.frame)
        setSidebarCollapsed(state.sidebarCollapsed ?? false)
        // The groups, the split and the divider all come from here — including
        // a file written by the one-bar build, whose `secondaryIndex` comes back
        // as a second group holding that document alone
        // (``SessionWindow/effectiveGroups``).
        groups.restore(state)
        // After the tabs, because showing the pane binds the selected tab's
        // buffer and there is no selection until `restore` has made one. A
        // session with no tabs restores no pane either: an editor bound to
        // nothing is a blank read-only rectangle.
        if state.editorVisible == true, tabs.selected != nil {
            setEditorVisible(true)
        }
    }

    /// Put the window back where it was, unless "where it was" is off screen.
    ///
    /// A display that has been unplugged since the last run leaves a frame
    /// nothing can show. `setFrame` would accept it happily and the window
    /// would be gone — indistinguishable, to the user, from a window that never
    /// came back. So the frame has to *intersect* a screen, not merely parse.
    private func restoreFrame(_ encoded: String?) {
        guard let encoded, let window else { return }
        let frame = NSRectFromString(encoded)
        guard frame.width >= window.minSize.width, frame.height >= window.minSize.height else {
            return
        }
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        guard visible else {
            Log.app.info(
                "restored window frame \(encoded, privacy: .public) is off every screen; cascading instead"
            )
            return
        }
        window.setFrame(frame, display: false)
    }

    /// Schedule a session write.
    ///
    /// Routed through the coordinator when there is one, because the file
    /// describes *every* window and a controller only knows its own. Without
    /// one — `mark-bench`, most tests — it falls back to writing itself as the
    /// single window, which is exactly what it did before there could be more
    /// than one.
    public func saveSessionSoon() {
        if let windows {
            windows.saveSoon()
            return
        }
        session.scheduleSave { [weak self] in
            self?.sessionSnapshot() ?? SessionState()
        }
    }

    /// The quit path. `applicationWillTerminate` is synchronous, which is why
    /// scroll offsets are pushed from the page continuously rather than
    /// queried here.
    public func saveSessionNow() {
        if let windows {
            windows.saveNow()
            return
        }
        session.saveNow(sessionSnapshot())
    }

    // MARK: - Chrome

    private func updateChrome() {
        let selected = tabs.selected
        window?.title = selected?.title ?? "mark"
        window?.representedURL = selected?.url
        updateDocumentPane()
        refreshAreas()
        // Only the window in front owns the menu bar. Without the guard, a
        // background window refreshing its badges would retitle ⌘1–⌘9 with
        // *its* tabs while the user is looking at another window's.
        if isMenuBarOwner {
            WindowMenu.shared?.update(with: tabs)
        }
    }

    /// Whether this window's tabs are the ones the Window menu should list.
    ///
    /// True for a controller with no coordinator, which is the single-window
    /// case every test and `mark-bench` builds.
    private var isMenuBarOwner: Bool {
        guard let windows else { return true }
        return windows.keyController === self
    }

    // MARK: - NSWindowDelegate

    /// This window is going away.
    ///
    /// The coordinator writes its dirty buffers before dropping it:
    /// `applicationWillTerminate` never sees a window closed an hour before
    /// quit, so this is the last chance its unsaved work has.
    public func windowWillClose(_ notification: Notification) {
        windows?.windowWillClose(self)
    }

    /// The Window menu follows the front window.
    public func windowDidBecomeKey(_ notification: Notification) {
        WindowMenu.shared?.update(with: tabs)
    }
}

// MARK: - TabHydrator

extension MainWindowController: TabHydrator {

    /// Hydration. Every web view made in the app is made here.
    public func makeDocumentView(for tab: DocumentTab) -> DocumentView {
        // The container of the group that holds this tab, not the focused
        // group's: splitting hydrates into a group the focus is about to move
        // to, and a window with two groups has two places a document can live.
        let container = container(for: tab)
        let view = DocumentView(frame: container.bounds)
        // Frame-based rather than autoresizing, because the container gives its
        // displayed view the bounds itself, and an autoresizing mask would
        // fight `DocumentContainerView.layout()` for the frame on every resize.
        view.isHidden = true
        container.addSubview(view)
        wire(view, to: tab)
        view.open(
            tab.url, source: tab.authoritativeSource, restoringScrollTo: tab.scrollOffset)
        return view
    }

    /// Everything a ``DocumentView`` needs to know about the window showing it.
    ///
    /// Extracted from ``makeDocumentView(for:)`` so that ``adopt(_:for:)`` — a
    /// view arriving from another window — goes through the identical wiring
    /// rather than a second copy of it that can fall behind. Every closure here
    /// captures `self`, which is exactly why a moved view must be re-wired: left
    /// alone it reports its scrolls to the window it came from.
    private func wire(_ view: DocumentView, to tab: DocumentTab) {
        view.onOpen = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.tabs.notePainted(tab)
            if tab == self.tabs.selected {
                self.window?.title = tab.title
                self.window?.representedURL = url
            }
            self.tabBar.reload()
        }
        // A link to a local file is the reader naming a document, so it opens
        // like every other route in rather than replacing the page underneath
        // the tab. `open(_:)` is the funnel: it records the opened-file
        // history, sends the reader to the other group if the file is already
        // showing there, and otherwise makes a tab — which is what relabels the
        // tab bar, retitles the window, moves the sidebar, extends the watch
        // set, and rebinds the editor pane to the new document's buffer.
        view.onFollow = { [weak self] url in
            self?.open(url)
        }
        view.onScroll = { [weak self, weak tab] y in
            guard let self, let tab else { return }
            tab.scrollOffset = y
            self.saveSessionSoon()
        }
        // The editor follows the preview: scrolling the rendered document
        // scrolls the source beside it to the same place.
        //
        // The guard is the binding itself rather than a flag kept in step with
        // it. A window has one editor pane and can have two documents on
        // screen; a hidden pane still holds the buffer it was showing; a view
        // can arrive here from another window. Asking "is this the document the
        // pane is showing?" answers all three, and no tab switch, split, or
        // pop-out can leave that answer stale.
        view.onSourceTop = { [weak self, weak tab] byte in
            guard let self, let tab, self.isEditorVisible,
                let buffer = tab.buffer, self.editor.buffer === buffer
            else { return }
            self.editor.follow(previewByte: byte)
        }
        // Clicking into a document is how a reader says which pane they mean.
        // A `WKWebView` swallows the click, so the signal comes from the view
        // taking first-responder rather than from a mouse event we never see.
        view.onFocus = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.focusGroup(holding: tab)
        }
        // ADR-6: *"nothing may read the file for rendering […] on a dirty
        // tab"*. Rehydration is a render, so a dirty tab is rehydrated from its
        // buffer — otherwise switching away from an unsaved document and back
        // would show the version on disk.
        if let buffer = tab.buffer {
            view.taskWriter = BufferTaskWriter(buffer: buffer)
        }
    }

    public func discardDocumentView(_ view: DocumentView, for tab: DocumentTab) {
        view.tearDown()
    }

    /// A live view that has just arrived from another window.
    ///
    /// The document is not reopened: it keeps its DOM, its scroll position and
    /// its JS state across the move, which is why a pop-out is instant rather
    /// than a ~4.7 ms rehydration — and, more importantly, why a dirty tab can
    /// move at all without being dehydrated, which
    /// `2026-08-25-flock-write-locking` forbids.
    public func adopt(_ view: DocumentView, for tab: DocumentTab) {
        let container = container(for: tab)
        view.isHidden = true
        container.addSubview(view)
        wire(view, to: tab)
        // The buffer's callbacks captured the old window too, and one of them
        // is load-bearing in a way that fails silently — see `wire(_:to:)` for
        // `Buffer`.
        if let buffer = tab.buffer {
            wire(buffer, to: tab)
        }
        container.needsLayout = true
    }
}

// MARK: - TabStoreDelegate

extension MainWindowController: TabStoreDelegate {

    /// The last chance to write a tab's unsaved buffer.
    ///
    /// Autosave's contract is *"at most the last 800 ms"*, and a tab closed
    /// inside that window would otherwise take the difference with it. A tab
    /// with an **unresolved conflict** is the one case that is not written:
    /// ADR-6 says never to resolve a conflict by writing, and closing the tab
    /// is not the user answering the question.
    public func tabStore(_ store: TabStore, willClose tab: DocumentTab) {
        guard let buffer = tab.buffer else { return }
        if buffer.isDirty && !buffer.isConflicted {
            buffer.save()
        } else if buffer.isConflicted {
            Log.core.error(
                """
                \(tab.url.lastPathComponent, privacy: .public) is closing with an unresolved \
                conflict; the unsaved buffer is discarded and the file on disk is left alone
                """
            )
        }
        conflicts.cancel(for: tab.url)
        editor.forget(buffer)
        tab.detachBuffer()
    }

    public func tabStoreDidChangeTabs(_ store: TabStore) {
        if let index = groups.groups.firstIndex(where: { $0 === store }),
            areas.indices.contains(index)
        {
            areas[index].tabBar.reload()
        }
        updateChrome()
        syncWatchedFiles()
        saveSessionSoon()
    }

    /// A group's selection moved.
    ///
    /// The switch itself is a show/hide, measured at 0.05 ms median because
    /// that is all it is: no re-injection, no re-layout of the document, no
    /// scroll restoration.
    ///
    /// Everything after the container is guarded on **which group** fired it.
    /// The window title, the sidebar's follow, the table of contents, the
    /// editor binding and the find bar all describe the document being acted
    /// on, and a selection in the group that does not have the focus is not
    /// that: a tab closing in the other half of a split must not retitle the
    /// window or rebind the editor.
    public func tabStore(_ store: TabStore, didSelect tab: DocumentTab?, previous: DocumentTab?) {
        let state = Log.signposter.beginInterval("tab switch")
        if let index = groups.groups.firstIndex(where: { $0 === store }),
            areas.indices.contains(index)
        {
            areas[index].container.show(tab?.documentView)
            areas[index].tabBar.reload()
        }
        Log.signposter.endInterval("tab switch", state)
        saveSessionSoon()
        guard store === groups.focused else { return }

        // The sidebar follows the selection too, so the tree is always
        // pointing at the document on screen (issue #7). Outside the signpost
        // interval on purpose: ADR-4's 0.05 ms is the show/hide, and folding a
        // directory read into that number would make it stop meaning anything.
        sidebar.follow(tab?.url)
        // The editor follows the selection. A tab that has never been edited
        // gets its buffer here, but only while the pane is open — an unopened
        // editor reads no files and allocates no buffers.
        if isEditorVisible {
            if let tab {
                bindEditor(to: tab)
            } else {
                editor.bind(nil)
            }
        }
        updateChrome()
        // The bar stays open across a switch, and its highlights were the
        // other document's. The new document has none until this runs.
        refreshFind()
    }

    /// A group ran out of documents.
    ///
    /// `2026-08-26-editor-groups-per-pane-tab-bars`: *"closing the last tab in
    /// a group collapses the split"*. A window with one group keeps it and shows
    /// its empty state — the sidebar is still there, which is the whole reason a
    /// mark window is heavier than a bare document viewer.
    public func tabStoreDidEmpty(_ store: TabStore) {
        guard groups.collapseIfEmpty(store) else {
            updateChrome()
            return
        }
        saveSessionSoon()
    }
}

// MARK: - TabGroupsDelegate

extension MainWindowController: TabGroupsDelegate {

    /// A group was added or removed.
    ///
    /// The areas are rebuilt from the arrangement — kept where they already
    /// exist, so a split does not dehydrate anything — and the window's chrome
    /// follows, because a collapse can change which document is being acted on.
    public func tabGroupsDidChangeLayout(_ groups: TabGroups) {
        rebuildAreas()
        syncWatchedFiles()
        updateChrome()
        // The find bar spans the window and belongs to the focused group; a
        // split that arrives or leaves changes which document that is, and its
        // highlights were the other one's.
        refreshFind()
        saveSessionSoon()
    }

    /// The focus moved to the other group.
    ///
    /// Nothing about either group's tabs changed, so this is only the two bars'
    /// active state and everything downstream of "which document is being acted
    /// on": the title, the table of contents, the editor binding and the find
    /// bar.
    public func tabGroupsDidMoveFocus(_ groups: TabGroups) {
        refreshAreas()
        sidebar.follow(tabs.selected?.url)
        if isEditorVisible {
            if let tab = tabs.selected {
                bindEditor(to: tab)
            } else {
                editor.bind(nil)
            }
        }
        updateChrome()
        refreshFind()
        saveSessionSoon()
    }
}

// MARK: - CommandTarget

/// What `mark-cli` and `mark://` can do to this window (ADR-3).
///
/// Every method here goes through ``TabStore``, which is also what the menu
/// items and the sidebar go through — so a command from the socket and the same
/// action taken with the mouse cannot diverge, and neither can bypass ADR-4's
/// residency accounting.
///
/// Nothing here calls `NSApp.activate`. ADR-3 launches the app with `open -g`
/// *"so focus is not stolen"*, and an app that immediately raises itself on the
/// command that follows would give the focus back with one hand and take it
/// with the other. `mark open` brings the **window** forward without activating
/// the app; `mark open --tab` does not even do that.
extension MainWindowController: CommandTarget {

    public func openDocument(at url: URL, background: Bool) throws -> OpenOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CommandFailure(
                .notFound, "\(url.path): no such file", detail: ["path": .string(url.path)])
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CommandFailure(
                .notFound, "\(url.path): not readable", detail: ["path": .string(url.path)])
        }
        if isDirectory.boolValue {
            // M8 made a directory a *place*, not a document, and M10 made
            // `open` say so instead of refusing: `mark open notes/` roots the
            // sidebar there, exactly as `mark nav notes/` does. It was refused
            // until now for a shape reason rather than a semantic one — the
            // reply could only carry a tab, and a success with no tab in it
            // lies to the caller. ``OpenOutcome`` is that shape fixed.
            //
            // `--tab` means "do not move me", so a background open still sets
            // the root but leaves the window where it is; the sidebar is
            // shared by every tab (ADR-4), so there is nothing else it could
            // mean here.
            let sidebar = try navigateSidebar(to: .path(url.path))
            if !background { showWindow(activating: false) }
            return .sidebar(sidebar)
        }

        // `--tab` is "add it to my tabs", so it must not move the reader off
        // whatever they are looking at. Re-selecting afterwards is cheap: the
        // new tab is already hydrated and the switch is a show/hide (ADR-4).
        let previous = background ? tabs.selected : nil
        let tab = openInFocusedGroup(url)
        if let previous, previous != tab { select(previous) }
        if !background { showWindow(activating: false) }
        return .tab(summary(for: tab))
    }

    /// Every tab in **every** window, each carrying its window index.
    ///
    /// All windows rather than just this one, because `mark tab list` is where
    /// someone goes to find out where a document ended up — and with commands
    /// acting on the key window
    /// (`2026-08-26-multiple-windows-and-split-panes`), "it is not in this
    /// window" is exactly the thing they are trying to discover. `index` stays
    /// per window, which is what `tab select 2` has always meant.
    public func documentTabs() -> [TabSummary] {
        // Every group's tabs, in group order — `allTabs` rather than the
        // focused group's, or a split window would report half its documents
        // and `mark tab list` would be the least useful place to find out where
        // one went (`2026-08-26-editor-groups-per-pane-tab-bars`).
        guard let windows else { return groups.allTabs.map { summary(for: $0) } }
        return windows.controllers.flatMap { controller in
            controller.groups.allTabs.map { controller.summary(for: $0) }
        }
    }

    public func selectTab(matching selector: TabSelector) throws -> TabSummary {
        // A path names a document, not a position, so it is worth finding in
        // another window rather than reporting absent from this one. An index
        // is a position *in a window's bar* and stays local — `tab select 2`
        // has always meant "the third tab of the window I am driving".
        if case .path(let path) = selector {
            let url = CommandRouter.fileURL(from: path)
            if tab(for: url) == nil,
                let owner = windows?.controllers.first(where: { $0.tab(for: url) != nil }),
                let tab = owner.tab(for: url)
            {
                owner.select(tab)
                owner.showWindow(activating: false)
                return owner.summary(for: tab)
            }
        }
        let tab = try resolve(selector)
        select(tab)
        showWindow(activating: false)
        return summary(for: tab)
    }

    public func closeTab(matching selector: TabSelector) throws -> TabSummary {
        let tab = try resolve(selector)
        // Captured before the close, because afterwards the tab has no index.
        let closed = summary(for: tab)
        close(tab)
        return closed
    }

    /// `mark tab close --all`.
    ///
    /// **This window's tabs**, in both halves of a split — the same scope the
    /// menu item has, and the scope every command acting on the key window has
    /// (`2026-08-26-multiple-windows-and-split-panes`). A caller who wants
    /// another window's documents gone closes them from that window, the way
    /// `tab select 2` has always meant "in the window I am driving".
    ///
    /// Summaries are captured before the close, because afterwards a tab has no
    /// index and no group to be reported in.
    public func closeAllTabs() -> [TabSummary] {
        let closing = groups.allTabs.map { summary(for: $0) }
        guard !closing.isEmpty else { return [] }
        groups.closeAllTabs()
        saveSessionSoon()
        return closing
    }

    public func scrollSelectedDocument(toAnchor anchor: String) async throws -> TabSummary {
        let tab = try selectedTab()
        guard let view = tab.documentView else {
            // ADR-4 never evicts the selected tab, so this is a genuine
            // internal inconsistency rather than an expected state.
            throw CommandFailure(
                .noDocument, "the selected tab has no view to scroll")
        }
        await view.awaitReady()
        let found: Bool
        do {
            found = try await view.scrollToAnchor(anchor)
        } catch {
            throw CommandFailure(
                .internalError, "scrolling to \"\(anchor)\" failed: \(String(describing: error))")
        }
        guard found else {
            throw CommandFailure(
                .anchorNotFound,
                "\(tab.url.lastPathComponent) has no anchor \"\(anchor)\"",
                detail: ["anchor": .string(anchor), "path": .string(tab.url.path)]
            )
        }
        return summary(for: tab)
    }

    public func reloadSelectedDocument() async throws -> Int {
        let tab = try selectedTab()
        guard let view = tab.documentView else {
            throw CommandFailure(.noDocument, "the selected tab has no view to reload")
        }
        // Reload means "re-read the file", and
        // `2026-08-24-editing-pane-and-autosave` forbids reading the file for
        // rendering while a tab is dirty. Doing it anyway would replace the
        // reader's unsaved text with the version on disk, silently — the same
        // failure the ADR rejects "reload-theirs" for. Refusing is the answer,
        // with the two ways out named.
        guard !tab.isDirty else {
            throw CommandFailure(
                .unsupported,
                "\(tab.url.lastPathComponent) has unsaved changes; save it (⌘S) or resolve the conflict before reloading",
                detail: ["path": .string(tab.url.path), "dirty": .bool(true)]
            )
        }
        await view.awaitReady()
        let report = await view.reload()
        tab.refreshMetadata { [weak self] in self?.metadataDidChange(of: tab) }
        return report?.blocks ?? 0
    }

    // MARK: The sidebar (M8)

    public func sidebarSummary() -> SidebarSummary {
        let state = sidebar.snapshot()
        return SidebarSummary(
            root: state.root.path,
            breadcrumb: sidebar.navigator.breadcrumb.map(\.name),
            back: state.back.map(\.path),
            forward: state.forward.map(\.path),
            showsNonMarkdown: state.options.showsNonMarkdown,
            showsHidden: state.options.showsHidden,
            sort: state.sort.rawValue,
            filter: state.filter
        )
    }

    /// M7. Apply a theme to every tab — including the dehydrated ones, which
    /// need nothing done to them.
    ///
    /// The gate is *"`mark theme dracula` applies to every open tab, including
    /// dehydrated ones"*, and the reason it is met is structural rather than
    /// careful: a hydrated tab gets one `<style>` assignment, and a dehydrated
    /// tab has no DOM to update and is rendered against
    /// ``ThemeController/active`` when it next hydrates (``makeDocumentView``).
    /// There is no per-tab theme state that could go stale.
    public func applyTheme(named name: String?, appearance: ThemeAppearance? = nil) async throws
        -> ThemeSummaryForCLI
    {
        let controller = ThemeController.shared
        let resolved: ResolvedTheme
        let previous = controller.active
        if let name {
            do {
                resolved = try controller.apply(named: name, appearance: appearance)
            } catch {
                throw CommandFailure(
                    .badArguments, String(describing: error),
                    detail: ["theme": .string(name)])
            }
        } else {
            // No name is either "what is applied?" or "just change which half
            // I am looking at" — neither of which resolves anything.
            if let appearance { controller.setAppearance(appearance) }
            resolved = controller.active
        }

        var applied = 0
        var rerendered = 0
        // Every group: a theme is the app's, and a split window whose other
        // half kept the old colours would be the bug M7 already fixed once.
        for tab in groups.allTabs {
            // A dehydrated tab needs nothing: it has no DOM, and it is
            // rendered against the new theme when it next hydrates.
            guard let view = tab.documentView else { continue }
            // `_ =` because the report is only interesting to `mark-bench`,
            // which reads it from its own harness; here the value is awaited
            // for its ordering — the CSS is installed before the count says it
            // is — and discarded.
            _ = await view.applyTheme(resolved).value
            applied += 1

            // Two things a `<style>` swap cannot re-colour, both of which are
            // *baked into the HTML* at render time:
            //
            //   * a diagram, because `merman` writes its own palette into the
            //     SVG's scoped `<style>` — the whole reason the core renders
            //     one copy per appearance rather than one copy;
            //   * code tokens, but only if the incoming theme's scope → slot
            //     map differs, which no shipped theme's does.
            //
            // Both are rare and both are a re-render, which is ~95 ms and
            // node-preserving where it can be. Everything else — chrome,
            // links, tables, code colours — is the style swap above and costs
            // nothing.
            let stampChanged = resolved.codeStamp != previous.codeStamp
            let hasDiagram = await view.containsDiagram()
            // `resolved == previous` is the appearance-only case — a pin, or a
            // bare `mark theme` asking what is applied. The baked-in copies are
            // baked in *per appearance* as well as per theme, and the page
            // switches between them with `prefers-color-scheme`, so there is
            // nothing to re-render and re-rendering anyway would make a report
            // cost 95 ms a tab.
            if resolved != previous, stampChanged || hasDiagram {
                rerendered += 1
                await view.rerenderForTheme()
                _ = await view.applyTheme(resolved).value
            }
        }
        if rerendered > 0 {
            Log.render.info(
                "theme \(resolved.name, privacy: .public): re-rendered \(rerendered) of \(applied) hydrated tab(s) — diagrams and code markup are baked in at render time"
            )
        }
        // The editor pane draws with AppKit colours rather than the page's
        // custom properties, and the dynamic `NSColor`s it holds were resolved
        // against the *previous* pair — they track the appearance by
        // themselves, but not the theme. Without this the two panes disagree
        // until something else happens to repaint the editor, which is the
        // most visible thing a theme change could get wrong now that one can be
        // chosen from a menu with the editor open.
        editor.themeChanged()
        // The markdown reference is not a tab, so the loop above cannot reach
        // it (`2026-08-26-markdown-reference-window`). A reference page left on
        // the old palette while every document changed is a rendering bug with
        // a very unhelpful shape — it looks like the theme half-applied.
        if let help = HelpWindowController.shared {
            await help.applyTheme(resolved, previous: previous)
        }
        saveSessionSoon()
        return ThemeSummaryForCLI(
            name: resolved.name,
            kind: resolved.kind.rawValue,
            light: resolved.light.name,
            dark: resolved.dark.name,
            paired: resolved.paired,
            appearance: controller.appearance.rawValue,
            showing: controller.visibleHalf.name,
            applied: applied,
            rerendered: rerendered
        )
    }

    public func navigateSidebar(to target: NavigationTarget) throws -> SidebarSummary {
        switch target {
        case .path(let path):
            let url = CommandRouter.fileURL(from: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CommandFailure(
                    .notFound, "\(url.path): no such directory",
                    detail: ["path": .string(url.path)])
            }
            guard isDirectory.boolValue else {
                throw CommandFailure(
                    .badArguments, "\(url.path) is a file; the sidebar's root is a directory",
                    detail: ["path": .string(url.path)])
            }
            sidebar.navigate(to: url)

        case .parent:
            guard sidebar.navigateToParent() else {
                throw CommandFailure(
                    .unsupported, "\(sidebar.root.path) has no parent")
            }

        case .back:
            guard sidebar.navigateBack() else {
                throw CommandFailure(.unsupported, "there is nothing to go back to")
            }

        case .forward:
            guard sidebar.navigateForward() else {
                throw CommandFailure(.unsupported, "there is nothing to go forward to")
            }
        }
        saveSessionSoon()
        return sidebarSummary()
    }

    // MARK: Helpers

    private func selectedTab() throws -> DocumentTab {
        guard let tab = tabs.selected else {
            throw CommandFailure(.noDocument, "no document is open")
        }
        return tab
    }

    private func resolve(_ selector: TabSelector) throws -> DocumentTab {
        switch selector {
        case .selected:
            return try selectedTab()
        case .index(let index):
            // The window's flat index, across its groups in group order — the
            // same one `mark tab list` prints
            // (`2026-08-26-editor-groups-per-pane-tab-bars`). A per-group index
            // would make `tab list` and `tab select` disagree about what "2"
            // means the moment a window is split.
            let count = groups.allTabs.count
            guard let found = groups.tab(atWindowIndex: index) else {
                throw CommandFailure(
                    .tabNotFound,
                    "there is no tab \(index); \(count) \(count == 1 ? "tab is" : "tabs are") open",
                    detail: ["index": .int(index), "tabs": .int(count)]
                )
            }
            return found.tab
        case .path(let path):
            let url = CommandRouter.fileURL(from: path)
            guard let tab = tab(for: url) else {
                // Say *where* it is rather than only that it is not here. With
                // more than one window "no tab is open on that" is a confusing
                // thing to be told about a document plainly on screen.
                if let elsewhere = windows?.controllers.firstIndex(where: {
                    $0.tab(for: url) != nil
                }) {
                    throw CommandFailure(
                        .tabNotFound,
                        "\(url.path) is open in window \(elsewhere), not this one",
                        detail: ["path": .string(url.path), "window": .int(elsewhere)])
                }
                throw CommandFailure(
                    .tabNotFound, "no tab is open on \(url.path)",
                    detail: ["path": .string(url.path)])
            }
            return tab
        }
    }

    fileprivate func summary(for tab: DocumentTab) -> TabSummary {
        TabSummary(
            // Per *window*, across its groups in group order — which is what
            // `mark tab select 2` has always meant and still means, now that a
            // window's tabs can be in two lists
            // (`2026-08-26-editor-groups-per-pane-tab-bars`).
            index: groups.windowIndex(of: tab) ?? -1,
            path: tab.url.path,
            title: tab.metadata?.documentTitle ?? tab.title,
            selected: tab == tabs.selected,
            resident: tab.state.isResident,
            preview: tab.isPreview,
            openTasks: tab.metadata?.taskCounts.open,
            totalTasks: tab.metadata?.taskCounts.total,
            window: windows?.index(of: self),
            group: groups.index(of: tab)
        )
    }
}

// MARK: - Menu actions

/// With native tabbing AppKit supplies *and validates* ⌘T, ⌘W, ⌃⇥ and the
/// Window-menu tab items. ADR-4 traded that away, so this is the other half of
/// the bill: `NSMenuItemValidation` explicitly, because `NSWindowController`
/// does not conform to it and an `override` here compiles as nothing.
extension MainWindowController: NSMenuItemValidation {

    // MARK: - New documents (2026-08-26-new-documents-are-files-on-disk)

    /// ⇧⌘N. Name a document, then make it.
    ///
    /// The ADR's shape, and the reason it is a panel rather than a blank
    /// buffer:
    ///
    /// > **mark never holds a document that has no file.** There is no untitled
    /// > state, no URL-less tab, and no `SessionTab` without a path.
    ///
    /// ⌘N is deliberately still New Window. It is a shipped, documented
    /// shortcut, and moving it for a new feature would break every reader's
    /// hands to save one keystroke.
    ///
    /// A `representedObject` carrying a URL means the breadcrumb's "New
    /// Document Here…", which knows the directory it wants; the menu-bar item
    /// carries none and means "where I am reading".
    @objc public func newDocument(_ sender: Any?) {
        let directory =
            ((sender as? NSMenuItem)?.representedObject as? URL)
            ?? tabs.selected?.url.deletingLastPathComponent()
            ?? sidebar.root
        newDocument(in: directory)
    }

    /// Run the save panel, then create what it names.
    ///
    /// Split from ``createDocument(at:)`` because `runModal()` cannot run in a
    /// test, and because the breadcrumb needs the same act with a different
    /// starting directory.
    public func newDocument(in directory: URL) {
        let panel = MarkdownPanel.save(
            startingIn: directory, named: MarkdownPanel.defaultDocumentName)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        // The panel's answer is not necessarily the file to write — see
        // ``MarkdownPanel/target(forChosen:)``, which is where the
        // appended-extension collision is caught.
        switch MarkdownPanel.target(forChosen: chosen) {
        case .nameTaken(let url):
            presentNameTaken(url)
        case .create(let url):
            do {
                try createDocument(at: url)
            } catch {
                presentCreationFailure(error, at: url)
            }
        }
    }

    /// Create an empty document at `url` and open it.
    ///
    /// **The write goes through the core**, which is not incidental:
    /// `2026-08-25-flock-write-locking` requires that *"every path that writes
    /// a user's document takes the lock first. No exceptions, including future
    /// features."* `MarkCore.save` is `write_atomically`, which acquires the
    /// `flock`, writes a temp file and renames it over the target — and which
    /// already treats a target that does not exist as
    /// `LockState::DocumentAbsent` rather than an error, so creating a file and
    /// overwriting one are the same call. The Replace case a save panel can
    /// produce is therefore refused, correctly, by machinery that predates this
    /// feature.
    ///
    /// The editor is shown and takes the keyboard. That is this route only:
    /// *"a document opens read-only until you ask to edit it"* still holds
    /// everywhere else, and making a file is asking.
    @discardableResult
    public func createDocument(at url: URL) throws -> DocumentTab {
        try MarkCore.save("", to: url.path)
        Log.app.info("created \(url.lastPathComponent, privacy: .public)")

        // Permanent, not preview: a file the reader has just named is the most
        // deliberate act there is.
        let tab = openInFocusedGroup(url)
        setEditorVisible(true)
        window?.makeFirstResponder(editor.textView)
        // Editor visibility is session state, and nothing else here writes it.
        saveSessionSoon()
        // The same reason `TreeViewController.drop(_:into:move:)` refreshes: a
        // listing that does not show the new file reads as the act having
        // failed. The tree follows the front document on its own, so a file
        // made outside the root still opens — it just does not move the root,
        // which is ⌘⇧O's job and nothing else's.
        sidebar.refresh()
        return tab
    }

    /// The name the reader typed became one that is already taken.
    ///
    /// Separate from ``presentCreationFailure(_:at:)`` because it is not a
    /// failure of the write — nothing was attempted. The alert offers to open
    /// the file instead, which is almost always what the reader wants once they
    /// know it is there.
    private func presentNameTaken(_ url: URL) {
        Log.app.info(
            "not creating \(url.lastPathComponent, privacy: .public): the name is taken")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(url.lastPathComponent)” already exists."
        alert.informativeText =
            "Nothing was written. Type the full name, including the extension, to replace it."
        alert.addButton(withTitle: "Open It")
        alert.addButton(withTitle: "Cancel")
        let open: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.open(url)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: open)
        } else {
            open(alert.runModal())
        }
    }

    /// Say why a document could not be made.
    ///
    /// An alert rather than the `NSSound.beep()` the drop path uses. A drop
    /// that beeps has a visible cause — the file is still under the cursor,
    /// the destination is on screen. A menu item that beeps looks broken, and
    /// the two reasons this fails are both worth reading: another `mark` holds
    /// the target, or the volume would not take the write.
    ///
    /// The core's own message is the alert's body. It already names the holding
    /// process and its pid, and phrases the advice carefully — see
    /// `LockError`'s `Display` — so rewording it here would only make it worse.
    private func presentCreationFailure(_ error: any Error, at url: URL) {
        let detail = (error as? CoreError)?.detail ?? String(describing: error)
        Log.app.error(
            "could not create \(url.path, privacy: .public): \(detail, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not create “\(url.lastPathComponent)”."
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// ⌘T. "New Tab" is an open panel — the tab is what you get, and the file
    /// is what you choose.
    ///
    /// It used to say *"a viewer has no blank document to open"*, which stopped
    /// being true when `2026-08-26-new-documents-are-files-on-disk` gave the
    /// File menu ⇧⌘N. This item keeps its meaning anyway: ⌘T is for a document
    /// that already exists, ⇧⌘N is for one that does not.
    @objc public func newTab(_ sender: Any?) {
        let panel = MarkdownPanel.open(
            startingIn: tabs.selected?.url.deletingLastPathComponent() ?? sidebar.root)
        guard panel.runModal() == .OK else { return }
        openFromPanel(panel.urls)
    }

    /// Open what an open panel handed back.
    ///
    /// Shared by ⌘T and ⌘O so the two cannot drift apart again. A folder roots
    /// the sidebar instead of opening a tab, through the method that already
    /// knows M8's *"a directory is a place, not a document"* — the same
    /// behaviour `mark open notes/` and a folder dropped on the window have.
    ///
    /// The throw is a path that disappeared between the panel listing it and
    /// this line. Worth a log, not worth stopping the rest of a multiple
    /// selection for.
    public func openFromPanel(_ urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory)
            guard exists && isDirectory.boolValue else {
                open(url)
                continue
            }
            do {
                _ = try openDocument(at: url, background: false)
            } catch {
                Log.app.error(
                    "open panel: \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// ⌘W closes the *tab*, matching every tab bar on the platform. The window
    /// has ⇧⌘W (`performClose:`), which AppKit routes itself.
    /// ⌘W closes the *tab*, matching every tab bar on the platform. The window
    /// has ⇧⌘W (`performClose:`), which AppKit routes itself.
    ///
    /// From the tab bar's context menu the sender carries the tab that was
    /// right-clicked; from the menu bar there is none and it means the selected
    /// one.
    @objc public func closeTab(_ sender: Any?) {
        guard let tab = tabForMenuItem(sender) else { return }
        close(tab)
    }

    /// Every other tab **in that tab's group**.
    ///
    /// A group is a set of documents the reader put together, so "close the
    /// others" means the others in the set — closing the other half of a split
    /// as well would make this item a way to lose work you were comparing
    /// against.
    @objc public func closeOtherTabs(_ sender: Any?) {
        guard let keep = tabForMenuItem(sender), let owner = groups.group(of: keep) else { return }
        for tab in owner.tabs where tab != keep { owner.close(tab) }
    }

    /// Every tab in the window, both halves of a split included.
    ///
    /// Unlike **Close Other Tabs**, which is deliberately per-group — "the
    /// others in the set I put together" — this one is the window's, because
    /// "all" that quietly left the other pane's documents open would be the
    /// surprising reading of the word. ⌥⌘W: ⌘W is one tab, ⇧⌘W is the window,
    /// and this sits between them.
    ///
    /// The window stays open on its empty state. Closing every tab is not the
    /// same request as closing the window, and the sidebar the reader was
    /// browsing is still there.
    @objc public func closeAllTabs(_ sender: Any?) {
        guard !groups.closeAllTabs().isEmpty else { return }
        saveSessionSoon()
    }

    // MARK: - Groups (2026-08-26-editor-groups-per-pane-tab-bars)

    /// ⌘\ — put this document in a group of its own beside the others.
    @objc public func splitRight(_ sender: Any?) {
        guard groups.splitRight() else {
            NSSound.beep()
            return
        }
        moveKeyboardFocusToSelectedDocument()
        saveSessionSoon()
    }

    /// ⇧⌘\ — back to one group, keeping **every** document.
    @objc public func closeSplit(_ sender: Any?) {
        guard groups.closeSplit() else { return }
        saveSessionSoon()
    }

    /// ⌥⌘\ — act on the other group.
    @objc public func focusOtherPane(_ sender: Any?) {
        guard groups.focusOther() else { return }
        moveKeyboardFocusToSelectedDocument()
    }

    /// Move the tab under the pointer — or the selected one — into the other
    /// group, splitting if there is only one.
    ///
    /// The tab bar's context menu, and the accessible half of the
    /// drag-across-the-divider gesture. No key equivalent: ⌘\ already answers
    /// "show me two".
    @objc public func moveToOtherPane(_ sender: Any?) {
        guard let tab = tabForMenuItem(sender) else { return }
        guard groups.moveToOtherGroup(tab) else {
            NSSound.beep()
            return
        }
        moveKeyboardFocusToSelectedDocument()
        saveSessionSoon()
    }

    /// Put the keyboard where the focus went, so ⌘F and the arrow keys land in
    /// the group the reader just moved to rather than the one they left.
    private func moveKeyboardFocusToSelectedDocument() {
        guard let webView = tabs.selected?.documentView?.webView else { return }
        window?.makeFirstResponder(webView)
    }

    // MARK: - Windows

    /// ⌃⌘N — move this tab into a window of its own.
    ///
    /// A *move*, not a copy: `2026-08-26-multiple-windows-and-split-panes`
    /// allows a tab exactly one view, so the document leaves this window's bar
    /// and takes its web view — DOM, scroll position and all — with it.
    @objc public func popOutTab(_ sender: Any?) {
        guard let tab = tabForMenuItem(sender), tabs.count >= 2 else {
            NSSound.beep()
            return
        }
        guard let coordinator = windows else {
            Log.app.error("no window coordinator; cannot pop \(tab.title, privacy: .public) out")
            NSSound.beep()
            return
        }
        // `2026-08-25-flock-write-locking`: never resolve a conflict by
        // writing, and never by moving the document somewhere the user is not
        // looking either. The prompt belongs to this window until it is
        // answered.
        if tab.buffer?.isConflicted == true {
            reportUnmovableConflict(tab)
            return
        }
        coordinator.popOut(tab, from: self)
    }

    /// ⌘N — a new window on the same folder, with no tabs.
    @objc public func newWindow(_ sender: Any?) {
        guard let coordinator = windows else { return }
        let controller = coordinator.makeWindow(root: sidebar.root, collapsedSidebar: false)
        controller.showWindow(activating: true)
    }

    /// The tab a context-menu item refers to, or the selected one for a
    /// menu-bar item.
    ///
    /// ``TabItemView`` puts its tab in `representedObject`; the Window and File
    /// menus have no tab in hand and mean "the one I am looking at".
    private func tabForMenuItem(_ sender: Any?) -> DocumentTab? {
        ((sender as? NSMenuItem)?.representedObject as? DocumentTab) ?? tabs.selected
    }

    private func reportUnmovableConflict(_ tab: DocumentTab) {
        Log.core.error(
            "\(tab.url.lastPathComponent, privacy: .public) has an unresolved conflict; not moving it to another window"
        )
        guard let window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(tab.title)” has unresolved changes."
        alert.informativeText =
            "This document was changed on disk while you were editing it. "
            + "Resolve that here before moving it to another window."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// ⌃⇥.
    @objc public func selectNextTab(_ sender: Any?) { tabs.selectNext() }

    /// ⌃⇧⇥.
    @objc public func selectPreviousTab(_ sender: Any?) { tabs.selectPrevious() }

    /// ⌘1–⌘9, dispatched by `tag`. ⌘9 is the last tab, not the ninth.
    @objc public func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        tabs.selectByKeyEquivalent(number: item.tag)
    }

    // MARK: M8 — the navigator

    /// ⌘↑.
    @objc public func navigateToParent(_ sender: Any?) {
        sidebar.navigateToParent()
    }

    /// ⌘[.
    @objc public func navigateBack(_ sender: Any?) {
        sidebar.navigateBack()
    }

    /// ⌘].
    @objc public func navigateForward(_ sender: Any?) {
        sidebar.navigateForward()
    }

    /// ⌘⇧O — jump the tree to the selected tab's file and select it.
    ///
    /// Goes through ``DocumentTab/url``, never through the tab's web view, so
    /// it works for a dehydrated tab exactly as it does for a resident one —
    /// ADR-4's *"no feature may assume a tab's web view exists"*, and one of
    /// the easier places to violate it by reaching for `documentView`.
    @objc public func revealInSidebar(_ sender: Any?) {
        guard let url = tabs.selected?.url else { return }
        if !sidebar.reveal(url) {
            Log.tree.error("reveal failed for \(url.path, privacy: .public)")
        }
    }

    /// ⌘⌥R — hand the file to Finder. The sidebar's selection if there is one,
    /// otherwise the selected tab's document.
    @objc public func revealInFinder(_ sender: Any?) {
        sidebar.revealInFinder(sidebar.selectedNode?.url ?? tabs.selected?.url)
    }

    /// ⌥⌘P — put the keyboard on the sidebar's path bar, where ← / → walk the
    /// crumbs, ↓ opens a folder's subfolders, and ⏎ navigates. Finder spells
    /// its own path-bar command the same way.
    @objc public func focusPathBar(_ sender: Any?) {
        sidebar.focusPathBar()
    }

    /// ⌃⌘T — the document pane, showing the outline.
    @objc public func toggleTableOfContents(_ sender: Any?) {
        toggleDocumentPane(.contents)
    }

    /// ⌃⌘Y — the document pane, showing the tasks.
    @objc public func toggleTaskList(_ sender: Any?) {
        toggleDocumentPane(.tasks)
    }

    /// One rule for both items: show the pane on this tab, or hide the pane if
    /// this tab is already the one showing
    /// (`2026-08-28-tabbed-document-pane`).
    ///
    /// It is what makes the pair read as a choice rather than as two
    /// independent toggles — and it leaves ⌃⌘T behaving exactly as it did for a
    /// reader who never presses ⌃⌘Y.
    public func toggleDocumentPane(_ mode: DocumentPaneController.Mode) {
        if sidebarPane.isDocumentPaneVisible, documentPane.mode == mode {
            sidebarPane.setDocumentPaneVisible(false)
            return
        }
        documentPane.mode = mode
        sidebarPane.setDocumentPaneVisible(true)
    }

    /// Every item in the Edit ▸ Find submenu, told apart by `tag`.
    ///
    /// A selector of our own rather than `performFindPanelAction:`, and the
    /// difference matters. That selector is `NSTextView`'s, so AppKit dispatches
    /// it to the first responder that implements it — which, with the caret in
    /// a search field or the focus anywhere near a text view, is never this
    /// window. Routing every Find item here instead makes the fork explicit and
    /// puts it in one place: the editor's text view when it has the focus, the
    /// preview otherwise.
    @objc public func performFindAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag
        let action = tag.flatMap(NSTextFinder.Action.init(rawValue:)) ?? .showFindInterface
        if editorHasFocus {
            editor.textView.performFindPanelAction(sender)
            return
        }
        // Replace and its relatives belong to the editor, and the editor does
        // not have the focus — so there is nothing here to write through to.
        if !finder.perform(action) {
            NSSound.beep()
        }
    }

    /// ⌥⌘F — put the caret in the sidebar's filter field.
    @objc public func focusSidebarFilter(_ sender: Any?) {
        guard let field = sidebar.filterField else { return }
        window?.makeFirstResponder(field)
    }

    @objc public func toggleShowsNonMarkdownFiles(_ sender: Any?) {
        sidebar.listingOptions.showsNonMarkdown.toggle()
    }

    @objc public func toggleShowsHiddenFiles(_ sender: Any?) {
        sidebar.listingOptions.showsHidden.toggle()
    }

    /// ⌥⌘I — the editor's whitespace marks, on or off.
    ///
    /// App-wide rather than per window, and it does not go through this
    /// controller's editor: ``Invisibles/isShowing`` posts, and every open
    /// editor repaints. A menu item reaches the focused window through the
    /// responder chain, and a second window still dotting its spaces would read
    /// as the toggle half-working.
    @objc public func toggleInvisibles(_ sender: Any?) {
        Invisibles.isShowing.toggle()
        saveSessionSoon()
    }

    /// The Sort By submenu, dispatched by `tag` in ``TreeSort/allCases`` order.
    @objc public func sortSidebar(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            TreeSort.allCases.indices.contains(item.tag)
        else { return }
        sidebar.sort = TreeSort.allCases[item.tag]
    }

    @objc public func refreshSidebar(_ sender: Any?) {
        sidebar.refresh()
    }

    // MARK: M7 — the theme

    /// The Theme submenu, dispatched by the name in `representedObject`.
    ///
    /// It goes through ``applyTheme(named:appearance:)`` — the same entry point
    /// `mark theme <name>` reaches over the socket — so the menu cannot drift
    /// from the CLI, and so choosing a theme is persisted, applied to every
    /// hydrated tab, and free for the dehydrated ones by exactly the mechanism
    /// ADR-7 describes.
    @objc public func chooseTheme(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        _Concurrency.Task { @MainActor in
            do {
                _ = try await self.applyTheme(named: name)
            } catch {
                self.reportThemeFailure(named: name, error: error)
            }
        }
    }

    /// **View ▸ Theme ▸ Match System Appearance.** Hand the choice of half back
    /// to macOS, keeping the theme.
    ///
    /// The counterweight to choosing a theme by name, which pins the half it
    /// names (see ``ThemeController``). Without a way back, one trip through
    /// the menu would cost a user the automatic light/dark switch for good.
    @objc public func matchSystemAppearance(_ sender: Any?) {
        _Concurrency.Task { @MainActor in
            _ = try? await self.applyTheme(named: nil, appearance: .system)
        }
    }

    /// M7's fourth gate on this side of the socket: *a broken theme is a named
    /// error rather than invisible text*. The CLI gets that on stderr; someone
    /// who picked the theme from a menu has no terminal to read, so they get a
    /// sheet saying which theme and why. The previous theme is still in force —
    /// ``ThemeController/apply(named:appearance:)`` changes nothing when it throws.
    private func reportThemeFailure(named name: String, error: any Error) {
        let reason = (error as? CommandFailure)?.message ?? String(describing: error)
        Log.render.error(
            "theme \(name, privacy: .public) was refused: \(reason, privacy: .public)")
        guard let window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The theme “\(name)” could not be used."
        alert.informativeText = "\(reason)\n\nThe previous theme is still in place."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// ⌘⇧D — show the document's differences against git `HEAD`, or stop.
    ///
    /// Failure is silent by design. `2026-08-28-git-differences-by-running-git`
    /// makes "no git here" indistinguishable from "not in a repository", and a
    /// reader who pressed this on a note outside a repository needs the menu
    /// item to have been greyed out, not a dialog explaining itself. The reason
    /// goes to the log, which is where `mark doctor` points.
    @objc public func toggleDiffView(_ sender: Any?) {
        guard let documentView else { return }
        _Concurrency.Task { @MainActor in
            if let reason = await documentView.toggleDiff() {
                Log.git.debug("changes view: \(reason.description, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    @objc public func reloadDocument(_ sender: Any?) {
        guard let documentView, let tab = tabs.selected else { return }
        // Same refusal as the socket's `reload`, for the same reason: a reload
        // is a read of the file, and on a dirty tab the buffer is the truth.
        guard !tab.isDirty else {
            Log.render.error(
                "\(tab.url.lastPathComponent, privacy: .public) has unsaved changes; refusing to reload it from disk"
            )
            NSSound.beep()
            return
        }
        _Concurrency.Task { @MainActor in
            await documentView.reload()
            tab.refreshMetadata { [weak self] in
                self?.metadataDidChange(of: tab)
            }
        }
    }

    // MARK: M9 — the editor

    /// ⌥⌘E.
    @objc public func toggleEditorPane(_ sender: Any?) {
        setEditorVisible(!isEditorVisible)
        if isEditorVisible {
            window?.makeFirstResponder(editor.textView)
        }
        // The pane's visibility is session state (M10), and nothing else in
        // this action changes anything the session records — so without this
        // the flag is only written the next time a tab or the sidebar moves.
        saveSessionSoon()
    }

    /// ⌘S. Autosave means this is rarely needed, which is exactly why it has to
    /// exist: an editor without ⌘S feels broken even when it is saving.
    @objc public func saveDocument(_ sender: Any?) {
        guard let buffer = tabs.selected?.buffer else { return }
        buffer.save()
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleEditorPane(_:)):
            item.title = isEditorVisible ? "Hide Editor" : "Show Editor"
            return tabs.selected != nil
        case #selector(saveDocument(_:)):
            return tabs.selected?.isDirty == true
        case #selector(reloadDocument(_:)):
            // Greyed out rather than beeping when there is something to lose.
            return tabs.selected != nil && tabs.selected?.isDirty != true
        case #selector(closeTab(_:)):
            return tabs.selected != nil
        case #selector(newDocument(_:)):
            // Unconditional, unlike every other item here. It needs no tab and
            // no group — a window with nothing open at all is exactly where
            // someone reaches for it.
            return true
        // Two items, one pane: each is ticked only when the pane is on screen
        // *and* showing its tab, so the pair reads as a choice.
        case #selector(toggleTableOfContents(_:)):
            item.state = documentPaneIsShowing(.contents) ? .on : .off
            return true
        case #selector(toggleTaskList(_:)):
            item.state = documentPaneIsShowing(.tasks) ? .on : .off
            return true
        case #selector(toggleDiffView(_:)):
            // The title says which way the toggle goes, as `toggleEditorPane`
            // does. Enabled whenever there is a document: whether it has
            // changes is a question only `git` can answer, and answering it
            // here would fork a process on every menu-bar tracking pass.
            let showing = documentView?.isShowingDiff == true
            item.title = showing ? "Hide Changes" : "Show Changes"
            item.state = showing ? .on : .off
            return tabs.selected != nil
        case #selector(performFindAction(_:)):
            // The editor's find bar can do everything `NSTextFinder` defines,
            // including Replace; the preview's can do the four that make sense
            // for something you cannot type into.
            if editorHasFocus { return true }
            return finder.validate(NSTextFinder.Action(rawValue: item.tag) ?? .showFindInterface)
        case #selector(navigateToParent(_:)):
            return sidebar.navigator.canGoUp
        case #selector(navigateBack(_:)):
            return sidebar.navigator.canGoBack
        case #selector(navigateForward(_:)):
            return sidebar.navigator.canGoForward
        case #selector(revealInSidebar(_:)):
            return tabs.selected != nil
        case #selector(revealInFinder(_:)):
            return sidebar.selectedNode != nil || tabs.selected != nil
        case #selector(toggleShowsNonMarkdownFiles(_:)):
            item.state = sidebar.listingOptions.showsNonMarkdown ? .on : .off
            return true
        case #selector(toggleShowsHiddenFiles(_:)):
            item.state = sidebar.listingOptions.showsHidden ? .on : .off
            return true
        case #selector(toggleInvisibles(_:)):
            // Enabled with the editor hidden, like `Show Changes` is with no
            // repository: it is a setting the next editor to open will honour,
            // and greying it out would say the setting does not exist.
            item.state = Invisibles.isShowing ? .on : .off
            return true
        case #selector(sortSidebar(_:)):
            item.state =
                TreeSort.allCases.indices.contains(item.tag)
                && TreeSort.allCases[item.tag] == sidebar.sort ? .on : .off
            return true
        case #selector(closeOtherTabs(_:)):
            return tabs.count > 1
        case #selector(closeAllTabs(_:)):
            // The window's tabs, not the focused group's: the item closes both
            // halves of a split, so it has to stay enabled while the only
            // documents left are in the other one.
            return !groups.allTabs.isEmpty
        case #selector(splitRight(_:)):
            // Two tabs in the focused group, because splitting *moves* one: a
            // group with a single tab has nothing to keep on this side, and one
            // document in two groups is still forbidden.
            return !groups.isSplit && tabs.count >= 2
        case #selector(closeSplit(_:)), #selector(focusOtherPane(_:)):
            return groups.isSplit
        case #selector(moveToOtherPane(_:)):
            guard let tab = (item.representedObject as? DocumentTab) ?? tabs.selected,
                let owner = groups.group(of: tab)
            else { return false }
            // Moving a group's only tab is a move when there is somewhere to
            // move it *to* — which collapses the split — and nothing at all
            // when there is only one group.
            return owner.count >= 2 || groups.isSplit
        case #selector(popOutTab(_:)):
            // Popping the only tab out would move this window's contents into a
            // new window and leave an empty one behind, which is not what
            // anyone means by "pop this out".
            return windows != nil && tabs.count >= 2
        case #selector(newWindow(_:)):
            return windows != nil
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return tabs.count > 1
        case #selector(selectTabByNumber(_:)):
            // The focused group's bar: ⌘1–9 are positions in the bar the reader
            // is looking at, not in a window-flat list they cannot see.
            return item.tag == 9 ? !tabs.isEmpty : tabs.tabs.indices.contains(item.tag - 1)
        default:
            return true
        }
    }
}

// MARK: - The editor split

/// Minimum widths for the preview and the editor.
///
/// Both are real minimums rather than politeness: a 40 pt preview cannot show a
/// code block, and a 40 pt editor wraps every line of markdown into a column of
/// single words. Dragging the divider to either end collapses the pane instead,
/// which is what ADR-6's "collapsible" means in AppKit.
extension MainWindowController: @MainActor NSSplitViewDelegate {

    public func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat,
        ofSubviewAt index: Int
    ) -> CGFloat {
        max(proposed, 320)
    }

    public func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat,
        ofSubviewAt index: Int
    ) -> CGFloat {
        min(proposed, splitView.bounds.width - 260)
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === editor
    }

    public func splitView(
        _ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
        forDoubleClickOnDividerAt index: Int
    ) -> Bool {
        subview === editor
    }
}

// MARK: - Layout

/// How far down a piece of chrome has to start to clear the title bar.
///
/// The window carries `.fullSizeContentView` (M2's choice, unchanged here), so
/// the content view extends *under* the title bar and a bar at y = 0 is drawn
/// behind the traffic lights and the window title. The first screenshot of M3
/// showed the first tab as a smear behind the title text; no test caught it,
/// and none would have.
///
/// `safeAreaInsets` is the documented answer and is the first thing tried. It
/// is **0** for the content item: `NSSplitViewController` applies the title-bar
/// allowance to its *sidebar* item and leaves the other flush with the top of
/// the content view. So the allowance is derived from the window directly when
/// AppKit does not supply one, and only for a view that really does reach the
/// top.
///
/// - Parameter view: a **flipped** view, so that its (0, 0) is its top-left.
@MainActor
func titlebarInset(for view: NSView) -> CGFloat {
    if view.safeAreaInsets.top > 0 { return view.safeAreaInsets.top }
    guard let window = view.window, let content = window.contentView else { return 0 }
    let titlebar = content.bounds.height - window.contentLayoutRect.height
    guard titlebar > 0 else { return 0 }
    // The caller is flipped, so its origin in the content view's unflipped
    // coordinates is the max-y edge.
    let top = view.convert(NSPoint.zero, to: content)
    return top.y >= content.bounds.maxY - 0.5 ? titlebar : 0
}

/// The preview column: the stacked web views, with ⌘F's bar along the bottom.
///
/// The find bar belongs to the *preview*, not to the window, which is why it
/// lives here rather than beside the tab bar: with the editor pane open the two
/// halves have separate find bars — this one, and `NSTextView`'s own — and a
/// bar spanning both would be claiming to search text it has never looked at.
@MainActor
public final class PreviewPaneView: NSView {

    private let findBar: FindBar
    /// Typed as `NSView` for the same reason ``DocumentAreaView``'s is: this
    /// view's job is two frames and a subtraction.
    private let container: NSView

    /// **Order matters, and it cost a debugging session to find out.** The
    /// container holds `WKWebView`s, which are layer-*hosted*: their layer is
    /// composited by WebKit, and a sibling added before them is painted over
    /// wholesale — not clipped to the overlap, painted over. The find bar added
    /// first drew nothing at all on screen while rendering perfectly in an
    /// offscreen snapshot, which is exactly how that failure presents.
    public init(frame: NSRect, findBar: FindBar, container: NSView) {
        self.findBar = findBar
        self.container = container
        super.init(frame: frame)
        addSubview(container)
        addSubview(findBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreviewPaneView is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        let barHeight = findBar.isHidden ? 0 : FindBar.barHeight
        container.frame = NSRect(
            x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
        findBar.frame = NSRect(
            x: 0, y: bounds.height - FindBar.barHeight, width: bounds.width,
            height: FindBar.barHeight)
        super.layout()
    }
}

/// One editor group on screen: its tab bar on top, its documents below.
///
/// Frame-based rather than autolayout for the same reason the document views
/// are: this view has two children whose geometry is one subtraction, and a
/// constraint solver invoked on every window resize with 20 resident web views
/// beneath it is a cost with nothing to show for it.
///
/// **One of these per group** (`2026-08-26-editor-groups-per-pane-tab-bars`).
/// It used to be the whole document half of the window — tab bar, editor split
/// and all — because a window had one bar. What was window-level about it lives
/// in ``WindowBodyView`` now: the title-bar allowance, and the folder drop.
@MainActor
public final class DocumentAreaView: NSView {

    public let tabBar: TabBarView
    public let container: DocumentContainerView

    public init(tabBar: TabBarView, container: DocumentContainerView) {
        self.tabBar = tabBar
        self.container = container
        super.init(frame: NSRect(x: 0, y: 0, width: 450, height: 700))
        addSubview(tabBar)
        addSubview(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentAreaView is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        let barHeight = tabBar.isHidden ? 0 : TabBarView.barHeight
        tabBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: TabBarView.barHeight)
        container.frame = NSRect(
            x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight)
        )
        super.layout()
    }
}

/// The window's document half: everything below the title bar.
///
/// Two jobs, both of which used to belong to ``DocumentAreaView`` when a window
/// had one tab bar and that view *was* the document half:
///
/// * **the title-bar allowance.** The window carries `.fullSizeContentView`, so
///   the content view extends under the title bar and chrome at y = 0 is drawn
///   behind the traffic lights. With one bar per group there is no single bar to
///   inset, so the whole body is inset once and every group's bar sits at its
///   own y = 0.
/// * **the folder drop**, which is a window-level gesture: dropping a folder
///   anywhere in the document half sets the sidebar's root, and which group it
///   landed over means nothing.
@MainActor
public final class WindowBodyView: NSView {

    /// The preview/editor split. Typed as `NSView` because this view's job is
    /// one frame and one subtraction; what is inside it is not its business.
    private let content: NSView

    /// Plan §2 M8's *"drop a folder onto the window to set the root"*, on the
    /// document half. Returns whether the drop was accepted.
    ///
    /// The sidebar registers for the same drop, so both halves of the window
    /// answer. What neither can claim is the region a `WKWebView` covers:
    /// WebKit installs its own drag destination on its hosting view and takes
    /// the drop before AppKit walks back up to us. Dropping on a tab bar, an
    /// empty state, or anywhere in the sidebar works; dropping onto a rendered
    /// document is WebKit's, and that is a limitation rather than a bug we can
    /// fix from here.
    public var onDrop: (([URL]) -> Bool)?

    public init(frame: NSRect, content: NSView) {
        self.content = content
        super.init(frame: frame)
        addSubview(content)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WindowBodyView is created in code, not from a nib")
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        SidebarContainerView.urls(from: sender).isEmpty ? [] : .generic
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        SidebarContainerView.urls(from: sender).isEmpty ? [] : .generic
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop?(SidebarContainerView.urls(from: sender)) ?? false
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        let top = titlebarInset(for: self)
        content.frame = NSRect(
            x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        super.layout()
    }

    // AppKit has no `safeAreaInsetsDidChange` on `NSView` (that is UIKit); it
    // re-lays-out the content view when the window's layout rect changes, so
    // `layout()` above is the whole story for entering and leaving full screen.
}

/// One group's resident web views, of which exactly one is on screen.
///
/// Every resident ``DocumentView`` for this group is a subview; ``layout()``
/// gives the displayed one the container's bounds and hides the rest. Showing a
/// tab is a show/hide rather than a re-injection — the outgoing view keeps its
/// DOM, its scroll position and its JS state, which is what makes a tab switch
/// 0.05 ms.
///
/// **One container per group** (`2026-08-26-editor-groups-per-pane-tab-bars`).
/// The one-bar model put two documents in one container and framed them side by
/// side, which is where the split's two rendering bugs lived: this container's
/// own `draw(_:)` drew a divider and a focus stripe *under* the web views, and
/// each pane's background painted over the other. Neither is possible now. The
/// divider belongs to ``GroupSplitView``, above both containers; the focus
/// indicator belongs to the tab bars; and a container has one document in it.
@MainActor
public final class DocumentContainerView: NSView {

    public override var isFlipped: Bool { true }

    /// Shown when this group has no tabs. A window keeps its sidebar when every
    /// document is closed, which is the whole reason a mark window is heavier
    /// than a bare document viewer.
    public let emptyStateLabel: NSTextField

    /// The resident ``DocumentView``s, in creation order.
    public var documentViews: [DocumentView] { subviews.compactMap { $0 as? DocumentView } }

    /// The one on screen, if any.
    public var visibleDocumentView: DocumentView? { documentViews.first { !$0.isHidden } }

    /// Kept for the callers that ask "which documents are up" without caring
    /// that the answer is now at most one per container.
    public var visibleDocumentViews: [DocumentView] { documentViews.filter { !$0.isHidden } }

    /// The view this container is showing.
    public private(set) var shownView: DocumentView?

    /// Called when the reader clicks the part of this container that no web
    /// view covers — a request to focus this group.
    public var onFocusRequested: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        emptyStateLabel = NSTextField(labelWithString: "No document open")
        emptyStateLabel.font = .systemFont(ofSize: 15)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: frameRect)
        addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentContainerView is created in code, not from a nib")
    }

    /// Put `view` on screen and hide every other resident view here.
    public func show(_ view: DocumentView?) {
        shownView = view
        for resident in documentViews {
            resident.isHidden = resident !== view
        }
        emptyStateLabel.isHidden = view != nil
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        shownView?.frame = bounds
    }

    /// A mouse-down that reached this container landed on the strip no web view
    /// covers — anything inside one never gets here, because WebKit took it,
    /// which is why group focus also comes from ``DocumentWebView``.
    public override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }
}

/// The groups side by side, with the divider between them.
///
/// **A divider view rather than drawing.** ``PreviewPaneView``'s header records
/// what drawing does around a layer-hosted `WKWebView`, and
/// `2026-08-26-editor-groups-per-pane-tab-bars` turned that note into a
/// constraint after the one-bar split shipped a blank pane: *nothing draws
/// around a `WKWebView` in a shared coordinate space*. So the divider is a
/// layer-backed view, added **after** both groups — a sibling added before them
/// is painted over wholesale, and one added after composites correctly, which
/// is the same order ``PreviewPaneView`` uses for the find bar.
@MainActor
public final class GroupSplitView: NSView {

    /// How the groups divide the width. Clamped, so neither can be dragged to
    /// nothing — collapsing is what ⇧⌘\ is for, and a 20 pt document is not a
    /// smaller document, it is an unusable one.
    public static let minimumSplitFraction: CGFloat = 0.2
    public static let maximumSplitFraction: CGFloat = 0.8
    public static let dividerWidth: CGFloat = 1
    /// The invisible margin either side of the divider that still starts a
    /// drag. A 1 pt hit target is a 1 pt hit target.
    public static let dividerGrabWidth: CGFloat = 9

    public override var isFlipped: Bool { true }

    /// The groups' areas, left to right. One, or two when split.
    public private(set) var areas: [DocumentAreaView] = []

    private let divider = DividerView(frame: .zero)

    public var isSplit: Bool { areas.count == 2 }

    /// Where the divider sits, as a fraction of the width.
    public var splitFraction: CGFloat = 0.5 {
        didSet {
            splitFraction = min(
                max(Self.minimumSplitFraction, splitFraction), Self.maximumSplitFraction)
            needsLayout = true
        }
    }

    /// Called when the reader drags the divider, so the window can persist it.
    public var onSplitFractionChanged: ((CGFloat) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GroupSplitView is created in code, not from a nib")
    }

    /// Put these areas on screen, in this order.
    public func show(_ areas: [DocumentAreaView]) {
        for area in self.areas where !areas.contains(area) {
            area.removeFromSuperview()
        }
        self.areas = areas
        for area in areas where area.superview !== self {
            // Below the divider, which is why it is added rather than drawn:
            // see this type's header.
            addSubview(area, positioned: .below, relativeTo: divider)
        }
        divider.isHidden = areas.count < 2
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    public override func layout() {
        super.layout()
        guard !areas.isEmpty else { return }
        guard areas.count == 2 else {
            areas[0].frame = bounds
            divider.frame = .zero
            return
        }
        let dividerX = (bounds.width * splitFraction).rounded()
        areas[0].frame = NSRect(x: 0, y: 0, width: max(0, dividerX), height: bounds.height)
        divider.frame = NSRect(
            x: dividerX, y: 0, width: Self.dividerWidth, height: bounds.height)
        areas[1].frame = NSRect(
            x: dividerX + Self.dividerWidth, y: 0,
            width: max(0, bounds.width - dividerX - Self.dividerWidth),
            height: bounds.height)
    }

    // MARK: - The divider drag

    private var dividerRect: NSRect {
        let dividerX = (bounds.width * splitFraction).rounded()
        return NSRect(
            x: dividerX - Self.dividerGrabWidth / 2, y: 0,
            width: Self.dividerGrabWidth, height: bounds.height)
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard isSplit else { return }
        addCursorRect(dividerRect, cursor: .resizeLeftRight)
    }

    public override func mouseDown(with event: NSEvent) {
        guard isSplit else {
            super.mouseDown(with: event)
            return
        }
        let start = convert(event.locationInWindow, from: nil)
        guard dividerRect.contains(start) else {
            super.mouseDown(with: event)
            return
        }

        // A modal tracking loop, matching `TabBarView`: the frames being
        // dragged belong to layer-hosted web views, and letting AppKit
        // interleave other event handling mid-drag is how the two groups end up
        // disagreeing about where the divider is.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            guard bounds.width > 0 else { break }
            splitFraction = point.x / bounds.width
            layoutSubtreeIfNeeded()
            displayIfNeeded()
        }
        window?.invalidateCursorRects(for: self)
        onSplitFractionChanged?(splitFraction)
    }

    /// Which area, if any, contains a point in this view's coordinates.
    ///
    /// The tab bar's cross-divider drag asks this on mouse-up to find out which
    /// group the reader dropped a tab into.
    public func areaIndex(at point: NSPoint) -> Int? {
        areas.firstIndex { $0.frame.contains(point) }
    }
}

/// The 1 pt line between two groups.
///
/// A view with a layer background rather than a drawn rectangle, for the reason
/// ``GroupSplitView`` gives — and because a hairline that has to be *seen*
/// beside a `WKWebView` is exactly the thing that was invisible before.
@MainActor
final class DividerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DividerView is created in code") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
