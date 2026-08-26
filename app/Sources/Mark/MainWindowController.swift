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

    /// The sidebar's lower half: the front document's headings, clickable.
    public let toc: TableOfContentsViewController

    /// The two of them, stacked. One sidebar still, as ADR-4 requires.
    public let sidebarPane: SidebarPaneController

    public let tabs: TabStore
    public let tabBar: TabBarView

    /// Where the resident web views live, stacked. Exactly one is unhidden.
    public let documentContainer: DocumentContainerView

    /// ⌘F's bar, along the bottom of the preview. Hidden until asked for.
    public let findBar: FindBar

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

    /// Shown when every tab has been closed. The window stays — it still has
    /// the sidebar, which is the entire reason ADR-4 chose one window over N.
    private let emptyStateLabel: NSTextField

    /// The selected tab's view, or `nil` when nothing is open.
    ///
    /// Optional on purpose. In M2 this was a stored, always-present property;
    /// under ADR-4 there is no such thing, because a window with no tabs has no
    /// web view at all and a dehydrated tab has none either. Callers that
    /// force-unwrapped it would be the first instance of the "assumes a tab's
    /// web view exists" bug the ADR warns about.
    public var documentView: DocumentView? { tabs.selected?.documentView }

    public init(root: URL, session: Session = Session()) {
        self.session = session
        sidebar = TreeViewController(root: root)
        toc = TableOfContentsViewController()
        sidebarPane = SidebarPaneController(tree: sidebar, contents: toc)
        tabs = TabStore()
        tabBar = TabBarView(store: tabs)
        documentContainer = DocumentContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

        emptyStateLabel = NSTextField(labelWithString: "No document open")
        emptyStateLabel.font = .systemFont(ofSize: 15)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        editor = EditorPane(frame: NSRect(x: 0, y: 0, width: 380, height: 700))
        // Hidden by default: ADR-6 says *"the pane is collapsible and hidden by
        // default; a document opens read-only until the user asks to edit it"*.
        editor.isHidden = true
        conflicts = ConflictController()

        findBar = FindBar(
            frame: NSRect(x: 0, y: 0, width: 900, height: FindBar.barHeight))
        findBar.isHidden = true
        previewPane = PreviewPaneView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            findBar: findBar,
            container: documentContainer
        )

        editorSplit = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        editorSplit.isVertical = true
        editorSplit.dividerStyle = .thin
        editorSplit.addSubview(previewPane)
        editorSplit.addSubview(editor)

        let documentArea = DocumentAreaView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            tabBar: tabBar,
            container: editorSplit
        )
        documentContainer.addSubview(emptyStateLabel)

        let documentController = NSViewController()
        documentController.view = documentArea

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

        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: documentContainer.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: documentContainer.centerYAnchor),
        ])

        // Before the store gets a delegate, so no tab can exist — and therefore
        // no `tabStoreDidChangeTabs` can reach ``syncWatchedFiles()`` — while
        // this is still nil.
        watcher = FileWatcher { [weak self] change in
            self?.documentChangedOnDisk(change)
        }
        tabs.delegate = self
        tabs.hydrator = self
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
        // M8: the root, the history, and the two listing toggles all live in
        // the session file, so anything that moves them schedules a save.
        sidebar.onStateChange = { [weak self] in
            self?.saveSessionSoon()
        }
        // ADR-6: *"nothing may read the file for […] task counts […] on a
        // dirty tab"*. The sidebar's badge is a task count computed from a file
        // read, so it asks here first and counts the buffer's tasks instead.
        sidebar.badges.dirtySource = { [weak self] url in
            self?.tabs.tab(for: url)?.authoritativeSource
        }
        documentArea.onDrop = { [weak self] urls in
            self?.sidebar.handleDrop(urls) ?? false
        }
        documentContainer.onSplitFractionChanged = { [weak self] _ in
            self?.saveSessionSoon()
        }
        documentContainer.onPaneClicked = { [weak self] pane in
            self?.tabs.moveFocus(to: pane)
        }
        // Picking a heading scrolls the preview to it — the sidebar's other
        // half answers "which file", this one answers "where in it".
        toc.onSelect = { [weak self] heading in
            self?.scrollToHeading(heading)
        }
        findBar.onQueryChanged = { [weak self] query in
            self?.search(query)
        }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose = { [weak self] in self?.setFindBarVisible(false) }
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
        tabs.open(url, preview: preview)
    }

    /// Move the focus to whichever pane is showing `tab`.
    ///
    /// The destination of ``DocumentView/onFocus``: the reader clicked into a
    /// document, and the window has to decide that document is now the one the
    /// tab bar, the find bar and the menus act on.
    func focusPane(showing tab: DocumentTab) {
        guard let pane = Pane.allCases.first(where: { tabs.panes.tab(in: $0) === tab }) else {
            return
        }
        tabs.moveFocus(to: pane)
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
        watcher.setWatched(Set(tabs.tabs.map(\.url)))
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
        let matching = tabs.tabs.filter { $0.url == url }
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
                        tab.refreshMetadata { [weak self] in self?.tabBar.reload() }
                        continue
                    case .adopted, .converged:
                        // `adopted` has already pushed the text into the editor
                        // through `onChange`; both need the preview and the
                        // badge brought up to date, which the code below does.
                        break
                    }
                }

                tab.refreshMetadata { [weak self, weak tab] in
                    guard let self, let tab, self.tabs.tabs.contains(tab) else { return }
                    self.tabBar.reload()
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
            tab.refreshMetadata { [weak self] in self?.tabBar.reload() }
        }
        buffer.onSaved = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            self.sidebar.invalidateBadge(for: tab.url)
            tab.refreshMetadata { [weak self] in self?.tabBar.reload() }
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
        // The outline is a function of the document, so it has to move when the
        // document does. This is the only edit path that changes the headings
        // without changing dirtiness — `onDirtyChanged` catches the first
        // keystroke and the save, and every keystroke in between lands here.
        // It costs the same background `toc` call the tab bar's badge already
        // pays for, against the buffer rather than the file.
        tab.refreshMetadata { [weak self] in
            self?.tabBar.reload()
            self?.updateTableOfContents()
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
        for tab in tabs.tabs {
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

    // MARK: - The table of contents

    /// Show the selected document's headings in the sidebar's lower half.
    ///
    /// Called from ``updateChrome()``, which is the one place that already runs
    /// on every tab switch, every tab-list change, and every metadata load —
    /// so there is no second list of "things that should also refresh the
    /// outline" to forget to update. ``TableOfContentsViewController/show(_:for:)``
    /// compares before it rebuilds, so calling it that often costs an array
    /// comparison rather than a reload.
    private func updateTableOfContents() {
        let tab = tabs.selected
        toc.show(tab?.metadata?.headings ?? [], for: tab?.url)
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

    // MARK: - Finding in the document

    /// The string the preview is currently showing matches for.
    private var findQuery = ""

    /// Bumped on every search, so a slow answer for a query the reader has
    /// already typed past cannot overwrite a newer one.
    private var findGeneration = 0

    public var isFindBarVisible: Bool { !findBar.isHidden }

    /// Show or hide ⌘F's bar.
    ///
    /// Hiding it drops the highlights as well as the bar. Leaving twelve
    /// yellow words behind after the bar has gone would look like the document
    /// had been marked up rather than searched.
    public func setFindBarVisible(_ visible: Bool) {
        guard visible != isFindBarVisible else { return }
        findBar.isHidden = !visible
        previewPane.needsLayout = true
        findBar.needsLayout = true
        findBar.needsDisplay = true
        guard !visible else { return }
        findQuery = ""
        findGeneration += 1
        findBar.query = ""
        findBar.report(nil)
        if let view = documentView {
            _Concurrency.Task { @MainActor in await view.clearFind() }
            window?.makeFirstResponder(view.webView)
        }
    }

    /// ⌘F.
    public func showFindBar() {
        setFindBarVisible(true)
        previewPane.layoutSubtreeIfNeeded()
        findBar.focus()
    }

    /// ⌘G, ↩, and the bar's down arrow.
    public func findNext() {
        advance(forward: true)
    }

    /// ⇧⌘G, ⇧↩, and the bar's up arrow.
    public func findPrevious() {
        advance(forward: false)
    }

    /// Move to the next or previous match, wrapping at both ends.
    ///
    /// A step through ranges the page has already built, not another search —
    /// which is what makes holding ⌘G down feel like cycling rather than like
    /// re-running a query twelve times.
    private func advance(forward: Bool) {
        guard isFindBarVisible, !findQuery.isEmpty else {
            // ⌘G with nothing to repeat is a request for the bar, not a beep.
            showFindBar()
            return
        }
        guard let view = documentView else { return }
        findGeneration += 1
        let generation = findGeneration
        _Concurrency.Task { @MainActor [weak self] in
            let result = await view.stepFind(forward: forward)
            guard let self, generation == self.findGeneration else { return }
            self.findBar.report(result)
        }
    }

    /// ⌘E — take the query from what the reader has selected in the preview.
    public func useSelectionForFind() {
        guard let view = documentView else { return }
        _Concurrency.Task { @MainActor [weak self] in
            let selection = await view.selectedText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !selection.isEmpty else { return }
            self.setFindBarVisible(true)
            self.findBar.query = selection
            self.search(selection)
        }
    }

    /// Search the preview, highlight every match, and report the position.
    private func search(_ query: String) {
        findQuery = query
        findGeneration += 1
        let generation = findGeneration
        guard let view = documentView else {
            findBar.report(query.isEmpty ? nil : FindResult.empty)
            return
        }
        guard !query.isEmpty else {
            findBar.report(nil)
            _Concurrency.Task { @MainActor in await view.clearFind() }
            return
        }
        _Concurrency.Task { @MainActor [weak self] in
            let result = await view.find(query)
            guard let self, generation == self.findGeneration else { return }
            self.findBar.report(result)
        }
    }

    /// Run the current search again, because the document underneath it moved.
    ///
    /// Every range the page holds points into a block element, and a patch
    /// replaces block elements — so an edit, an external change, or a tab
    /// switch leaves the highlights stale. `shell.js` drops them on every
    /// document mutation; this is what puts them back.
    private func refreshFind() {
        guard isFindBarVisible, !findQuery.isEmpty else { return }
        search(findQuery)
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
        return state
    }

    /// This window's state, for the coordinator to assemble with the others.
    public func windowSnapshot() -> SessionWindow {
        let sidebarState = sidebar.snapshot()
        return SessionWindow(
            tabs: tabs.tabs.map {
                SessionTab(
                    path: $0.url.path,
                    scrollOffset: $0.documentView?.scrollOffset ?? $0.scrollOffset,
                    title: $0.metadata?.documentTitle,
                    preview: $0.isPreview
                )
            },
            selectedIndex: tabs.selectedIndex,
            secondaryIndex: tabs.secondary.flatMap { tabs.index(of: $0) },
            focus: tabs.focus.rawValue,
            splitFraction: Double(documentContainer.splitFraction),
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
        if let fraction = state.splitFraction {
            documentContainer.splitFraction = CGFloat(fraction)
        }
        restoreFrame(state.frame)
        setSidebarCollapsed(state.sidebarCollapsed ?? false)
        tabs.restore(state)
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
        emptyStateLabel.isHidden = !tabs.isEmpty
        updateTableOfContents()
        if tabBar.isHidden != tabs.isEmpty {
            tabBar.isHidden = tabs.isEmpty
            tabBar.superview?.needsLayout = true
        }
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
        let view = DocumentView(frame: documentContainer.bounds)
        // Frame-based rather than autoresizing, because the container now
        // places its views rather than stacking them: a split gives the two
        // displayed views half the width each, and an autoresizing mask would
        // fight `DocumentContainerView.layout()` for the frame on every resize.
        view.isHidden = true
        documentContainer.addSubview(view)
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
        view.onScroll = { [weak self, weak tab] y in
            guard let self, let tab else { return }
            tab.scrollOffset = y
            self.saveSessionSoon()
        }
        // Clicking into a document is how a reader says which pane they mean.
        // A `WKWebView` swallows the click, so the signal comes from the view
        // taking first-responder rather than from a mouse event we never see.
        view.onFocus = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.focusPane(showing: tab)
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
        view.isHidden = true
        documentContainer.addSubview(view)
        wire(view, to: tab)
        // The buffer's callbacks captured the old window too, and one of them
        // is load-bearing in a way that fails silently — see `wire(_:to:)` for
        // `Buffer`.
        if let buffer = tab.buffer {
            wire(buffer, to: tab)
        }
        documentContainer.needsLayout = true
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
        tabBar.reload()
        updateChrome()
        syncWatchedFiles()
        saveSessionSoon()
    }

    /// Which document is in which pane, and which pane is being acted on.
    ///
    /// The switch itself is still a show/hide, measured at 0.05 ms median
    /// because that is all it is: no re-injection, no re-layout of the
    /// document, no scroll restoration. Splitting adds a second view to the
    /// same operation rather than a different one.
    public func tabStore(_ store: TabStore, didChangePanes panes: PaneArrangement) {
        let state = Log.signposter.beginInterval("tab switch")
        documentContainer.show(
            primary: panes.primary?.documentView,
            secondary: panes.secondary?.documentView)
        documentContainer.focusedPane = panes.focus
        Log.signposter.endInterval("tab switch", state)
        tabBar.reload()
        updateChrome()
        // The bar stays open across a split, and its highlights belonged to
        // whichever document was being searched.
        refreshFind()
        saveSessionSoon()
    }

    /// The selection moved within the focused pane.
    public func tabStore(_ store: TabStore, didSelect tab: DocumentTab?, previous: DocumentTab?) {
        // The pane contents are set by `didChangePanes`, which the store fires
        // first. This one is about everything that follows *the selection*
        // rather than the layout.
        documentContainer.show(
            primary: store.panes.primary?.documentView,
            secondary: store.panes.secondary?.documentView)
        documentContainer.focusedPane = store.focus
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
        tabBar.reload()
        updateChrome()
        // The bar stays open across a switch, and its highlights were the
        // other document's. The new document has none until this runs.
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
        let tab = tabs.open(url)
        if let previous, previous != tab { tabs.select(previous) }
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
        guard let windows else { return tabs.tabs.map { summary(for: $0) } }
        return windows.controllers.flatMap { controller in
            controller.tabs.tabs.map { controller.summary(for: $0) }
        }
    }

    public func selectTab(matching selector: TabSelector) throws -> TabSummary {
        // A path names a document, not a position, so it is worth finding in
        // another window rather than reporting absent from this one. An index
        // is a position *in a window's bar* and stays local — `tab select 2`
        // has always meant "the third tab of the window I am driving".
        if case .path(let path) = selector {
            let url = CommandRouter.fileURL(from: path)
            if tabs.tab(for: url) == nil,
                let owner = windows?.controllers.first(where: { $0.tabs.tab(for: url) != nil }),
                let tab = owner.tabs.tab(for: url)
            {
                owner.tabs.select(tab)
                owner.showWindow(activating: false)
                return owner.summary(for: tab)
            }
        }
        let tab = try resolve(selector)
        tabs.select(tab)
        showWindow(activating: false)
        return summary(for: tab)
    }

    public func closeTab(matching selector: TabSelector) throws -> TabSummary {
        let tab = try resolve(selector)
        // Captured before the close, because afterwards the tab has no index.
        let closed = summary(for: tab)
        tabs.close(tab)
        return closed
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
        tab.refreshMetadata { [weak self] in self?.tabBar.reload() }
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
        for tab in tabs.tabs {
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
            guard tabs.tabs.indices.contains(index) else {
                throw CommandFailure(
                    .tabNotFound,
                    "there is no tab \(index); \(tabs.count) \(tabs.count == 1 ? "tab is" : "tabs are") open",
                    detail: ["index": .int(index), "tabs": .int(tabs.count)]
                )
            }
            return tabs.tabs[index]
        case .path(let path):
            let url = CommandRouter.fileURL(from: path)
            guard let tab = tabs.tab(for: url) else {
                // Say *where* it is rather than only that it is not here. With
                // more than one window "no tab is open on that" is a confusing
                // thing to be told about a document plainly on screen.
                if let elsewhere = windows?.controllers.firstIndex(where: {
                    $0.tabs.tab(for: url) != nil
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
            index: tabs.index(of: tab) ?? -1,
            path: tab.url.path,
            title: tab.metadata?.documentTitle ?? tab.title,
            selected: tab == tabs.selected,
            resident: tab.state.isResident,
            preview: tab.isPreview,
            openTasks: tab.metadata?.tasks.open,
            totalTasks: tab.metadata?.tasks.total,
            window: windows?.index(of: self),
            pane: Pane.allCases.first { tabs.panes.tab(in: $0) === tab }?.rawValue
        )
    }
}

// MARK: - Menu actions

/// With native tabbing AppKit supplies *and validates* ⌘T, ⌘W, ⌃⇥ and the
/// Window-menu tab items. ADR-4 traded that away, so this is the other half of
/// the bill: `NSMenuItemValidation` explicitly, because `NSWindowController`
/// does not conform to it and an `override` here compiles as nothing.
extension MainWindowController: NSMenuItemValidation {

    /// ⌘T. A viewer has no blank document to open, so "New Tab" is the open
    /// panel — the tab is what you get, and the file is what you choose.
    @objc public func newTab(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = tabs.selected?.url.deletingLastPathComponent() ?? sidebar.root
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
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
        tabs.close(tab)
    }

    @objc public func closeOtherTabs(_ sender: Any?) {
        guard let keep = tabForMenuItem(sender) else { return }
        for tab in tabs.tabs where tab != keep { tabs.close(tab) }
    }

    // MARK: - Panes (2026-08-26-multiple-windows-and-split-panes)

    /// ⌘\ — put a second document on screen beside this one.
    @objc public func splitRight(_ sender: Any?) {
        guard tabs.splitRight() else {
            NSSound.beep()
            return
        }
        saveSessionSoon()
    }

    /// ⇧⌘\ — back to one document, keeping the focused pane's.
    @objc public func closeSplit(_ sender: Any?) {
        guard tabs.closeSplit() else { return }
        saveSessionSoon()
    }

    /// ⌥⌘\ — move the focus to the other pane, so the tab bar acts on it.
    @objc public func focusOtherPane(_ sender: Any?) {
        guard tabs.isSplit else { return }
        tabs.moveFocus(to: tabs.focus.other)
        // Move the keyboard as well as the model's idea of focus, so ⌘F and
        // the arrow keys land in the pane the reader just switched to.
        if let webView = tabs.selected?.documentView?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    /// Open the tab under the pointer — or the selected one — in the right
    /// pane. The tab bar's context menu; there is no key equivalent, because
    /// ⌘\ already answers "show me two".
    @objc public func openInRightPane(_ sender: Any?) {
        guard let tab = tabForMenuItem(sender) else { return }
        guard tabs.count >= 2 else {
            NSSound.beep()
            return
        }
        // Asking for the *left* pane's document on the right, with nothing
        // split yet, means "put this one over there and show me something
        // else here" — not "empty the left half". Splitting first gives the
        // left pane a companion; the swap then puts the asked-for document
        // where it was asked to go.
        if !tabs.isSplit, tabs.primary === tab {
            guard tabs.splitRight() else {
                NSSound.beep()
                return
            }
            tabs.swapPanes()
        } else {
            tabs.show(tab, in: .secondary)
        }
        saveSessionSoon()
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

    /// ⌃⌘T — show or hide the sidebar's table of contents.
    @objc public func toggleTableOfContents(_ sender: Any?) {
        sidebarPane.setContentsVisible(!sidebarPane.isContentsVisible)
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
        switch action {
        case .showFindInterface: showFindBar()
        case .hideFindInterface: setFindBarVisible(false)
        case .nextMatch: findNext()
        case .previousMatch: findPrevious()
        case .setSearchString: useSelectionForFind()
        default:
            // Replace and its relatives belong to the editor. The preview is
            // rendered output; there is nothing there to write through to.
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
                self?.tabBar.reload()
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
        case #selector(toggleTableOfContents(_:)):
            item.state = sidebarPane.isContentsVisible ? .on : .off
            return true
        case #selector(performFindAction(_:)):
            // The editor's find bar can do everything `NSTextFinder` defines,
            // including Replace; the preview's can do the four that make sense
            // for something you cannot type into.
            if editorHasFocus { return true }
            switch NSTextFinder.Action(rawValue: item.tag) ?? .showFindInterface {
            case .showFindInterface, .setSearchString:
                return tabs.selected != nil
            case .nextMatch, .previousMatch:
                return tabs.selected != nil && !findQuery.isEmpty
            case .hideFindInterface:
                return isFindBarVisible
            default:
                return false
            }
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
        case #selector(sortSidebar(_:)):
            item.state =
                TreeSort.allCases.indices.contains(item.tag)
                && TreeSort.allCases[item.tag] == sidebar.sort ? .on : .off
            return true
        case #selector(closeOtherTabs(_:)):
            return tabs.count > 1
        case #selector(splitRight(_:)):
            // Two tabs, because a split shows two *different* documents — one
            // tab in both panes is the thing
            // `2026-08-26-multiple-windows-and-split-panes` forbids outright.
            return !tabs.isSplit && tabs.count >= 2
        case #selector(closeSplit(_:)), #selector(focusOtherPane(_:)):
            return tabs.isSplit
        case #selector(openInRightPane(_:)):
            guard let tab = (item.representedObject as? DocumentTab) ?? tabs.selected else {
                return false
            }
            return tabs.count >= 2 && tabs.secondary !== tab
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

/// The document half of the split: the tab bar on top, the web views below.
///
/// Frame-based rather than autolayout for the same reason the stacked document
/// views are: this view has two children whose geometry is one subtraction, and
/// a constraint solver invoked on every window resize with 20 resident web
/// views beneath it is a cost with nothing to show for it.
@MainActor
public final class DocumentAreaView: NSView {

    private let tabBar: TabBarView
    /// The preview/editor split. Typed as `NSView` because this view's job is
    /// two frames and a subtraction; what is inside the lower one is not its
    /// business.
    private let container: NSView

    /// Plan §2 M8's *"drop a folder onto the window to set the root"*, on the
    /// document half. Returns whether the drop was accepted.
    ///
    /// The sidebar registers for the same drop, so both halves of the window
    /// answer. What neither can claim is the region a `WKWebView` covers:
    /// WebKit installs its own drag destination on its hosting view and takes
    /// the drop before AppKit walks back up to us. Dropping on the tab bar,
    /// the empty state, or anywhere in the sidebar works; dropping onto a
    /// rendered document is WebKit's, and that is a limitation rather than a
    /// bug we can fix from here.
    public var onDrop: (([URL]) -> Bool)?

    public init(frame: NSRect, tabBar: TabBarView, container: NSView) {
        self.tabBar = tabBar
        self.container = container
        super.init(frame: frame)
        addSubview(tabBar)
        addSubview(container)
        registerForDraggedTypes([.fileURL])
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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentAreaView is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        let top = titlebarInset(for: self)
        let barHeight = tabBar.isHidden ? 0 : TabBarView.barHeight
        tabBar.frame = NSRect(
            x: 0, y: top, width: bounds.width, height: TabBarView.barHeight)
        container.frame = NSRect(
            x: 0,
            y: top + barHeight,
            width: bounds.width,
            height: max(0, bounds.height - top - barHeight)
        )
        super.layout()
    }

    // AppKit has no `safeAreaInsetsDidChange` on `NSView` (that is UIKit); it
    // re-lays-out the content view when the window's layout rect changes, so
    // `layout()` above is the whole story for entering and leaving full screen.
}

/// The resident web views, of which one or two are on screen.
///
/// Every resident ``DocumentView`` is a subview; ``layout()`` gives the
/// displayed one or two a frame and hides the rest. Showing a tab is still a
/// show/hide rather than a re-injection — the outgoing view keeps its DOM, its
/// scroll position and its JS state, which is what makes a tab switch 0.05 ms.
///
/// **A hand-drawn divider rather than an `NSSplitView`.** ``PreviewPaneView``'s
/// header records a debugging session lost to subview ordering around
/// layer-hosted `WKWebView`s — a sibling added before them is painted over
/// wholesale, rendering perfectly in an offscreen snapshot and not at all on
/// screen. Wrapping this container in a split view rearranges exactly that
/// hierarchy. A divider view plus the modal tracking loop already used by
/// ``TabBarView/beginInteraction(with:event:)`` is less code and stays inside a
/// shape that is known to work here.
@MainActor
public final class DocumentContainerView: NSView {

    /// How the panes divide the width. Clamped, so neither pane can be dragged
    /// to nothing — collapsing is what ⇧⌘\ is for, and a 20 pt document is not
    /// a smaller version of a document, it is an unusable one.
    public static let minimumSplitFraction: CGFloat = 0.2
    public static let maximumSplitFraction: CGFloat = 0.8
    public static let dividerWidth: CGFloat = 1
    /// The invisible margin either side of the divider that still starts a
    /// drag. A 1 pt hit target is a 1 pt hit target.
    public static let dividerGrabWidth: CGFloat = 9

    /// The accent stripe marking the focused pane, drawn only when split.
    public static let focusStripeHeight: CGFloat = 2

    public override var isFlipped: Bool { true }

    /// The resident ``DocumentView``s, in creation order.
    public var documentViews: [DocumentView] { subviews.compactMap { $0 as? DocumentView } }

    /// The one or two views on screen, left to right.
    public var visibleDocumentViews: [DocumentView] { documentViews.filter { !$0.isHidden } }

    /// The leftmost view on screen, if any.
    ///
    /// Kept for the callers that predate the split and only ever want "the
    /// document"; anything that cares which pane should ask for ``panes``.
    public var visibleDocumentView: DocumentView? { visibleDocumentViews.first }

    /// The views the panes are showing. `secondary` is nil when not split.
    public private(set) var primaryView: DocumentView?
    public private(set) var secondaryView: DocumentView?

    /// Which pane draws the focus stripe.
    public var focusedPane: Pane = .primary {
        didSet { needsDisplay = true }
    }

    public var isSplit: Bool { secondaryView != nil }

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

    /// Called when the reader clicks in a pane that is not the focused one.
    public var onPaneClicked: ((Pane) -> Void)?

    /// Put these views on screen and hide everything else.
    public func show(primary: DocumentView?, secondary: DocumentView?) {
        primaryView = primary
        secondaryView = secondary
        for view in documentViews {
            view.isHidden = view !== primary && view !== secondary
        }
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        guard let primaryView else { return }
        if let secondaryView {
            let dividerX = (bounds.width * splitFraction).rounded()
            primaryView.frame = NSRect(
                x: 0, y: 0, width: max(0, dividerX), height: bounds.height)
            secondaryView.frame = NSRect(
                x: dividerX + Self.dividerWidth, y: 0,
                width: max(0, bounds.width - dividerX - Self.dividerWidth),
                height: bounds.height)
        } else {
            primaryView.frame = bounds
        }
    }

    /// The divider and the focused pane's stripe.
    ///
    /// Both are drawn rather than being subviews, for the layer-hosting reason
    /// in this type's header: a sibling view over a `WKWebView` is painted over
    /// wholesale. Drawing happens in this view's own backing store, underneath
    /// nothing, and the divider sits in the gap between the two web views where
    /// there is no web view to be painted over by.
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSplit else { return }
        let dividerX = (bounds.width * splitFraction).rounded()
        NSColor.separatorColor.setFill()
        NSRect(x: dividerX, y: 0, width: Self.dividerWidth, height: bounds.height).fill()

        // Which half is being acted on. Only drawn when split: unsplit there is
        // nothing to disambiguate, and a stripe across the top of every
        // single-document window would be chrome for its own sake.
        NSColor.controlAccentColor.setFill()
        let stripe =
            focusedPane == .primary
            ? NSRect(x: 0, y: 0, width: dividerX, height: Self.focusStripeHeight)
            : NSRect(
                x: dividerX + Self.dividerWidth, y: 0,
                width: bounds.width - dividerX - Self.dividerWidth,
                height: Self.focusStripeHeight)
        stripe.fill()
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

    /// A mouse-down here is either a divider drag or a click on the thin strip
    /// of container not covered by a web view. Anything landing inside a web
    /// view never reaches this method — WebKit took it — which is why pane
    /// focus comes from ``DocumentWebView`` instead.
    public override func mouseDown(with event: NSEvent) {
        guard isSplit else {
            super.mouseDown(with: event)
            return
        }
        let start = convert(event.locationInWindow, from: nil)
        guard dividerRect.contains(start) else {
            onPaneClicked?(start.x < bounds.width * splitFraction ? .primary : .secondary)
            super.mouseDown(with: event)
            return
        }

        // A modal tracking loop, matching `TabBarView`: the frames being
        // dragged belong to layer-hosted web views, and letting AppKit
        // interleave other event handling mid-drag is how the two panes end up
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
}
