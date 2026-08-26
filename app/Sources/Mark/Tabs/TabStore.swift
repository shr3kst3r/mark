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

    /// Take in a live view that arrived from another window, and re-wire it.
    ///
    /// Separate from ``makeDocumentView(for:)`` because nothing is being made:
    /// the document keeps its DOM, its scroll offset and its JS state across a
    /// pop-out. What it does **not** keep is its callbacks — every one of them
    /// captured the window it came from — so an implementation that only
    /// re-parents the view and forgets to re-wire it leaves a document
    /// reporting its scrolls to a window that is no longer showing it.
    func adopt(_ view: DocumentView, for tab: DocumentTab)
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
    /// Which tab is in which pane, or which pane has the focus, changed.
    ///
    /// Separate from ``tabStore(_:didSelect:previous:)`` because splitting does
    /// not necessarily move the selection: opening a split puts a *second*
    /// document on screen while the selected one stays exactly where it was.
    /// Defaulted, so existing conformances and the test stubs still compile.
    func tabStore(_ store: TabStore, didChangePanes panes: PaneArrangement)
}

extension TabStoreDelegate {
    public func tabStore(_ store: TabStore, willClose tab: DocumentTab) {}
    public func tabStore(_ store: TabStore, didChangePanes panes: PaneArrangement) {}
}

/// Where in a window a document is shown.
///
/// Two, not N. `2026-08-26-multiple-windows-and-split-panes`:
///
/// > Two panes is what is built. More panes per window is not foreclosed, but
/// > the focus model here is a boolean, and generalising it is a design change
/// > rather than a loop bound.
public enum Pane: String, Sendable, Equatable, CaseIterable {
    case primary
    case secondary

    public var other: Pane { self == .primary ? .secondary : .primary }
}

/// The panes' contents and which one has the focus, as one value.
///
/// Passed to the delegate whole rather than as three arguments, so a future
/// third field does not change every call site.
@MainActor
public struct PaneArrangement: Equatable {
    public var primary: DocumentTab?
    public var secondary: DocumentTab?
    public var focus: Pane

    public var isSplit: Bool { secondary != nil }

    /// The tabs on screen, in pane order. At most two, and never the same tab
    /// twice — the ADR forbids one tab having two views.
    public var displayed: [DocumentTab] { [primary, secondary].compactMap { $0 } }

    public func tab(in pane: Pane) -> DocumentTab? {
        pane == .primary ? primary : secondary
    }
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

    /// **3, carried forward from `2026-08-24-tab-residency-and-memory-model`.**
    /// That ADR's predecessor said 20, derived from a measurement that put a
    /// resident tab at ~1.2 MB. That measurement summed RSS by walking the app's
    /// process subtree — but WebKit's content processes are children of launchd,
    /// not of us, so it could not see them at all. A resident tab actually costs
    /// ~52 MB: 20 of them is ~1.16 GB, 3 is ~264 MB.
    ///
    /// An alias for ``ResidencyGovernor/defaultLimit``, kept because the limit
    /// stopped being this type's property when
    /// `2026-08-26-multiple-windows-and-split-panes` made it application-wide.
    public static var defaultResidentLimit: Int { ResidencyGovernor.defaultLimit }

    /// An alias for ``ResidencyGovernor/configuredLimit``. See above.
    public static var configuredResidentLimit: Int { ResidencyGovernor.configuredLimit }

    /// Who budgets this store's web views — **shared with every other window**.
    ///
    /// `2026-08-26-multiple-windows-and-split-panes` makes residency an
    /// application-level fact rather than a per-store one, precisely so that
    /// opening a window cannot multiply the memory budget while every log line
    /// keeps reporting the old number.
    public let governor: ResidencyGovernor

    /// How many tabs may hold a web view at once, across the whole app.
    ///
    /// A pass-through. Setting it through any store sets it for all of them,
    /// which is the point rather than a leak.
    public var residentLimit: Int {
        get { governor.limit }
        set { governor.limit = newValue }
    }

    /// Tabs in bar order. Reordering this is what drag-to-reorder does.
    public private(set) var tabs: [DocumentTab] = []

    /// What each pane is showing. Absent keys mean an empty pane.
    private var paneTabs: [Pane: DocumentTab] = [:]

