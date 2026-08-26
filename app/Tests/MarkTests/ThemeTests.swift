import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// M7's gates, on the Swift side.
///
/// The two that need a real `WKWebView` running the shipped `shell.js` are here
/// rather than in the core, because what is being asserted is what the *page*
/// resolves — a Swift-side model of "we set a variable" would agree with itself
/// and prove nothing. The colours are read back out of `getComputedStyle`.
///
/// The appearance-switch gate proper (nothing runs, the colours change anyway)
/// needs a window on screen to be honest about compositing, so it lives in
/// `mark-bench`. What is asserted here is the half that does not: that a theme
/// change re-renders nothing, and that it reaches a dehydrated tab.
@Suite("Themes — M7")
@MainActor
struct ThemeTests {

    /// The shared controller is app-wide state — and now so is
    /// `NSApplication.appearance`, which is how a pinned half reaches the page.
    /// Each test puts both back.
    private func withTheme(_ body: () async throws -> Void) async rethrows {
        let name = ThemeController.shared.chosenName
        let appearance = ThemeController.shared.appearance
        defer { _ = try? ThemeController.shared.apply(named: name, appearance: appearance) }
        try await body()
    }

    /// A document with everything a theme touches in it.
    static let source = """
        # Themed

        Prose with a [link](https://example.com) and `inline code`.

        ```rust
        fn main() { let x: u32 = 1; }
        ```

        - [ ] a task
        """

    // MARK: - The core's answers

    @Test("the shipped themes list, and every one of them resolves")
    func catalog() throws {
        let catalog = try MarkCore.themes()
        #expect(catalog.themes.count >= 16, "only \(catalog.themes.count) themes")
        #expect(catalog.default == "default-dark")
        #expect(catalog.problems.isEmpty, "\(catalog.problems)")
        #expect(catalog.dir?.hasSuffix("/mark/themes") == true, "\(catalog.dir ?? "nil")")
        for summary in catalog.themes {
            let resolved = try MarkCore.theme(named: summary.name)
            #expect(resolved.name == summary.name)
            #expect(!resolved.css.isEmpty)
        }
    }

    @Test("a paired theme carries both appearances; an unpaired one is used for both")
    func pairing() throws {
        let paired = try MarkCore.theme(named: "gruvbox-dark")
        #expect(paired.paired)
        #expect(paired.light.name == "gruvbox-light")
        #expect(paired.dark.name == "gruvbox-dark")
        #expect(paired.css.contains("@media (prefers-color-scheme: dark)"))
        #expect(paired.light.color(of: "background") != paired.dark.color(of: "background"))

        let single = try MarkCore.theme(named: "dracula")
        #expect(!single.paired)
        #expect(single.light.name == "dracula")
        // One theme for both appearances needs no media query at all.
        #expect(!single.css.contains("prefers-color-scheme"))
    }

