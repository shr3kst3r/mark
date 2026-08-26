import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The Theme submenu — M7's catalogue as something you can point at.
///
/// The theme *mechanism* is covered by `ThemeTests`; what is asserted here is
/// the selector on top of it: that every theme is listed, that the list is
/// rebuilt rather than frozen at launch, that a pair reads as a pair, and that
/// clicking an item goes through the same entry point `mark theme <name>` does.
@Suite("Theme menu — M7")
@MainActor
struct ThemeMenuTests {

    /// The shared controller is app-wide state, and these tests move it. Each
    /// one puts it back.
    private func withTheme(_ body: () async throws -> Void) async rethrows {
        let previous = ThemeController.shared.chosenName
        let appearance = ThemeController.shared.appearance
        defer { _ = try? ThemeController.shared.apply(named: previous, appearance: appearance) }
        try await body()
    }

    private static func summary(
        _ name: String, _ title: String, _ kind: ThemeKind, pair: String? = nil,
        author: String? = nil, source: ThemeSource = .builtin
    ) -> ThemeSummary {
        ThemeSummary(
            name: name, title: title, kind: kind, pair: pair, author: author, source: source)
    }

    /// Two pairs and one single, which is the shape of the real catalogue.
    private static let fixture = ThemeCatalog(
        themes: [
            summary("blue-dark", "Blue Dark", .dark, pair: "blue-light"),
            summary("blue-light", "Blue Light", .light, pair: "blue-dark"),
            summary("amber-dark", "Amber Dark", .dark, pair: "amber-light"),
            summary("amber-light", "Amber Light", .light, pair: "amber-dark"),
            summary("mono", "Mono", .dark),
        ],
        default: "blue-dark",
        dir: "/tmp/mark-themes-fixture",
        problems: []
    )

