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

    /// The sidebar's Tasks tab navigates through this, and
    /// `2026-08-28-tabbed-document-pane` fixes both halves of how: the byte
    /// offset is tried before the index, and the lookup goes through
    /// `ensureFullyRendered` for ADR-2's reason — a task three quarters of the
    /// way down the document is not in the DOM until it does.
    ///
    /// Asserted against the shipped source, because a page that scrolls to the
    /// wrong task is indistinguishable from one that scrolls to the right one
    /// when nothing has renumbered.
    @Test("the shell exposes scrollToTask, byte offset first")
    func scrollToTaskExists() throws {
        let js = try code("shell.js")
        #expect(js.contains("mark.scrollToTask"))
        let body = try #require(js.range(of: "mark.scrollToTask")).upperBound
        let tail = String(js[body...].prefix(900))
        #expect(tail.contains("mark.ensureFullyRendered()"))
        let byOffset = try #require(tail.range(of: "data-mk-start"))
        let byIndex = try #require(tail.range(of: "data-mk-idx"))
        #expect(
            byOffset.lowerBound < byIndex.lowerBound,
            "the byte offset is the identity; the index is the fallback")
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
        for attribute in ["data-mk-idx", "data-mk-start", "data-mk-end", "data-mk-state"] {
            #expect(
                js.contains("input.setAttribute(\"\(attribute)\""),
                "\(attribute) is read on a click but never re-stamped after a patch")
        }
        #expect(js.contains("getAttribute(\"data-mk-state\")"))
    }

    /// > `shell.js` reports `state` and `renderedState` as strings instead of
    /// > `checked`/`rendered` booleans, because with five states the browser can
    /// > no longer compute the requested state for us during pre-click
    /// > activation.
    ///
    /// The click handler must therefore not read `target.checked` at all: for a
    /// cancelled marker that property is false while the core's `checked` — "the
    /// state is terminal" — is true, so a handler that reads it asks the wrong
    /// question and gets a plausible answer.
    @Test("the click handler derives the requested state instead of reading target.checked")
    func clickDoesNotReadTheCheckedProperty() throws {
        let js = try code("shell.js")
        #expect(!js.contains("target.checked"))
        #expect(js.contains("event.altKey"), "⌥-click is what reaches cancelled")
        #expect(js.contains("\"cancelled\""))
        // Both states, by name, on the message the write path reads.
        #expect(js.contains("renderedState"))
        #expect(js.contains("\"taskMenu\""))
    }

    /// The restamp's count-mismatch refusal, which
    /// `2026-08-27-five-task-states` turns into a standing constraint: *"a task
    /// marker stays an `input.mk-task` element […] so a marker rendered as
    /// anything else breaks incremental patching silently."* Five states are a
    /// `data-mk-state` attribute on that element, never a different element.
    @Test("the restamp still refuses a checkbox count that does not line up")
    func restampRefusesACountMismatch() throws {
        let js = try code("shell.js")
        #expect(js.contains("querySelectorAll(\"input.mk-task\")"))
        #expect(js.contains("inputs.length !== tasks.length"))
        #expect(js.contains("checkboxes, the source has "))
    }

    // MARK: - The two stylesheets

    /// The shell's checkbox rules and the core's `document_css()` are the same
    /// rules, and this is what says so.
    ///
    /// `2026-08-27-five-task-states` accepts owning checkbox rendering and
    /// names the cost: *"two stylesheets […] must be edited in lockstep.
    /// `core/src/render.rs` and `app/Resources/shell.css` are deliberately not
    /// generated from one source."* Not generated, so pinned — otherwise a box
    /// drawn one way in the window and another way in `mark render --html`
    /// output is exactly the GUI/CLI capability split ADR-5 exists to prevent,
    /// and nothing would fail.
    @Test("the shell stylesheet's checkbox rules match the core's")
    func checkboxRulesMatchTheCore() throws {
        let core = try Self.coreDocumentCSS()
        let shell = try text("shell.css")

        var selectors = [
            "input.mk-task", "input.mk-task:focus-visible", ".mk-tag",
            ".mk-tag[data-mk-priority=\"1\"]",
            ".mk-tag[data-mk-priority=\"2\"]",
            ".mk-tag[data-mk-priority=\"3\"]",
            "mark",
            "li:has(> input.mk-task[data-mk-state=\"cancelled\"])",
        ]
        // Open is the bare box — the base rule *is* its rule — so it is the one
        // state with no selector of its own, in either file. Asserted rather
        // than skipped, because a rule appearing for it in one file and not the
        // other is exactly the drift this test is for.
        for state in TaskState.allCases where state != .open {
            selectors.append("input.mk-task[data-mk-state=\"\(state.rawValue)\"]")
        }
        for stylesheet in [core, shell] {
            #expect(
                Self.declarations(of: "input.mk-task[data-mk-state=\"open\"]", in: stylesheet)
                    == nil,
                "open gained a rule of its own; add it to both stylesheets and to this list")
        }

        for selector in selectors {
            let inCore = try #require(
                Self.declarations(of: selector, in: core),
                "the core's stylesheet has no rule for \(selector)")
            let inShell = try #require(
                Self.declarations(of: selector, in: shell),
                "shell.css has no rule for \(selector) — the two have drifted")
            #expect(inCore == inShell, "\(selector) differs between the two stylesheets")
        }
    }

    /// The diff view's rules, pinned to the core's the same way the checkbox
    /// rules are.
    ///
    /// The failure this catches is one the app cannot: a diff that is tinted in
    /// `mark diff --html` and plain in the window. That is exactly what happened
    /// the first time the diff view was run — the rules had been added to
    /// `document_css()` and not to `shell.css`, and the page rendered the right
    /// blocks with none of the colour.
    @Test("the diff view's rules match the core's")
    func diffRulesMatchTheCore() throws {
        let core = try Self.coreDocumentCSS()
        let shell = try text("shell.css")

        let selectors = [
            ".mk-blk.mk-diff-add, .mk-blk.mk-diff-mod, .mk-blk.mk-diff-del",
            ".mk-blk.mk-diff-add::before, .mk-blk.mk-diff-mod::before, .mk-blk.mk-diff-del::before",
            ".mk-blk.mk-diff-add",
            ".mk-blk.mk-diff-add::before",
            ".mk-blk.mk-diff-mod",
            ".mk-blk.mk-diff-mod::before",
            ".mk-blk.mk-diff-del",
            ".mk-blk.mk-diff-del::before",
            ".mk-blk.mk-diff-del > *",
            ".mk-blk.mk-diff-del > pre, .mk-blk.mk-diff-del > .mk-diagram",
            // Double quotes, because `declarations(of:in:)` normalises the
            // stylesheet's quotes and not the selector's.
            ".mk-blk[data-mk-side=\"old\"] input.mk-task",
        ]
        for selector in selectors {
            let inCore = try #require(
                Self.declarations(of: selector, in: core),
                "the core's stylesheet has no rule for \(selector)")
            let inShell = try #require(
                Self.declarations(of: selector, in: shell),
                "shell.css has no rule for \(selector) — the two have drifted")
            #expect(inCore == inShell, "\(selector) differs between the two stylesheets")
        }

        // No new custom property: the tints reuse the slots a theme already
        // defines, so a theme change stays a CSS swap.
        for property in ["--mk-diff", "--mk-added", "--mk-removed"] {
            #expect(
                !shell.contains(property) && !core.contains(property),
                "\(property) would be a new theme slot; the ADR says there is none")
        }
    }

    /// Overdue colouring is the *app's*, and only the app's: the core may not
    /// read a clock (`2026-08-27-inline-task-metadata`), so the two stylesheets
    /// are asymmetric here on purpose and the test says which way round.
    @Test("due-date colouring exists in the shell and not in the core")
    func overdueColouringIsTheAppsAlone() throws {
        let core = try Self.coreDocumentCSS()
            + (try MarkCore.renderHTML(source: "- [ ] a task @due(2026-09-01)\n"))
        let shell = try text("shell.css")
        #expect(shell.contains(".mk-tag.mk-overdue"))
        #expect(shell.contains(".mk-tag.mk-due-today"))
        #expect(!core.contains("mk-overdue"), "the renderer compared a date")
        #expect(!core.contains("mk-due-today"), "the renderer compared a date")
        // ...and the class is put on by the injected script, from the chip's
        // own data, rather than by the renderer.
        let js = try code("shell.js")
        #expect(js.contains("data-mk-due"))
        #expect(js.contains("mk-overdue"))
    }

    /// `document_css()`'s stylesheet, read from the Rust source it is written
    /// in.
    ///
    /// Not from the core over the ABI: `mark_render_html` answers with a
    /// document *fragment* — the shell page supplies the CSS — and the only
    /// caller that gets the standalone document with a `<style>` in it is
    /// `mark render --html`, which is a process this suite does not run. The
    /// two files are what the ADR says must move in lockstep, so the two files
    /// are what this compares.
    private static func coreDocumentCSS() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarkTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // the repository root
        let source = try String(
            contentsOf: root.appendingPathComponent("core/src/render.rs"), encoding: .utf8)
        let start = try #require(
            source.range(of: "pub fn document_css()"), "render.rs has no document_css()")
        let end = try #require(
            source.range(of: "token_css()", range: start.upperBound..<source.endIndex),
            "document_css() no longer ends by appending token_css()")
        // A `\` at the end of a line in a Rust string literal swallows the
        // newline *and* the next line's indentation, which is how the tick's
        // data URI is written across four lines and arrives as one. Undo it
        // here or the comparison fails on whitespace that does not exist in
        // the string the core actually emits.
        return source[start.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "\\\n", with: "")
    }

    /// One rule's declarations, normalised: quotes unified, whitespace
    /// collapsed, and sorted, so the core's compact one-liner and the shell's
    /// expanded block compare equal while a changed value does not.
    private static func declarations(of selector: String, in css: String) -> [String]? {
        let flat = css.replacingOccurrences(of: "'", with: "\"")
            .split(separator: "\n").joined(separator: " ")
        // A prefix match would let `input.mk-task` match
        // `input.mk-task:focus-visible`, so the selector has to end at its
        // brace.
        guard let range = flat.range(of: selector + " {") ?? flat.range(of: selector + "{"),
            let close = flat.range(of: "}", range: range.upperBound..<flat.endIndex)
        else { return nil }
        return flat[range.upperBound..<close.lowerBound]
            .split(separator: ";")
            .map { $0.split(separator: " ").filter { !$0.isEmpty }.joined(separator: " ") }
            .filter { !$0.isEmpty }
            .sorted()
    }
}
