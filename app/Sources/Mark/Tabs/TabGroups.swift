import AppKit
import Foundation

/// What a window is told when its groups, or which one has the focus, change.
///
/// Separate from ``TabStoreDelegate`` because these are events about the
/// *arrangement* rather than about a list of tabs: a split opening does not
/// change any group's tabs, and moving the focus does not change any group's
/// selection. A window that conflated them would rebuild both bars on every
/// metadata refresh and reload nothing when the divider moved.
@MainActor
public protocol TabGroupsDelegate: AnyObject {
    /// A group was added or removed, or the groups swapped places.
    func tabGroupsDidChangeLayout(_ groups: TabGroups)
    /// The focus moved to another group. The groups themselves are unchanged.
    func tabGroupsDidMoveFocus(_ groups: TabGroups)
}

/// A window's editor groups: one, or two when split.
///
/// `2026-08-26-editor-groups-per-pane-tab-bars`:
///
/// > A window contains one or two editor groups. A group owns an ordered list
/// > of tabs, a selection, a tab bar and a document container.
///
/// This type owns the half of that sentence a ``TabStore`` deliberately does
/// not: how many groups there are, which one is focused, where the divider
/// sits, and what it means to move a tab from one to the other. Everything
/// about a *list* of documents is one level down.
///
/// **Two, not N.** The predecessor ADR's note survives verbatim: more panes per
/// window is not foreclosed, but the focus model is an index into a
/// two-element array and the layout is one divider, so generalising it is a
/// design change rather than a loop bound.
@MainActor
public final class TabGroups {

    /// The groups, left to right. Never empty; at most two.
    public private(set) var groups: [TabStore]

    /// Which group the tab bar highlights, the menus act on, and new documents
    /// open into.
    public private(set) var focusIndex: Int = 0

    /// Where the divider sits, as a fraction of the document area's width.
    /// Clamped by the view that draws it; kept here because it is session state.
    public var splitFraction: CGFloat = 0.5

    public weak var delegate: (any TabGroupsDelegate)?

    /// Everything a new group's store needs from the window that owns it — its
    /// delegate and its hydrator.
    ///
    /// A closure rather than a protocol call, because the window is already the
    /// delegate of every store here and a `didCreate` callback would be a
    /// second way to say the same thing. Set once, before anything can split.
    public var configureStore: ((TabStore) -> Void)?

    /// Who budgets every group's web views — shared with every other window's
    /// groups. A group is **not** a memory allowance.
    public let governor: ResidencyGovernor

    public init(governor: ResidencyGovernor = .shared, first: TabStore? = nil) {
        self.governor = governor
        self.groups = [first ?? TabStore(governor: governor)]
    }

    // MARK: - Reading

    public var isSplit: Bool { groups.count == 2 }

    /// The group being acted on. Never nil: an empty group still has the focus,
    /// and a window with no tabs still has one group.
    public var focused: TabStore { groups[min(focusIndex, groups.count - 1)] }

    /// The group that does not have the focus, when there is one.
    public var unfocused: TabStore? {
        guard isSplit else { return nil }
        return groups[1 - focusIndex]
    }

    /// Every tab in the window, in group order then bar order.
    ///
    /// The index space `mark tab list` reports and `mark tab select` takes —
    /// one flat list per window, so the socket keeps one command surface and no
    /// new verbs.
    public var allTabs: [DocumentTab] { groups.flatMap(\.tabs) }

    /// The documents on screen: one per group.
    public var displayedTabs: [DocumentTab] { groups.flatMap(\.displayedTabs) }

    /// Which group holds `tab`.
    public func index(of tab: DocumentTab) -> Int? {
        groups.firstIndex { $0.tabs.contains(tab) }
    }

    /// The group holding `tab`, or nil if it is in another window.
    public func group(of tab: DocumentTab) -> TabStore? {
        index(of: tab).map { groups[$0] }
    }

    /// The tab at a window-flat index, and the group holding it.
    public func tab(atWindowIndex index: Int) -> (tab: DocumentTab, group: Int)? {
        var remaining = index
        guard remaining >= 0 else { return nil }
        for (groupIndex, group) in groups.enumerated() {
            if remaining < group.tabs.count {
                return (group.tabs[remaining], groupIndex)
            }
            remaining -= group.tabs.count
        }
        return nil
    }

    /// The window-flat index of `tab`.
    public func windowIndex(of tab: DocumentTab) -> Int? {
        var offset = 0
        for group in groups {
            if let index = group.tabs.firstIndex(of: tab) { return offset + index }
            offset += group.tabs.count
        }
        return nil
    }

