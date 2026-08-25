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
        defer { _ = try? ThemeController.shared.apply(named: previous) }
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

    @Test("the half in force is checked and the other half of its pair is dashed")
    func pairIsVisible() async throws {
        try await withTheme {
            // Choosing either half installs both — the page picks with
            // `prefers-color-scheme`. A menu that checked only the name that
            // was clicked would make that look like a bug.
            try ThemeController.shared.apply(named: "gruvbox-dark")
            let menu = ThemeMenu()
            let states = Dictionary(
                uniqueKeysWithValues: themeItems(of: menu).map {
                    ($0.representedObject as! String, $0.state)
                })
            #expect(states["gruvbox-dark"] == .on)
            #expect(states["gruvbox-light"] == .mixed)
            #expect(states["nord"] == .off)
            #expect(states.values.filter { $0 == .on }.count == 1)
        }
    }

    @Test("an unpaired theme is checked alone — it is both appearances by itself")
    func unpairedIsCheckedAlone() async throws {
        try await withTheme {
            try ThemeController.shared.apply(named: "dracula")
            let menu = ThemeMenu()
            let states = themeItems(of: menu).map { ($0.representedObject as! String, $0.state) }
            #expect(states.filter { $0.1 == .on }.map(\.0) == ["dracula"])
            #expect(
                states.allSatisfy { $0.1 != .mixed }, "an unpaired theme has no partner to dash")
        }
    }

    @Test("the default theme is checked when nothing has been chosen")
    func defaultIsChecked() async throws {
        try await withTheme {
            try ThemeController.shared.apply(named: nil)
            let catalog = try MarkCore.themes()
            let menu = ThemeMenu()
            let checked = themeItems(of: menu).filter { $0.state == .on }
                .compactMap { $0.representedObject as? String }
            #expect(checked == [catalog.default])
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