    /// Which pane the tab bar, the menus and the socket act on.
    public private(set) var focus: Pane = .primary

    /// The tab in the **focused** pane.
    ///
    /// Deliberately still called `selected` and still meaning "the tab this
    /// window is acting on". Keeping the name is what lets the window title,
    /// the table of contents, the find bar, the editor binding and every socket
    /// command carry on unchanged: with no split there is one pane, and this is
    /// exactly what it always was.
    public var selected: DocumentTab? { paneTabs[focus] }

    /// The right-hand pane's tab, or `nil` when the window is not split.
    public var secondary: DocumentTab? { paneTabs[.secondary] }

    /// The left-hand pane's tab.
    public var primary: DocumentTab? { paneTabs[.primary] }

    public var isSplit: Bool { paneTabs[.secondary] != nil }

    /// The panes as one value, for the delegate.
    public var panes: PaneArrangement {
        PaneArrangement(
            primary: paneTabs[.primary], secondary: paneTabs[.secondary], focus: focus)
    }

    /// The tabs on screen in this window — at most two, never the same twice.
    public var displayedTabs: [DocumentTab] { panes.displayed }

    /// Whether `tab` is in either pane. The governor's third eviction exemption.
    public func isDisplayed(_ tab: DocumentTab) -> Bool {
        paneTabs.values.contains { $0 === tab }
    }

    public weak var delegate: (any TabStoreDelegate)?
    public weak var hydrator: (any TabHydrator)?

    public init(governor: ResidencyGovernor = .shared) {
        self.governor = governor
        governor.register(self)
    }

    /// A store with a residency budget of its own.
    ///
    /// For tests and `mark-bench` only. It builds a **private** governor rather
    /// than setting the shared one's limit, because a test that mutated
    /// ``ResidencyGovernor/shared`` would change the answer for every suite
    /// running beside it.
    public convenience init(residentLimit: Int) {
        self.init(governor: ResidencyGovernor(limit: residentLimit))
    }

