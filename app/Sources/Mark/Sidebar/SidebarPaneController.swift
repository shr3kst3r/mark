import AppKit
import Foundation

/// The sidebar, split: the directory tree on top, the front document's pane
/// underneath.
///
/// ADR-4 makes the shared sidebar the reason `mark` is one window rather than N
/// native tabs — *"the sidebar shows the project tree, not a per-document
/// outline"*. This adds the per-document outline **without** taking that back:
/// there is still one sidebar, in one window, and the outline half follows the
/// front document exactly the way the tree half already follows it.
///
/// The lower half is a ``DocumentPaneController`` — the outline or the tasks,
/// chosen by a control in its own header (`2026-08-28-tabbed-document-pane`).
/// That changes nothing here: the split, the divider's autosave, the minimum
/// heights and the collapse behaviour all belong to the geometry, and the
/// geometry did not change when the lower half gained a second thing to show.
///
/// A plain `NSSplitView` inside a plain `NSViewController`, and deliberately
/// **not** a nested `NSSplitViewController`. `toggleSidebar(_:)` is dispatched
/// down the responder chain to the first split view controller it finds, so a
/// second one inside the sidebar would swallow ⌃⌘S whenever the focus happened
/// to be in the tree — and swallow it silently, because a split view controller
/// with no `.sidebar` item has nothing to toggle.
@MainActor
public final class SidebarPaneController: NSViewController {

    /// The directory tree. Unchanged, and still the thing every other caller
    /// means by "the sidebar".
    public let tree: TreeViewController

    /// The front document's pane: headings or tasks.
    public let documentPane: DocumentPaneController

    /// The front document's headings — the pane's Contents tab.
    public var contents: TableOfContentsViewController { documentPane.contents }

    /// The front document's tasks — the pane's Tasks tab.
    public var taskList: TaskListViewController { documentPane.taskList }

    /// How tall the document pane is when it has never been dragged.
    public static let defaultContentsHeight: CGFloat = 220

    /// Neither half may be squeezed below this. Two rows and a header.
    static let minimumPaneHeight: CGFloat = 72

    public private(set) var splitView: NSSplitView!

    /// Whether the divider has been placed once, so the default share is
    /// applied on first layout and never again.
    private var didPlaceDivider = false

    public init(tree: TreeViewController, documentPane: DocumentPaneController) {
        self.tree = tree
        self.documentPane = documentPane
        super.init(nibName: nil, bundle: nil)
        addChild(tree)
        addChild(documentPane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarPaneController is created in code, not from a nib")
    }

    public override func loadView() {
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 260, height: 700))
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        // UserDefaults, like the window's own frame autosave — not
        // `NSWindowRestoration`, which ADR-4 turns off. Where the reader put
        // the divider is a preference, not session state, and it is the same
        // one for every project they open.
        splitView.autosaveName = "dev.mark.SidebarSplit"
        splitView.addSubview(tree.view)
        splitView.addSubview(documentPane.view)
        splitView.delegate = self
        self.splitView = splitView
        view = splitView
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        placeDividerIfNeeded()
    }

    /// Give the document pane its default share, once.
    ///
    /// Skipped entirely when `autosaveName` has already restored a position —
    /// which is what the height check is: a restored divider leaves the lower
    /// pane with a real height, and an unset one leaves it with essentially
    /// none, because `NSSplitView` divides evenly only after it has been asked
    /// to lay out at all.
    private func placeDividerIfNeeded() {
        guard !didPlaceDivider, splitView.bounds.height > 0 else { return }
        didPlaceDivider = true
        guard !splitView.isSubviewCollapsed(documentPane.view) else { return }
        let height = splitView.bounds.height
        let existing = documentPane.view.frame.height
        // An even 50/50 split is `NSSplitView`'s answer when nothing was
        // restored, and it is the wrong one here: the tree is the pane you
        // scroll and the outline is the pane you glance at.
        guard existing < Self.minimumPaneHeight || abs(existing - height / 2) < 1 else { return }
        let wanted = min(Self.defaultContentsHeight, max(Self.minimumPaneHeight, height * 0.4))
        splitView.setPosition(height - wanted, ofDividerAt: 0)
    }

    // MARK: - Showing and hiding the document pane

    public var isDocumentPaneVisible: Bool {
        isViewLoaded && !splitView.isSubviewCollapsed(documentPane.view)
            && !documentPane.view.isHidden
    }

    /// Show or hide the lower half. The tree half is always on screen —
    /// ⌃⌘S hides the whole sidebar, which is the coarse control.
    ///
    /// Visibility is the pane's, not a tab's: ⌃⌘T and ⌃⌘Y choose *which* tab is
    /// on screen, and this says whether any of it is
    /// (`2026-08-28-tabbed-document-pane`).
    public func setDocumentPaneVisible(_ visible: Bool) {
        guard isViewLoaded, visible != isDocumentPaneVisible else { return }
        documentPane.view.isHidden = !visible
        if visible, documentPane.view.frame.height < Self.minimumPaneHeight {
            let height = splitView.bounds.height
            let wanted = min(Self.defaultContentsHeight, max(Self.minimumPaneHeight, height * 0.4))
            splitView.setPosition(height - wanted, ofDividerAt: 0)
        }
        splitView.adjustSubviews()
        splitView.needsLayout = true
        Log.tree.info("document pane \(visible ? "shown" : "hidden")")
    }
}

// MARK: - NSSplitViewDelegate

extension SidebarPaneController: @MainActor NSSplitViewDelegate {

    public func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int
    ) -> CGFloat {
        max(proposed, Self.minimumPaneHeight)
    }

    public func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int
    ) -> CGFloat {
        min(proposed, splitView.bounds.height - Self.minimumPaneHeight)
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === documentPane.view
    }

    public func splitView(
        _ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
        forDoubleClickOnDividerAt index: Int
    ) -> Bool {
        subview === documentPane.view
    }
}
