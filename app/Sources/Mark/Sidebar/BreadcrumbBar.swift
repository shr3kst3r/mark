import AppKit
import Foundation

/// The sidebar's path bar: back, forward, and one clickable button per path
/// component.
///
/// Plan §2 M8 asks for *"a breadcrumb bar showing the path with each component
/// clickable"* and for ⌘[ / ⌘] *"because 'up, look, back down' is the actual
/// navigation loop"*. The two belong together: the breadcrumb is how you get
/// somewhere, and the arrows are how you undo having gone there.
///
/// M8's first cut stopped at "clickable components", and that turned out to be
/// the floor rather than the feature. What a path bar in Finder, Windows
/// Explorer, or GNOME Files does — and what this now does — is four more
/// things, each of which fixes something the first cut got wrong:
///
/// * **The overflow is reachable.** Crumbs that do not fit collapse into a `…`
///   *button* whose menu lists them. The first cut dropped them behind a `…`
///   label with no menu, which made those ancestors unreachable except by
///   repeated ⌘↑ — a bar that hides where you came from and offers no way
///   back is worse than one that scrolls.
/// * **The root is pinned.** Truncation eats the *middle*, nearest the root
///   first, keeping `/` and the current directory. The first cut truncated
///   from index 0, so `/` and the volume were the first things to go; head and
///   tail are exactly the two crumbs people navigate by.
/// * **Every chevron is a menu.** The separator after a crumb lists that
///   directory's subdirectories, with the one you are actually in checked. It
///   is how you get from `notes/2026/08` to `notes/2026/07` in one click
///   instead of up-then-down, and it is the single feature that distinguishes
///   Explorer's address bar from a row of links. Each menu costs **exactly one
///   directory read, when it opens** — never during layout, never on a
///   navigation, so the "the tree must never eagerly walk" constraint
///   (research §2.8) survives intact.
/// * **Crumbs answer to the keyboard, to right-click, and to drags.** ⌘⌥P
///   focuses the bar; ← / → walk it; ↓ opens the sibling menu; ⏎ navigates.
///   Right-click gives Go Here / Copy Path / Reveal in Finder. A crumb can be
///   dragged out to Finder, and files can be dropped onto one.
///
/// Laid out by hand rather than in a stack view. The bar has to **shrink, then
/// collapse the middle** when the path is deeper than the sidebar is wide, and
/// `NSStackView` has no notion of "shrink everything to a floor, then drop the
/// crumbs nearest the root behind an ellipsis".
@MainActor
public final class BreadcrumbBar: NSView {

    public static let barHeight: CGFloat = 26

    /// How many entries a chevron menu lists before it stops. A directory with
    /// more subdirectories than this gets a disabled "N more…" row rather than
    /// a silently short menu — a truncated list that does not say it is
    /// truncated reads as "that folder isn't there".
    public static let menuLimit = 500

    // MARK: - Wiring

    /// A crumb was clicked, or a sibling was chosen from a menu.
    public var onSelect: ((URL) -> Void)?
    public var onBack: (() -> Void)?
    public var onForward: (() -> Void)?

    /// The subdirectories of a directory, for the chevron menus.
    ///
    /// Called **only when a menu is about to open**, which is what keeps this
    /// from being an eager walk: one read, for one directory, because someone
    /// clicked a chevron.
    public var childDirectories: ((URL) -> [URL])?

    /// ⌘⌥R, from the context menu.
    public var onRevealInFinder: ((URL) -> Void)?

    /// Files were dropped onto a crumb: `(destination, dropped, move)`. `move`
    /// is true when the user held ⌘. Returns whether the drop was accepted.
    public var onDropFiles: ((URL, [URL], Bool) -> Bool)?

    /// Files were dropped on the bar but not on a crumb — same meaning as a
    /// drop on the sidebar below it.
    public var onDropOnBar: (([URL]) -> Bool)?

    // MARK: - Geometry

    private enum Metric {
        static let inset: CGFloat = 6
        static let arrow: CGFloat = 20
        static let chevron: CGFloat = 13
        static let ellipsis: CGFloat = 18
        static let maxCrumb: CGFloat = 140
        static let minCrumb: CGFloat = 34
        static let padding: CGFloat = 8
    }

