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
/// The document follows `prefers-color-scheme` and nothing else — which is the
/// system's answer until a pin changes the web view's appearance (see below).
/// What AppKit still has to be told is the colour *behind* the web view:
/// `WebViewFactory` turns off the web view's own background so the shell's
/// first paint does not flash white, which leaves the container to paint it.
/// ``backgroundColor`` is a dynamic `NSColor` holding both halves of the pair,
/// so it too re-resolves on an appearance change with nothing observing.
///
/// # Which half you get
///
/// A pair carries both halves, so *something* has to say which one is on
/// screen. Leaving that to the system alone had one consequence nobody wants:
/// choosing Solarized Light from the menu in dark mode left the window dark,
/// because the CSS the page was handed still resolved to the dark half.
/// Naming a theme is not a request for its pair — it is a request for **that
/// theme** — so ``apply(named:appearance:)`` pins ``appearance`` to the named
/// half's kind, and ``matchSystemAppearance()`` is how you hand the choice back
/// to macOS.
///
/// The pin is one `NSApplication.appearance` assignment, and everything follows
/// from it: WebKit resolves `prefers-color-scheme` against the web view's
/// effective appearance, so the document's variables, its `color-scheme` form
/// controls, and the per-appearance copies of a diagram (`.mk-appear-light` /
/// `.mk-appear-dark`) all switch with no IPC, no re-render, and no DOM work —
/// the same mechanism a system switch uses, driven from this side. The window's
/// own chrome, the sidebar, the editor pane, and the scrollbars come along
/// because they are AppKit, which is the half a page-only pin would have left
/// mismatched.
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

    /// Which half of ``active`` is on screen, or ``ThemeAppearance/system`` for
    /// "whichever macOS is in".
    public private(set) var appearance: ThemeAppearance = .system

    private init() {
        active = Self.resolveOrFallBack(nil)
    }

    /// The theme's name, as `mark theme` reports it.
    public var name: String { active.name }

    /// The CSS the page needs: both appearances, in one string.
    public var css: String { active.css }

    /// The half on screen right now: the pin, or what macOS is in.
    ///
    /// An unpaired theme answers with its own kind whatever the system is
    /// doing, because it has no other half to switch to.
    public var visibleKind: ThemeKind {
        switch appearance {
        case .light: return .light
        case .dark: return .dark
        case .system:
            guard active.paired else { return active.kind }
            return NSApplication.shared.effectiveAppearance.isDark ? .dark : .light
        }
    }

    /// The half on screen right now, as a theme.
    public var visibleHalf: ThemeHalf {
        visibleKind == .dark ? active.dark : active.light
    }

    /// Switch themes.
    ///
    /// - Parameters:
    ///   - name: the theme to resolve, or `nil` for the built-in default.
    ///   - appearance: which half to show. `nil` — the default — means *the one
    ///     you just named*: choosing Solarized Light gets you Solarized Light,
    ///     in a dark-mode system too, which is the only reading of "use this
    ///     theme" that does not need explaining. Pass
    ///     ``ThemeAppearance/system`` to keep following macOS instead.
    /// - Throws: ``CoreError`` naming the theme and what is wrong with it. The
    ///   caller reports that; nothing is applied, and the previous theme stays
    ///   in place — including its appearance. Plan §2 M7's fourth gate is that
    ///   a broken theme is a named error rather than invisible text, and
    ///   swallowing this would be exactly the invisible version.
    @discardableResult
    public func apply(named name: String?, appearance: ThemeAppearance? = nil) throws
        -> ResolvedTheme
    {
        let resolved = try MarkCore.theme(named: name)
        let needsRerender = resolved.codeStamp != active.codeStamp
        active = resolved
        chosenName = name
        // A theme chosen by name pins the half it names; the default pair —
        // which nobody chose — keeps following the system.
        self.appearance = appearance ?? (name == nil ? .system : .pinning(resolved.kind))
        syncAppearance()
        Log.render.info(
            """
            theme \(resolved.name, privacy: .public) \
            (\(resolved.light.name, privacy: .public)/\(resolved.dark.name, privacy: .public)), \
            appearance \(self.appearance.rawValue, privacy: .public), \
            re-render \(needsRerender ? "needed" : "not needed", privacy: .public)
            """
        )
        return resolved
    }

    /// Show whichever half macOS is in, keeping the theme.
    ///
    /// The way back from a pin, and the reason pinning does not cost anyone the
    /// zero-work appearance switch the pair mechanism exists for.
    public func matchSystemAppearance() {
        setAppearance(.system)
    }

    /// Pin the half on screen, or hand the choice back to macOS.
    public func setAppearance(_ appearance: ThemeAppearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        syncAppearance()
        Log.render.info(
            "appearance \(appearance.rawValue, privacy: .public), showing \(self.visibleHalf.name, privacy: .public)"
        )
    }

    /// Adopt a persisted name and appearance at launch.
    ///
    /// Deliberately not `throws`: a theme file the user has since deleted or
    /// broken must not stop the app from opening a document. It falls back to
    /// the default and says so in the log, which is the one place a "why is my
    /// theme not applied" question gets answered.
    ///
    /// - Parameter appearance: `nil` is a session file written before there was
    ///   anything to record — the theme was chosen by name back then too, so it
    ///   comes back pinned rather than at the mercy of whatever macOS is in.
    public func restore(named name: String?, appearance: ThemeAppearance? = nil) {
        guard let name, !name.isEmpty else {
            // A session with no theme but a recorded appearance still gets it:
            // "match the system" is a choice, and the default pair is the one
            // it is most likely to have been made about.
            if let appearance { setAppearance(appearance) }
            return
        }
        do {
            try apply(named: name, appearance: appearance)
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

    /// Tell AppKit which appearance the app is in — the whole of applying a
    /// pin.
    ///
    /// One assignment, and both halves of the window follow it: AppKit's own
    /// chrome directly, and the document because WebKit resolves
    /// `prefers-color-scheme` against the web view's effective appearance. So a
    /// pin costs exactly what a system switch costs, which is nothing — no IPC,
    /// no re-render, no `<style>` reinstalled, and no per-tab work for the
    /// dehydrated ones.
    ///
    /// `nil` is "follow macOS", and it is what an *unpaired* theme deliberately
    /// does not get: Dracula is dark in either appearance, so leaving the app
    /// light around it would be the same mismatch this method exists to remove.
    private func syncAppearance() {
        let pinned: ThemeKind? =
            switch appearance {
            case .light: .light
            case .dark: .dark
            case .system: active.paired ? nil : active.kind
            }
        NSApplication.shared.appearance = pinned
            .map { $0 == .dark ? NSAppearance.Name.darkAqua : .aqua }
            .flatMap(NSAppearance.init(named:))
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

/// Which half of the theme is on screen.
///
/// Three states rather than two, and the third is not "unset": *following the
/// system* is a real choice, it is the one a fresh install starts in, and it is
/// the one **View ▸ Theme ▸ Match System Appearance** and `mark theme --system`
/// go back to. Pinning is what naming a theme means.
public enum ThemeAppearance: String, Sendable, CaseIterable {
    /// Whichever appearance macOS is in — the pair mechanism, unchanged.
    case system
    case light
    case dark

    /// The pin that shows `kind`.
    public static func pinning(_ kind: ThemeKind) -> ThemeAppearance {
        kind == .dark ? .dark : .light
    }

    /// `"system"`, `"light"`, `"dark"` — and `"auto"`, which is what a person
    /// types about half the time. Anything else is `nil`, so the CLI can say
    /// so rather than guess.
    public init?(argument: String) {
        switch argument.lowercased() {
        case "system", "auto": self = .system
        case "light": self = .light
        case "dark": self = .dark
        default: return nil
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
