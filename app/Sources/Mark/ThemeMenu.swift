import AppKit
import Foundation

/// The Theme submenu: M7's catalogue, as something you can point at.
///
/// Everything under it already existed — ``ThemeController`` resolves a name,
/// ``MainWindowController/applyTheme(named:appearance:)`` pushes it at every
/// tab, and the session file remembers it. What was missing was a way to
/// choose one without typing `mark theme <name>` in a terminal, which is a
/// strange thing to have to do to change the colour of a window that is
/// already open.
///
/// # Why it is rebuilt every time it opens
///
/// M7's promise is that *"a user TOML in `~/.config/mark/themes` loads without
/// a rebuild"*. A menu built once at launch would keep that promise for the
/// renderer and quietly break it for the menu bar: the file would work, and be
/// unlistable. So the items come from ``ThemeController/catalog()`` in
/// `menuNeedsUpdate:`, which is the moment before the menu is drawn and the
/// only moment the answer has to be right.
///
/// That is also why ``menuHasKeyEquivalent(_:for:target:action:)`` is
/// implemented and answers `false`. No theme has a key equivalent, but AppKit
/// does not know that: while matching a keystroke it walks the menu bar, and a
/// delegate that does not answer this question gets `menuNeedsUpdate:` instead
/// — which would re-read and re-parse every theme file on disk on the way to
/// ⌘S.
///
/// # What the items say
///
/// A pair is one theme with two halves (`gruvbox-dark` / `gruvbox-light`), and
/// choosing either half installs *both*. Which of them you are looking at is
/// the first item, **Match System Appearance**:
///
/// * Off — the normal case, because choosing a theme by name pins it — the half
///   you chose is checked and nothing else is marked. You asked for the light
///   one and you have the light one, in a dark-mode system too.
/// * On, and the page follows macOS. The half in force is checked and its
///   partner is dashed (`.mixed`): both are in play, one of them right now.
///
/// The dash is therefore never the answer to "why is my light theme dark" — it
/// only appears once you have asked for both halves to be live.
@MainActor
public final class ThemeMenu: NSMenu, NSMenuDelegate {

    /// Where the list comes from.
    ///
    /// Injected so a test can drive the unparseable-file and no-catalogue cases
    /// without writing into the developer's own `~/.config/mark/themes`.
    private let source: () -> ThemeCatalog?

    /// The parse failures from the most recent rebuild, in the order the core
    /// reported them. Kept because the alert needs them after the menu has
    /// closed and the items are gone.
    public private(set) var problems: [String] = []

    /// - Parameter source: the catalogue to list. The default is the real one.
    ///   It is a parameter rather than an `init()` override because
    ///   `NSMenu.init()` is `nonisolated` and this class is `@MainActor`, the
    ///   same reason ``WindowMenu/init(positions:)`` takes one.
    @MainActor
    public init(source: @escaping () -> ThemeCatalog? = { ThemeController.shared.catalog() }) {
        self.source = source
        super.init(title: "Theme")
        delegate = self
        rebuild()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ThemeMenu is created in code, not from a nib")
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// Nothing in here has a key equivalent. Saying so keeps the theme
    /// catalogue off the keystroke path — see the type's documentation.
    public func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }

    // MARK: - Building

