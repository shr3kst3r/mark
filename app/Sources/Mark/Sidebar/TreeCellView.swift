import AppKit
import Foundation

/// One sidebar row: icon, name, and up to two badges on the right —
/// `weekly.md   +12 −3   3/7`.
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
/// * **Changes come first, then tasks.** The order is
///   `2026-08-28-git-badges-ride-the-sidebar-poll`'s, and it is the order
///   `mark ls --git` prints too, so the two halves of the product read alike.
///   The two badges have different lifetimes — a task badge is per file and
///   arrives from a background read, a git badge is per *repository* and
///   arrives from a query that answered every row at once — so either can be
///   present without the other.
@MainActor
public final class TreeCellView: NSTableCellView {

    public static let identifier = NSUserInterfaceItemIdentifier("TreeCell")

    public let badgeLabel = NSTextField(labelWithString: "")

    /// The git badge. A separate field rather than one concatenated string
    /// because the two are coloured independently — additions are green whether
    /// or not any tasks are outstanding — and because a stack lets the name
    /// truncate against whatever is actually present.
    public let gitLabel = NSTextField(labelWithString: "")

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

        gitLabel.translatesAutoresizingMaskIntoConstraints = false
        gitLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        gitLabel.alignment = .right
        gitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        gitLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(gitLabel)

        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Changes, then tasks, then the edge. `greaterThanOrEqualTo` on the
            // name is what makes the name truncate rather than the badges: the
            // numbers are the fixed part of the row and the name is the elastic
            // one, which is the right way round when the badges are the reason
            // the row is being scanned.
            gitLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            gitLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: gitLabel.trailingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TreeCellView is created in code, not from a nib")
    }

    /// Draw `node`. Either badge is `nil` when it has not been computed yet,
    /// which is the normal state for a row that has just scrolled into view.
    public func configure(with node: TreeNode, badge: TaskBadge?, git: GitBadge? = nil) {
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
            // Dimmed once nothing is outstanding — which now includes a file
            // whose remaining items were all cancelled rather than done.
            badgeLabel.textColor =
                (badge?.outstanding ?? 0) > 0 ? .secondaryLabelColor : .tertiaryLabelColor
        } else {
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
        }

        if let label = git?.label {
            gitLabel.stringValue = label
            gitLabel.isHidden = false
            // Additions green, deletions red — the same `success` / `error`
            // theme slots the rendered diff uses, so green means the same thing
            // in the sidebar as it does in the document. A row with no countable
            // lines (a binary) shows its status word in the muted colour
            // instead, because `+0 −0` would be a lie.
            gitLabel.textColor =
                (git?.added != nil) ? Self.additionColor : .tertiaryLabelColor
        } else {
            gitLabel.stringValue = ""
            gitLabel.isHidden = true
        }

        // **No `toolTip` here.** Setting `NSView.toolTip` registers a tooltip
        // rectangle with the window and makes it rebuild its tracking areas,
        // per cell, on every configure — which showed up in `mark-bench` as
        // milliseconds per row on a path that runs for every visible row on
        // every reload. The same text is supplied on demand by
        // ``TreeViewController``'s `outlineView(_:toolTipFor:…)`.
        setAccessibilityLabel(Self.accessibilityLabel(for: node, badge: badge, git: git))
    }

    /// The colour additions are drawn in.
    ///
    /// `systemGreen` rather than the document theme's `success` slot: the
    /// sidebar is AppKit chrome and follows the *system* appearance, while the
    /// theme belongs to the rendered page and can be pinned per window
    /// (`ThemeController`). A row tinted with the document's theme would change
    /// colour when the reader switched a tab's theme, which is not what the row
    /// is about.
    static let additionColor = NSColor.systemGreen

    /// What VoiceOver reads. The badge is part of the label rather than a
    /// separate element: `3/7` on its own is meaningless, and a screen-reader
    /// user should not have to navigate into a row to find out a file has open
    /// tasks in it.
    static func accessibilityLabel(
        for node: TreeNode, badge: TaskBadge?, git: GitBadge? = nil
    ) -> String {
        var parts = [node.name]
        if node.isDirectory {
            parts.append("folder")
        } else if !node.isMarkdown {
            parts.append("not a markdown file")
        }
        // "outstanding", not "open", because open is now one of five states and
        // in-progress and blocked are also still to do
        // (`2026-08-27-five-task-states`). Cancelled items are not counted at
        // all, in either number, which is what the badge shows.
        if let badge, badge.active > 0 {
            parts.append("\(badge.outstanding) of \(badge.active) tasks outstanding")
        }
        if let badge, badge.counts.cancelled > 0 {
            parts.append(
                "\(badge.counts.cancelled) cancelled")
        }
        // One phrase rather than a separate element, on the same grounds the
        // task counts are: "+12 −3" read on its own is meaningless, and a
        // screen-reader user should not have to navigate into a row to learn
        // that a file has uncommitted work in it.
        if let git {
            switch (git.added, git.removed) {
            case let (added?, removed?):
                parts.append("\(added) lines added, \(removed) removed since the last commit")
            default:
                parts.append("\(git.status.label) since the last commit")
            }
        }
        return parts.joined(separator: ", ")
    }
}
