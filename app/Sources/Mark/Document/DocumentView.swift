import AppKit
import Foundation
import WebKit

/// Why a document could not be shown. Plan §3: the GUI shows an inline error
/// card and stays open; it does not throw the window away.
public enum DocumentError: Error, CustomStringConvertible {
    /// The file could not be read as text in any encoding Foundation would
    /// guess. `underlying` is the *UTF-8* failure, which is the useful one:
    /// "not valid UTF-8 at byte N" beats "the operation could not be
    /// completed".
    case unreadable(path: String, underlying: any Error)

    public var description: String {
        switch self {
        case .unreadable(let path, let underlying):
            return "\(path): \(underlying.localizedDescription)"
        }
    }
}

/// The document area: exactly one `WKWebView`, hosting the shell page for the
/// lifetime of the view, with documents injected into it.
///
/// This is where ADR-2 lands. On open:
///
/// 1. Read the file.
/// 2. Ask the core for the **first N blocks only**, N derived from viewport
///    height by ``ProgressiveRenderer`` — never a constant.
/// 3. Inject that prefix and let WebKit paint it.
/// 4. On a background thread, render the whole document, take the tail, and
///    hand it to `shell.js`'s `setTimeout` pump to land behind the paint.
///
/// The shell page is loaded **once**. Nothing here calls `loadHTMLString` per
/// document: ADR-2 rejects that outright as the documented cause of "live
/// preview jumps to the top" — it tears down the DOM, loses scroll and JS
/// state, and flashes white.
@MainActor
public final class DocumentView: NSView, ScriptBridgeDelegate, WKNavigationDelegate {

    /// The single web view. `public` so `mark-bench` can drive it; M3 will make
    /// one of these per tab, all on ``WebViewFactory/configuration``.
    public private(set) var webView: WKWebView!

    private let bridge = ScriptBridge()

    /// ADR-2's first-paint tunable, and the running estimate behind it.
    public let renderer = ProgressiveRenderer()

    /// The document currently shown, if any.
    public private(set) var url: URL?

    /// Called when a document has been opened, so the window can retitle.
    public var onOpen: ((URL) -> Void)?

    /// Called once, when `shell.js` has installed `window.mark`. Nothing may
    /// be injected before this fires; `mark-bench` waits on it.
    public var onShellReady: (() -> Void)?

    /// Called on every throttled `scroll` message from the page.
    ///
    /// ADR-4's tab layer uses this to keep ``DocumentTab/scrollOffset`` live,
    /// so dehydration and the session file can both read the reader's position
    /// synchronously.
    public var onScroll: ((Double) -> Void)?

    /// Called with the source position at the top of the viewport — a UTF-8
    /// byte offset — on every scroll report that carried one.
    ///
    /// Separate from ``onScroll`` because the two consumers want different
    /// things and fail differently. `onScroll` is bookkeeping: it must fire on
    /// every report, because a tab about to be dehydrated has to remember where
    /// the reader was. This is the editor pane following the preview, and it
    /// must *not* fire when the page could not say where it is, because "I do
    /// not know" and "the top of the file" would then be the same message.
    public var onSourceTop: ((Int) -> Void)?

    /// Called when the reader clicks or tabs into this document.
    ///
    /// With a split there are two documents on screen and the window has to
    /// know which one the tab bar and the find bar should act on. See
    /// ``DocumentWebView`` for why this cannot be a mouse event.
    public var onFocus: (() -> Void)?

    /// The last position the page reported. Readable without a round trip,
    /// which is the whole reason it is pushed rather than queried.
    public private(set) var scrollOffset: Double = 0

    /// Where a checkbox click is written.
    ///
    /// Injectable because it is the one thing in the app that mutates a user's
    /// file, so a test must be able to stand in front of it — and because
    /// `2026-08-24-editing-pane-and-autosave` puts an unsaved buffer here in
    /// M9, at which point *this* property is the switch between "the file is
    /// truth" and "the buffer is truth".
    public var taskWriter: any TaskWriteTarget = FileTaskWriter.shared

    /// The document the DOM currently shows, or `nil` if nothing has painted.
    ///
    /// This is the "old" side of every block diff, so it must be exactly the
    /// bytes the page was rendered from — not "what the file said recently".
    public var renderedSource: String? { source }

    private var source: String?
    private var isShellReady = false

    /// Whether the page is currently showing the diff against `HEAD` rather
    /// than the document.
    ///
    /// The diff view is a **mode of the tab**, not a separate tab: ⌘⇧D is a way
    /// of looking at the document you already have open, and opening a second
    /// tab for it would cost a web view (ADR-4 budgets those at ~52 MB) to say
    /// something about the first one.
    public private(set) var isShowingDiff = false

    /// Fired when the mode changes, so the window can retick the menu item and
    /// the tab can remember.
    public var onDiffModeChanged: ((Bool) -> Void)?
    private var pendingOpen: URL?

    /// The bytes a deferred open should use instead of the file's — see
    /// ``open(_:source:restoringScrollTo:)``.
    private var pendingOpenSource: String?

    /// The in-flight ``present(_:)``, so ``awaitReady()`` can wait for the
    /// document to be in the DOM rather than for a wall-clock guess.
    private var presentTask: _Concurrency.Task<Void, Never>?

    /// Callers parked in ``awaitReady()`` before the shell page loaded.
    private var shellReadyWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingScrollRestore: Double = 0
    private var fillTask: _Concurrency.Task<Void, Never>?

    /// Bumped on every open so a background fill for a document the user has
    /// already navigated away from is dropped instead of appended to the wrong
    /// document.
    private var generation = 0

    /// A patch is in the page right now.
    private var isApplying = false

    /// The newest source that arrived while a patch was in flight.
    private var pendingApply: String?

    /// How long the last diff took, in seconds — the number M5 flagged as
    /// unaffordable at typing cadence, so `mark-bench` can watch it.
    public private(set) var lastDiffSeconds: Double = 0

