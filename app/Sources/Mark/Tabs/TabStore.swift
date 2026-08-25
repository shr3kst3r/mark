import AppKit
import Foundation

/// Who makes and unmakes a tab's web view.
///
/// A protocol rather than a direct dependency on ``MainWindowController`` for
/// the same reason ``DirectoryLister`` is one: it is the only way to assert the
/// hydration state machine without putting 25 `WKWebView`s on screen in a unit
/// test. The window controller is the real implementation; the tests
/// substitute a counting stub and check *which* tabs were torn down and when,
/// which is the property ADR-4's memory bound actually rests on.
@MainActor
public protocol TabHydrator: AnyObject {
    /// Build a resident view for `tab`, add it to the document container, and
    /// start the ADR-2 prefix-then-fill open. Called synchronously; the open
    /// itself is asynchronous.
    func makeDocumentView(for tab: DocumentTab) -> DocumentView

    /// Take `view` out of the view hierarchy and release its web view.
    /// ``DocumentTab/scrollOffset`` has already been captured.
    func discardDocumentView(_ view: DocumentView, for tab: DocumentTab)
}

/// What the UI is told when the tab list changes.
@MainActor
public protocol TabStoreDelegate: AnyObject {
    /// The list, its order, or a tab's metadata changed. Redraw the bar.
    func tabStoreDidChangeTabs(_ store: TabStore)
    /// The selection moved. `previous` is nil on the first selection.
    func tabStore(_ store: TabStore, didSelect tab: DocumentTab?, previous: DocumentTab?)
    /// A tab is about to be removed and is still fully intact.
    ///
    /// The last moment an unsaved buffer can be written. Defaulted, so the
    /// stubs that only care about the two above are unaffected.
    func tabStore(_ store: TabStore, willClose tab: DocumentTab)
}

extension TabStoreDelegate {
    public func tabStore(_ store: TabStore, willClose tab: DocumentTab) {}
}

/// The open documents, their order, their MRU ranking, and ADR-4's
/// hydrate/dehydrate state machine.
///
/// This type deliberately knows nothing about AppKit views. Everything that
/// needs a web view goes through ``TabHydrator``; everything the tab bar needs
/// to draw is a plain value read off ``DocumentTab``. That split is what makes
/// the eviction policy — the part with the memory bound attached to it —
/// testable at all.
@MainActor
public final class TabStore {

/// How many tabs may hold a web view at once.
    ///
    /// **3, from `2026-08-24-tab-residency-and-memory-model`.** The superseded
    /// ADR said 20, derived from a measurement that put a resident tab at
    /// ~1.2 MB. That measurement summed RSS by walking the app's process
    /// subtree — but WebKit's content processes are children of launchd, not of
    /// us, so it could not see them at all. A resident tab actually costs
    /// ~52 MB: 20 of them is ~1.16 GB, 3 is ~264 MB.
    ///
    /// 3 keeps the current tab and the two most recently used switching in
    /// 0.0001 ms; anything beyond rehydrates in ~4.7 ms, which is imperceptible.
    /// Still a tunable, and still overridable at launch via `MARK_RESIDENT_TABS`
    /// — `MARK_RESIDENT_TABS=1` is a defensible setting, not a wrong one.
    public static let defaultResidentLimit = 3

    /// The environment override, read once. Nonsense values are ignored with a
    /// log line rather than silently clamping to something surprising.
    public static let configuredResidentLimit: Int = {
        guard let raw = ProcessInfo.processInfo.environment["MARK_RESIDENT_TABS"] else {
            return defaultResidentLimit
        }
        guard let value = Int(raw), value >= 1 else {
            Log.tabs.error(
                "MARK_RESIDENT_TABS=\(raw, privacy: .public) is not a positive integer; using \(defaultResidentLimit)"
            )
            return defaultResidentLimit
        }
        return value
    }()

    /// How many tabs may hold a web view at once.
    public var residentLimit: Int {
        didSet {
            residentLimit = max(1, residentLimit)
            enforceResidentLimit()
        }
    }

    /// Tabs in bar order. Reordering this is what drag-to-reorder does.
    public private(set) var tabs: [DocumentTab] = []