    deinit {
        // `governor` holds stores weakly, so this is tidiness rather than
        // correctness — but a window closing should not leave a dead entry for
        // the next eviction pass to walk past.
        let governor = self.governor
        MainActor.assumeIsolated { governor.unregister(self) }
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
        tab.store = self
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
        vacatePanes(of: tab)
        tabs.remove(at: index)
        tab.store = nil
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

    /// Show `tab` in the **focused** pane.
    ///
    /// Unsplit, this is exactly what it always was. Split, it is what makes the
    /// one tab bar drive two panes: click into the right-hand pane and the next
    /// tab you pick lands there.
    public func select(_ tab: DocumentTab?) {
        show(tab, in: focus)
    }

    /// Show `tab` in `pane`, without moving the focus.
    ///
    /// The one place a pane's contents change, so the invariant that no tab is
    /// in both panes has exactly one site to hold rather than one per caller.
    public func show(_ tab: DocumentTab?, in pane: Pane) {
        guard tab == nil || tabs.contains(tab!) else { return }
        let previous = selected
        if let tab {
            tab.lastUsed = governor.stamp()
        }

        // **The invariant**: one tab is never in two panes. Two views of one
        // document is ~104 MB and two DOMs fed by one `Buffer`, and
        // `2026-08-26-multiple-windows-and-split-panes` forbids it outright.
        //
        // So a tab arriving in a pane it is not already in **swaps** with
        // whatever that pane held, rather than being copied. Swapping rather
        // than simply vacating matters: vacating leaves the other pane empty,
        // and an empty left pane with a document on the right is a state no
        // user asked for and no menu item can get out of.
        let unchanged = paneTabs[pane] === tab
        if let tab, paneTabs[pane.other] === tab {
            paneTabs[pane.other] = paneTabs[pane]
        }
        paneTabs[pane] = tab
        normalizePanes()

        if let tab {
            let state = Log.signposter.beginInterval("tab hydrate")
            hydrate(tab)
            Log.signposter.endInterval("tab hydrate", state)
        }
        enforceResidentLimit()

        guard !unchanged else {
            // Re-selecting the current tab is how a caller asks for it to be
            // brought back after an eviction that raced the selection; the
            // hydration above has already done that. Nothing moved, so nothing
            // is announced.
            return
        }
        delegate?.tabStore(self, didChangePanes: panes)
        if pane == focus {
            delegate?.tabStore(self, didSelect: tab, previous: previous)
        }
    }

    /// Move the focus to `pane`, which changes what ``selected`` means.
    ///
    /// Named `moveFocus(to:)` rather than `focus(_:)` so it cannot be confused
    /// with the ``focus`` property at a call site — one reads the pane, the
    /// other changes it, and a one-character difference between them is how a
    /// bug gets past review.
    public func moveFocus(to pane: Pane) {
        guard pane != focus else { return }
        // Focusing an empty pane would make `selected` nil while a document is
        // plainly on screen, and every menu item would grey out.
        guard paneTabs[pane] != nil else { return }
        let previous = selected
        focus = pane
        if let tab = paneTabs[pane] { tab.lastUsed = governor.stamp() }
        Log.tabs.debug("focus \(pane.rawValue, privacy: .public)")
        delegate?.tabStore(self, didChangePanes: panes)
        delegate?.tabStore(self, didSelect: selected, previous: previous)
    }

    /// ⌘\ — put a second document on screen beside this one.
    ///
    /// The right-hand pane gets the **second most recently used** tab, and the
    /// focus stays where it is. It never duplicates the current tab: the ADR
    /// forbids one tab having two views, so with fewer than two tabs there is
    /// nothing to split and the menu item is disabled.
    @discardableResult
    public func splitRight() -> Bool {
        guard !isSplit, tabs.count >= 2 else { return false }
        let companion = mruOrder.first { !isDisplayed($0) }
        guard let companion else { return false }
        Log.tabs.info(
            "split right: \(companion.title, privacy: .public) beside \(self.selected?.title ?? "nothing", privacy: .public)"
        )
        show(companion, in: .secondary)
        return true
    }

    /// ⇧⌘\ — back to one document.
    ///
    /// The focused pane's document is the one kept, which is the one the user
    /// was last acting on.
    @discardableResult
    public func closeSplit() -> Bool {
        guard isSplit else { return false }
        let kept = selected
        paneTabs = [.primary: kept].compactMapValues { $0 }
        focus = .primary
        Log.tabs.info("split closed, keeping \(kept?.title ?? "nothing", privacy: .public)")
        enforceResidentLimit()
        delegate?.tabStore(self, didChangePanes: panes)
        return true
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
        // Which pane it was in, captured before it is removed from them. A tab
        // in the *other* pane is on screen without being selected, and closing
        // it must collapse that pane rather than pick a successor for it.
        let vacated = Pane.allCases.first { paneTabs[$0] === tab }
        // Before anything is torn down: a tab closed 300 ms after the last
        // keystroke still has an unwritten buffer, and this is where it is
        // written.
        delegate?.tabStore(self, willClose: tab)
        dehydrate(tab)
        vacatePanes(of: tab)
        tabs.remove(at: index)
        tab.store = nil
        Log.tabs.info("close tab \(tab.title, privacy: .public), \(self.tabs.count) left")

        switch vacated {
        case .secondary:
            // The split's right-hand pane. Collapsing it is the whole
            // behaviour: filling it with another document would be the app
            // deciding the user wants to keep comparing.
            focus = .primary
            delegate?.tabStore(self, didChangePanes: panes)

        case .primary where isSplit:
            // The left pane emptied while the right one still has something.
            // Promote the survivor rather than leaving a blank half-window.
            let survivor = paneTabs[.secondary]
            paneTabs = [.primary: survivor].compactMapValues { $0 }
            focus = .primary
            delegate?.tabStore(self, didChangePanes: panes)
            delegate?.tabStore(self, didSelect: selected, previous: nil)

        case .primary:
            if let successor = mruOrder.first {
                select(successor)
            } else {
                // The last tab. The window stays open on its empty state — it
                // still has the sidebar, which is the whole reason
                // `2026-08-26-multiple-windows-and-split-panes` keeps a window
                // heavier than a bare document viewer. ⇧⌘W closes the window.
                delegate?.tabStore(self, didChangePanes: panes)
                delegate?.tabStore(self, didSelect: nil, previous: nil)
            }

        case nil:
            // A tab that was open but not on screen. Nothing moved.
            break
        }
        delegate?.tabStoreDidChangeTabs(self)
    }

    /// Take `tab` out of whichever pane holds it, leaving the pane empty.
    private func vacatePanes(of tab: DocumentTab) {
        for pane in Pane.allCases where paneTabs[pane] === tab {
            paneTabs[pane] = nil
        }
        normalizePanes()
    }

    /// **The left pane is never empty while the right one is full.**
    ///
    /// Not tidiness. A window in that state shows one document on the right
    /// half and a blank left half, with no menu item that fixes it: ⇧⌘\ keeps
    /// the *focused* pane, ⌘\ refuses because the window is already split, and
    /// clicking a tab fills whichever pane has the focus. It is reachable
    /// several ways — moving the left pane's document to the right, closing the
    /// left pane's tab, popping it out — so it is repaired in one place rather
    /// than guarded against in each of them.
    private func normalizePanes() {
        guard paneTabs[.primary] == nil, let orphan = paneTabs[.secondary] else { return }
        paneTabs[.primary] = orphan
        paneTabs[.secondary] = nil
        focus = .primary
    }

    /// Exchange the two panes' documents, keeping the focus on the same
    /// *document* rather than on the same side.
    ///
    /// Following the document is the useful half: the reader asked for the
    /// thing they were reading to move, not to start acting on the other one.
    @discardableResult
    public func swapPanes() -> Bool {
        guard isSplit, let left = paneTabs[.primary], let right = paneTabs[.secondary] else {
            return false
        }
        paneTabs[.primary] = right
        paneTabs[.secondary] = left
        focus = focus.other
        Log.tabs.debug("panes swapped")
        delegate?.tabStore(self, didChangePanes: panes)
        return true
    }

    public func closeSelected() {
        guard let selected else { return }
        close(selected)
    }

    public func closeAll() {
        for tab in tabs {
            delegate?.tabStore(self, willClose: tab)
            dehydrate(tab)
            tab.store = nil
        }
        tabs.removeAll()
        paneTabs.removeAll()
        focus = .primary
        delegate?.tabStore(self, didChangePanes: panes)
        delegate?.tabStore(self, didSelect: nil, previous: nil)
        delegate?.tabStoreDidChangeTabs(self)
    }

    // MARK: - Moving a tab to another window

    /// Take `tab` out of this store **without closing it**, and hand back its
    /// live view.
    ///
    /// Deliberately not ``close(_:)``, and the difference is the whole point.
    /// `close` fires `willClose`, which writes and then discards the tab's
    /// `Buffer` — correct for a document going away, catastrophic for one
    /// merely changing windows, which would arrive at its new home having
    /// silently lost its undo stack, its `flock(2)` lock and its conflict
    /// state.
    ///
    /// The `DocumentView` is returned still alive rather than dehydrated.
    /// `2026-08-25-flock-write-locking` says a dirty tab is never dehydrated,
    /// and a move should not become the one path that does it — so the view is
    /// reparented into the destination window instead, which also saves the
    /// ~4.7 ms rehydration.
    ///
    /// The caller **must** hand both to ``adopt(_:view:)`` on another store.
    /// A tab left in the return value is a tab nothing owns.
    public func detach(_ tab: DocumentTab) -> (tab: DocumentTab, view: DocumentView?) {
        guard let index = tabs.firstIndex(of: tab) else { return (tab, nil) }
        let vacated = Pane.allCases.first { paneTabs[$0] === tab }
        vacatePanes(of: tab)
        tabs.remove(at: index)
        tab.store = nil
        let view = tab.documentView
        // Not `detach()` on the tab — that clears `documentView` and marks it
        // dehydrated. The view is moving house, not being torn down; the
        // destination re-attaches it as-is.
        view?.removeFromSuperview()

        Log.tabs.info(
            "detach \(tab.title, privacy: .public) (\(view == nil ? "dehydrated" : "carrying its view", privacy: .public)), \(self.tabs.count) left"
        )

        if vacated == .secondary {
            focus = .primary
        } else if vacated == .primary, isSplit {
            paneTabs = [.primary: paneTabs[.secondary]].compactMapValues { $0 }
            focus = .primary
        } else if vacated == .primary, let successor = mruOrder.first {
            paneTabs[.primary] = successor
            successor.lastUsed = governor.stamp()
            hydrate(successor)
        }
        delegate?.tabStore(self, didChangePanes: panes)
        delegate?.tabStore(self, didSelect: selected, previous: tab)
        delegate?.tabStoreDidChangeTabs(self)
        return (tab, view)
    }

    /// Take in a tab detached from another store, with its view if it had one.
    ///
    /// The tab arrives selected, because a window that opens showing nothing is
    /// not what "pop this out" means.
    public func adopt(_ tab: DocumentTab, view: DocumentView?, at index: Int? = nil) {
        let insertAt = min(max(0, index ?? tabs.count), tabs.count)
        tabs.insert(tab, at: insertAt)
        tab.store = self
        if let view {
            // Re-attached rather than remade: the document keeps its DOM, its
            // scroll position and its JS state across the move.
            hydrator?.adopt(view, for: tab)
        }
        Log.tabs.info(
            "adopt \(tab.title, privacy: .public) at \(insertAt) of \(self.tabs.count)")
        delegate?.tabStoreDidChangeTabs(self)
        show(tab, in: .primary)
        moveFocus(to: .primary)
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
    /// **The pass itself lives on ``ResidencyGovernor``, not here**, because
    /// `2026-08-26-multiple-windows-and-split-panes` budgets residency across
    /// every window at once:
    ///
    /// > A per-window limit multiplies the budget by the window count while
    /// > continuing to report the old number.
    ///
    /// So this store cannot decide what to evict by looking at its own tabs —
    /// the least recently used tab in the application may be in another window.
    /// Kept as a method rather than deleted because it is the name every call
    /// site already uses, and because "enforce the limit" is the thing being
    /// asked for; where the ranking happens is the governor's business.
    public func enforceResidentLimit() {
        governor.enforce()
    }

    // MARK: - Session

    /// This store as a session snapshot, in bar order.
    public func snapshot(sidebarRoot: URL?) -> SessionState {
        SessionState(windows: [snapshotWindow(sidebarRoot: sidebarRoot)])
    }

    /// This store as one window's session entry.
    public func snapshotWindow(sidebarRoot: URL?) -> SessionWindow {
        SessionWindow(
            tabs: tabs.map {
                SessionTab(
                    path: $0.url.path,
                    scrollOffset: $0.documentView?.scrollOffset ?? $0.scrollOffset,
                    title: $0.metadata?.documentTitle,
                    preview: $0.isPreview
                )
            },
            selectedIndex: selectedIndex,
            secondaryIndex: secondary.flatMap { index(of: $0) },
            focus: focus.rawValue,
            sidebarRoot: sidebarRoot?.path
        )
    }

    /// Rebuild the tab list from a session.
    ///
    /// Every restored tab starts **dehydrated** — only the one that gets
    /// selected pays for a web view, so a session with 40 tabs restores at the
    /// cost of one document, not forty. Missing files are dropped with a log
    /// line rather than restored as tabs that cannot open.
    /// Restore from a whole session file, taking the first window.
    ///
    /// The single-window shorthand. A store belongs to one window, so "restore
    /// this session" can only mean the window the file describes first —
    /// ``WindowCoordinator`` is what fans the rest out.
    public func restore(_ session: SessionState) {
        guard let window = session.effectiveWindows.first else {
            closeAll()
            return
        }
        restore(window)
    }

    public func restore(_ session: SessionWindow) {
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
            tab.store = self
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
            tab.lastUsed = governor.stamp()
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

        // The split, last: `show(_:in:)` on an empty primary would put the
        // second document on the left. `repairedSecondaryIndex` has already
        // discarded an out-of-range index and one equal to the selection —
        // a hand-edited file naming the same tab twice would otherwise ask for
        // the one thing `2026-08-26-multiple-windows-and-split-panes` forbids.
        //
        // Resolved by path for the same reason the selection is: dropping a
        // missing file shifts every index after it.
        if let index = session.repairedSecondaryIndex,
            session.tabs.indices.contains(index)
        {
            let url = URL(fileURLWithPath: session.tabs[index].path).standardizedFileURL
            if let tab = tab(for: url), tab !== selected {
                show(tab, in: .secondary)
            }
        }
        if session.repairedSecondaryIndex == nil, session.secondaryIndex != nil {
            Log.tabs.info("session named an unusable secondary pane; restoring unsplit")
        }
        if isSplit, let pane = session.focus.flatMap(Pane.init(rawValue:)) {
            moveFocus(to: pane)
        }
    }
}