    // MARK: - Views

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let ellipsisButton = MenuButton()
    private var crumbButtons: [CrumbButton] = []
    /// `chevronButtons[i]` is the chevron drawn *after* crumb `i`; its menu
    /// lists crumb `i`'s subdirectories.
    private var chevronButtons: [MenuButton] = []

    private var crumbs: [Navigator.Crumb] = []

    /// The indices folded behind the ellipsis. Always contiguous, and always a
    /// prefix-ish run: `1..<k` while the root survives, `0..<n-1` once it does
    /// not.
    public private(set) var collapsed: Range<Int> = 0..<0

    /// The crumb the keyboard is on, while the bar is first responder.
    public private(set) var focusedCrumbIndex: Int?

    /// The crumb a drag is hovering over.
    private var dropTarget: Int?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureIconButton(backButton, symbol: "chevron.left", fallback: "‹", label: "Back")
        configureIconButton(
            forwardButton, symbol: "chevron.right", fallback: "›", label: "Forward")
        backButton.target = self
        backButton.action = #selector(backClicked)
        forwardButton.target = self
        forwardButton.action = #selector(forwardClicked)
        addSubview(backButton)
        addSubview(forwardButton)

        configureIconButton(ellipsisButton, symbol: nil, fallback: "…", label: "Hidden folders")
        ellipsisButton.target = self
        ellipsisButton.action = #selector(ellipsisClicked(_:))
        ellipsisButton.isHidden = true
        ellipsisButton.toolTip = "Show the folders that don't fit"
        ellipsisButton.menuProvider = { [weak self] in self?.makeOverflowMenu() }
        addSubview(ellipsisButton)

        registerForDraggedTypes([.fileURL])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Path")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BreadcrumbBar is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    // MARK: - Content

    /// Rebuild for a navigator's current state.
    public func update(with navigator: Navigator) {
        backButton.isEnabled = navigator.canGoBack
        forwardButton.isEnabled = navigator.canGoForward
        setCrumbs(navigator.breadcrumb)
    }

    /// The crumbs currently shown, for tests and for `mark-bench`.
    public var crumbTitles: [String] { crumbs.map(\.name) }

    /// The crumbs that actually fit, in path order. Everything else is behind
    /// the ellipsis.
    public var visibleCrumbTitles: [String] {
        crumbButtons.filter { !$0.isHidden }.map(\.title)
    }

    /// The crumbs folded behind the ellipsis, outermost first. Empty when the
    /// whole path fits.
    public var overflowedCrumbTitles: [String] {
        collapsed.map { crumbs[$0].name }
    }

    private func setCrumbs(_ crumbs: [Navigator.Crumb]) {
        self.crumbs = crumbs
        // Reuse buttons rather than rebuilding: a breadcrumb changes on every
        // navigation, and discarding views on each one churns the responder
        // chain and the accessibility tree for no reason.
        while crumbButtons.count < crumbs.count {
            let index = crumbButtons.count

            let button = CrumbButton()
            configureCrumbButton(button)
            button.tag = index
            button.target = self
            button.action = #selector(crumbClicked(_:))
            button.onBeginDrag = { [weak self] button, event in
                self?.beginDrag(from: button, with: event)
            }
            // Right-click has to be answered *here* rather than on the bar: the
            // click hit-tests to the button, and whether AppKit walks a nil
            // `menu(for:)` up to the superview is not something to rely on.
            button.menuProvider = { [weak self] in self?.makeContextMenu(forCrumbAt: index) }
            addSubview(button)
            crumbButtons.append(button)

            let chevron = MenuButton()
            configureIconButton(
                chevron, symbol: "chevron.right", fallback: "›", label: "Subfolders")
            chevron.tag = index
            chevron.target = self
            chevron.action = #selector(chevronClicked(_:))
            chevron.menuProvider = { [weak self] in self?.makeSiblingMenu(forCrumbAt: index) }
            addSubview(chevron)
            chevronButtons.append(chevron)
        }

        for (index, button) in crumbButtons.enumerated() {
            guard index < crumbs.count else {
                button.title = ""
                button.url = nil
                continue
            }
            let crumb = crumbs[index]
            let isCurrent = index == crumbs.count - 1
            button.title = crumb.name
            button.url = crumb.url
            button.toolTip = crumb.url.path
            // The AppKit analogue of `aria-current="page"`: the last crumb is
            // where you already are, and a bar that looks identical whether or
            // not you have arrived is the confusion GNOME's design notes record
            // — users read a highlighted middle crumb as "I moved there".
            button.setAccessibilityLabel(isCurrent ? "\(crumb.name), current folder" : crumb.name)
            button.contentTintColor = isCurrent ? .labelColor : .secondaryLabelColor
            chevronButtons[index].toolTip = "Folders in \(crumb.name)"
            chevronButtons[index].setAccessibilityLabel("Folders in \(crumb.name)")
        }

        if let focused = focusedCrumbIndex, focused >= crumbs.count {
            focusedCrumbIndex = crumbs.indices.last
        }
        needsLayout = true
    }