    public private(set) var selected: DocumentTab?

    public weak var delegate: (any TabStoreDelegate)?
    public weak var hydrator: (any TabHydrator)?

    /// Monotonic MRU clock. Every selection stamps the selected tab with the
    /// next value, so "least recently used" is a comparison and not a list to
    /// keep in sync.
    private var useClock: UInt64 = 0

    public init(residentLimit: Int = TabStore.configuredResidentLimit) {
        self.residentLimit = max(1, residentLimit)
    }

    // MARK: - Reading

    public var count: Int { tabs.count }
    public var isEmpty: Bool { tabs.isEmpty }

    public var selectedIndex: Int? {
        guard let selected else { return nil }
        return tabs.firstIndex(of: selected)
    }

    /// Tabs holding a web view — each costs ~52 MB of WebContent process
    /// (`2026-08-24-tab-residency-and-memory-model`), not the ~1.2 MB the
    /// superseded ADR assumed.
    public var residentCount: Int { tabs.filter { $0.state.isResident }.count }

    /// Most recently used first. The order eviction walks backwards.
    public var mruOrder: [DocumentTab] {
        tabs.sorted { $0.lastUsed > $1.lastUsed }
    }

    public func tab(for url: URL) -> DocumentTab? {
        let standardized = url.standardizedFileURL
        return tabs.first { $0.url == standardized }
    }

    /// The single preview tab, if there is one.
    ///
    /// *At most one* is the invariant every mutation here preserves, and it is
    /// the whole mechanism: a preview open does not add a tab, it **takes over
    /// this one's slot**. Reading it as a search rather than caching an index
    /// keeps it correct across reordering and closing for free.
    public var previewTab: DocumentTab? { tabs.first { $0.isPreview } }

    public func index(of tab: DocumentTab) -> Int? { tabs.firstIndex(of: tab) }

    // MARK: - Opening

    /// Open `url`, or select the tab already showing it.
    ///
    /// Re-selecting rather than duplicating is what makes the sidebar usable:
    /// clicking the same file twice should not leave two identical tabs.
    ///
    /// `preview` is VS Code's single-click semantics, and it is the difference
    /// between reading a directory of notes and drowning in tabs. A preview
    /// open **reuses the preview tab's slot**: the tab that was there is closed
    /// and the new one takes its index, so clicking down forty files leaves one
    /// tab rather than forty. A permanent open never displaces anything, and
    /// asking for a permanent open of a file that is already the preview
    /// promotes it in place — which is what makes clicking down the tree and
    /// then double-clicking the one you want do the obvious thing, rather than
    /// leaving a duplicate behind.
    ///
    /// The default is `false` so every existing caller — `mark open`, `mark://`,
    /// ⌘T, a drop on the window — keeps making permanent tabs. Only the
    /// sidebar's single click passes `true`.
    @discardableResult
    public func open(_ url: URL, preview: Bool = false) -> DocumentTab {
        if let existing = tab(for: url) {
            // A permanent open of the preview tab is a promotion, not a
            // no-op: `mark open` on the file you were skimming means keep it.
            if !preview, existing.promote() {
                delegate?.tabStoreDidChangeTabs(self)
            }
            select(existing)
            return existing
        }

        // The slot the new tab lands in. A preview open takes over the outgoing
        // preview tab's index so the bar does not visibly reshuffle; everything
        // else opens after the selection, as it always has.
        var insertAt = selectedIndex.map { $0 + 1 } ?? tabs.count
        if preview, let stale = previewTab, let index = tabs.firstIndex(of: stale) {
            discardPreview(stale, at: index)
            insertAt = index
        }

        let tab = DocumentTab(url: url, isPreview: preview)
        insertAt = min(max(0, insertAt), tabs.count)
        tabs.insert(tab, at: insertAt)
        Log.tabs.info(
            "open \(preview ? "preview" : "tab", privacy: .public) \(tab.title, privacy: .public) at \(insertAt) of \(self.tabs.count)"
        )
        tab.refreshMetadata { [weak self, weak tab] in
            guard let self, let tab, self.tabs.contains(tab) else { return }
            self.delegate?.tabStoreDidChangeTabs(self)
        }
        delegate?.tabStoreDidChangeTabs(self)
        select(tab)
        return tab
    }