    @Test("a theme that does not exist is a named error, not a silent default")
    func unknownTheme() {
        #expect(throws: CoreError.self) { try MarkCore.theme(named: "no-such-theme") }
        do {
            _ = try MarkCore.theme(named: "no-such-theme")
        } catch let error as CoreError {
            #expect(error.detail?.contains("no theme named \"no-such-theme\"") == true)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - The stylesheet and the core agree

    /// `shell.css` and `core/src/render.rs` are two hand-written copies of the
    /// same colour contract — the app loads one, `mark render --html` inlines
    /// the other. Nothing makes them agree except this.
    @Test("every variable shell.css uses is one a theme defines")
    func stylesheetVariablesExist() throws {
        let css = try #require(ShellAssets.data(named: "shell.css")).utf8String
        let theme = try MarkCore.theme(named: "default-dark")

        var used: Set<String> = []
        var scanner = css[...]
        while let at = scanner.range(of: "var(--mk-") {
            let rest = scanner[at.upperBound...]
            guard let close = rest.firstIndex(where: { $0 == ")" || $0 == "," }) else { break }
            used.insert("--mk-" + rest[..<close])
            scanner = rest[close...]
        }
        #expect(used.count > 10, "found only \(used.count) variables in shell.css")

        for name in used.sorted() {
            // `--mk-s10` … `--mk-s17` are base24's extra eight. shell.css has
            // rules for them so a *user* theme can use them; no shipped theme
            // defines any, and a `var()` with no value simply inherits.
            if name.hasPrefix("--mk-s1") { continue }
            #expect(
                theme.css.contains("\(name):"),
                "shell.css uses \(name), which no theme defines")
        }
    }

    @Test("the slot classes the core emits are the ones shell.css colours")
    func slotClassesMatch() throws {
        let css = try #require(ShellAssets.data(named: "shell.css")).utf8String
        let html = try MarkCore.renderHTML(source: Self.source)
        var emitted: Set<String> = []
        var scanner = html[...]
        while let at = scanner.range(of: "<span class=\"") {
            let rest = scanner[at.upperBound...]
            guard let close = rest.firstIndex(of: "\"") else { break }
            emitted.insert(String(rest[..<close]))
            scanner = rest[close...]
        }
        #expect(!emitted.isEmpty, "the render emitted no token spans")
        for name in emitted.sorted() {
            #expect(css.contains(".\(name) {"), "shell.css has no rule for .\(name)")
        }
        // And nothing inline, which is the property that makes it re-themable.
        #expect(!html.contains("style=\"color"), "an inline colour survived")
    }

    // MARK: - Applying a theme

    @Test("applying a theme installs CSS and re-renders nothing")
    func applyingDoesNotRerender() async throws {
        let harness = try await PatchHarness(Self.source)
        let before = try #require(await harness.view.stats())

        let dracula = try MarkCore.theme(named: "dracula")
        let report = try #require(await harness.view.applyTheme(dracula).value)
        #expect(report.applied)
        #expect(report.background.trimmingCharacters(in: .whitespaces) == "#282a36")

        let after = try #require(await harness.view.stats())
        #expect(after.documents == before.documents, "the document was re-injected")
        #expect(after.patches == before.patches, "the document was patched")
        #expect(after.themes == before.themes + 1)

        // The colours the page actually resolved, not the ones we sent.
        let colors = try await harness.view.call("return window.mark.resolvedColors(null);")
        let background = ((colors as? [String: Any])?["background"] as? String) ?? ""
        #expect(background.contains("40, 42, 54"), "resolved \(background)")
    }

    @Test("applying the same theme twice is a no-op the second time")
    func idempotent() async throws {
        let harness = try await PatchHarness(Self.source)
        let theme = try MarkCore.theme(named: "nord")
        let first = try #require(await harness.view.applyTheme(theme).value)
        let second = try #require(await harness.view.applyTheme(theme).value)
        #expect(first.applied)
        #expect(!second.applied, "the same CSS was installed twice")
    }

    /// **Gate 2.** `mark theme dracula` applies to every open tab, *including*
    /// dehydrated ones — which, precisely because they have no DOM, is a
    /// statement about what happens when they come back.
    @Test("a theme reaches every tab, and a dehydrated tab comes back themed")
    func everyTabIncludingDehydrated() async throws {
        try await withTheme {
            let fixture = try TabFixture()
            let controller = MainWindowController(root: fixture.directory, session: fixture.session)
            defer { controller.tabs.closeAll() }

            controller.open(fixture.file(named: "a.md"))
            controller.open(fixture.file(named: "b.md"))
            let dehydrated = try #require(controller.tabs.tab(for: fixture.file(named: "a.md")))
            controller.tabs.dehydrate(dehydrated)
            #expect(dehydrated.documentView == nil, "the tab is not dehydrated")
            let hydrated = try #require(controller.tabs.selected?.documentView)
            await hydrated.awaitReady()

            let summary = try await controller.applyTheme(named: "dracula")
            #expect(summary.name == "dracula")
            #expect(summary.applied == 1, "one tab is hydrated; the other has no DOM to update")

            let live = try #require(await hydrated.call("return window.mark.themeCSS();") as? String)
            #expect(live.contains("--mk-background:#282a36"), "the hydrated tab is not dracula")

            // The dehydrated tab: selecting it builds a new web view, which renders
            // against the theme the controller now holds. Nothing had to remember
            // to re-theme it, which is the point.
            controller.tabs.select(dehydrated)
            let rehydrated = try #require(dehydrated.documentView)
            await rehydrated.awaitReady()
            let restored = try #require(
                await rehydrated.call("return window.mark.themeCSS();") as? String)
            #expect(
                restored.contains("--mk-background:#282a36"),
                "a rehydrated tab came back in the old theme")
        }
    }

    @Test("a theme that will not resolve is refused and changes nothing")
    func refusedThemeChangesNothing() async throws {
        try await withTheme {
            let fixture = try TabFixture()
            let controller = MainWindowController(root: fixture.directory, session: fixture.session)
            defer { controller.tabs.closeAll() }
            controller.open(fixture.file(named: "a.md"))

            _ = try await controller.applyTheme(named: "nord")
            await #expect(throws: CommandFailure.self) {
                _ = try await controller.applyTheme(named: "no-such-theme")
            }
            #expect(ThemeController.shared.name == "nord", "a refused theme was applied anyway")
        }
    }

    @Test("the chosen theme reaches the session file and comes back")
    func sessionRoundTrip() async throws {
        try await withTheme {
            let fixture = try TabFixture()
            let controller = MainWindowController(root: fixture.directory, session: fixture.session)
            defer { controller.tabs.closeAll() }
            controller.open(fixture.file(named: "a.md"))
            _ = try await controller.applyTheme(named: "solarized-light")

            let state = controller.sessionSnapshot()
            #expect(state.theme == "solarized-light")
            // Which half, not just which pair: a relaunch that dropped this would
            // put the light theme back under a dark system, which is the whole
            // defect.
            #expect(state.themeAppearance == "light")

            _ = try await controller.applyTheme(named: "default-dark")
            controller.restore(state)
            #expect(ThemeController.shared.name == "solarized-light")
            #expect(ThemeController.shared.appearance == .light)

            // And the other way: following the system is a choice too, and it
            // survives the same trip.
            _ = try await controller.applyTheme(named: nil, appearance: .system)
            let following = controller.sessionSnapshot()
            #expect(following.themeAppearance == "system")
            _ = try await controller.applyTheme(named: "gruvbox-dark")
            controller.restore(following)
            #expect(ThemeController.shared.appearance == .system)

            // A session file from before there was anything to record: the theme
            // was named, so it comes back as the named half rather than at the
            // mercy of the system.
            var old = state
            old.themeAppearance = nil
            _ = try await controller.applyTheme(named: "default-dark")
            controller.restore(old)
            #expect(ThemeController.shared.appearance == .light)
        }
    }

    @Test("a session naming a theme that no longer exists falls back rather than failing")
    func brokenSessionTheme() throws {
        let previous = ThemeController.shared.name
        ThemeController.shared.restore(named: "a-theme-that-was-deleted")
        #expect(ThemeController.shared.name == previous, "a stale session name was applied")
    }

    // MARK: - Which half is on screen

    /// The defect: choosing a light theme on a Mac in dark mode left the window
    /// dark, because the CSS carried both halves and `prefers-color-scheme`
    /// picked the other one.
    ///
    /// Asserted from inside the page, and in *both* directions, so it says the
    /// same thing whatever appearance the machine running the tests is in.
    @Test("naming a theme shows that theme, whatever the system appearance is")
    func namingAThemePinsIt() async throws {
        try await withTheme {
            let harness = try await WindowedHarness(Self.source)

            for name in ["solarized-light", "solarized-dark"] {
                let theme = try ThemeController.shared.apply(named: name)
                _ = await harness.view.applyTheme(theme).value
                let wanted = name.hasSuffix("-dark")

                #expect(ThemeController.shared.visibleHalf.name == name)
                // WebKit resolves `prefers-color-scheme` against the web view's
                // effective appearance, which is what the pin sets. A page still
                // following the system is the defect itself.
                let dark = await harness.pageIsDark(waitingFor: wanted)
                #expect(dark == wanted, "\(name) resolved prefers-color-scheme: dark = \(dark)")

                // And the colours a reader actually sees, not the ones we sent.
                let half = wanted ? theme.dark : theme.light
                let background = try #require(half.document["background"]?.color)
                let resolved = try await harness.view.call(
                    "return window.mark.resolvedColors(null);")
                let painted = ((resolved as? [String: Any])?["background"] as? String) ?? ""
                #expect(
                    painted.contains(Self.rgb(background)),
                    "\(name) painted \(painted), not \(background)")
            }
        }
    }

    /// The way back, and the reason pinning costs nobody the free switch.
    @Test("Match System Appearance hands the choice back to macOS")
    func matchingTheSystem() async throws {
        try await withTheme {
            try ThemeController.shared.apply(named: "gruvbox-light")
            #expect(ThemeController.shared.appearance == .light)

            ThemeController.shared.matchSystemAppearance()
            #expect(ThemeController.shared.appearance == .system)
            #expect(ThemeController.shared.name == "gruvbox-light", "the theme changed too")
            // Whichever half that is, it is the one the system is in.
            let systemIsDark = NSApplication.shared.effectiveAppearance.isDark
            #expect(ThemeController.shared.visibleKind == (systemIsDark ? .dark : .light))
        }
    }

    /// An unpaired theme has one appearance and AppKit had better agree with
    /// it: Dracula in a light-mode system was a dark page in a light window.
    @Test("an unpaired theme takes the window with it")
    func unpairedThemePinsTheWindow() async throws {
        try await withTheme {
            try ThemeController.shared.apply(named: "dracula", appearance: .system)
            #expect(ThemeController.shared.appearance == .system)
            #expect(ThemeController.shared.visibleKind == .dark)
            #expect(
                NSApplication.shared.effectiveAppearance.isDark,
                "the window is light around a dark-only theme")
        }
    }

    @Test("an appearance change re-renders nothing, not even a diagram")
    func pinningDoesNotRerender() async throws {
        try await withTheme {
            let fixture = try TabFixture()
            let controller = MainWindowController(root: fixture.directory, session: fixture.session)
            defer { controller.tabs.closeAll() }
            controller.open(fixture.file(named: "a.md"))
            let view = try #require(controller.tabs.selected?.documentView)
            await view.awaitReady()

            _ = try await controller.applyTheme(named: "nord")
            let before = try #require(await view.stats())
            let summary = try await controller.applyTheme(named: nil, appearance: .light)
            #expect(summary.appearance == "light")
            #expect(summary.rerendered == 0)
            let after = try #require(await view.stats())
            #expect(after.documents == before.documents, "an appearance change re-rendered")
        }
    }

    /// `#rrggbb` as `getComputedStyle` gives it back — `rgb(40, 42, 54)`.
    private static func rgb(_ hex: String) -> String {
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let value = UInt32(text, radix: 16) else { return hex }
        return "\((value >> 16) & 0xFF), \((value >> 8) & 0xFF), \(value & 0xFF)"
    }

    // MARK: - Diagrams and math

    /// **Gate 5, the part a string assertion can carry.** The pixel evidence is
    /// `mark-bench`'s two snapshots; what is checked here is the mechanism that
    /// produces them — one SVG per appearance, and MathML with no colour of its
    /// own at all.
    @Test("a diagram is emitted once per appearance and MathML inherits the text colour")
    func diagramsAndMath() throws {
        let source = """
            ```mermaid
            flowchart TD
              A[Start] --> B[Done]
            ```

            Math: $x^2$
            """
        let html = try MarkCore.renderHTML(source: source, theme: "gruvbox-dark")
        #expect(html.contains("class=\"mk-appear-light\"><svg"))
        #expect(html.contains("class=\"mk-appear-dark\"><svg"))
        // M6's defect: merman paints the SVG root white unconditionally.
        #expect(!html.contains("background-color: white"))

        let light = try MarkCore.theme(named: "gruvbox-light")
        let dark = try MarkCore.theme(named: "gruvbox-dark")
        let lightText = try #require(light.light.document["foreground"]?.color)
        let darkText = try #require(dark.dark.document["foreground"]?.color)
        let halves = html.components(separatedBy: "mk-appear-dark")
        #expect(halves[0].contains("fill:\(lightText)"), "the light copy is not in the light palette")
        #expect(halves[1].contains("fill:\(darkText)"), "the dark copy is not in the dark palette")

        // MathML carries no colour of its own — checked rather than assumed,
        // which is how the diagram defect was missed in M6.
        let math = try #require(html.range(of: "<math"))
        let mathml = String(html[math.lowerBound...].prefix(while: { $0 != "\n" }))
        #expect(!mathml.contains("fill="))
        #expect(!mathml.contains("color"))
    }

    @Test("an unpaired theme emits one diagram, not two identical ones")
    func unpairedDiagram() throws {
        let source = "```mermaid\nflowchart TD\n  A --> B\n```\n"
        let html = try MarkCore.renderHTML(source: source, theme: "dracula")
        #expect(!html.contains("mk-appear-"))
        #expect(html.components(separatedBy: "<svg").count == 2, "expected exactly one SVG")
    }

    // MARK: - The tree flags M8 could not reach

    @Test("the listing toggles reach the core, gitignore included")
    func treeFlags() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-flags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "*.log\n".write(
            to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for name in ["doc.md", "picture.png", "build.log", ".hidden.md"] {
            try "x\n".write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let markdownOnly = try MarkCore.tree(directory: directory.path).map(\.name)
        #expect(markdownOnly == ["doc.md"])

        let everything = try MarkCore.tree(
            directory: directory.path,
            options: TreeListingOptions(showsNonMarkdown: true, showsHidden: true)
        ).map(\.name)
        #expect(everything.contains("picture.png"))
        #expect(everything.contains(".hidden.md"))
        // The gap M8 recorded and could not close from Swift.
        #expect(!everything.contains("build.log"), "a gitignored file came back")
    }
}

