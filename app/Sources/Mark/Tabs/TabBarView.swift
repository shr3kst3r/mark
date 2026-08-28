import AppKit
import Foundation

/// The hand-built tab bar.
///
/// ADR-4 chose one window with a shared sidebar over native `NSWindow`
/// tabbing, and was explicit about the bill that comes with it:
///
/// > We are rebuilding a well-tested piece of AppKit by hand, and the parts
/// > that look easy are not. […] Accessibility is ours now: a hand-drawn tab
/// > bar is invisible to VoiceOver unless we implement `NSAccessibility` roles
/// > deliberately, and it is the kind of work that gets skipped and then never
/// > done.
///
/// So the accessibility tree here is not decoration. The bar reports
/// `AXTabGroup` with its tabs as `accessibilityTabs()`; each tab reports
/// `AXRadioButton` with a label carrying its filename *and* its open-task
/// count, an `isAccessibilitySelected` state, and a pressable close button as
/// a child. `TabBarAccessibilityTests` asserts all of it, and `mark-bench`
/// prints the tree so a regression is visible in the gate output rather than
/// only to someone running VoiceOver.
///
/// `2026-08-26-multiple-windows-and-split-panes` since gave the app more than
/// one window, so the first item on that list came back — but through the menu
/// bar and this bar's context menu (*Move Tab to New Window*), **not** by
/// dragging a tab out of the bar. The drag loop below reorders within the bar
/// and nothing else; tearing a tab off with the mouse would mean tracking the
/// pointer outside the window, hit-testing every other window's bar, and
/// drawing a detached tab under the cursor, which is a great deal of hand-built
/// AppKit for a gesture the menu already performs.
///
/// Still not implemented, and still for the reason the superseded ADR gave:
/// cross-window tab merging, and the ⌘⇧\ "Show All Tabs" overview.
@MainActor
public final class TabBarView: NSView {

    // MARK: - Metrics

    /// The bar's height. Matches a compact toolbar row rather than a full one:
    /// the document is what the window is for.
    public static let barHeight: CGFloat = 30

    /// Below this a tab shows a truncated filename and nothing useful, so the
    /// overflow menu takes over instead of shrinking further.
    public static let minimumTabWidth: CGFloat = 118

    /// Above this, four open documents would each be 300 pt wide and the bar
    /// would look like a toolbar. Native tabs cap similarly.
    public static let maximumTabWidth: CGFloat = 220

    /// Width reserved for the overflow chevron when not every tab fits.
    public static let overflowWidth: CGFloat = 36

    static let horizontalPadding: CGFloat = 8
    static let closeButtonSize: CGFloat = 15

    // MARK: - State

    public weak var store: TabStore?