    /// Take the outgoing preview tab out of the list without choosing a
    /// successor for it.
    ///
    /// Deliberately not ``close(_:)``: close picks the most recently used
    /// survivor and selects it, and here the successor is already known — it is
    /// the tab about to be inserted into this very slot. Routing through close
    /// would fire a selection at some third document and then immediately fire
    /// another, which the delegate turns into a visible flash of the wrong
    /// file.
    ///
    /// Everything else close does still happens, in the same order: the
    /// `willClose` hook that writes an unsaved buffer, then dehydration.
    private func discardPreview(_ tab: DocumentTab, at index: Int) {
        delegate?.tabStore(self, willClose: tab)
        dehydrate(tab)
        if tab == selected { selected = nil }
        tabs.remove(at: index)
        Log.tabs.debug("preview \(tab.title, privacy: .public) replaced in place at \(index)")
    }

    // MARK: - Promotion

    /// Make `tab` permanent, and tell the bar if that changed anything.
    ///
    /// Every VS Code promotion route lands here: double-clicking the tab,
    /// double-clicking the file in the tree, typing the first character into
    /// the editor, and dragging the tab to a new position. They have nothing in
    /// common except the user having said *keep this*, which is why the store
    /// exposes one verb rather than four.
    @discardableResult
    public func promote(_ tab: DocumentTab) -> Bool {
        guard tabs.contains(tab), tab.promote() else { return false }
        delegate?.tabStoreDidChangeTabs(self)
        return true
    }

    // MARK: - Selecting

    public func select(_ tab: DocumentTab?) {
        guard tab == nil || tabs.contains(tab!) else { return }
        let previous = selected
        if let tab {
            useClock += 1
            tab.lastUsed = useClock
        }
        guard tab != previous else {
            // Still worth the hydration check: re-selecting the current tab is
            // how a caller asks for it to be brought back after an eviction
            // that raced the selection.
            if let tab {
                hydrate(tab)
                enforceResidentLimit()
            }
            return
        }
        selected = tab
        if let tab {
            let state = Log.signposter.beginInterval("tab hydrate")
            hydrate(tab)
            Log.signposter.endInterval("tab hydrate", state)
        }
        enforceResidentLimit()
        delegate?.tabStore(self, didSelect: tab, previous: previous)
    }

    public func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// ⌃⇥. Wraps, like every tab bar on this platform.
    public func selectNext() {
        guard !tabs.isEmpty else { return }
        let current = selectedIndex ?? -1
        select(index: (current + 1) % tabs.count)
    }

    /// ⌃⇧⇥.
    public func selectPrevious() {
        guard !tabs.isEmpty else { return }
        let current = selectedIndex ?? 0
        select(index: (current - 1 + tabs.count) % tabs.count)
    }

    /// ⌘1–8 select by position; ⌘9 is the last tab, matching the platform
    /// convention rather than "the ninth tab".
    public func selectByKeyEquivalent(number: Int) {
        guard !tabs.isEmpty else { return }
        if number == 9 {
            select(index: tabs.count - 1)
        } else {
            select(index: number - 1)
        }
    }

    // MARK: - Closing

    /// Close `tab`.
    ///
    /// The successor is the most recently used survivor rather than the
    /// adjacent tab. With MRU already tracked for eviction this costs nothing,
    /// and it matches what a reader flipping between two documents expects:
    /// closing the one you just opened returns you to the one you were reading.
    public func close(_ tab: DocumentTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        let wasSelected = tab == selected
        // Before anything is torn down: a tab closed 300 ms after the last
        // keystroke still has an unwritten buffer, and this is where it is
        // written.
        delegate?.tabStore(self, willClose: tab)
        dehydrate(tab)
        tabs.remove(at: index)
        Log.tabs.info("close tab \(tab.title, privacy: .public), \(self.tabs.count) left")
        if wasSelected {
            selected = nil
            if let successor = mruOrder.first {
                select(successor)
            } else {
                // The last tab. The window stays open on its empty state — it
                // still has the sidebar, which is the whole reason ADR-4 chose
                // one window. ⇧⌘W closes the window.
                delegate?.tabStore(self, didSelect: nil, previous: nil)
            }
        }
        delegate?.tabStoreDidChangeTabs(self)
    }

