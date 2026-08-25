import AppKit
import Foundation

/// The app's half of M7: which theme is chosen, and how it reaches a page.
///
/// # What "applying a theme" is
///
/// One `<style>` element's text. The core resolves a name to a **pair** — a
/// light theme and a dark one — and emits custom properties for both, with the
/// dark half behind `@media (prefers-color-scheme: dark)`. Handing that string
/// to the page is the entire operation:
///
/// * **Switching macOS appearance costs nothing.** No IPC, no re-render, no DOM
///   work, nothing scheduled — WebKit re-resolves the variables and repaints.
///   Nothing in this file runs at all. That is the first gate, and it is met by
///   there being no code path rather than by a fast one.
/// * **Switching *themes* costs one `textContent` assignment per hydrated tab.**
///   Code tokens carry palette *slots* (`class="t0B"`), not colours, so the
///   document's HTML does not depend on which theme is active — only on the
///   scope → slot map, which every shipped theme shares. ``ResolvedTheme``
///   carries a `codeStamp` identifying that map, and a re-render happens only
///   when it changes, which for the themes that ship it never does.
/// * **A dehydrated tab needs nothing.** It has no DOM to update, and when it
///   comes back it is rendered against ``active`` like any other open.
///
/// # System appearance
///
/// The document follows the system through `prefers-color-scheme` and nothing
/// else. What AppKit still has to be told is the colour *behind* the web view:
/// `WebViewFactory` turns off the web view's own background so the shell's
/// first paint does not flash white, which leaves the container to paint it.
/// ``backgroundColor`` is a dynamic `NSColor` holding both halves of the pair,
/// so it too re-resolves on an appearance change with nothing observing.
@MainActor
public final class ThemeController {

    /// The one instance. A theme is app-wide — ADR-4 has one window, and a
    /// per-tab theme is a feature nobody asked for.
    public static let shared = ThemeController()

    /// The resolved pair every render and every page uses.
    public private(set) var active: ResolvedTheme

    /// The name to persist. `nil` when it is the built-in default, so a session
    /// file does not pin a name the user never chose.
    public private(set) var chosenName: String?

    private init() {
        active = Self.resolveOrFallBack(nil)
    }

    /// The theme's name, as `mark theme` reports it.
    public var name: String { active.name }

    /// The CSS the page needs: both appearances, in one string.
    public var css: String { active.css }

    /// Switch themes.
    ///
    /// - Throws: ``CoreError`` naming the theme and what is wrong with it. The
    ///   caller reports that; nothing is applied, and the previous theme stays
    ///   in place. Plan §2 M7's fourth gate is that a broken theme is a named
    ///   error rather than invisible text, and swallowing this would be exactly
    ///   the invisible version.
    @discardableResult
    public func apply(named name: String?) throws -> ResolvedTheme {
        let resolved = try MarkCore.theme(named: name)
        let needsRerender = resolved.codeStamp != active.codeStamp
        active = resolved
        chosenName = name
        Log.render.info(
            """
            theme \(resolved.name, privacy: .public) \
            (\(resolved.light.name, privacy: .public)/\(resolved.dark.name, privacy: .public)), \
            re-render \(needsRerender ? "needed" : "not needed", privacy: .public)
            """
        )
        return resolved
    }

    /// Adopt a persisted name at launch.
    ///
    /// Deliberately not `throws`: a theme file the user has since deleted or
    /// broken must not stop the app from opening a document. It falls back to
    /// the default and says so in the log, which is the one place a "why is my
    /// theme not applied" question gets answered.
    public func restore(named name: String?) {
        guard let name, !name.isEmpty else { return }
        do {
            try apply(named: name)
        } catch {
            Log.render.error(
                "session theme \(name, privacy: .public) did not load (\(String(describing: error), privacy: .public)); using \(self.active.name, privacy: .public)"
            )
        }
    }

    /// Every theme that can be named, for the menu.
    public func catalog() -> ThemeCatalog? {
        do {
            return try MarkCore.themes()
        } catch {
            Log.render.error("listing themes failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The page background, as a colour that follows the system appearance by
    /// itself.
    ///
    /// `NSColor(name:dynamicProvider:)` is re-evaluated by AppKit whenever the
    /// effective appearance changes, so nothing here observes anything: the
    /// same "no code runs on a switch" property the document has.
    public var backgroundColor: NSColor {
        let light = active.light.color(of: "background") ?? .textBackgroundColor
        let dark = active.dark.color(of: "background") ?? .textBackgroundColor
        return NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        }
    }

    /// The default pair, which is built in and cannot be broken by a user file.
    private static func resolveOrFallBack(_ name: String?) -> ResolvedTheme {
        do {
            return try MarkCore.theme(named: name)
        } catch {
            // Unreachable: the default is embedded in the binary and covered by
            // `theme::tests::the_default_pair_is_the_documented_one`. A window
            // with no colours would be a worse answer than grey ones, so there
            // is a floor here rather than a `try!`.
            Log.render.error(
                "the default theme did not resolve: \(String(describing: error), privacy: .public)"
            )
            return ResolvedTheme.fallback
        }
    }
}

extension NSAppearance {
    /// Whether this appearance is one of the dark ones.
    public var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension ResolvedTheme {
    /// The last resort, used only if the built-in default fails to load — which
    /// would mean the binary itself is damaged.
    static let fallback = ResolvedTheme(
        name: "fallback",
        kind: .dark,
        paired: false,
        light: ThemeHalf.fallback,
        dark: ThemeHalf.fallback,
        css: ":root{color-scheme:dark;--mk-background:#1c1c1c;--mk-foreground:#d8d8d8;}\n",
        codeStamp: "0000000000000000"
    )
}

extension ThemeHalf {
    static let fallback = ThemeHalf(
        name: "fallback",
        title: "fallback",
        kind: .dark,
        author: nil,
        palette: [:],
        document: ["background": Chrome(slot: "base00", color: "#1c1c1c")]
    )
}