    /// Re-read the catalogue and rebuild every item.
    public func rebuild() {
        removeAllItems()

        guard let catalog = source() else {
            // `catalog()` has already logged why. An empty menu would read as
            // "this app has no themes"; this reads as "something went wrong",
            // which is what happened.
            addItem(disabled: "No themes could be listed")
            problems = []
            return
        }
        problems = catalog.problems

        let controller = ThemeController.shared
        let active = controller.active
        let following = controller.appearance == .system
        // The half on screen — which is the one the user named, unless they
        // have asked to follow macOS and macOS disagrees.
        let showing = controller.visibleHalf.name
        // The other half of the pair, dashed to say "also installed, not on
        // screen". Only while following the system: under a pin the partner is
        // not in play at all, and marking it would put back the very ambiguity
        // pinning removed. An unpaired theme like `dracula` never has one.
        let partner: String? =
            following && active.paired
            ? (showing == active.dark.name ? active.light.name : active.dark.name) : nil

        addItem(matchSystem(checked: following))
        addItem(.separator())

        for kind in [ThemeKind.dark, ThemeKind.light] {
            let themes = catalog.themes.filter { $0.kind == kind }.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            guard !themes.isEmpty else { continue }
            addItem(.sectionHeader(title: kind == .dark ? "Dark" : "Light"))
            for theme in themes {
                addItem(item(for: theme, active: showing, partner: partner))
            }
        }

        // Only if there is something under it: a menu ending in a rule is a
        // menu that looks like it lost its last item.
        if (catalog.dir != nil || !problems.isEmpty) && numberOfItems > 0 {
            addItem(.separator())
        }

        // The catalogue knows where user themes live, and a folder nobody can
        // find is a feature nobody uses.
        if let dir = catalog.dir {
            let reveal = addItem(
                withTitle: "Reveal Themes Folder in Finder",
                action: #selector(revealThemesFolder(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = dir
        }

        // A user file that will not parse is *reported*. The core keeps it out
        // of the list rather than pretending it is fine, and dropping it here
        // too would put the app right back in the failure M7 is built around:
        // a theme that silently vanishes.
        if !problems.isEmpty {
            let title =
                problems.count == 1
                ? "1 Theme File Did Not Load…" : "\(problems.count) Theme Files Did Not Load…"
            let item = addItem(
                withTitle: title, action: #selector(showProblems(_:)), keyEquivalent: "")
            item.target = self
        }
    }

    /// The way back from a pin: keep the theme, let macOS pick the half.
    ///
    /// First, above the catalogue, because it is the setting the items below it
    /// are read against — and separated from them because it is not a theme.
    private func matchSystem(checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Match System Appearance",
            action: #selector(MainWindowController.matchSystemAppearance(_:)), keyEquivalent: "")
        item.state = checked ? .on : .off
        item.toolTip =
            "Follow macOS between light and dark.\nChoosing a theme below pins the half it names."
        return item
    }

    /// One theme.
    ///
    /// The name travels in `representedObject` rather than in `tag`: the
    /// catalogue is not a fixed list — a file dropped into
    /// `~/.config/mark/themes` joins it between one opening of the menu and the
    /// next — so there is no stable index to encode.
    private func item(for theme: ThemeSummary, active: String, partner: String?) -> NSMenuItem {
        let item = NSMenuItem(
            title: theme.title, action: #selector(MainWindowController.chooseTheme(_:)),
            keyEquivalent: "")
        item.representedObject = theme.name
        item.state = theme.name == active ? .on : (theme.name == partner ? .mixed : .off)
        item.toolTip = Self.tooltip(for: theme)
        return item
    }

    /// What the menu cannot show without becoming a table: the name the CLI
    /// uses, the other half of the pair, and — for a user theme — the file it
    /// came from, which is the answer to "why is my edit not showing up".
    static func tooltip(for theme: ThemeSummary) -> String {
        var lines = ["mark theme \(theme.name)"]
        if let pair = theme.pair {
            lines.append("Pairs with \(pair) in the other appearance.")
        } else {
            lines.append("Used for both light and dark appearances.")
        }
        if let author = theme.author {
            lines.append("By \(author).")
        }
        if case .user(let path) = theme.source {
            lines.append("From \(path)")
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    private func addItem(disabled title: String) -> NSMenuItem {
        let item = addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions this menu owns itself

    /// Both of these are about the *menu*, not about the window, so they are
    /// targeted at this object rather than sent down the responder chain the
    /// way ``MainWindowController/chooseTheme(_:)`` is.
    @objc private func revealThemesFolder(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        // Created on demand. The directory does not exist until someone puts a
        // theme in it, and revealing a folder that is not there does nothing at
        // all — which would read as a dead menu item rather than as an empty
        // folder.
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true)
            } catch {
                Log.app.error(
                    "could not create \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                NSSound.beep()
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func showProblems(_ sender: Any?) {
        guard !problems.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            problems.count == 1
            ? "One theme file did not load." : "\(problems.count) theme files did not load."
        alert.informativeText = problems.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
