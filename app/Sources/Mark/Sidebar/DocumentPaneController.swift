import AppKit
import Foundation

/// The sidebar's lower half: the front document, in one of two tabs.
///
/// `2026-08-28-tabbed-document-pane`. The tree above answers *"which file"*.
/// This pane answers *"where in it"* twice — the headings, or the tasks — and
/// those two are a mode switch rather than a reading loop, which is why they are
/// tabs of one pane and why the tree and this pane are still stacked.
///
/// It owns three things and no document state of its own: the header with the
/// control that chooses the tab, the two child controllers, and the mode. Both
/// children are fed from the selected tab's `DocumentMetadata` by
/// ``MainWindowController``, so this class never reads a file, never queries a
/// DOM, and has nothing to invalidate.
@MainActor
public final class DocumentPaneController: NSViewController {

    /// Which tab is on screen.
    ///
    /// A raw-value enum because it is written to `UserDefaults`, and the raw
    /// values are the strings a log line prints.
    public enum Mode: String, CaseIterable, Sendable {
        case contents
        case tasks

        /// The segment's label, and the menu item's noun.
        public var title: String {
            switch self {
            case .contents: return "Contents"
            case .tasks: return "Tasks"
            }
        }
    }

    /// Where the mode is remembered.
    ///
    /// `UserDefaults` and not the session file, for the reason
    /// ``SidebarPaneController`` gives about the divider: which tab a reader
    /// wants is a preference, the same one for every project they open, and
    /// `SessionState.currentVersion` does not move for a preference.
    public static let modeDefaultsKey = "dev.mark.sidebar.documentPaneMode"

    /// How tall the header row is. One small segmented control plus its
    /// breathing room.
    public static let headerHeight: CGFloat = 26

    /// The front document's headings.
    public let contents: TableOfContentsViewController

    /// The front document's tasks.
    public let taskList: TaskListViewController

    private let defaults: UserDefaults

    /// Called when the tab on screen changes, before the new one is installed,
    /// so its owner can fill it from the selected tab's metadata.
    ///
    /// The pane is fed **lazily**, and the cost of not doing so was measured
    /// against `bench/corpus/1mb.md` (1,787 tasks): building the groups is
    /// 1.9 ms and comparing the task arrays 0.2 ms, plus an outline reload of
    /// ~1,800 rows — per tab switch, for a tab nobody is looking at. Filling it
    /// *before* the swap is what makes the alternative argument ("a tab filled
    /// only while on screen would show the previous document for a frame")
    /// moot.
    public var onNeedsContent: (() -> Void)?

    /// The tab on screen. Setting it swaps the child view, moves the control,
    /// and records the preference.
    public var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
            applyMode()
            Log.tree.info("document pane → \(self.mode.rawValue, privacy: .public)")
        }
    }

    private var container: DocumentPaneContainerView {
        // `view` is this controller's own, built in `loadView`.
        view as! DocumentPaneContainerView
    }

    public init(
        contents: TableOfContentsViewController,
        taskList: TaskListViewController,
        defaults: UserDefaults = .standard
    ) {
        self.contents = contents
        self.taskList = taskList
        self.defaults = defaults
        // An unknown or absent stored value reads as `contents`: the tab this
        // pane has always opened on, and the one a reader who has never pressed
        // ⌃⌘Y expects.
        self.mode = Mode(rawValue: defaults.string(forKey: Self.modeDefaultsKey) ?? "") ?? .contents
        super.init(nibName: nil, bundle: nil)
        addChild(contents)
        addChild(taskList)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentPaneController is created in code, not from a nib")
    }

    public override func loadView() {
        let container = DocumentPaneContainerView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 220),
            titles: Mode.allCases.map(\.title))
        container.onSelect = { [weak self] index in
            guard let self, Mode.allCases.indices.contains(index) else { return }
            self.mode = Mode.allCases[index]
        }
        view = container
        applyMode()
    }

    /// The view currently installed below the header.
    public var activeChild: NSViewController {
        switch mode {
        case .contents: return contents
        case .tasks: return taskList
        }
    }

    /// Install the active child and take the other one out of the hierarchy.
    ///
    /// Out, rather than hidden: a hidden `NSScrollView` still lays out and still
    /// answers hit tests, and two outline views in the same rectangle is exactly
    /// the sort of thing this repo cannot see in a test
    /// (`2026-08-26-editor-groups-per-pane-tab-bars`).
    private func applyMode() {
        guard isViewLoaded else { return }
        let wanted = activeChild
        // Filled before it is installed, never after: the child that is about
        // to appear is holding whichever document it last drew.
        onNeedsContent?()
        for child in [contents as NSViewController, taskList as NSViewController]
        where child !== wanted {
            if child.view.superview === container { child.view.removeFromSuperview() }
        }
        container.body = wanted.view
        container.selectedIndex = Mode.allCases.firstIndex(of: mode) ?? 0
    }
}

/// The header row and whichever child is on screen, stacked.
///
/// Frame-based, like the panes it holds. The header carries an
/// `NSSegmentedControl` rather than two labels we draw: it is keyboard- and
/// VoiceOver-reachable without our writing either, and hand-drawn chrome is
/// where this repo's invisible bugs have come from
/// (`2026-08-26-editor-groups-per-pane-tab-bars`).
@MainActor
public final class DocumentPaneContainerView: NSView {

    /// Called with the segment the user picked.
    public var onSelect: ((Int) -> Void)?

    /// The child view under the header.
    public var body: NSView? {
        didSet {
            guard body !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let body {
                addSubview(body)
            }
            needsLayout = true
        }
    }

    public var selectedIndex: Int {
        get { tabs.selectedSegment }
        set {
            guard newValue != tabs.selectedSegment else { return }
            tabs.selectedSegment = newValue
        }
    }

    public let tabs: NSSegmentedControl

    /// The sidebar's material, for the reason the two child containers carry
    /// one: `mark-bench` hosts these views in a plain window, and a header strip
    /// that is only opaque inside an `NSSplitViewItem` is a strip whose
    /// appearance cannot be checked.
    private let backing = NSVisualEffectView()

    public init(frame: NSRect, titles: [String]) {
        tabs = NSSegmentedControl(
            labels: titles, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: frame)
        backing.material = .sidebar
        backing.blendingMode = .behindWindow
        backing.state = .followsWindowActiveState
        backing.autoresizingMask = [.width, .height]
        addSubview(backing)
        tabs.controlSize = .small
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabPicked)
        tabs.setAccessibilityLabel("Document pane")
        for (index, title) in titles.enumerated() {
            tabs.setToolTip(title, forSegment: index)
        }
        addSubview(tabs)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentPaneContainerView is created in code, not from a nib")
    }

    public override var isFlipped: Bool { true }

    @objc private func tabPicked() {
        onSelect?(tabs.selectedSegment)
    }

    public override func layout() {
        backing.frame = bounds
        let header = DocumentPaneController.headerHeight
        tabs.frame = NSRect(x: 8, y: 3, width: max(0, bounds.width - 16), height: header - 6)
        body?.frame = NSRect(
            x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        super.layout()
    }
}
