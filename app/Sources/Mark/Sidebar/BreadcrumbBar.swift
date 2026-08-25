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
/// Laid out by hand rather than in a stack view. The bar has to **truncate from
/// the left** when the path is deeper than the sidebar is wide — the tail of a
/// path is what identifies where you are, the head is what everyone shares —
/// and `NSStackView` has no notion of "drop leading views and show an ellipsis".
@MainActor
public final class BreadcrumbBar: NSView {

    public static let barHeight: CGFloat = 26

    /// A crumb was clicked.
    public var onSelect: ((URL) -> Void)?
    public var onBack: (() -> Void)?
    public var onForward: (() -> Void)?

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private var crumbButtons: [NSButton] = []
    private var separators: [NSTextField] = []
    private let ellipsis = NSTextField(labelWithString: "…")

    private var crumbs: [Navigator.Crumb] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure(backButton, symbol: "chevron.left", fallback: "‹", label: "Back")
        configure(forwardButton, symbol: "chevron.right", fallback: "›", label: "Forward")
        backButton.target = self
        backButton.action = #selector(backClicked)
        forwardButton.target = self
        forwardButton.action = #selector(forwardClicked)
        addSubview(backButton)
        addSubview(forwardButton)

        ellipsis.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        ellipsis.textColor = .secondaryLabelColor
        ellipsis.isHidden = true
        addSubview(ellipsis)

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

    /// The crumbs that actually fit, most recent last. Everything before the
    /// first of these is behind the ellipsis.
    public var visibleCrumbTitles: [String] {
        crumbButtons.filter { !$0.isHidden }.map(\.title)
    }

    private func setCrumbs(_ crumbs: [Navigator.Crumb]) {
        self.crumbs = crumbs
        // Reuse buttons rather than rebuilding: a breadcrumb changes on every
        // navigation, and discarding views on each one churns the responder
        // chain and the accessibility tree for no reason.
        while crumbButtons.count < crumbs.count {
            let button = NSButton()
            configure(button, symbol: nil, fallback: "", label: nil)
            button.target = self
            button.action = #selector(crumbClicked(_:))
            button.tag = crumbButtons.count
            addSubview(button)
            crumbButtons.append(button)

            let separator = NSTextField(labelWithString: "›")
            separator.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            separator.textColor = .tertiaryLabelColor
            addSubview(separator)
            separators.append(separator)
        }
        for (index, button) in crumbButtons.enumerated() {
            if index < crumbs.count {
                button.title = crumbs[index].name
                button.toolTip = crumbs[index].url.path
                button.setAccessibilityLabel(crumbs[index].name)
                // The last crumb is where you already are; it stays clickable
                // (clicking it is a no-op the Navigator swallows) but is drawn
                // as the current location rather than as a link.
                button.contentTintColor = index == crumbs.count - 1 ? .labelColor : .secondaryLabelColor
            } else {
                button.title = ""
            }
        }
        needsLayout = true
    }

    // MARK: - Layout

    public override func layout() {
        let inset: CGFloat = 6
        let arrowWidth: CGFloat = 20
        var x = inset
        backButton.frame = NSRect(x: x, y: 0, width: arrowWidth, height: bounds.height)
        x += arrowWidth
        forwardButton.frame = NSRect(x: x, y: 0, width: arrowWidth, height: bounds.height)
        x += arrowWidth + 4

        let available = max(0, bounds.width - x - inset)

        // Widths first, so the truncation decision is made before anything is
        // positioned. Dropping from the front is what keeps the *current*
        // directory visible, which is the only crumb that is always wanted.
        var widths: [CGFloat] = []
        for (index, button) in crumbButtons.enumerated() where index < crumbs.count {
            widths.append(min(140, ceil(button.intrinsicContentSize.width) + 8))
        }
        let separatorWidth: CGFloat = 12
        var first = 0
        func total(from start: Int) -> CGFloat {
            var sum: CGFloat = start > 0 ? separatorWidth : 0  // the ellipsis
            for index in start..<widths.count {
                sum += widths[index]
                if index > start { sum += separatorWidth }
            }
            return sum
        }
        while first < widths.count - 1 && total(from: first) > available {
            first += 1
        }

        ellipsis.isHidden = first == 0
        if first > 0 {
            ellipsis.frame = NSRect(x: x, y: 0, width: separatorWidth, height: bounds.height)
            x += separatorWidth
        }

        for index in 0..<crumbButtons.count {
            let button = crumbButtons[index]
            let separator = separators[index]
            guard index < crumbs.count, index >= first else {
                button.isHidden = true
                separator.isHidden = true
                continue
            }
            if index > first {
                separator.isHidden = false
                separator.frame = NSRect(x: x, y: 0, width: separatorWidth, height: bounds.height)
                x += separatorWidth
            } else {
                separator.isHidden = true
            }
            button.isHidden = false
            button.frame = NSRect(x: x, y: 0, width: widths[index], height: bounds.height)
            x += widths[index]
        }
        super.layout()
    }

    /// A hairline under the bar, and nothing else — the sidebar's material
    /// shows through from ``SidebarContainerView``'s backing view.
    public override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Actions

    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard crumbs.indices.contains(sender.tag) else { return }
        onSelect?(crumbs[sender.tag].url)
    }

    private func configure(_ button: NSButton, symbol: String?, fallback: String, label: String?) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.lineBreakMode = .byTruncatingMiddle
        button.title = fallback
        if let symbol,
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        {
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        }
        if let label { button.setAccessibilityLabel(label) }
    }
}
