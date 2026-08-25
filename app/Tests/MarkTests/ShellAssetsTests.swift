import Foundation
import Testing

@testable import MarkKit

/// The shell page, its transport, and the two ADR-2 bans that live in its
/// source rather than in a type.
/// `@MainActor` because `ShellSchemeHandler` conforms to `WKURLSchemeHandler`,
/// which the SDK annotates `@MainActor`. WebKit's `@preconcurrency` import lets
/// a cross-isolation call compile and then trap at runtime, so getting this
/// wrong shows up as a bare `SIGTRAP` in the test run rather than as a
/// diagnostic.
@Suite("Shell assets")
@MainActor
struct ShellAssetsTests {

    /// One asset as text. A helper rather than a nested `#require`, which the
    /// testing macro cannot expand inside itself.
    private func text(_ name: String) throws -> String {
        let data = try #require(ShellAssets.data(named: name), "\(name) missing")
        return try #require(String(data: data, encoding: .utf8), "\(name) is not UTF-8")
    }

    /// The same asset with comments removed.
    ///
    /// The bans below are asserted against the shipped source, and the shipped
    /// source *documents* each ban by name — `shell.js` explains why
    /// `requestIdleCallback` is absent, `shell.html` says ADR-5 forbids KaTeX
    /// and mermaid.js. A naive `contains` check therefore fails on the very
    /// comment that records the rule. Strip comments, then assert.
    private func code(_ name: String) throws -> String {
        var source = try text(name)
        for (open, close) in [("/*", "*/"), ("<!--", "-->")] {
            while let start = source.range(of: open),
                let end = source.range(of: close, range: start.upperBound..<source.endIndex)
            {
                source.replaceSubrange(start.lowerBound..<end.upperBound, with: "")
            }
        }
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("all three assets are in the bundle")
    func present() throws {
        for name in ["shell.html", "shell.js", "shell.css"] {
            let data = try #require(ShellAssets.data(named: name), "\(name) missing")
            #expect(!data.isEmpty)
        }
    }

    @Test("the handler serves the three assets with usable MIME types")
    func serves() throws {
        let handler = ShellSchemeHandler()
        for (name, mime) in ShellAssets.served {
            let url = try #require(URL(string: "\(ShellAssets.scheme)://shell/\(name)"))
            let (data, resolved) = try handler.resolve(url)
            #expect(!data.isEmpty)
            #expect(resolved == mime)
            // A `; charset=` parameter here is not parsed by `URLResponse` and
            // silently degrades to text/plain — which renders the shell page as
            // its own source text. This caught exactly that.
            #expect(!resolved.contains(";"), "\(name) MIME type must be bare: \(resolved)")
        }
    }

    @Test("the handler is not a general file server")
    func refusesEverythingElse() throws {
        let handler = ShellSchemeHandler()
        for path in ["/etc/passwd", "/shell/../../etc/passwd", "/notes.md", "/"] {
            let url = try #require(URL(string: "\(ShellAssets.scheme)://shell\(path)"))
            #expect(throws: ShellSchemeHandler.AssetError.self) { try handler.resolve(url) }
        }
        #expect(throws: ShellSchemeHandler.AssetError.self) { try handler.resolve(nil) }
    }

    /// ADR-3 registers `mark://` with LaunchServices in M4. A
    /// `WKURLSchemeHandler` on the same scheme would shadow it inside the web
    /// view, so the asset scheme must stay distinct.
    @Test("the asset scheme does not collide with ADR-3's mark:// scheme")
    func schemeDoesNotForecloseM4() {
        #expect(ShellAssets.scheme != "mark")
        #expect(ShellAssets.shellURL.scheme == ShellAssets.scheme)
    }

    // MARK: - The installed-app trap

    /// `Bundle.module` is a loaded gun in this target, and the safety is that
    /// nothing pulls the trigger.
    ///
    /// SwiftPM generates it as a `static let` whose initialiser calls
    /// `fatalError` when it cannot find `Mark_MarkKit.bundle`, and it looks in
    /// exactly two places: the *root* of `Bundle.main` — `mark.app/`, not
    /// `mark.app/Contents/Resources/`, which is where
    /// `scripts/assemble-bundle.sh` puts it — and the absolute `.build` path of
    /// whatever machine compiled the binary. In this checkout that second path
    /// exists, so a reference to `Bundle.module` runs fine here and kills the
    /// app the moment it is installed anywhere else. That shipped: every
    /// `brew install --HEAD` of mark died on launch with
    /// `could not load resource bundle`, while `just build` in a worktree was
    /// fine, because the build directory it named was still on disk.
    ///
    /// ``ShellAssets/moduleBundle`` does the same search over `Bundle(url:)`,
    /// which returns `nil` instead of trapping. Use that.
    @Test("no MarkKit source references Bundle.module")
    func sourceNeverTouchesBundleModule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarkTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .appendingPathComponent("Sources/Mark")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "found no Swift sources under \(sources.path)")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Explaining the trap in a comment is the point of the comment, so
            // only code counts.
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///"), !trimmed.hasPrefix("*")
                else { continue }
                let site = "\(file.lastPathComponent):\(number + 1)"
                #expect(
                    !trimmed.contains("Bundle.module"),
                    """
                    \(site) reads Bundle.module, which fatalErrors in an installed app. \
                    Use ShellAssets.moduleBundle instead.
                    """)
            }
        }
    }

    /// The lookup has to be anchored to a bundle that actually holds MarkKit.
    /// Under `swift test` that is `MarkPackageTests.xctest`, *not*
    /// `Bundle.main` — which is SwiftPM's helper binary off in
    /// `/Library/Developer/CommandLineTools`. Getting this wrong does not fail
    /// a test; it hangs the entire suite before its first line of output, since
    /// a web view awaiting a shell page that never arrives never returns.
    @Test("the resource bundle is found from wherever the code is loaded")
    func moduleBundleResolves() throws {
        let bundle = try #require(
            ShellAssets.moduleBundle, "Mark_MarkKit.bundle was not found from any anchor")
        for name in ShellAssets.served.keys {
            #expect(bundle.url(forResource: name, withExtension: nil) != nil, "\(name) missing")
        }
    }

    // MARK: - ADR-2 bans, asserted against the shipped source

    /// > **`content-visibility: auto` is not to be reintroduced** without a
    /// > fresh measurement on the then-current WebKit that beats plain
    /// > injection.
    ///
    /// It is the obvious optimization, it is a measured 1.8× pessimization
    /// here, and the next person will reach for it. A comment does not stop
    /// that; a failing test does.
    @Test("content-visibility appears in the stylesheet only as the ban")
    func contentVisibilityIsNotUsed() throws {
        #expect(!(try code("shell.css")).contains("content-visibility"))
        // ...and the ban itself is still written down where the next person
        // reaching for it will read it.
        #expect((try text("shell.css")).contains("content-visibility"))
    }

    /// > **`requestIdleCallback` is unavailable** — do not reach for it.
    @Test("the fill pump does not call requestIdleCallback")
    func noRequestIdleCallback() throws {
        let js = try code("shell.js")
        // The capability probe names it, and reports it as absent; that is a
        // `typeof` test, not a call.
        #expect(!js.contains("requestIdleCallback("))
        #expect(js.contains("setTimeout("), "the pump must be driven by setTimeout")
    }

    /// > `document.body.scrollTop` returns 0 in `WKWebView`. Use
    /// > `window.pageYOffset`.
    @Test("scroll position is read from pageYOffset, never body.scrollTop")
    func noBodyScrollTop() throws {
        let js = try code("shell.js")
        #expect(!js.contains("body.scrollTop"))
        #expect(js.contains("window.pageYOffset"))
    }

    /// ADR-5: the WebView receives no JavaScript for math or diagrams, and no
    /// third-party JS at all.
    @Test("the shell page loads no third-party script")
    func noThirdPartyScript() throws {
        let html = try code("shell.html")
        #expect(html.components(separatedBy: "<script").count - 1 == 1)
        #expect(html.contains("src=\"shell.js\""))
        #expect(!html.lowercased().contains("katex"))
        #expect(!html.lowercased().contains("mermaid"))
        #expect(!html.contains("//cdn"))
        #expect(!html.contains("http"))
    }

    /// ADR-2's escape hatch has to exist, by that name, because the constraint
    /// is written as "route such features through it".
    @Test("the shell exposes ensureFullyRendered")
    func ensureFullyRenderedExists() throws {
        let js = try code("shell.js")
        #expect(js.contains("mark.ensureFullyRendered"))
    }

    /// > **`requestAnimationFrame` is suspended for an occluded window.**
    ///
    /// M4 hit this — `mark reload` on a background window never resolved — and
    /// added `beforeNextPaint`, which arms rAF and a 100 ms timeout and takes
    /// whichever fires first. The patch path must go through it too, or a
    /// watcher event for a window behind the terminal hangs instead of
    /// patching.
    @Test("every pre-paint hook goes through beforeNextPaint, never a bare rAF")
    func noBareRequestAnimationFrame() throws {
        let js = try code("shell.js")
        #expect(js.contains("mark.applyEditScript"))
        #expect(js.contains("beforeNextPaint(function"))
        // One call, inside `beforeNextPaint` itself.
        #expect(js.components(separatedBy: "requestAnimationFrame(").count - 1 == 1)
    }

    /// The M5 trap, asserted against the shipped source rather than only
    /// against behaviour: the patch must re-stamp task attributes from the
    /// core's own JSON, and the click handler must read the *rendered* state
    /// from the content attribute rather than inferring it.
    @Test("the patch re-stamps task attributes, and the click reports both states")
    func restampIsPresent() throws {
        let js = try code("shell.js")
        for attribute in ["data-mk-idx", "data-mk-start", "data-mk-end"] {
            #expect(
                js.contains("input.setAttribute(\"\(attribute)\""),
                "\(attribute) is read on a click but never re-stamped after a patch")
        }
        #expect(js.contains("hasAttribute(\"checked\")"))
    }
}