    /// Whether this bar's group has the focus.
    ///
    /// **This is the focus indicator**
    /// (`2026-08-26-editor-groups-per-pane-tab-bars`). The one-bar model drew an
    /// accent stripe across the top of the focused pane, in a view underneath
    /// the web views, where it could not be seen; a bar that dims when its
    /// group is not the one being acted on is drawn where a reader is already
    /// looking to answer the same question.
    ///
    /// True for a window with one group, which is what makes an unsplit window
    /// look exactly as it did.
    public var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            reload()
        }
    }

    /// Clicking anywhere in this bar means "act on my group".
    ///
    /// Fired before the selection changes, so a click on a tab in the unfocused
    /// group focuses that group *and* selects the tab, rather than selecting in
    /// a group the window is not acting on.
    public var onFocusRequested: (() -> Void)?

    /// A tab was dragged out of this bar and dropped at `point`, in window
    /// coordinates. Returns whether someone took it.
    ///
    /// The cross-divider move the ADR asks for. The bar deliberately does not
    /// know what is on the other side of the divider — it reports a drop that
    /// left it and lets the window decide whether that lands in another group.
    public var onDragOut: ((DocumentTab, NSPoint) -> Bool)?

    /// Tab views in bar order. The accessibility children, and the drag model.
    public private(set) var items: [TabItemView] = []

    /// Index of the leftmost drawn tab when not all of them fit.
    public private(set) var firstVisibleIndex = 0

    /// How many tabs the bar is currently drawing.
    public private(set) var visibleCount = 0

    private let overflowButton = TabOverflowButton()

    /// The tab currently being dragged, excluded from ordinary layout so it
    /// can follow the pointer.
    private var draggingItem: TabItemView?

    public override var isFlipped: Bool { true }

    // MARK: - Lifecycle

    public init(store: TabStore) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.barHeight))
        wantsLayer = true
        overflowButton.bar = self
        overflowButton.isHidden = true
        addSubview(overflowButton)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabBarView is created in code, not from a nib")
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barHeight)
    }

    // MARK: - Model → views

    /// Rebuild from the store. Cheap enough to call on every change: it reuses
    /// item views and only adds or removes at the ends.
    public func reload() {
        guard let store else { return }
        let tabs = store.tabs

        while items.count > tabs.count {
            items.removeLast().removeFromSuperview()
        }
        while items.count < tabs.count {
            let item = TabItemView()
            item.bar = self
            items.append(item)
            addSubview(item)
        }
        for (item, tab) in zip(items, tabs) {
            item.configure(
                tab: tab,
                isSelected: tab == store.selected,
                isBarActive: isActive)
        }
        layoutTabs()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutTabs()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTabs()
    }

    // MARK: - Layout and overflow

    /// Place the tabs, deciding how many fit and which window of them to show.
    ///
    /// Overflow is a *window* over the tab list plus a chevron menu, not a
    /// scroll view. A scroll view would be less code and worse: a bar that can
    /// be scrolled away from the selected tab means the selected document is
    /// not visibly selected, and there is no scrollbar affordance in 30 pt of
    /// height to tell the reader that more exists.
    public func layoutTabs() {
        guard !items.isEmpty else {
            overflowButton.isHidden = true
            visibleCount = 0
            firstVisibleIndex = 0
            return
        }
        let available = bounds.width
        let layout = Self.plan(
            tabCount: items.count,
            selectedIndex: store?.selectedIndex,
            firstVisible: firstVisibleIndex,
            availableWidth: available
        )
        firstVisibleIndex = layout.firstVisible
        visibleCount = layout.visibleCount

        for (index, item) in items.enumerated() {
            let position = index - layout.firstVisible
            let visible = position >= 0 && position < layout.visibleCount
            item.isHidden = !visible
            guard visible else { continue }
            guard item !== draggingItem else { continue }
            item.frame = NSRect(
                x: CGFloat(position) * layout.tabWidth,
                y: 0,
                width: layout.tabWidth,
                height: bounds.height
            )
        }

        let hidden = items.count - layout.visibleCount
        overflowButton.isHidden = hidden <= 0
        overflowButton.hiddenCount = hidden
        overflowButton.frame = NSRect(
            x: bounds.width - Self.overflowWidth,
            y: 0,
            width: Self.overflowWidth,
            height: bounds.height
        )
        overflowButton.needsDisplay = true
    }

    /// The layout decision, as a pure function so overflow can be tested
    /// without a window.
    ///
    /// The invariant that matters and is easy to lose: **the selected tab is
    /// always inside the visible window**. Everything else here is arithmetic.
    public struct Layout: Equatable {
        public var tabWidth: CGFloat
        public var visibleCount: Int
        public var firstVisible: Int
    }

    public static func plan(
        tabCount: Int,
        selectedIndex: Int?,
        firstVisible: Int,
        availableWidth: CGFloat
    ) -> Layout {
        guard tabCount > 0, availableWidth > 0 else {
            return Layout(tabWidth: minimumTabWidth, visibleCount: 0, firstVisible: 0)
        }
        // Everything fits: share the width out, capped so four tabs do not
        // each become 300 pt wide.
        if CGFloat(tabCount) * minimumTabWidth <= availableWidth {
            let width = min(maximumTabWidth, availableWidth / CGFloat(tabCount))
            return Layout(tabWidth: width, visibleCount: tabCount, firstVisible: 0)
        }
        let usable = max(minimumTabWidth, availableWidth - overflowWidth)
        let fits = max(1, Int((usable / minimumTabWidth).rounded(.down)))
        let visible = min(tabCount, fits)
        let width = usable / CGFloat(visible)

        var first = min(max(0, firstVisible), max(0, tabCount - visible))
        if let selected = selectedIndex {
            if selected < first { first = selected }
            if selected >= first + visible { first = selected - visible + 1 }
            first = min(max(0, first), max(0, tabCount - visible))
        }
        return Layout(tabWidth: width, visibleCount: visible, firstVisible: first)
    }

    /// The tabs the overflow menu lists: everything not currently drawn.
    public var overflowTabs: [DocumentTab] {
        guard let store else { return [] }
        let visible = firstVisibleIndex..<(firstVisibleIndex + visibleCount)
        return store.tabs.enumerated()
            .filter { !visible.contains($0.offset) }
            .map(\.element)
    }

    func showOverflowMenu(from view: NSView) {
        guard let store else { return }
        let menu = NSMenu(title: "Open Documents")
        for tab in overflowTabs {
            let item = NSMenuItem(
                title: Self.menuTitle(for: tab), action: #selector(overflowPick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab
            item.state = tab == store.selected ? .on : .off
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No hidden tabs", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    /// Used by the overflow menu and by the Window menu's tab list, so the two
    /// read identically.
    public static func menuTitle(for tab: DocumentTab) -> String {
        guard let outstanding = tab.openTaskCount else { return tab.title }
        return "\(tab.title) — \(outstanding) outstanding"
    }

    @objc private func overflowPick(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? DocumentTab else { return }
        store?.select(tab)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        if !isActive {
            // The unfocused group's bar, dimmed. Drawn over its own background
            // rather than as a different colour so it tracks every theme and
            // both appearances for free.
            NSColor.windowBackgroundColor.withAlphaComponent(0.5).setFill()
            bounds.fill()
        }
        // A hairline under the bar, so the tab bar reads as chrome rather than
        // as the top of the document.
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Selection and drag-to-reorder

    /// Called by a tab on mouse-down. Selects immediately — like every native
    /// tab bar, selection happens on press, not on release — and then tracks
    /// the mouse for a reorder.
    func beginInteraction(with item: TabItemView, event: NSEvent) {
        guard let store, let tab = item.tab, let window else { return }
        // Before the selection: with two groups, clicking a tab means "act on
        // this group, on this tab" — in that order, or the selection lands in a
        // group the window is not acting on.
        onFocusRequested?()
        store.select(tab)

        // The gesture the whole preview mechanism hangs off: a second click on
        // the tab itself is the user saying *keep this one*. `>= 2` rather than
        // `== 2` because a triple click is still a double click that carried
        // on, and a tab that un-promotes on the third would be absurd.
        if event.clickCount >= 2 {
            store.promote(tab)
        }

        let startPoint = convert(event.locationInWindow, from: nil)
        let startOrigin = item.frame.origin.x
        var isDragging = false

        // A modal tracking loop rather than mouseDragged/mouseUp overrides:
        // reordering mutates the very view array those callbacks arrive on, so
        // owning the loop is the difference between "the list changed under
        // me" being a design and being a crash.
        var lastLocationInWindow = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            lastLocationInWindow = next.locationInWindow
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            let delta = point.x - startPoint.x
            if !isDragging {
                guard abs(delta) > 4 else { continue }
                isDragging = true
                draggingItem = item
                item.isDragging = true
                addSubview(item, positioned: .above, relativeTo: nil)
            }
            var frame = item.frame
            frame.origin.x = min(max(0, startOrigin + delta), bounds.width - frame.width)
            item.frame = frame

            if let from = store.index(of: tab) {
                let target = dropIndex(forCenterX: frame.midX)
                if target != from {
                    store.move(from: from, to: target)
                }
            }
        }

        if isDragging {
            draggingItem = nil
            item.isDragging = false
            // Dropped outside this bar: the window gets first refusal, because
            // the drop may be in the other group's half of the split. A move
            // rebuilds both bars, so nothing below this line may touch `item`.
            let dropped = convert(lastLocationInWindow, from: nil)
            if !bounds.contains(dropped), onDragOut?(tab, lastLocationInWindow) == true {
                return
            }
            layoutTabs()
            // The tracking loop above consumed every drag event, so the
            // tracking areas the pointer passed over never got their
            // `mouseExited`. Without this, a drag across the bar leaves a
            // close button drawn on every tab it crossed — visible in a
            // screenshot, invisible to every test here.
            refreshHover()
        }
    }

    /// Recompute hover state from where the pointer actually is.
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        for item in items {
            item.setHovered(!item.isHidden && item.frame.contains(point))
        }
    }

    /// Which index a tab dropped with its centre at `centerX` should land on.
    ///
    /// Pure and `public` so the reorder arithmetic is unit-testable; the drag
    /// itself is not, short of synthesising `NSEvent`s.
    public func dropIndex(forCenterX centerX: CGFloat) -> Int {
        guard let store, visibleCount > 0 else { return 0 }
        let width = bounds.width > 0 && visibleCount > 0
            ? (overflowButton.isHidden ? bounds.width : bounds.width - Self.overflowWidth)
                / CGFloat(visibleCount)
            : Self.minimumTabWidth
        let position = Int((centerX / max(1, width)).rounded(.down))
        let index = firstVisibleIndex + min(max(0, position), visibleCount - 1)
        return min(max(0, index), store.tabs.count - 1)
    }

    // MARK: - Cycling

    /// ⌘⌥→ and ⌘⌥← — next and previous tab.
    ///
    /// Handled here rather than in the Window menu because ⌃⇥ and ⌃⇧⇥ already
    /// hold those two items and an `NSMenuItem` carries exactly one key
    /// equivalent. The alternative is a second, near-identically named pair of
    /// menu rows, which is worse than an undisplayed shortcut — Safari makes
    /// the same trade for the same reason.
    ///
    /// The bar is in the window's view tree, so `NSView`'s default
    /// `performKeyEquivalent` walk reaches it no matter what holds first
    /// responder. That is the point: the shortcut has to work while the caret
    /// is in the editor pane, which is where a reader switching documents most
    /// often is.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let store, !store.isEmpty else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .option] else { return false }
        switch event.charactersIgnoringModifiers {
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            store.selectNext()
            return true
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            store.selectPrevious()
            return true
        default:
            return false
        }
    }

    // MARK: - Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }

    public override func accessibilityLabel() -> String? { "Open documents" }

    public override func isAccessibilityElement() -> Bool { true }

    /// The `AXTabs` attribute. This is the one VoiceOver uses to enumerate a
    /// tab group with ⌃⌥→, and it is what a hand-built bar silently lacks.
    public override func accessibilityTabs() -> [Any]? { items }

    public override func accessibilityChildren() -> [Any]? {
        overflowButton.isHidden ? items : items + [overflowButton]
    }

    /// A tab group's value is its selected tab.
    public override func accessibilityValue() -> Any? {
        items.first { $0.isSelected }
    }

    /// A one-line description of the whole bar, for the bench output and for
    /// the accessibility test. Not an AppKit method — deliberately named so it
    /// cannot be mistaken for one.
    public func accessibilityTreeDescription() -> String {
        let role = accessibilityRole()?.rawValue ?? "nil"
        let tabs = items.map { item -> String in
            let selected = item.isAccessibilitySelected() ? "*" : " "
            let children = (item.accessibilityChildren() ?? []).count
            return "\(selected)[\(item.accessibilityRole()?.rawValue ?? "nil")] "
                + "\(item.accessibilityLabel() ?? "nil") (+\(children) child)"
        }
        return "\(role) \"\(accessibilityLabel() ?? "")\" with \(items.count) tabs\n"
            + tabs.map { "    " + $0 }.joined(separator: "\n")
    }
}