    // MARK: - Layout

    /// What a given width can show: which crumbs fold away, how wide the rest
    /// are, and whether there was room for the chevrons at all.
    private struct Plan {
        var collapsed: Range<Int>
        var widths: [CGFloat]
        var showsChevrons: Bool
    }

    public override func layout() {
        var x = Metric.inset
        backButton.frame = NSRect(x: x, y: 0, width: Metric.arrow, height: bounds.height)
        x += Metric.arrow
        forwardButton.frame = NSRect(x: x, y: 0, width: Metric.arrow, height: bounds.height)
        x += Metric.arrow + 4

        let available = max(0, bounds.width - x - Metric.inset)
        let plan = plan(for: available)
        collapsed = plan.collapsed

        // Everything starts hidden and is unhidden as it is placed. Positioning
        // is a single left-to-right pass, so "which chevron survives next to
        // the ellipsis" is decided by where it lands rather than by a second
        // set of rules that could disagree with the first.
        ellipsisButton.isHidden = true
        for button in crumbButtons { button.isHidden = true }
        for chevron in chevronButtons { chevron.isHidden = true }

        for index in crumbs.indices {
            if index == collapsed.lowerBound && !collapsed.isEmpty {
                ellipsisButton.isHidden = false
                ellipsisButton.frame = NSRect(
                    x: x, y: 0, width: Metric.ellipsis, height: bounds.height)
                x += Metric.ellipsis
                // The chevron for the *last* collapsed crumb is kept: it both
                // separates the ellipsis from what follows and lists the
                // siblings of the crumb that follows it, which is the most
                // useful menu on the bar when the path is deep.
                if plan.showsChevrons {
                    let chevron = chevronButtons[collapsed.upperBound - 1]
                    chevron.isHidden = false
                    chevron.frame = NSRect(
                        x: x, y: 0, width: Metric.chevron, height: bounds.height)
                    x += Metric.chevron
                }
            }
            guard !collapsed.contains(index) else { continue }

            let button = crumbButtons[index]
            button.isHidden = false
            button.frame = NSRect(x: x, y: 0, width: plan.widths[index], height: bounds.height)
            x += plan.widths[index]

            if plan.showsChevrons {
                let chevron = chevronButtons[index]
                chevron.isHidden = false
                chevron.frame = NSRect(x: x, y: 0, width: Metric.chevron, height: bounds.height)
                x += Metric.chevron
            }
        }
        // A resize can fold away the very crumb the keyboard was on, and focus
        // sitting on a crumb nobody can see is focus nobody can use.
        clampFocus()
        super.layout()
    }