    // MARK: - The split

    /// ⌘\ — put the focused group's document in a group of its own beside it.
    ///
    /// **Splitting moves a tab; it never copies one.** A group with a single
    /// tab has nothing to compare it against and nothing to keep on this side,
    /// so it refuses and the menu item is disabled — which is exactly what the
    /// one-bar model did, for the same reason.
    @discardableResult
    public func splitRight() -> Bool {
        guard !isSplit, focused.count >= 2, let moving = focused.selected else { return false }
        let source = focused
        let destination = makeStore()
        groups.append(destination)
        Log.tabs.info(
            "split right: \(moving.title, privacy: .public) into a group of its own")
        // **The layout is announced before the tab moves**, and the ordering is
        // load-bearing: adopting a tab asks the window which container its
        // group draws into, and a window that has not built the new group's
        // area yet answers with the old group's — so the moved document's web
        // view lands in the wrong half and the new pane comes up blank.
        delegate?.tabGroupsDidChangeLayout(self)
        // The focus follows the document, because ⌘\ is "put this over there"
        // and the reader's attention goes with it. The one-bar model kept the
        // focus on the left, which meant the next tab click landed in the pane
        // the reader had just moved away from.
        move(moving, from: source, to: destination)
        focusIndex = 1
        delegate?.tabGroupsDidChangeLayout(self)
        delegate?.tabGroupsDidMoveFocus(self)
        return true
    }

    /// ⇧⌘\ — back to one group, **keeping every document**.
    ///
    /// The one-bar model dropped the other pane's document from the window,
    /// which was defensible when a tab belonged to no pane. A group owns its
    /// tabs, so closing the split merges them: the second group's tabs land at
    /// the end of the first group's bar, in order, and the focused group's
    /// selection survives as the selection.
    @discardableResult
    public func closeSplit() -> Bool {
        guard isSplit else { return false }
        let kept = focused
        let closing = groups[1 - focusIndex]
        let keptSelection = kept.selected
        for tab in closing.tabs {
            move(tab, from: closing, to: kept)
        }
        groups = [kept]
        focusIndex = 0
        if let keptSelection { kept.select(keptSelection) }
        Log.tabs.info(
            "split closed, keeping \(kept.count) document(s) in one group")
        delegate?.tabGroupsDidChangeLayout(self)
        delegate?.tabGroupsDidMoveFocus(self)
        return true
    }

    /// A group emptied. Collapse it, unless it is the only one.
    ///
    /// Called by the window when a store reports itself empty. A window with
    /// one group and no tabs keeps that group and shows its empty state; a
    /// window with two collapses to the one that still has documents.
    @discardableResult
    public func collapseIfEmpty(_ store: TabStore) -> Bool {
        guard isSplit, store.isEmpty, let index = groups.firstIndex(where: { $0 === store })
        else { return false }
        groups.remove(at: index)
        focusIndex = 0
        Log.tabs.info("group \(index) emptied; collapsing the split")
        delegate?.tabGroupsDidChangeLayout(self)
        delegate?.tabGroupsDidMoveFocus(self)
        return true
    }

    // MARK: - The focus

    /// Move the focus to the group at `index`.
    @discardableResult
    public func focus(_ index: Int) -> Bool {
        guard groups.indices.contains(index), index != focusIndex else { return false }
        focusIndex = index
        // Stamped, so the group a reader just moved into is not the one the next
        // eviction pass picks from.
        focused.selected?.lastUsed = governor.stamp()
        Log.tabs.debug("focus group \(index)")
        delegate?.tabGroupsDidMoveFocus(self)
        return true
    }

    @discardableResult
    public func focus(_ store: TabStore) -> Bool {
        guard let index = groups.firstIndex(where: { $0 === store }) else { return false }
        return focus(index)
    }

    /// ⌥⌘\.
    @discardableResult
    public func focusOther() -> Bool {
        guard isSplit else { return false }
        return focus(1 - focusIndex)
    }

    // MARK: - Moving a tab between groups

