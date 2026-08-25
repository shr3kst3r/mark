import AppKit
import Foundation

/// One sidebar row: icon, name, and — for markdown files with tasks — a `3/7`
/// badge on the right.
///
/// Two things the row has to say that M2's plain `NSTableCellView` could not:
///
/// * **Non-markdown files are dimmed and not openable.** Plan §2 M8 wants them
///   visible *"so a folder does not look empty when it holds a `.png` and a
///   `.md`"*, but `mark` cannot render them, and a row that looks openable and
///   then does nothing is worse than one that never looked openable.
/// * **The badge is the *sidebar's* count, not the tab bar's.** It comes from
///   ``TaskBadgeService``, which reads the file in the background, so a row
///   draws with no badge and gains one a frame or two later. That is the
///   progressive behaviour plan §2 M8 requires; a row that waited for its badge
///   would put a file read on the draw path.
@MainActor
public final class TreeCellView: NSTableCellView {

    public static let identifier = NSUserInterfaceItemIdentifier("TreeCell")

    public let badgeLabel = NSTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.identifier = TreeCellView.identifier

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
        imageView = image

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingMiddle
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        addSubview(text)
        textField = text

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .right
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TreeCellView is created in code, not from a nib")
    }

    /// Draw `node`. `badge` is `nil` when it has not been computed yet, which
    /// is the normal state for a row that has just scrolled into view.
    public func configure(with node: TreeNode, badge: TaskBadge?) {
        textField?.stringValue = node.name
        // By kind, from ``SidebarIcons``' cache, not by path: a per-path
        // LaunchServices lookup on every row is where 414 ms of a 608k-file
        // tree's root move went (measured — see that type's documentation).
        imageView?.image = SidebarIcons.icon(for: node)

        let openable = node.isDirectory || node.isMarkdown
        textField?.textColor = openable ? .labelColor : .tertiaryLabelColor
        imageView?.alphaValue = openable ? 1.0 : 0.45

        if let label = badge?.label {
            badgeLabel.stringValue = label
            badgeLabel.isHidden = false
            badgeLabel.textColor = (badge?.open ?? 0) > 0 ? .secondaryLabelColor : .tertiaryLabelColor
        } else {
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
        }

        // **No `toolTip` here.** Setting `NSView.toolTip` registers a tooltip
        // rectangle with the window and makes it rebuild its tracking areas,
        // per cell, on every configure — which showed up in `mark-bench` as
        // milliseconds per row on a path that runs for every visible row on
        // every reload. The same text is supplied on demand by
        // ``TreeViewController``'s `outlineView(_:toolTipFor:…)`.
        setAccessibilityLabel(Self.accessibilityLabel(for: node, badge: badge))
    }

    /// What VoiceOver reads. The badge is part of the label rather than a
    /// separate element: `3/7` on its own is meaningless, and a screen-reader
    /// user should not have to navigate into a row to find out a file has open
    /// tasks in it.
    static func accessibilityLabel(for node: TreeNode, badge: TaskBadge?) -> String {
        var parts = [node.name]
        if node.isDirectory {
            parts.append("folder")
        } else if !node.isMarkdown {
            parts.append("not a markdown file")
        }
        if let badge, badge.total > 0 {
            parts.append("\(badge.open) of \(badge.total) tasks open")
        }
        return parts.joined(separator: ", ")
    }
}