    /// Shrink before collapsing; collapse the middle before the root.
    ///
    /// The order is the whole point. Mature path bars squeeze every crumb down
    /// to a floor first, and only fold crumbs away when even the floor does not
    /// fit — folding while there is still slack is what makes a bar feel jumpy
    /// as the sidebar is resized. When something must go, it is the crumbs
    /// *adjacent to the root* (GNOME's rule), because the head says which tree
    /// you are in and the tail says where you are; the middle is the part
    /// nobody navigates by.
    private func plan(for available: CGFloat) -> Plan {
        let n = crumbs.count
        guard n > 0 else { return Plan(collapsed: 0..<0, widths: [], showsChevrons: false) }

        let natural = (0..<n).map { index in
            min(Metric.maxCrumb, ceil(crumbButtons[index].intrinsicContentSize.width) + Metric.padding)
        }
        let floors = natural.map { min($0, Metric.minCrumb) }

        func minimumWidth(_ collapsed: Range<Int>, chevrons: Bool) -> CGFloat {
            var sum: CGFloat = 0
            if !collapsed.isEmpty {
                sum += Metric.ellipsis + (chevrons ? Metric.chevron : 0)
            }
            for index in 0..<n where !collapsed.contains(index) {
                sum += floors[index] + (chevrons ? Metric.chevron : 0)
            }
            return sum
        }

        var collapsed = 1..<1
        var upper = 1
        while minimumWidth(collapsed, chevrons: true) > available && upper < n - 1 {
            upper += 1
            collapsed = 1..<upper
        }
        // The root goes last, and only if it has to.
        if minimumWidth(collapsed, chevrons: true) > available && n > 1 {
            collapsed = 0..<(n - 1)
        }
        // Narrower than that and the chevrons are what gives: a bar showing
        // only the current folder is still a bar, one showing only chevrons is
        // not.
        let showsChevrons = minimumWidth(collapsed, chevrons: true) <= available

        // Hand the slack back in proportion to what each crumb actually wanted,
        // so a long name and a short one shrink together rather than the long
        // one being truncated while the short one keeps its padding.
        var widths = floors
        let leftover = available - minimumWidth(collapsed, chevrons: showsChevrons)
        if leftover > 0 {
            let wants = (0..<n).map { collapsed.contains($0) ? 0 : natural[$0] - floors[$0] }
            let total = wants.reduce(0, +)
            if total > 0 {
                let share = min(1, leftover / total)
                for index in 0..<n { widths[index] = floors[index] + wants[index] * share }
            }
        }
        return Plan(collapsed: collapsed, widths: widths, showsChevrons: showsChevrons)
    }