    public func closeSelected() {
        guard let selected else { return }
        close(selected)
    }

    public func closeAll() {
        for tab in tabs {
            delegate?.tabStore(self, willClose: tab)
            dehydrate(tab)
        }
        tabs.removeAll()
        selected = nil
        delegate?.tabStore(self, didSelect: nil, previous: nil)
        delegate?.tabStoreDidChangeTabs(self)
    }

    // MARK: - Reordering

    /// Drag-to-reorder's model half. `to` is the destination index in the list
    /// *after* the tab has been lifted out, which is what a drop-target
    /// calculation naturally produces.
    ///
    /// **Reordering promotes.** Choosing where a tab sits is only meaningful
    /// for a tab you intend to keep, and a preview tab carefully dragged into
    /// place and then destroyed by the next click in the sidebar is the exact
    /// surprise this whole feature exists to avoid. Promotion is folded into
    /// the same delegate call rather than routed through ``promote(_:)``,
    /// because the drag loop calls this on every mouse-moved event.
    public func move(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let clamped = min(max(0, to), tabs.count - 1)
        guard clamped != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped)
        tab.promote()
        Log.tabs.debug("reorder \(from) -> \(clamped)")
        delegate?.tabStoreDidChangeTabs(self)
    }

    // MARK: - The hydration state machine

    /// Give `tab` a web view if it does not have one.
    ///
    /// The rehydration branch measures 4.690 ms end to end (M3), and goes
    /// through
    /// exactly the same ``DocumentView/open(_:restoringScrollTo:)`` that a
    /// fresh open does, so ADR-2's prefix-then-fill is not bypassed.
    private func hydrate(_ tab: DocumentTab) {
        guard !tab.state.isResident else { return }
        guard let hydrator else {
            Log.tabs.error("no hydrator; \(tab.title, privacy: .public) stays dehydrated")
            return
        }
        let view = hydrator.makeDocumentView(for: tab)
        tab.attach(view)
        Log.tabs.debug(
            "hydrate \(tab.title, privacy: .public) at y=\(tab.scrollOffset), resident=\(self.residentCount)"
        )
    }

    /// Tear `tab`'s web view down, keeping path, scroll offset, title, and
    /// task counts.
    public func dehydrate(_ tab: DocumentTab) {
        guard tab.state.isResident else { return }
        let state = Log.signposter.beginInterval("tab dehydrate")
        defer { Log.signposter.endInterval("tab dehydrate", state) }
        guard let view = tab.detach() else { return }
        hydrator?.discardDocumentView(view, for: tab)
        Log.tabs.debug(
            "dehydrate \(tab.title, privacy: .public) at y=\(tab.scrollOffset), resident=\(self.residentCount)"
        )
    }

    /// The selected tab has painted.
    public func notePainted(_ tab: DocumentTab) {
        tab.notePainted()
    }

    /// Evict least-recently-used residents until the working set fits.
    ///
    /// The selected tab is never evicted, so a `residentLimit` of 1 still
    /// works: it means "only the tab you are looking at".
    ///
    /// **A dirty tab is never evicted either**, regardless of MRU position.
    /// `2026-08-24-editing-pane-and-autosave` states it twice, once as a
    /// decision and once as a constraint on future work, and
    /// `2026-08-24-tab-residency-and-memory-model` records what it costs:
    ///
    /// > A user with many dirty tabs pays full residency, because
    /// > `2026-08-24-editing-pane-and-autosave` forbids dehydrating unsaved
    /// > work. At ~52 MB per tab that is now a much sharper constraint than
    /// > when it was written against ~1.2 MB. Ten dirty tabs is ~620 MB.
    ///
    /// So the working set can legitimately exceed ``residentLimit``, and the
    /// log says by how much and why. That is the accepted trade, not a bug: the
    /// alternative is throwing away a `WKWebView` whose document exists only in
    /// a buffer.
    public func enforceResidentLimit() {
        var residents = tabs.filter { $0.state.isResident && $0 != selected && !$0.isDirty }
        var over = residentCount - residentLimit
        guard over > 0 else { return }
        residents.sort { $0.lastUsed < $1.lastUsed }
        for tab in residents {
            guard over > 0 else { break }
            dehydrate(tab)
            over -= 1
        }
        let pinned = tabs.filter { $0.state.isResident && $0 != selected && $0.isDirty }
        if !pinned.isEmpty && residentCount > residentLimit {
            Log.tabs.info(
                """
                resident set is \(self.residentCount) with a limit of \(self.residentLimit):                 \(pinned.count) dirty tab(s) are exempt from eviction                 (~\(pinned.count * 52) MB) — unsaved work is never dehydrated
                """
            )
        }
    }

    // MARK: - Session

    /// This store as a session snapshot, in bar order.
    public func snapshot(sidebarRoot: URL?) -> SessionState {
        SessionState(
            tabs: tabs.map {
                SessionTab(
                    path: $0.url.path,
                    scrollOffset: $0.documentView?.scrollOffset ?? $0.scrollOffset,
                    title: $0.metadata?.documentTitle,
                    preview: $0.isPreview
                )
            },
            selectedIndex: selectedIndex,
            sidebarRoot: sidebarRoot?.path
        )
    }

    /// Rebuild the tab list from a session.
    ///
    /// Every restored tab starts **dehydrated** — only the one that gets
    /// selected pays for a web view, so a session with 40 tabs restores at the
    /// cost of one document, not forty. Missing files are dropped with a log
    /// line rather than restored as tabs that cannot open.
    public func restore(_ session: SessionState) {
        closeAll()

        // Resolved to a *path* before filtering, because dropping a missing
        // file shifts every index after it — restoring by index alone would
        // silently select the wrong document.
        let selectedPath = session.selectedIndex
            .flatMap { session.tabs.indices.contains($0) ? session.tabs[$0].path : nil }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }

        var restored: [DocumentTab] = []
        for entry in session.tabs {
            let url = URL(fileURLWithPath: entry.path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                Log.tabs.info("session drops missing \(entry.path, privacy: .public)")
                continue
            }
            // Preview-ness survives a relaunch, so a session that ended with
            // one italic skim tab comes back with one — not with a permanent
            // tab the user never asked to keep. `preview` is absent from
            // session files older than this feature and decodes to `false`, which is the
            // conservative direction: the worst a stale file can do is keep a
            // tab the user would have let go.
            let tab = DocumentTab(url: url, isPreview: entry.preview)
            tab.scrollOffset = entry.scrollOffset
            restored.append(tab)
        }
        // *At most one preview tab* is an invariant of this type, not a hope
        // about the file it is reading: a hand-edited or truncated session
        // file can name two, and two preview tabs means the next single click
        // replaces one of them and leaves the other stranded in italics
        // forever. Extras are promoted, which keeps the user's documents.
        if let first = restored.firstIndex(where: { $0.isPreview }) {
            for extra in restored[(first + 1)...] where extra.isPreview {
                Log.tabs.info(
                    "session named a second preview tab (\(extra.title, privacy: .public)); promoting it"
                )
                extra.promote()
            }
        }
        tabs = restored

        // MRU stamps in bar order, so a restored session that is immediately
        // over the resident limit evicts from the left rather than in an
        // arbitrary order.
        for tab in tabs {
            useClock += 1
            tab.lastUsed = useClock
        }
        for tab in tabs {
            tab.refreshMetadata { [weak self, weak tab] in
                guard let self, let tab, self.tabs.contains(tab) else { return }
                self.delegate?.tabStoreDidChangeTabs(self)
            }
        }
        delegate?.tabStoreDidChangeTabs(self)
        if let selectedPath, let tab = tab(for: selectedPath) {
            select(tab)
        } else if let first = tabs.first {
            select(first)
        }
    }
}