// MARK: - One tab

/// A single tab: close button, filename, open-task badge.
///
/// The badge's source is the constraint worth restating, because getting it
/// from the obvious place would be a silent ADR-4 violation:
///
/// > **No feature may assume a tab's web view exists.** Anything operating
/// > across all open documents goes through the core against the file on disk.
///
/// So the count comes from ``DocumentTab/metadata``, which
/// ``DocumentMetadata/load(url:)`` fills in from `mark_tasks_json`. A
/// dehydrated tab has no DOM to query and shows a correct badge anyway.
@MainActor
public final class TabItemView: NSView {

    weak var bar: TabBarView?
    public private(set) var tab: DocumentTab?
    public private(set) var isSelected = false

    /// On screen in the pane that does **not** have the focus.
    ///
    /// A third state, added by `2026-08-26-multiple-windows-and-split-panes`.
    /// Without it a split window has two documents visible and only one of them
    /// looks open, so there is no way to tell which of six tabs are the two you
    /// are actually reading.
    /// Whether the bar this tab is in has the focus. A selected tab in the
    /// unfocused group is still the document on screen there, so it keeps its
    /// background and loses the full-strength accent stripe.
    public private(set) var isBarActive = true

    /// Drawn lifted and semi-transparent while the user drags it.
    var isDragging = false {
        didSet { needsDisplay = true }
    }

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            closeButton.isHidden = !(isHovered || isSelected)
            needsDisplay = true
        }
    }

    /// Set from outside after a drag, where the tracking areas were bypassed.
    func setHovered(_ hovered: Bool) { isHovered = hovered }

    private let closeButton = TabCloseButton()
    private var trackingArea: NSTrackingArea?

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        closeButton.item = self
        closeButton.isHidden = true
        addSubview(closeButton)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabItemView is created in code, not from a nib")
    }

    func configure(tab: DocumentTab, isSelected: Bool, isBarActive: Bool = true) {
        self.tab = tab
        self.isSelected = isSelected
        self.isBarActive = isBarActive
        closeButton.isHidden = !(isSelected || isHovered)
        toolTip = [tab.metadata?.documentTitle, tab.url.path]
            .compactMap { $0 }
            .joined(separator: "\n")
        needsDisplay = true
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        let size = TabBarView.closeButtonSize
        closeButton.frame = NSRect(
            x: TabBarView.horizontalPadding - 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public override func mouseDown(with event: NSEvent) {
        bar?.beginInteraction(with: self, event: event)
    }

    /// Right-click. ⌘\\ and ⌃⌘N are in the menu bar, and a shortcut nobody can
    /// find is not a feature — this is where someone looks for "show this one
    /// beside that one".
    ///
    /// Every item carries its tab in `representedObject`, so the actions act on
    /// the tab that was clicked rather than on the selected one. Validation is
    /// `MainWindowController`'s, through the responder chain, exactly like the
    /// menu-bar copies.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab else { return nil }
        let menu = NSMenu(title: tab.title)
        let items: [(String, Selector)] = [
            ("Move to Other Pane", #selector(MainWindowController.moveToOtherPane(_:))),
            ("Move Tab to New Window", #selector(MainWindowController.popOutTab(_:))),
        ]
        for (title, action) in items {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.representedObject = tab
        }
        menu.addItem(.separator())
        let close = menu.addItem(
            withTitle: "Close Tab", action: #selector(MainWindowController.closeTab(_:)),
            keyEquivalent: "")
        close.representedObject = tab
        let closeOthers = menu.addItem(
            withTitle: "Close Other Tabs",
            action: #selector(MainWindowController.closeOtherTabs(_:)), keyEquivalent: "")
        closeOthers.representedObject = tab
        // No `representedObject`: this one is about the window rather than
        // about the tab that was clicked, and handing it a tab would suggest
        // otherwise.
        menu.addItem(
            withTitle: "Close All Tabs",
            action: #selector(MainWindowController.closeAllTabs(_:)), keyEquivalent: "")
        // Right-clicking a tab is also a way of pointing at it, and acting on a
        // tab that is not the selected one without saying so would be a
        // surprise. Selecting first makes the two agree.
        bar?.store?.select(tab)
        return menu
    }

    /// Middle-click closes, matching every browser tab bar.
    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let tab, bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        bar?.store?.close(tab)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let tab else { return }

        if isSelected {
            NSColor.controlBackgroundColor.setFill()
            bounds.fill()
            // The accent stripe is the redundant-encoding half of "do not rely
            // on colour alone": the selected tab is also the only one drawn on
            // the document's own background.
            //
            // Dimmed in the unfocused group: that document *is* on screen —
            // this is the tab of the pane beside the one being acted on — so it
            // keeps the stripe rather than losing it, and the difference is a
            // strength rather than a hue, which survives the colour-blind case
            // the selected state is already careful about.
            NSColor.controlAccentColor.withAlphaComponent(isBarActive ? 1 : 0.35).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        } else if isHovered {
            NSColor.controlBackgroundColor.withAlphaComponent(0.4).setFill()
            bounds.fill()
        }
        if isDragging {
            NSColor.controlBackgroundColor.setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            bounds.insetBy(dx: 0.5, dy: 0.5).frame(withWidth: 1)
        }

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: 4, width: 1, height: bounds.height - 8).fill()

        let badgeWidth = drawBadge(outstanding: tab.openTaskCount)
        let dirtyWidth = drawDirtyDot(tab.isDirty)

        let leading = TabBarView.horizontalPadding + TabBarView.closeButtonSize + dirtyWidth
        let trailing = TabBarView.horizontalPadding + badgeWidth
        let titleRect = NSRect(
            x: leading,
            y: 0,
            width: max(0, bounds.width - leading - trailing),
            height: bounds.height
        )
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        // The second half of the focus indicator, and the one that survives a
        // dark theme where two greys are nearly the same: the unfocused group's
        // current document is named in the colour every *other* tab is named in,
        // so only the focused group has a full-strength title.
        let titleColour: NSColor =
            isSelected && isBarActive ? .labelColor : .secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont(selected: isSelected, preview: tab.isPreview),
            .foregroundColor: titleColour,
            .paragraphStyle: style,
        ]
        let title = tab.title as NSString
        let height = title.size(withAttributes: attributes).height
        title.draw(
            in: titleRect.insetBy(dx: 0, dy: (titleRect.height - height) / 2),
            withAttributes: attributes)
    }

    /// The tab label's font: italic for a preview tab, upright otherwise.
    ///
    /// Italic is the signal VS Code uses and the one this bar can afford — the
    /// tab is already carrying a close button, a dirty dot, and a task badge,
    /// and a fourth glyph would leave no room for the filename. It is
    /// deliberately **not** the only signal: ``TabItemView/accessibilityLabel``
    /// says "preview" in words, for the same reason the dirty dot is spoken as
    /// "edited".
    ///
    /// Converted through `NSFontManager` rather than by adding `.italic` to the
    /// descriptor, because the descriptor route **silently drops the weight**:
    /// asking a semibold system font for the italic trait resolves to
    /// `.SFNS-RegularItalic`, so the selected tab would quietly stop being
    /// bolder than its neighbours the moment it was a preview. The font manager
    /// resolves the same request to `.SFNS-SemiboldItalic` and keeps both.
    ///
    /// It also fails in the right direction: with no italic face available it
    /// returns the font it was given, which is a legible upright tab rather
    /// than a missing label.
    static func titleFont(selected: Bool, preview: Bool) -> NSFont {
        let size = NSFont.smallSystemFontSize + 1
        let base = NSFont.systemFont(ofSize: size, weight: selected ? .semibold : .regular)
        guard preview else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    /// The unsaved-changes dot, in the place every editor on this platform
    /// puts it.
    ///
    /// Autosave makes this short-lived — 800 ms after the last keystroke — but
    /// it is not decoration: a dirty tab is exempt from ADR-4's eviction and is
    /// rendered from its buffer rather than from the file, and *"which of my
    /// tabs is in that state"* is otherwise invisible. It also tells the reader
    /// at a glance when autosave has stopped, which is what an unresolved
    /// conflict looks like from the outside.
    @discardableResult
    private func drawDirtyDot(_ isDirty: Bool) -> CGFloat {
        guard isDirty else { return 0 }
        let diameter: CGFloat = 6
        let rect = NSRect(
            x: TabBarView.horizontalPadding + TabBarView.closeButtonSize,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        (isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
        NSBezierPath(ovalIn: rect).fill()
        return diameter + 4
    }

    /// The outstanding-task badge. Returns the width it consumed so the title
    /// can avoid it.
    ///
    /// One number, not two: the bar has room for a count and the sidebar is
    /// where `outstanding/active` is spelled out. It counts open, in-progress
    /// and blocked, and no longer counts a cancelled item at all
    /// (`2026-08-27-five-task-states`).
    @discardableResult
    private func drawBadge(outstanding: Int?) -> CGFloat {
        guard let open = outstanding else { return 0 }
        let text = "\(open)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let width = max(16, textSize.width + 10)
        let rect = NSRect(
            x: bounds.width - TabBarView.horizontalPadding - width,
            y: (bounds.height - 15) / 2,
            width: width,
            height: 15
        )
        (isSelected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7.5, yRadius: 7.5).fill()
        text.draw(
            at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2),
            withAttributes: attributes)
        return width + TabBarView.horizontalPadding
    }

    // MARK: - Accessibility

    /// `AXRadioButton` is what AppKit's own `NSTabView` tabs report, so
    /// VoiceOver's tab-group navigation and its announcements already know
    /// what to do with it. A custom role would be honest and useless.
    public override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }

    public override func isAccessibilityElement() -> Bool { true }

    /// Filename **and** open-task count.
    ///
    /// The count is in the label rather than only in the value because
    /// VoiceOver reads a radio button's value as its selected state; a count
    /// left in `accessibilityValue` would simply not be spoken. It is also
    /// exposed as ``accessibilityValueDescription()`` for clients that do read
    /// it.
    public override func accessibilityLabel() -> String? {
        guard let tab else { return nil }
        // "edited" rather than a dot, because the dot is exactly the
        // colour-and-shape-only signal VoiceOver cannot see.
        let edited = tab.isDirty ? ", edited" : ""
        // "preview" in words, because the italic that says it on screen is
        // exactly the shape-only signal VoiceOver cannot see — and this one
        // matters more than most: a preview tab is the one that disappears
        // when you open the next document.
        let preview = tab.isPreview ? ", preview" : ""
        guard let outstanding = tab.openTaskCount else { return tab.title + preview + edited }
        return
            "\(tab.title)\(preview)\(edited), \(outstanding) outstanding \(outstanding == 1 ? "task" : "tasks")"
    }

    /// The badge, read out.
    ///
    /// "Outstanding" rather than "open" since `2026-08-27-five-task-states`:
    /// open is one of five states now, and in-progress and blocked are also
    /// still to do. Cancelled items leave both numbers, so the count VoiceOver
    /// reads and the count the badge draws are the same arithmetic —
    /// ``TaskCounts``' — rather than two.
    public override func accessibilityValueDescription() -> String? {
        guard let tab else { return nil }
        guard let counts = tab.metadata?.taskCounts, counts.active > 0 else { return "no tasks" }
        return "\(counts.outstanding) of \(counts.active) tasks outstanding"
    }

    public override func accessibilityValue() -> Any? { isSelected }

    public override func isAccessibilitySelected() -> Bool { isSelected }

    public override func accessibilityHelp() -> String? {
        guard let tab else { return nil }
        return "\(tab.url.path) — \(tab.state.rawValue)"
    }

    public override func accessibilityChildren() -> [Any]? { [closeButton] }

    /// ⌃⌥space on the tab. Note this works whether or not the close button is
    /// currently *drawn*: hover-to-reveal is a pointer affordance, and a tab
    /// that VoiceOver cannot activate because the mouse is elsewhere would be
    /// exactly the kind of hand-built-bar defect ADR-4 warns about.
    public override func accessibilityPerformPress() -> Bool {
        guard let tab, let store = bar?.store else { return false }
        store.select(tab)
        return true
    }
}

// MARK: - The close button

/// The per-tab ✕.
@MainActor
public final class TabCloseButton: NSView {

    weak var item: TabItemView?

    private var isHovered = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabCloseButton is created in code, not from a nib")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Swallows the event so a click on ✕ never starts a drag on the tab
    /// underneath it.
    public override func mouseDown(with event: NSEvent) {}

    public override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = close(closeOthers: event.modifierFlags.contains(.option))
    }

    /// ⌥-click closes the *other* tabs, which is what native tabbing does and
    /// what research §2.11 recorded as free there.
    @discardableResult
    func close(closeOthers: Bool) -> Bool {
        guard let tab = item?.tab, let store = item?.bar?.store else { return false }
        if closeOthers {
            for other in store.tabs where other != tab { store.close(other) }
        } else {
            store.close(tab)
        }
        return true
    }

    public override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.separatorColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        }
        let inset = bounds.insetBy(dx: 4.5, dy: 4.5)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset.minX, y: inset.minY))
        path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        path.move(to: NSPoint(x: inset.maxX, y: inset.minY))
        path.line(to: NSPoint(x: inset.minX, y: inset.maxY))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        (isHovered ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
        path.stroke()
    }

    // MARK: - Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityLabel() -> String? {
        guard let title = item?.tab?.title else { return "Close tab" }
        return "Close \(title)"
    }
    public override func accessibilityPerformPress() -> Bool { close(closeOthers: false) }
}

// MARK: - The overflow chevron

/// Shown only when the bar cannot draw every tab.
@MainActor
public final class TabOverflowButton: NSView {

    weak var bar: TabBarView?
    var hiddenCount = 0

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabOverflowButton is created in code, not from a nib")
    }

    public override func mouseDown(with event: NSEvent) {
        bar?.showOverflowMenu(from: self)
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 4, width: 1, height: bounds.height - 8).fill()

        let text = "»\(hiddenCount)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    public override func accessibilityLabel() -> String? {
        "\(hiddenCount) more \(hiddenCount == 1 ? "document" : "documents")"
    }
    public override func accessibilityPerformPress() -> Bool {
        bar?.showOverflowMenu(from: self)
        return true
    }
}