    /// Every item that stands for a theme, in menu order.
    private func themeItems(of menu: ThemeMenu) -> [NSMenuItem] {
        menu.items.filter { $0.representedObject is String && $0.action != nil }
            .filter { $0.action == #selector(MainWindowController.chooseTheme(_:)) }
    }

    // MARK: - The list

    @Test("every shipped theme is in the menu, under a Dark and a Light heading")
    func listsTheCatalog() throws {
        let catalog = try MarkCore.themes()
        let menu = ThemeMenu()

        let items = themeItems(of: menu)
        #expect(
            items.count == catalog.themes.count,
            "\(items.count) items for \(catalog.themes.count) themes")
        let listed = Set(items.compactMap { $0.representedObject as? String })
        #expect(listed == Set(catalog.themes.map(\.name)))

        let headers = menu.items.filter(\.isSectionHeader).map(\.title)
        #expect(headers == ["Dark", "Light"])

        // The headings have to mean something: everything between "Dark" and
        // "Light" is dark, and everything after "Light" is light.
        let kinds = Dictionary(uniqueKeysWithValues: catalog.themes.map { ($0.name, $0.kind) })
        var current: ThemeKind?
        for item in menu.items {
            if item.isSectionHeader { current = item.title == "Dark" ? .dark : .light }
            guard let name = item.representedObject as? String, let kind = kinds[name] else {
                continue
            }
            #expect(
                kind == current,
                "\(name) is \(kind) but sits under \(current.map(String.init(describing:)) ?? "nothing")")
        }
    }

    @Test("the menu is rebuilt when it opens, so a new theme file needs no relaunch")
    func rebuildsOnOpen() {
        // M7's promise is that a TOML dropped into `~/.config/mark/themes` is
        // picked up without a rebuild. A menu built once at launch would keep
        // that promise for the renderer and break it for the menu bar.
        var catalog = Self.fixture
        let menu = ThemeMenu { catalog }
        #expect(themeItems(of: menu).count == 5)

        catalog = ThemeCatalog(
            themes: Self.fixture.themes
                + [Self.summary("mine", "Mine", .dark, source: .user(path: "/tmp/mine.toml"))],
            default: Self.fixture.default, dir: Self.fixture.dir, problems: [])
        menu.menuNeedsUpdate(menu)

        let names = themeItems(of: menu).compactMap { $0.representedObject as? String }
        #expect(names.contains("mine"), "a theme added since launch is missing: \(names)")
    }

    @Test("a catalogue that cannot be read says so instead of looking empty")
    func unavailableCatalog() {
        let menu = ThemeMenu { nil }
        #expect(themeItems(of: menu).isEmpty)
        #expect(menu.items.contains { $0.title.contains("No themes") })
    }

    // MARK: - What is checked

    private func states(of menu: ThemeMenu) -> [String: NSControl.StateValue] {
        Dictionary(
            uniqueKeysWithValues: themeItems(of: menu).map {
                ($0.representedObject as! String, $0.state)
            })
    }

    @Test("the theme you chose is checked, and its partner is not")
    func chosenHalfIsChecked() async throws {
        try await withTheme {
            // Choosing a half pins it, so the other one is not in play and is
            // not marked. A dash here would put back the ambiguity the pin
            // removes: "I chose the light one and it is dark".
            try ThemeController.shared.apply(named: "gruvbox-light")
            let states = states(of: ThemeMenu())
            #expect(states["gruvbox-light"] == .on)
            #expect(states["gruvbox-dark"] == .off)
            #expect(states["nord"] == .off)
            #expect(states.values.filter { $0 != .off }.isEmpty == false)
            #expect(states.values.filter { $0 == .on }.count == 1)
            #expect(states.values.allSatisfy { $0 != .mixed }, "a pinned pair dashed its partner")
        }
    }

    @Test("while following the system, the half in force is checked and its partner is dashed")
    func pairIsVisible() async throws {
        try await withTheme {
            // Both halves are live here — the page picks with
            // `prefers-color-scheme` — so a menu that marked only one would
            // hide half of what is installed.
            try ThemeController.shared.apply(named: "gruvbox-dark", appearance: .system)
            let states = states(of: ThemeMenu())
            let dark = NSApplication.shared.effectiveAppearance.isDark
            #expect(states[dark ? "gruvbox-dark" : "gruvbox-light"] == .on)
            #expect(states[dark ? "gruvbox-light" : "gruvbox-dark"] == .mixed)
            #expect(states["nord"] == .off)
            #expect(states.values.filter { $0 == .on }.count == 1)
        }
    }

    // MARK: - Which half

    @Test("Match System Appearance is the first item, and says which mode you are in")
    func matchSystemItem() async throws {
        try await withTheme {
            try ThemeController.shared.apply(named: "solarized-light")
            let pinned = ThemeMenu()
            let item = try #require(pinned.items.first)
            #expect(item.title == "Match System Appearance")
            #expect(item.action == #selector(MainWindowController.matchSystemAppearance(_:)))
            #expect(item.state == .off, "a pinned theme is not following the system")
            // It is not a theme, so it does not sit inside the catalogue.
            #expect(pinned.items[1].isSeparatorItem)

            ThemeController.shared.matchSystemAppearance()
            #expect(ThemeMenu().items.first?.state == .on)
        }
    }

    @Test("choosing a theme from the menu shows that theme, not the system's half")
    func choosingPinsTheHalf() async throws {
        try await withTheme {
            let fixture = try TabFixture()
            let controller = MainWindowController(root: fixture.directory, session: fixture.session)
            defer { controller.tabs.closeAll() }
            ThemeController.shared.matchSystemAppearance()

            let menu = ThemeMenu()
            let item = try #require(
                themeItems(of: menu).first { $0.representedObject as? String == "solarized-light" })
            controller.chooseTheme(item)

            let deadline = ContinuousClock.now + .seconds(5)
            while ThemeController.shared.name != "solarized-light", ContinuousClock.now < deadline {
                try? await _Concurrency.Task.sleep(for: .milliseconds(10))
            }
            #expect(ThemeController.shared.visibleHalf.name == "solarized-light")
            #expect(ThemeController.shared.appearance == .light)
            #expect(controller.sessionSnapshot().themeAppearance == "light")
        }
    }

    @Test("an unpaired theme is checked alone — it is both appearances by itself")
    func unpairedIsCheckedAlone() async throws {
        try await withTheme {
            try ThemeController.shared.apply(named: "dracula", appearance: .system)
            let menu = ThemeMenu()
            let states = themeItems(of: menu).map { ($0.representedObject as! String, $0.state) }
            #expect(states.filter { $0.1 == .on }.map(\.0) == ["dracula"])
            #expect(
                states.allSatisfy { $0.1 != .mixed }, "an unpaired theme has no partner to dash")
        }
    }

    @Test("the default theme's half is checked when nothing has been chosen")
    func defaultIsChecked() async throws {
        try await withTheme {
            // Nobody chose this one, so it follows the system — and what is
            // checked is the half that is on screen because of that.
            try ThemeController.shared.apply(named: nil)
            #expect(ThemeController.shared.appearance == .system)
            let expected = ThemeController.shared.visibleHalf.name
            let menu = ThemeMenu()
            let checked = themeItems(of: menu).filter { $0.state == .on }
                .compactMap { $0.representedObject as? String }
            #expect(checked == [expected])
        }
    }

    // MARK: - What an item carries

    @Test("the tooltip names the theme the way the CLI does, and says where it came from")
    func tooltips() {
        let paired = ThemeMenu.tooltip(
            for: Self.summary(
                "blue-dark", "Blue Dark", .dark, pair: "blue-light", author: "Someone"))
        #expect(paired.contains("mark theme blue-dark"))
        #expect(paired.contains("Pairs with blue-light"))
        #expect(paired.contains("By Someone."))

        let single = ThemeMenu.tooltip(for: Self.summary("mono", "Mono", .dark))
        #expect(single.contains("both light and dark"))

        // The one question a list of titles cannot answer: which file is this,
        // and is it shadowing a built-in of the same name?
        let mine = ThemeMenu.tooltip(
            for: Self.summary("nord", "Nord", .dark, source: .user(path: "/tmp/themes/nord.toml")))
        #expect(mine.contains("/tmp/themes/nord.toml"))
    }

    @Test("the themes folder is one click away")
    func revealsTheFolder() {
        let menu = ThemeMenu { Self.fixture }
        let reveal = menu.items.first { $0.title.contains("Reveal Themes Folder") }
        #expect(reveal?.representedObject as? String == Self.fixture.dir)
    }

    // MARK: - Files that would not load

    @Test("a theme file that will not parse is reported in the menu, not dropped")
    func problemsAreReported() {
        let broken = ThemeCatalog(
            themes: Self.fixture.themes, default: "blue-dark", dir: Self.fixture.dir,
            problems: ["/tmp/themes/oops.toml: missing base0D"])
        let menu = ThemeMenu { broken }
        #expect(menu.items.contains { $0.title == "1 Theme File Did Not Load…" })
        #expect(menu.problems == broken.problems)

        let clean = ThemeMenu { Self.fixture }
        #expect(!clean.items.contains { $0.title.contains("Did Not Load") })
        #expect(clean.problems.isEmpty)
    }

    // MARK: - Choosing one

    @Test("choosing a theme applies it to the window")
    func choosingApplies() async throws {
        try await withTheme {
            let fixture = try TabFixture()
            let controller = MainWindowController(root: fixture.directory, session: fixture.session)
            defer { controller.tabs.closeAll() }
            try ThemeController.shared.apply(named: "nord")

            let menu = ThemeMenu()
            let item = try #require(
                themeItems(of: menu).first { $0.representedObject as? String == "solarized-light" })
            // The window controller is what the responder chain reaches; the
            // menu only carries the name.
            #expect(controller.responds(to: item.action))
            controller.chooseTheme(item)

            let deadline = ContinuousClock.now + .seconds(5)
            while ThemeController.shared.name != "solarized-light", ContinuousClock.now < deadline {
                try? await _Concurrency.Task.sleep(for: .milliseconds(10))
            }
            #expect(ThemeController.shared.name == "solarized-light")
            // It went through `applyTheme(named:)`, so it is session state too.
            #expect(controller.sessionSnapshot().theme == "solarized-light")
        }
    }

    @Test("an item with no name does nothing at all")
    func ignoresAnItemWithNoName() async throws {
        try await withTheme {
            let fixture = try TabFixture()
            let controller = MainWindowController(root: fixture.directory, session: fixture.session)
            defer { controller.tabs.closeAll() }
            try ThemeController.shared.apply(named: "nord")
            controller.chooseTheme(NSMenuItem())
            try? await _Concurrency.Task.sleep(for: .milliseconds(50))
            #expect(ThemeController.shared.name == "nord")
        }
    }
}