/// A ``DocumentView`` in a window, which is what an appearance needs to reach
/// it.
///
/// `PatchHarness` deliberately has no window, and a windowless view resolves
/// its appearance against the system rather than against
/// `NSApplication.appearance` — so it would report the system's half whatever
/// the pin says, and pass this suite for the wrong reason. The window is never
/// ordered in: it exists to be the link in the chain that the app has and the
/// patch harness does not.
@MainActor
final class WindowedHarness {
    let fixture: PatchFixture
    let window: NSWindow
    let view: DocumentView
    let url: URL

    init(_ source: String) async throws {
        fixture = try PatchFixture()
        url = try fixture.write(source)
        view = DocumentView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.open(url)
        await view.awaitReady()
        await view.ensureFullyRendered()
    }

    /// The page's own answer to `prefers-color-scheme: dark`.
    ///
    /// Polled, because the appearance reaches the web content process
    /// asynchronously — the same reason `mark-bench` sleeps a frame before
    /// reading colours back. It returns as soon as the answer is `wanted`, so a
    /// passing run waits milliseconds and only a failing one waits the timeout.
    func pageIsDark(waitingFor wanted: Bool) async -> Bool? {
        let deadline = ContinuousClock.now + .seconds(2)
        var answer: Bool?
        repeat {
            answer =
                try? await view.call(
                    "return window.matchMedia('(prefers-color-scheme: dark)').matches;") as? Bool
            if answer == wanted { return answer }
            try? await _Concurrency.Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        return answer
    }
}

extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