    /// Move `tab` into the other group, splitting first if there is only one.
    ///
    /// The menu item's model half — "Move to Other Pane" — and where the tab
    /// bar's cross-divider drag lands. Returns false when there is nothing
    /// sensible to do: one group with one tab has no other side to move to, and
    /// moving a group's only tab into the other group would empty it, which is
    /// the same thing as closing the split.
    @discardableResult
    public func moveToOtherGroup(_ tab: DocumentTab) -> Bool {
        guard let sourceIndex = index(of: tab) else { return false }
        let source = groups[sourceIndex]
        guard source.count >= 2 || isSplit else { return false }

        if !isSplit {
            let destination = makeStore()
            groups.append(destination)
            // Before the move, for the reason ``splitRight()`` gives.
            delegate?.tabGroupsDidChangeLayout(self)
            move(tab, from: source, to: destination)
            focusIndex = 1
            delegate?.tabGroupsDidChangeLayout(self)
            delegate?.tabGroupsDidMoveFocus(self)
            return true
        }

        let destinationIndex = 1 - sourceIndex
        move(tab, from: source, to: groups[destinationIndex])
        focusIndex = destinationIndex
        // The source may have just emptied, which collapses the split — and
        // that has to happen after the move rather than being refused before
        // it, because "move my last tab to the other side" is a legitimate way
        // to say "stop splitting".
        if source.isEmpty {
            groups.removeAll { $0 === source }
            focusIndex = 0
        }
        delegate?.tabGroupsDidChangeLayout(self)
        delegate?.tabGroupsDidMoveFocus(self)
        return true
    }

    /// Detach from one store and adopt into another, carrying the live view.
    ///
    /// Deliberately `detach`/`adopt` rather than a list splice, and the reason
    /// is the same one `2026-08-26-multiple-windows-and-split-panes` gave for a
    /// pop-out: a tab is not a row, it is a `Buffer`, an `flock(2)` lock, an
    /// autosave debounce, a conflict state and a `DocumentView` full of
    /// closures that captured the window. The move is now *within* a window,
    /// which makes skipping the re-wiring more tempting and no less wrong.
    private func move(_ tab: DocumentTab, from source: TabStore, to destination: TabStore) {
        let detached = source.detach(tab)
        destination.adopt(detached.tab, view: detached.view)
    }

    /// A second group's store, wired to the window that owns this arrangement.
    private func makeStore() -> TabStore {
        let store = TabStore(governor: governor)
        configureStore?(store)
        return store
    }

    // MARK: - Session

    /// This window's groups as a session entry.
    ///
    /// The first group is written **twice** — once in `groups`, once in the flat
    /// `tabs`/`selectedIndex` fields — which is the same deliberate
    /// compatibility cost ``SessionState/windows`` pays one level up: a build
    /// that predates groups restores the first group rather than nothing.
    public func snapshotWindow(sidebarRoot: URL?) -> SessionWindow {
        let entries = groups.map { $0.snapshotGroup() }
        let first = entries.first ?? SessionGroup()
        return SessionWindow(
            tabs: first.tabs,
            selectedIndex: first.selectedIndex,
            focus: String(focusIndex),
            groups: entries,
            splitFraction: Double(splitFraction),
            sidebarRoot: sidebarRoot?.path
        )
    }

    /// Rebuild this window's groups from a session entry.
    ///
    /// Reads ``SessionWindow/effectiveGroups``, which is where a file from the
    /// one-bar build is migrated: its `secondaryIndex` tab comes back as a
    /// second group holding that document alone.
    public func restore(_ window: SessionWindow) {
        let entries = window.effectiveGroups
        // Groups are rebuilt rather than reused, so a restore into a window
        // that is already split does not leave a stale third group behind. Any
        // group being dropped is closed rather than abandoned: `closeAll` is
        // what writes an unsaved buffer and releases its `flock(2)` lock, and a
        // store dropped on the floor would take both with it.
        while groups.count > 1 {
            let dropped = groups.removeLast()
            dropped.closeAll()
        }
        groups[0].restore(entries.first ?? SessionGroup())
        for entry in entries.dropFirst().prefix(1) {
            let store = makeStore()
            groups.append(store)
            // The window needs an area for this group before anything in it
            // hydrates, for the reason ``splitRight()`` gives.
            delegate?.tabGroupsDidChangeLayout(self)
            store.restore(entry)
        }
        // A restored group with no documents on disk any more is not a group.
        if groups.count == 2, groups[1].isEmpty {
            groups.removeLast()
            Log.tabs.info("session's second group restored empty; window is unsplit")
        }
        if groups.count == 2, groups[0].isEmpty {
            groups.removeFirst()
            Log.tabs.info("session's first group restored empty; window is unsplit")
        }
        focusIndex = min(window.focusedGroupIndex, groups.count - 1)
        if let fraction = window.splitFraction { splitFraction = CGFloat(fraction) }
        delegate?.tabGroupsDidChangeLayout(self)
        delegate?.tabGroupsDidMoveFocus(self)
    }
}