    // MARK: - Lifecycle

    public override init(frame: NSRect) {
        super.init(frame: frame)
        bridge.delegate = self
        // Layer-backed on purpose: see the note on ``updateLayer()``. Without
        // it AppKit has nowhere to put the background colour, and drawing it
        // instead reaches the other pane.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let webView = WebViewFactory.makeWebView(bridge: bridge)
        webView.navigationDelegate = self
        webView.onBecomeFirstResponder = { [weak self] in self?.onFocus?() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.webView = webView

        let state = Log.signposter.beginInterval("shell load")
        webView.load(URLRequest(url: ShellAssets.shellURL))
        Log.signposter.endInterval("shell load", state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentView is created in code, not from a nib")
    }

    // MARK: - Opening

    /// Show the document at `url`.
    ///
    /// Safe to call before the shell page has finished loading; the request is
    /// held and replayed on `ready`. That matters on cold start, where research
    /// §2.6 measured the window visible at 150 ms and the shell ready at
    /// 264 ms — an open triggered from `main` arrives inside that window.
    /// - Parameter restoringScrollTo: where to put the reader once the
    ///   document has painted. Non-zero only on ADR-4's rehydration path,
    ///   which deliberately reuses this method rather than getting one of its
    ///   own: rehydration must go through the same prefix-then-fill pipeline a
    ///   fresh open does, or ADR-2's gate stops covering it.
    /// - Parameter source: the bytes to render, when the caller already has
    ///   them and the file is *not* the authority. That is M9's dirty tab
    ///   rehydrating: `2026-08-24-editing-pane-and-autosave` forbids reading
    ///   the file for rendering while a buffer is dirty, and rehydration is a
    ///   render. `nil` means "read the file", which is every other caller.
    public func open(_ url: URL, source: String? = nil, restoringScrollTo offset: Double = 0) {
        self.url = url
        scrollOffset = offset
        pendingScrollRestore = offset
        guard isShellReady else {
            pendingOpen = url
            pendingOpenSource = source
            Log.render.debug("open deferred until the shell is ready")
            return
        }
        if let source {
            present(url, source: source)
        } else {
            present(url)
        }
    }

    /// Release the web view.
    ///
    /// The dehydration half of ADR-4's state machine. Everything that outlives
    /// it — path, scroll offset, title, task counts — lives on ``DocumentTab``,
    /// not here.
    public func tearDown() {
        fillTask?.cancel()
        fillTask = nil
        presentTask?.cancel()
        presentTask = nil
        // A `CheckedContinuation` that is never resumed hangs its caller and
        // leaks. Dehydrating a tab out from under an in-flight `mark goto` is
        // exactly that case (ADR-4 evicts on selection, ADR-3 commands arrive
        // whenever they arrive), so releasing the waiters is part of teardown.
        let waiting = shellReadyWaiters
        shellReadyWaiters = []
        for continuation in waiting { continuation.resume() }
        onScroll = nil
        onSourceTop = nil
        onOpen = nil
        onShellReady = nil
        if let webView {
            webView.navigationDelegate = nil
            webView.stopLoading()
            WebViewFactory.release(webView)
            webView.removeFromSuperview()
        }
        removeFromSuperview()
    }

    /// Re-read the file and bring the document up to date, holding the reader's
    /// place.
    ///
    /// - Returns: `shell.js`'s patch report, or `nil` when nothing changed.
    @discardableResult
    public func reload() async -> PatchReport? {
        guard let url else { return nil }
        do {
            return await apply(source: try DocumentSource.read(url))
        } catch {
            show(error: error, for: url)
            return nil
        }
    }

    /// Bring the document up to date with `newSource`, touching only the blocks
    /// that actually changed.
    ///
    /// ADR-2's incremental patch, end to end:
    ///
    /// > On a file change the core re-parses, diffs the block-hash sequence, and
    /// > emits a minimal edit script; the shell patches only the affected blocks
    /// > by `data-blk` and leaves every other DOM node untouched.
    ///
    /// Three things happen here that are easy to leave out and impossible to
    /// notice afterwards:
    ///
    /// 1. **The background fill is forced first.** The script addresses every
    ///    block of the old document, and half of them may still be waiting in
    ///    the pump. This is exactly the hazard ADR-2 names, and
    ///    ``ensureFullyRendered()`` is the sanctioned way out of it.
    /// 2. **A no-op script is still applied.** Inserting a blank line between
    ///    two paragraphs changes no block's identity — the core hashes the
    ///    trimmed slice — so the diff is a single `keep`, while every byte
    ///    offset below the edit has moved. Skipping the "empty" patch would
    ///    leave every task span below it stale, which is the same corruption
    ///    the re-stamp exists to prevent, arriving by a quieter route.
    /// 3. **A refused patch re-renders wholesale.** `shell.js` returns
    ///    `ok: false` the moment the script stops describing the DOM. Correct
    ///    and slower beats plausible and wrong.
    ///
    /// - Returns: the patch report, or `nil` when the source was already what
    ///   is on screen.
    @discardableResult
    public func apply(source newSource: String) async -> PatchReport? {
        guard let url else { return nil }
        // In the diff view the page is not this document: it is blocks from two
        // parses interleaved. An edit script between the file's old and new
        // sequences does not describe that DOM, and applying one would corrupt
        // it in exactly the quiet way ADR-2 warns about. So a change to the file
        // recomputes the *diff* instead of patching.
        if isShowingDiff {
            source = newSource
            _ = await showDiff()
            return nil
        }
        // M9 drives this at typing cadence, where a second edit routinely
        // arrives while the first patch is still in the page. Only the newest
        // source matters — every one of them is a whole document — so the
        // in-flight patch finishes and the latest waiting source runs next.
        // Without this the two interleave at their `await`s and the older
        // document can land last.
        if isApplying {
            pendingApply = newSource
            return nil
        }
        isApplying = true
        let report = await performApply(url: url, newSource: newSource)
        isApplying = false
        if let next = pendingApply {
            pendingApply = nil
            return await apply(source: next)
        }
        return report
    }

    @discardableResult
    private func performApply(url: URL, newSource: String) async -> PatchReport? {
        guard let old = source else {
            // Nothing has painted yet — there is no old document to diff
            // against, so this is an open rather than a patch.
            present(url, source: newSource)
            return nil
        }
        guard old != newSource else {
            Log.watch.debug(
                "\(url.lastPathComponent, privacy: .public) changed and re-read identical; nothing to patch"
            )
            return nil
        }

        let generation = self.generation
        // The tail has to be in the DOM before a script that names blocks in it
        // can be applied (ADR-2).
        await ensureFullyRendered()
        guard generation == self.generation else { return nil }

        let script: EditScript
        let stamps: String
        let state = Log.signposter.beginInterval("core diff")
        // **Off the main actor.** M5 measured `mark_diff_json` plus the two
        // `*_json` re-stamp calls at 10–15 ms for a 1 MB document, on the main
        // actor, which is fine once per save and is three dropped frames per
        // keystroke. The core is thread-safe by construction (its caches are
        // behind mutexes; ADR-1 forbids ambient state), and this is the same
        // move `startBackgroundFill` already makes for the full render.
        let theme = ThemeController.shared.name
        let computed = await _Concurrency.Task.detached(priority: .userInitiated) {
            () -> Result<(EditScript, String, Double), CoreError> in
            do {
                let measured = try timed { () -> (EditScript, String) in
                    let script = try MarkCore.diff(old: old, new: newSource, theme: theme)
                    // The authority for `data-mk-idx` / `data-mk-start` /
                    // `data-mk-end`, and for a heading's deduplicated `id`,
                    // after the patch. Handed to the page as the core's own
                    // JSON.
                    let tasks = try MarkCore.tasksJSON(source: newSource)
                    let headings = try MarkCore.tocJSON(source: newSource)
                    return (script, "{\"tasks\":\(tasks),\"headings\":\(headings)}")
                }
                return .success((measured.value.0, measured.value.1, measured.seconds))
            } catch let error as CoreError {
                return .failure(error)
            } catch {
                return .failure(CoreError(function: "mark_diff_json", detail: "\(error)"))
            }
        }.value
        Log.signposter.endInterval("core diff", state)
        guard generation == self.generation else { return nil }

        switch computed {
        case .success(let (produced, produtedStamps, seconds)):
            script = produced
            stamps = produtedStamps
            lastDiffSeconds = seconds
            Log.stage(
                "core diff", seconds,
                detail:
                    "kept=\(script.kept) inserted=\(script.inserted) deleted=\(script.deleted) replaced=\(script.replaced) coarse=\(script.coarse)"
            )
        case .failure(let error):
            Log.render.error(
                "diffing \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public); re-rendering"
            )
            return await replaceWholeDocument(url: url, source: newSource)
        }

        if script.coarse {
            // Correct but not minimal. Worth saying out loud: a patch that is
            // always coarse means the diff is doing no better than a re-render.
            Log.render.info(
                "the edit script for \(url.lastPathComponent, privacy: .public) is coarse: the edit distance exceeded the core's budget"
            )
        }

        let result: Any?
        do {
            let state = Log.signposter.beginInterval("patch")
            result = try await call(
                "return window.mark.applyEditScript(script, stamps);",
                arguments: ["script": script.json, "stamps": stamps]
            )
            Log.signposter.endInterval("patch", state)
        } catch {
            Log.render.error(
                "the patch call failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public); re-rendering"
            )
            return await replaceWholeDocument(url: url, source: newSource)
        }
        guard generation == self.generation else { return nil }

        guard let payload = result as? [String: Any], (payload["ok"] as? Bool) == true else {
            let reason = (result as? [String: Any])?["reason"] as? String ?? "no reason given"
            // Not a crash and not a silent stale document: the shell refused
            // because the script stopped describing the DOM, so the whole
            // document is re-rendered from the new source.
            Log.render.error(
                "patch refused for \(url.lastPathComponent, privacy: .public): \(reason, privacy: .public); re-rendering"
            )
            return await replaceWholeDocument(url: url, source: newSource)
        }

        source = newSource
        let report = PatchReport(payload)
        Log.render.info(
            """
            patched \(url.lastPathComponent, privacy: .public): \
            \(script.touchedBlocks) of \(script.newBlocks) blocks, \
            \(report?.tasksStamped ?? -1) task attribute sets re-stamped, \
            anchored=\(report?.anchored ?? false)
            """
        )
        return report
    }

    /// Throw the document away and inject a fresh one, holding the reader's
    /// place.
    ///
    /// The fallback for a patch that could not be applied, and the path M2
    /// always took. Node identity is lost — already-laid-out MathML and diagram
    /// SVG are re-decoded — which is exactly why it is the fallback and not the
    /// mechanism.
    @discardableResult
    private func replaceWholeDocument(url: URL, source newSource: String) async -> PatchReport? {
        do {
            let count = renderer.prefixBlockCount(viewportHeight: viewportHeight)
            let theme = ThemeController.shared.name
            let prefix = try MarkCore.renderHTML(
                source: newSource, prefixBlocks: count, theme: theme)
            let full = try MarkCore.renderHTML(source: newSource, prefixBlocks: 0, theme: theme)
            let tail = ProgressiveRenderer.tail(full: full, prefix: prefix)

            generation += 1
            fillTask?.cancel()
            source = newSource

            let result = try await call(
                "return window.mark.replaceDocument(prefix, tail);",
                arguments: ["prefix": prefix, "tail": tail ?? ""]
            )
            let report = PatchReport(result)
            Log.render.debug(
                "re-rendered \(report?.blocks ?? -1) blocks, anchored=\(report?.anchored ?? false)"
            )
            return report
        } catch {
            show(error: error, for: url)
            return nil
        }
    }

    /// Wait until the shell page is up and the current document's prefix is in
    /// the DOM.
    ///
    /// The IPC path needs this and the UI path does not: `mark open x.md &&
    /// mark goto '#install'` are two processes racing a cold start, and
    /// `window.mark` does not exist for the first ~264 ms of one (research
    /// §2.6). Without this, `goto` would report "anchor not found" for a
    /// heading that is simply not painted yet — a wrong answer, not a slow one.
    ///
    /// Not a timeout: the two things awaited are a page load that is already in
    /// flight and a `Task` that is already running. `mark-cli` owns the
    /// deadline, because it is the one with a user attached to it.
    public func awaitReady() async {
        if !isShellReady {
            await withCheckedContinuation { continuation in
                shellReadyWaiters.append(continuation)
            }
        }
        await presentTask?.value
    }

    /// Install a theme's CSS — the whole of applying a theme to this page.
    ///
    /// One `<style>` element's text. The document is not re-rendered and not
    /// touched: code tokens carry palette *slots*, so their colours come from
    /// the very variables this installs. A caller that changes to a theme with
    /// a different scope map re-renders separately, and
    /// ``ThemeController/apply(named:appearance:)`` is what says whether that is needed.
    ///
    /// Nothing calls this on an **appearance** change, because nothing needs
    /// to: the CSS carries both halves and `prefers-color-scheme` picks.
    @discardableResult
    public func applyTheme(_ theme: ResolvedTheme) -> _Concurrency.Task<ThemeReport?, Never> {
        needsDisplay = true
        return _Concurrency.Task { @MainActor in
            guard self.isShellReady else { return nil }
            let result = try? await self.call(
                "return window.mark.setTheme(css);", arguments: ["css": theme.css])
            return ThemeReport(result)
        }
    }

    /// Re-render the current document, for the two things a theme change
    /// cannot fix with a stylesheet: a diagram's baked-in palette, and — for a
    /// theme with its own `[code]` map, which none of the shipped ones have —
    /// the token classes themselves.
    public func rerenderForTheme() async {
        guard let url, let source else { return }
        await replaceWholeDocument(url: url, source: source)
    }

    /// Whether the painted document holds a Mermaid diagram.
    ///
    /// Asked of the page rather than guessed from the source, because "does
    /// this document contain ```` ```mermaid ```` " and "did a diagram render"
    /// are different questions — `NoDiagram` prose in a mermaid fence is a code
    /// block, and re-rendering for it would be work for nothing.
    public func containsDiagram() async -> Bool {
        let result = try? await call(
            "return document.querySelector('.mk-diagram') !== null;")
        return (result as? Bool) ?? false
    }

    /// How many top-level blocks the page currently has in its DOM.
    ///
    /// Asked of the page rather than inferred from this app's own state
    /// machine, which is the point: `2026-08-26-multiple-windows-and-split-panes`
    /// puts a second document on screen, and "resident, visible and correctly
    /// framed" is not the same as "painted". A pane that lays out perfectly and
    /// renders nothing looks exactly like a broken feature, and only the page
    /// can say which it is.
    public func renderedBlockCount() async -> Int {
        let result = try? await call(
            "return document.getElementById('mk-doc')?.children.length ?? 0;")
        return (result as? Int) ?? 0
    }

    /// Scroll to a heading anchor, reporting whether it exists.
    ///
    /// Routed through `shell.js`'s `scrollToAnchor`, which forces the
    /// background fill first — ADR-2's constraint that nothing may assume the
    /// whole document is in the DOM. `false` here means the document really has
    /// no such heading, which is what makes `mark goto` able to exit non-zero.
    public func scrollToAnchor(_ anchor: String) async throws -> Bool {
        let result = try await call(
            "return window.mark.scrollToAnchor(anchor);", arguments: ["anchor": anchor])
        return (result as? Bool) ?? false
    }

    /// Scroll to a task, reporting whether the page holds it.
    ///
    /// `byteOffset` is the marker's `data-mk-start` and is tried first; `index`
    /// is its `data-mk-idx` and is the fallback. Two identities because they
    /// fail differently, and the reasoning is in
    /// `2026-08-28-tabbed-document-pane`: an index renumbers when the task set
    /// grows, and the pane can be a moment ahead of the rendered page.
    ///
    /// Routed through `shell.js`'s `scrollToTask`, which forces the background
    /// fill first for the reason ``scrollToAnchor(_:)`` does. `false` means the
    /// page really does not hold that task.
    public func scrollToTask(index: Int, byteOffset: Int) async throws -> Bool {
        let result = try await call(
            "return window.mark.scrollToTask(index, start);",
            arguments: ["index": index, "start": byteOffset])
        return (result as? Bool) ?? false
    }

    // MARK: - Finding

    /// Find every occurrence of `text`, highlight them all, and go to one.
    ///
    /// Done in the page rather than through `WKWebView.find`, and the reason is
    /// in ``FindResult``: WebKit's own find highlights one match, cannot say
    /// "3 of 12", and reports only whether it landed on something.
    ///
    /// Forces the background fill first, for ADR-2's reason: a search that only
    /// looked at the painted prefix would find nothing in the second half of a
    /// long document and say so.
    @discardableResult
    public func find(_ text: String, caseSensitive: Bool = false) async -> FindResult {
        guard !text.isEmpty else {
            await clearFind()
            return .empty
        }
        await ensureFullyRendered()
        let result = try? await call(
            "return window.mark.find(needle, { caseSensitive: caseSensitive });",
            arguments: ["needle": text, "caseSensitive": caseSensitive])
        return FindResult(result)
    }

    /// Move to the next or previous match, wrapping in both directions.
    ///
    /// Cheap on purpose: the ranges are already built, so cycling is a repaint
    /// and a scroll rather than another walk of the document.
    @discardableResult
    public func stepFind(forward: Bool) async -> FindResult {
        let result = try? await call(
            "return window.mark.findStep(delta);", arguments: ["delta": forward ? 1 : -1])
        return FindResult(result)
    }

    /// What the page thinks the current search is, without changing it.
    public func findState() async -> FindResult {
        FindResult(try? await call("return window.mark.findState();"))
    }

    /// Drop the highlights and the selection they left behind.
    public func clearFind() async {
        _ = try? await call("return window.mark.clearFind();")
    }

    /// What the reader has selected in the preview — ⌘E's half of Find.
    public func selectedText() async -> String {
        let result = try? await call("return window.mark.selectedText();")
        return (result as? String) ?? ""
    }

    /// Force the background fill to completion.
    ///
    /// ADR-2 constraint: *"Nothing may depend on the whole document being in
    /// the DOM without first awaiting or forcing completion of the background
    /// fill."* This is the one path; in-page search, "scroll to heading", and
    /// print all go through it.
    ///
    /// **Both halves of the fill, in order.** The page's pump is only the
    /// second one: the tail is rendered by the core on ``fillTask`` and handed
    /// to `appendTail` when that finishes, so a bare
    /// `window.mark.ensureFullyRendered()` arriving before the handover drains
    /// a pump that has been given nothing yet — and truthfully reports that it
    /// forced nothing, because there was nothing there. That is how a search of
    /// a freshly opened long document can miss text that is plainly in the
    /// file, and it is the *"awaiting or"* the ADR puts in front of *"forcing"*.
    ///
    /// Costs nothing once the fill has landed, which is every call after the
    /// first second of a document's life — a finished `Task`'s `value` is
    /// already there.
    @discardableResult
    public func ensureFullyRendered() async -> EnsureReport? {
        await fillTask?.value
        let result = try? await call("return window.mark.ensureFullyRendered();")
        return EnsureReport(result)
    }

    /// The three WebKit capability probes ADR-2's design rests on.
    public func probe() async -> ShellProbe? {
        ShellProbe(try? await call("return window.mark.probe();"))
    }

    /// What the page has done to the document since it loaded: injections,
    /// replacements, patches. The M5 "one visible change, not two" gate is a
    /// subtraction over these.
    public func stats() async -> ShellStats? {
        ShellStats(try? await call("return window.mark.stats();"))
    }

    // MARK: - The ADR-2 pipeline

    private func present(_ url: URL) {
        let source: String
        do {
            source = try DocumentSource.read(url)
        } catch {
            show(error: error, for: url)
            return
        }
        present(url, source: source)
    }

    /// The same, for a caller that already has the bytes — the watcher, which
    /// has just read the file and must not read it a second time and possibly
    /// get a different answer.
    private func present(_ url: URL, source: String) {
        generation += 1
        let generation = self.generation
        fillTask?.cancel()
        self.source = source

        let blocks = renderer.prefixBlockCount(viewportHeight: viewportHeight)
        let prefix: String
        let renderSeconds: Double
        do {
            let state = Log.signposter.beginInterval("core render prefix")
            let measured = try timed {
                try MarkCore.renderHTML(
                    source: source, prefixBlocks: blocks, theme: ThemeController.shared.name)
            }
            Log.signposter.endInterval("core render prefix", state)
            prefix = measured.value
            renderSeconds = measured.seconds
        } catch {
            show(error: error, for: url)
            return
        }
        Log.stage(
            "core render prefix", renderSeconds,
            detail: "blocks=\(blocks) bytes=\(prefix.utf8.count)")

        presentTask = _Concurrency.Task { @MainActor in
            let state = Log.signposter.beginInterval("first paint")
            do {
                let injected = try await self.call(
                    "return window.mark.setDocument(html, meta);",
                    arguments: ["html": prefix, "meta": ["path": url.path]]
                )
                Log.signposter.endInterval("first paint", state)
                self.absorb(paintReport: injected)
            } catch {
                Log.signposter.endInterval("first paint", state)
                Log.render.error("injecting the prefix failed: \(String(describing: error))")
                return
            }
            guard generation == self.generation else { return }
            self.onOpen?(url)
            // Attempted before the fill starts, because the common case — a
            // reader within the first ~1.5 viewports — is satisfiable from the
            // prefix alone and should not wait 27 ms for the tail. A deeper
            // offset fails here and is retried once the fill lands.
            await self.restorePendingScroll(generation: generation)
            self.startBackgroundFill(source: source, prefix: prefix, generation: generation)
        }
    }

    // MARK: - The diff against HEAD

    /// Why the diff view is unavailable for this document.
    public enum DiffUnavailable: Error, CustomStringConvertible {
        case notInRepository
        case nothingChanged
        case notDiffable

        public var description: String {
            switch self {
            case .notInRepository: return "not in a git repository"
            case .nothingChanged: return "no changes against HEAD"
            case .notDiffable: return "nothing here that can be diffed"
            }
        }
    }

    /// Swap the page for the rendered diff against `HEAD`, or back again.
    ///
    /// `2026-08-28-git-differences-by-running-git`: the differences are shown as
    /// *rendered markdown*, so what lands in the page is a document — blocks in
    /// order, removed ones struck through in place — rather than patch text.
    ///
    /// Returns the reason when it could not, so the caller can disable a menu
    /// item rather than put up an alert. A reader who pressed ⌘⇧D on a note that
    /// is not in a repository does not need a dialog.
    @discardableResult
    public func toggleDiff() async -> DiffUnavailable? {
        if isShowingDiff {
            await hideDiff()
            return nil
        }
        return await showDiff()
    }

    /// Leave the diff view and put the document back.
    public func hideDiff() async {
        guard isShowingDiff, let url else { return }
        isShowingDiff = false
        onDiffModeChanged?(false)
        // Re-present rather than patch: the diff document and the real one do
        // not share a block sequence — the diff carries blocks from two parses —
        // so an edit script between them would be meaningless.
        if let source { present(url, source: source) } else { present(url) }
        // Awaited, so `hideDiff()` returning means the document is actually
        // back. `present` is fire-and-forget for the open path, where the caller
        // wants the frame; here the caller is a toggle, and a toggle that
        // returns before it has finished toggling is a race every caller would
        // have to know about.
        await presentTask?.value
    }

    /// Show the diff against `HEAD`.
    private func showDiff() async -> DiffUnavailable? {
        guard let url else { return .notInRepository }
        // The buffer when a tab is holding one, so ⌘⇧D on a document being
        // edited shows what the reader is looking at rather than what is saved.
        let working = source ?? (try? DocumentSource.read(url))
        guard let working else { return .notDiffable }

        let path = url.path
        let theme = ThemeController.shared.name
        let detail: DiffDetail
        do {
            // Both hops off the main thread: `git(base:)` forks a process, and
            // the diff renders every changed block.
            detail = try await _Concurrency.Task.detached(priority: .userInitiated) {
                let base = try MarkCore.git(base: path)
                guard base.repo != nil else { throw DiffUnavailable.notInRepository }
                return try MarkCore.diffDetail(
                    old: base.base ?? "", new: working, theme: theme)
            }.value
        } catch let reason as DiffUnavailable {
            return reason
        } catch {
            Log.git.debug("diff view unavailable: \(String(describing: error))")
            return .notDiffable
        }

        guard !detail.isEmpty else { return .nothingChanged }

        isShowingDiff = true
        onDiffModeChanged?(true)
        generation += 1
        fillTask?.cancel()
        do {
            // One injection, not a prefix plus a pump: the diff document is
            // bounded by what actually changed rather than by the document's
            // size, and ⌘⇧D is a deliberate gesture rather than an open.
            let injected = try await call(
                "return window.mark.setDocument(html, meta);",
                arguments: ["html": detail.document, "meta": ["path": url.path]])
            absorb(paintReport: injected)
        } catch {
            Log.render.error("injecting the diff failed: \(String(describing: error))")
            isShowingDiff = false
            onDiffModeChanged?(false)
            return .notDiffable
        }
        Log.git.debug(
            "diff view: +\(detail.diffAdded) −\(detail.diffRemoved) ~\(detail.diffChanged) blocks"
        )
        return nil
    }

    /// Put the reader back where ADR-4's tab layer says they were.
    ///
    /// Routed through `shell.js`'s `restoreScroll`, which falls back to
    /// ADR-2's `ensureFullyRendered` when the offset is past what has been
    /// painted so far. Nothing here assumes the whole document is in the DOM.
    private func restorePendingScroll(generation: Int) async {
        guard pendingScrollRestore > 0, generation == self.generation else { return }
        let target = pendingScrollRestore
        let result = try? await call(
            "return window.mark.restoreScroll(y);", arguments: ["y": target])
        guard let report = result as? [String: Any] else { return }
        scrollOffset = PaintReport.double(report["y"])
        if (report["restored"] as? Bool) == true {
            pendingScrollRestore = 0
            Log.tabs.debug(
                "scroll restored to \(self.scrollOffset) (forced=\((report["forced"] as? Bool) == true))"
            )
        } else {
            Log.tabs.debug("scroll restore to \(target) deferred until the fill lands")
        }
    }

    /// Render the rest of the document off the main thread and hand it to the
    /// pump.
    ///
    /// The C ABI exposes `mark_render_html(source, prefix_blocks)` and nothing
    /// that renders an arbitrary block range, so the tail is derived by taking
    /// the full render and dropping the prefix that is already on screen. The
    /// re-render is close to free: ADR-2's highlight memo cache turns the
    /// second pass over the prefix's code blocks into cache hits.
    private func startBackgroundFill(source: String, prefix: String, generation: Int) {
        let theme = ThemeController.shared.name
        fillTask = _Concurrency.Task.detached(priority: .utility) { [weak self] in
            let state = Log.signposter.beginInterval("core render full")
            let rendered: Result<String, any Error>
            do {
                let measured = try timed {
                    try MarkCore.renderHTML(source: source, prefixBlocks: 0, theme: theme)
                }
                Log.stage("core render full", measured.seconds, detail: "bytes=\(measured.value.utf8.count)")
                rendered = .success(measured.value)
            } catch {
                rendered = .failure(error)
            }
            Log.signposter.endInterval("core render full", state)

            guard !_Concurrency.Task.isCancelled else { return }

            switch rendered {
            case .failure(let error):
                Log.render.error("background render failed: \(String(describing: error))")
            case .success(let full):
                let tail = ProgressiveRenderer.tail(full: full, prefix: prefix)
                await self?.appendTail(tail, whole: full, generation: generation)
            }
        }
    }

    private func appendTail(_ tail: String?, whole: String, generation: Int) async {
        guard generation == self.generation else { return }
        do {
            let state = Log.signposter.beginInterval("background fill")
            let result: Any?
            if let tail {
                result = try await call(
                    "return window.mark.appendTail(html);", arguments: ["html": tail])
            } else {
                // The prefix render was not a byte-prefix of the full render.
                // That should be impossible — blocks render independently and
                // in order — but appending a wrong tail would corrupt the
                // document silently, which is exactly the failure mode ADR-2
                // warns about. Replace instead, and say so loudly.
                Log.render.error(
                    "prefix render was not a prefix of the full render; replacing the document")
                result = try await call(
                    "return window.mark.setDocument(html, {});", arguments: ["html": whole])
            }
            Log.signposter.endInterval("background fill", state)
            if let report = FillReport(result) {
                Log.render.debug(
                    "fill appended \(report.appended) blocks in \(report.fillMs) ms (parse \(report.parseMs) ms)"
                )
            }
            // The second chance for a deep rehydration offset: the whole
            // document is in the DOM now, so an offset past the prefix is
            // finally reachable.
            await restorePendingScroll(generation: generation)
        } catch {
            Log.render.error("background fill failed: \(String(describing: error))")
        }
    }

    private func absorb(paintReport: Any?) {
        guard let report = PaintReport(paintReport) else { return }
        renderer.observe(meanBlockHeight: report.meanBlockHeight)
        if Log.tracing {
            Log.render.info(
                """
                first paint: blocks=\(report.blocks) inject=\(report.injectMs) ms \
                layout=\(report.layoutMs) ms prefixLayout=\(report.prefixLayoutMs) ms
                """
            )
        }
    }

    // MARK: - The colour behind the page

    /// `WebViewFactory` turns the web view's own background off so the shell's
    /// first paint does not flash white, which leaves this view to paint it.
    ///
    /// **This is a layer background, not a `draw(_:)` fill, and the difference
    /// is a two-pane window that shows one document.** A `WKWebView` is
    /// layer-hosted, and the note in ``PreviewPaneView`` records what that does
    /// to a sibling: drawing is composited over the whole of it, *not clipped
    /// to the overlap*. Filling this view's `dirtyRect` therefore painted over
    /// the **other** pane's web view as well as behind this one's page —
    /// invisible with one document on screen, and with two it left the loser
    /// blank while every frame, layer and `visibilityState` said it was there
    /// (`WKWebView.takeSnapshot` returned the page, correctly rendered, from a
    /// pane showing nothing). A layer background cannot leave its own bounds.
    ///
    /// The colour is dynamic — it holds both halves of the theme pair — so
    /// ``updateLayer()`` re-resolves it against the effective appearance rather
    /// than baking one `CGColor` in for the life of the view.
    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = ThemeController.shared.backgroundColor.cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Viewport

    /// The height ADR-2's block count is derived from.
    ///
    /// The fallbacks matter on cold start, where the first open can land before
    /// autolayout has sized anything: a zero height would silently collapse the
    /// prefix to the floor, which looks like a bug in the block-count logic
    /// rather than in the timing.
    public var viewportHeight: Double {
        if bounds.height > 1 { return Double(bounds.height) }
        if let window, window.contentLayoutRect.height > 1 {
            return Double(window.contentLayoutRect.height)
        }
        return Double(NSScreen.main?.visibleFrame.height ?? 900)
    }

    // MARK: - Talking to the page

    /// The only way this file runs JavaScript.
    ///
    /// `callAsyncJavaScript`, never `evaluateJavaScript`: the latter cannot
    /// return a Promise (it fails with "unsupported type"), and every entry
    /// point in `shell.js` that matters is async. Document HTML is passed as an
    /// **argument** rather than interpolated into the script string — a
    /// megabyte of markup in a script body would have to be escaped, re-parsed
    /// as source, and would put the document's own text on the JS parse path.
    @discardableResult
    public func call(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    }

    // MARK: - Errors

    private func show(error: any Error, for url: URL) {
        Log.render.error("\(url.path, privacy: .public): \(String(describing: error))")
        let html = """
            <div class="mk-error" role="alert">
            <h2>Could not open \(Self.escape(url.lastPathComponent))</h2>
            <p>\(Self.escape(String(describing: error)))</p>
            </div>
            """
        _Concurrency.Task { @MainActor in
            _ = try? await call("return window.mark.setDocument(html, {});", arguments: ["html": html])
        }
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: - ScriptBridgeDelegate

    public func scriptBridge(_ bridge: ScriptBridge, didReceive message: ShellMessage) {
        switch message {
        case .ready:
            isShellReady = true
            Log.shell.debug("shell ready")
            // Before the deferred open is replayed, so the first painted frame
            // is already in the right colours rather than flashing the
            // stylesheet's fallback palette.
            applyTheme(ThemeController.shared.active)
            onShellReady?()
            // Before the waiters are released, so anyone in `awaitReady()`
            // sees the deferred open's task rather than a nil one and returns
            // to an empty document.
            if let pending = pendingOpen {
                pendingOpen = nil
                if let source = pendingOpenSource {
                    pendingOpenSource = nil
                    present(pending, source: source)
                } else {
                    present(pending)
                }
            }
            let waiting = shellReadyWaiters
            shellReadyWaiters = []
            for continuation in waiting { continuation.resume() }

        case .toggle(let index, let start, let end, let state, let renderedState):
            write(
                TaskToggle(
                    index: index, span: start..<end, rendered: renderedState, desired: state))

        case .taskMenu(let index, let start, let end, let renderedState, let x, let y):
            presentStateMenu(
                for: TaskToggle(
                    index: index, span: start..<end, rendered: renderedState,
                    desired: renderedState),
                at: CGPoint(x: x, y: y))

        case .scroll(let y, let source):
            scrollOffset = y
            onScroll?(y)
            if let source { onSourceTop?(source) }

        case .link(let href):
            follow(href: href)

        case .metrics(let name, let milliseconds):
            Log.stage(name, milliseconds / 1000)
        }
    }

    // MARK: - Writing

    /// Apply a checkbox click to the file.
    ///
    /// **Nothing here touches the DOM.** The write changes one byte; the file
    /// watcher notices; the resulting block patch is what flips the box on
    /// screen. That is one visible change rather than two, and — more
    /// importantly — what the reader sees afterwards is what is on disk rather
    /// than what the app hoped it put there.
    ///
    /// The two failure paths both end in a re-render, per plan §3: *"if the
    /// byte at the target span is no longer a task marker, refuse and
    /// re-render"*, and, for a write that succeeded against a page rendered
    /// from stale bytes, because an already-correct file changes no byte and so
    /// produces no watcher event to fix the display.
    private func write(_ toggle: TaskToggle) {
        guard let url else { return }
        let state = Log.signposter.beginInterval("checkbox write")
        defer { Log.signposter.endInterval("checkbox write", state) }

        let result: TaskWriteResult
        do {
            let measured = try timed { try taskWriter.apply(toggle, to: url) }
            result = measured.value
            Log.stage("checkbox write", measured.seconds, detail: "task=\(toggle.index)")
        } catch {
            // A refusal is a normal, expected outcome — the file moved under a
            // rendered page — so it is logged with the reason and the document
            // is brought back into agreement with the disk. It is never a
            // guessed byte.
            Log.core.error(
                "\(String(describing: error), privacy: .public)"
            )
            _Concurrency.Task { @MainActor in await self.reload() }
            return
        }

        Log.core.info(
            """
            checkbox \(result.index) in \(url.lastPathComponent, privacy: .public) \
            is now \(result.state.rawValue, privacy: .public); one byte at \(result.byteOffset)
            """
        )
        if result.renderWasStale {
            Log.watch.info(
                "\(url.lastPathComponent, privacy: .public) was rendered from stale bytes; re-reading rather than waiting for a watcher event"
            )
            _Concurrency.Task { @MainActor in await self.reload() }
        }
    }

    // MARK: - The state picker

    /// The five-state menu, from a right-click on a checkbox.
    ///
    /// `2026-08-27-five-task-states` makes every state but done explicit —
    /// *"reaching any other state is explicit: ⌥-click or the context menu in
    /// the app"* — and this is that menu. Picking an item goes down exactly the
    /// same ``TaskToggle`` path a plain click takes, so nothing new writes: the
    /// only thing that differs is which state the toggle asks for.
    ///
    /// The item for the state the marker is *already* in is checked and
    /// disabled rather than hidden, because a menu whose items move depending
    /// on the current state is a menu you cannot learn.
    ///
    /// Built here rather than in the page for the reason ADR-5 gives: the
    /// emitted document gets no JavaScript, and a menu drawn in markup would
    /// need some.
    func presentStateMenu(for toggle: TaskToggle, at pagePoint: CGPoint) {
        guard let webView else { return }
        let menu = stateMenu(for: toggle)
        // The page reports client coordinates, which grow downwards from the
        // top of the viewport; `WKWebView` is an unflipped `NSView`, so y has
        // to be turned over. Getting this wrong puts the menu at the other end
        // of the window, which is the kind of bug a screenshot finds and a
        // test does not.
        let point = NSPoint(x: pagePoint.x, y: webView.bounds.height - pagePoint.y)
        Log.shell.debug(
            "state menu for task \(toggle.index) (\(toggle.rendered.rawValue, privacy: .public))")
        guard let present = presentMenu else {
            menu.popUp(positioning: nil, at: point, in: webView)
            return
        }
        present(menu, point)
    }

    /// The menu itself, built and returned rather than shown.
    ///
    /// Separate from showing it because `NSMenu.popUp` is modal: a test that
    /// exercised the click path with the real presenter in place would stop
    /// the run dead on a menu nobody can dismiss. ``presentMenu`` is the seam
    /// the tests substitute, and this is what they inspect.
    func stateMenu(for toggle: TaskToggle) -> NSMenu {
        let menu = NSMenu(title: "Task state")
        menu.autoenablesItems = false
        for state in TaskState.allCases {
            let item = NSMenuItem(
                title: Self.menuTitle(for: state),
                action: #selector(pickState(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = StatePick(toggle: toggle, state: state)
            item.state = state == toggle.rendered ? .on : .off
            item.isEnabled = state != toggle.rendered
            menu.addItem(item)
        }
        return menu
    }

    /// Show the state menu some other way. `nil` means `NSMenu.popUp`, which
    /// is what the app does; the tests put a capture here instead.
    public var presentMenu: ((NSMenu, NSPoint) -> Void)?

    /// What one menu item carries: the click it came from, and the state it
    /// would ask for. A box rather than two properties on the view, so two
    /// menus racing cannot read each other's target.
    private final class StatePick: NSObject {
        let toggle: TaskToggle
        let state: TaskState
        init(toggle: TaskToggle, state: TaskState) {
            self.toggle = toggle
            self.state = state
        }
    }

    /// The menu's titles. `⌥-click` is named on the cancelled item because a
    /// modifier nobody documents is a modifier nobody finds.
    static func menuTitle(for state: TaskState) -> String {
        switch state {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .cancelled: return "Cancelled (⌥-click)"
        case .blocked: return "Blocked"
        }
    }

    @objc private func pickState(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? StatePick else { return }
        write(
            TaskToggle(
                index: pick.toggle.index,
                span: pick.toggle.span,
                rendered: pick.toggle.rendered,
                desired: pick.state))
    }

    /// Links never navigate the shell page. Local markdown opens in place;
    /// anything else goes to the system handler.
    private func follow(href: String) {
        if let target = URL(string: href), let scheme = target.scheme,
            scheme == "http" || scheme == "https" || scheme == "mailto"
        {
            NSWorkspace.shared.open(target)
            return
        }
        if href.hasPrefix("#") {
            let anchor = String(href.dropFirst())
            _Concurrency.Task { @MainActor in
                _ = try? await scrollToAnchor(anchor)
            }
            return
        }
        guard let base = url else { return }
        let target = URL(fileURLWithPath: href, relativeTo: base.deletingLastPathComponent())
            .standardizedFileURL
        if FileManager.default.fileExists(atPath: target.path) {
            open(target)
        } else {
            Log.render.info("link target does not exist: \(target.path, privacy: .public)")
        }
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // The shell page is loaded once and never navigated. Anything else is
        // either a link `shell.js` failed to intercept or an embedded
        // `<meta refresh>` in a document; neither may replace the shell.
        let url = navigationAction.request.url
        if url?.scheme == ShellAssets.scheme {
            decisionHandler(.allow)
            return
        }
        Log.shell.info("blocked navigation to \(url?.absoluteString ?? "nil", privacy: .public)")
        if let url, let scheme = url.scheme, scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