    /// A hairline under the bar, the keyboard focus ring, and the drop
    /// highlight — the sidebar's material shows through from
    /// ``SidebarContainerView``'s backing view for everything else.
    public override func draw(_ dirtyRect: NSRect) {
        if let target = dropTarget, crumbButtons.indices.contains(target) {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(
                roundedRect: crumbButtons[target].frame.insetBy(dx: 0, dy: 3), xRadius: 4,
                yRadius: 4
            ).fill()
        }
        if let focused = focusedCrumbIndex, crumbButtons.indices.contains(focused),
            !crumbButtons[focused].isHidden, window?.firstResponder === self
        {
            let rect = crumbButtons[focused].frame.insetBy(dx: 0, dy: 3)
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.30).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            ring.lineWidth = 1
            ring.stroke()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Menus

    /// The ancestors folded behind the ellipsis, outermost first.
    public func makeOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        for index in collapsed {
            let crumb = crumbs[index]
            let item = NSMenuItem(
                title: crumb.name, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = crumb.url
            item.toolTip = crumb.url.path
            item.image = Self.folderIcon
            menu.addItem(item)
        }
        return menu
    }

    /// The subdirectories of crumb `index`, with the one this path goes through
    /// checked.
    ///
    /// Costs one directory read, here, because a menu is opening. Returns `nil`
    /// when nothing supplied ``childDirectories``.
    public func makeSiblingMenu(forCrumbAt index: Int) -> NSMenu? {
        guard crumbs.indices.contains(index), let childDirectories else { return nil }
        let crumb = crumbs[index]
        let children = childDirectories(crumb.url)
        let menu = NSMenu()
        guard !children.isEmpty else {
            let empty = NSMenuItem(title: "No Folders", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        // The crumb after this one is the child the current path goes through;
        // marking it is what turns "a list of folders" into "where you are, and
        // what is beside it".
        let onPath = index + 1 < crumbs.count ? crumbs[index + 1].url.path : nil
        for child in children.prefix(Self.menuLimit) {
            let item = NSMenuItem(
                title: child.lastPathComponent, action: #selector(menuItemChosen(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = child
            item.toolTip = child.path
            item.image = Self.folderIcon
            item.state = child.path == onPath ? .on : .off
            menu.addItem(item)
        }
        if children.count > Self.menuLimit {
            menu.addItem(.separator())
            let more = NSMenuItem(
                title: "\(children.count - Self.menuLimit) more not shown", action: nil,
                keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
        return menu
    }

    /// Right-click on a crumb. The current location gets a different menu from
    /// the rest — "Go Here" on the folder you are already in is the item that
    /// makes people think the bar is broken.
    public func makeContextMenu(forCrumbAt index: Int) -> NSMenu? {
        guard crumbs.indices.contains(index) else { return nil }
        let crumb = crumbs[index]
        let menu = NSMenu()
        if index != crumbs.count - 1 {
            let go = NSMenuItem(
                title: "Go Here", action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            go.target = self
            go.representedObject = crumb.url
            menu.addItem(go)
            menu.addItem(.separator())
        }
        let copy = NSMenuItem(
            title: "Copy Path", action: #selector(copyPathChosen(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = crumb.url
        menu.addItem(copy)

        let reveal = NSMenuItem(
            title: "Reveal in Finder", action: #selector(revealChosen(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = crumb.url
        menu.addItem(reveal)
        return menu
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if !ellipsisButton.isHidden, ellipsisButton.frame.contains(point) {
            return makeOverflowMenu()
        }
        guard let index = crumbIndex(at: point) else { return super.menu(for: event) }
        return makeContextMenu(forCrumbAt: index)
    }

    private static let folderIcon: NSImage = {
        let icon = SidebarIcons.icon(isDirectory: true, pathExtension: "")
        let small = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }
        return small
    }()

    private func popUp(_ menu: NSMenu, under view: NSView) {
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: isFlipped ? view.bounds.maxY : view.bounds.minY), in: view)
    }

    // MARK: - Keyboard

    /// ⌘⌥P. Focus the bar, landing on the current folder.
    public func focusPathBar() {
        window?.makeFirstResponder(self)
    }

    public override var acceptsFirstResponder: Bool { !crumbs.isEmpty }

    public override func becomeFirstResponder() -> Bool {
        if focusedCrumbIndex == nil { focusedCrumbIndex = crumbs.indices.last }
        clampFocus()
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        focusedCrumbIndex = nil
        needsDisplay = true
        return true
    }

    /// Move the keyboard focus `offset` crumbs along, skipping what is folded
    /// away. Returns whether it moved.
    @discardableResult
    public func moveFocus(by offset: Int) -> Bool {
        guard !crumbs.isEmpty else { return false }
        var index = focusedCrumbIndex ?? crumbs.count - 1
        let step = offset < 0 ? -1 : 1
        for _ in 0..<abs(offset) {
            var next = index + step
            while collapsed.contains(next) { next += step }
            guard crumbs.indices.contains(next) else { return false }
            index = next
        }
        focusedCrumbIndex = index
        needsDisplay = true
        return true
    }

    /// ⏎ on the focused crumb.
    @discardableResult
    public func activateFocusedCrumb() -> Bool {
        guard let index = focusedCrumbIndex, crumbs.indices.contains(index) else { return false }
        onSelect?(crumbs[index].url)
        return true
    }

    /// ↓ or Space on the focused crumb: its subfolders, as a menu.
    @discardableResult
    public func openFocusedCrumbMenu() -> Bool {
        guard let index = focusedCrumbIndex, crumbs.indices.contains(index),
            let menu = makeSiblingMenu(forCrumbAt: index)
        else { return false }
        popUp(menu, under: crumbButtons[index].isHidden ? self : crumbButtons[index])
        return true
    }

    public override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 123:  // ←
            if moveFocus(by: -1) { return }
        case 124:  // →
            if moveFocus(by: 1) { return }
        case 125:  // ↓
            if openFocusedCrumbMenu() { return }
        case 36, 76:  // ⏎, enter
            if activateFocusedCrumb() { return }
        case 49:  // space
            if openFocusedCrumbMenu() { return }
        case 53:  // esc
            window?.makeFirstResponder(nil)
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// Keep the focus off a crumb that has since folded away.
    private func clampFocus() {
        guard let index = focusedCrumbIndex, collapsed.contains(index) else { return }
        focusedCrumbIndex = min(collapsed.upperBound, crumbs.count - 1)
    }

    // MARK: - Drag and drop

    /// A crumb is a folder, and a folder should be draggable out of the bar the
    /// same way a row is draggable out of the tree.
    private func beginDrag(from button: CrumbButton, with event: NSEvent) {
        guard let url = button.url else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(button.frame, contents: Self.folderIcon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = SidebarContainerView.urls(from: sender)
        guard !urls.isEmpty else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let index = crumbIndex(at: point)
        if index != dropTarget {
            dropTarget = index
            needsDisplay = true
        }
        guard index != nil else { return onDropOnBar == nil ? [] : .generic }
        // **Copy, not move, unless ⌘ is held.** Explorer and Finder default a
        // same-volume drop to a move; `mark` is a *reader*, and a stray drag
        // across the path bar that silently relocates a note out of the folder
        // it was filed in is a worse failure than a duplicate. ⌘ is Finder's
        // own "force move" modifier, so the destructive reading is available,
        // deliberate, and spelled the way the platform spells it.
        return sender.draggingSourceOperationMask.contains(.move)
            && NSEvent.modifierFlags.contains(.command) ? .move : .copy
    }

    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget = nil
        needsDisplay = true
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = SidebarContainerView.urls(from: sender)
        let point = convert(sender.draggingLocation, from: nil)
        let index = crumbIndex(at: point)
        dropTarget = nil
        needsDisplay = true
        guard !urls.isEmpty else { return false }
        guard let index, crumbs.indices.contains(index) else {
            return onDropOnBar?(urls) ?? false
        }
        let move = NSEvent.modifierFlags.contains(.command)
        return onDropFiles?(crumbs[index].url, urls, move) ?? false
    }

    // MARK: - Hit testing

    /// The crumb under a point in the bar's own coordinates, or `nil`.
    public func crumbIndex(at point: NSPoint) -> Int? {
        for (index, button) in crumbButtons.enumerated()
        where !button.isHidden && index < crumbs.count {
            if button.frame.contains(point) { return index }
        }
        return nil
    }

    // MARK: - Actions

    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard crumbs.indices.contains(sender.tag) else { return }
        focusedCrumbIndex = sender.tag
        needsDisplay = true
        onSelect?(crumbs[sender.tag].url)
    }

    @objc private func chevronClicked(_ sender: NSButton) {
        guard let menu = makeSiblingMenu(forCrumbAt: sender.tag) else { return }
        popUp(menu, under: sender)
    }

    @objc private func ellipsisClicked(_ sender: NSButton) {
        popUp(makeOverflowMenu(), under: sender)
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onSelect?(url)
    }

    @objc private func copyPathChosen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func revealChosen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onRevealInFinder?(url)
    }

    // MARK: - Button configuration

    private func configureIconButton(
        _ button: NSButton, symbol: String?, fallback: String, label: String?
    ) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.lineBreakMode = .byTruncatingMiddle
        button.title = fallback
        button.contentTintColor = .secondaryLabelColor
        if let symbol,
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        {
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        }
        if let label { button.setAccessibilityLabel(label) }
    }

    private func configureCrumbButton(_ button: CrumbButton) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // Middle truncation, the way GNOME ellipsizes: the head of a folder
        // name distinguishes it from its siblings and the tail is often a date
        // or an index, so eating the middle keeps both.
        button.lineBreakMode = .byTruncatingMiddle
    }
}

// MARK: - Dragging source

extension BreadcrumbBar: NSDraggingSource {
    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Same split as the tree's rows: a folder can go out to Finder, and
        // there is nothing inside `mark` for it to be dropped on.
        context == .outsideApplication ? .copy : []
    }
}

// MARK: - The buttons

/// A borderless button whose contextual menu is built when it is asked for.
///
/// The ellipsis and the chevrons both show menus that depend on state at the
/// moment of the click — which crumbs are folded away, what is in a directory
/// right now — so `NSView.menu`, which is a stored property, is the wrong hook.
@MainActor
class MenuButton: NSButton {
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }
}

/// A crumb: a borderless text button that is also a drag source.
///
/// The custom tracking loop exists because `NSButton.mouseDown(with:)` runs
/// its *own* loop until mouse-up, so `mouseDragged(with:)` is never delivered
/// and there is no supported hook for "start a drag instead of a click". The
/// loop below is the standard workaround — watch for the drag threshold first,
/// and fall back to sending the action when the mouse comes up without one.
@MainActor
final class CrumbButton: MenuButton {

    /// The directory this crumb stands for.
    var url: URL?

    /// The drag threshold was crossed, with the event that crossed it.
    var onBeginDrag: ((CrumbButton, NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window, url != nil, onBeginDrag != nil else {
            super.mouseDown(with: event)
            return
        }
        let origin = event.locationInWindow
        isHighlighted = true
        defer { isHighlighted = false }

        var last = event
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            last = next
            if next.type == .leftMouseUp { break }
            let point = next.locationInWindow
            if hypot(point.x - origin.x, point.y - origin.y) > 4 {
                dragging = true
                break
            }
        }
        if dragging {
            onBeginDrag?(self, last)
        } else if bounds.contains(convert(last.locationInWindow, from: nil)), let action {
            sendAction(action, to: target)
        }
    }
}
