import AppKit
import Foundation
import MarkKit
import WebKit

//
// `mark-bench` — ADR-2's gate, in a real window.
//
// The four things this has to settle, from the M2 brief:
//
//   1. ~16 ms to visible for the 1 MB fixture, measured end to end (core
//      render + inject + first paint) and failing above a committed threshold.
//   2. That the first-paint block count moves with viewport height. (The
//      *unit* test for this is `ProgressiveRendererTests`; here it is checked
//      against real laid-out geometry, which is the thing the unit test
//      abstracts away.)
//   3. Class-based vs inline-style syntax highlighting, decided by measurement
//      rather than by argument. ADR-2 defers it to implementation.
//   4. Scroll position surviving a re-render through the manual anchor.
//
// It runs as a real app with a real window, and **activates**, because
// `requestAnimationFrame` is throttled when the window is not frontmost — that
// hung an earlier research harness. Every number below therefore requires the
// window to be frontmost; running this while switching away invalidates it.
//
// What "first paint" means here, stated plainly because the honest answer is
// not "the pixels hit the glass": WebKit gives no API for that. What is
// measured is core render + `innerHTML` + **forced layout**, the layout being
// forced by reading laid-out geometry from JavaScript. Two variants are
// reported:
//
//   * `layout` reads only the *first* block's `getBoundingClientRect()`. This
//     is the measurement research §2.5 settled on, because it lets subtrees
//     that WebKit is entitled to skip legitimately stay skipped.
//   * `prefixLayout` forces layout across the entire injected prefix. Since the
//     prefix is sized to ~1.5 viewports, this is the closer proxy for "what the
//     reader can see", and it is the one the gate is applied to — the stricter
//     of the two.
//
// A `takeSnapshot`-based number is also reported for reference; it is the only
// thing here that provably involves the compositor, and it is dominated by IPC.
//

// MARK: - Thresholds

/// Plan §5's committed ceiling for first paint. Generous against ADR-2's ~16 ms
/// target so it does not flake on other hardware, tight enough that a change
/// turning prefix-then-fill back into naive injection (124 ms) fails loudly.
let firstPaintLimitMs = 25.0

/// ADR-2's headline figure, reported alongside the gate.
let adrTargetMs = 16.0

/// ADR-4's memory gate: *"24 tabs at ≤110 MB RSS"* (plan §2 M3). Research
/// §2.7's follow-up measured 102.0 MB on this machine with 256 KB documents;
/// the 8 MB of headroom is the plan's, not a fudge factor added here.
/// Measured floor for the app with no resident web view
/// (`2026-08-24-tab-residency-and-memory-model`).
let tabMemoryBaselineMB = 100.0
/// Measured cost of one resident `WKWebView`, i.e. one WebContent process.
let tabMemoryPerResidentMB = 52.0
/// Kept only to colour the sweep table; the gate uses the formula above.
let tabMemoryLimitMB = 110.0

/// ADR-4's switch gate: *"tab switch ≤1 ms"*. Research measured 0.05 ms median
/// and 0.23 ms worst for show/hide of a resident view, so this is 20× headroom
/// — tight enough that re-injecting the document on switch (8–9 ms) fails
/// loudly, which is exactly the regression the resident design exists to
/// prevent.
let tabSwitchLimitMs = 1.0

// MARK: - Reporting

struct Stat {
    var samples: [Double] = []
    mutating func add(_ value: Double) { samples.append(value) }
    var best: Double { samples.min() ?? .nan }
    var median: Double {
        guard !samples.isEmpty else { return .nan }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }
    var worst: Double { samples.max() ?? .nan }

    /// The 95th percentile. M9's typing gate is about the *tail* — a median
    /// keystroke that is fast and a p95 that is not is exactly what "it feels
    /// laggy" means, and a median cannot see it.
    var p95: Double {
        guard !samples.isEmpty else { return .nan }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))
        return sorted[index]
    }

    var max: Double { worst }
}

func row(_ label: String, _ stat: Stat, unit: String = "ms") {
    print(
        String(
            format: "  %-26s best %8.3f   median %8.3f   worst %8.3f %@",
            (label as NSString).utf8String!, stat.best, stat.median, stat.worst, unit))
}

func line(_ label: String, _ value: String) {
    print(String(format: "  %-26s %@", (label as NSString).utf8String!, value))
}

var failures: [String] = []

@MainActor
func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok    \(message)")
    } else {
        print("  FAIL  \(message)")
        failures.append(message)
    }
}

// MARK: - Harness

@MainActor
final class Harness {
    let window: NSWindow
    let documentView: DocumentView
    let corpus: URL
    let source: String

    init(corpus: URL) throws {
        self.corpus = corpus
        self.source = try String(contentsOf: corpus, encoding: .utf8)

        documentView = DocumentView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // ADR-4's constraint applies to every window we make, not just the
        // app's: AppKit must never add a native tab bar.
        window.tabbingMode = .disallowed
        window.title = "mark-bench"
        window.contentView = documentView
        window.center()
    }

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            documentView.onShellReady = { continuation.resume() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        // One frame, so the web view has a real laid-out size before anything
        // derives a block count from it.
        try? await _Concurrency.Task.sleep(for: .milliseconds(200))
    }

    var viewportHeight: Double { documentView.viewportHeight }

    @discardableResult
    func js(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
        do {
            return try await documentView.call(body, arguments: arguments)
        } catch {
            print("  JS error: \(error)")
            return nil
        }
    }

    func clear() async {
        await js("return window.mark.setDocument(html, {});", ["html": ""])
    }
}

// MARK: - Measurements

/// Install or remove one `<style>` element by id.
@MainActor
func installStyle(_ harness: Harness, id: String, css: String?) async {
    guard let css else {
        await harness.js("var s = document.getElementById(id); if (s) s.remove(); return true;", ["id": id])
        return
    }
    await harness.js(
        """
        var style = document.getElementById(id);
        if (!style) { style = document.createElement('style'); style.id = id;
          document.head.appendChild(style); }
        style.textContent = css;
        return true;
        """, ["id": id, "css": css])
}

/// M7's first two gates, measured rather than argued.
///
///   1. *"Switching macOS appearance re-colours the document with no re-render
///      and no flash."* The document counter must not move, the theme counter
///      must not move, and the colours the page resolves must change — which
///      together mean the only thing that happened was WebKit re-resolving
///      variables.
///   2. *"`mark theme dracula` applies to every open tab."* One `<style>`
///      assignment per tab, with the document counter still not moving.
@MainActor
func measureTheming(_ harness: Harness) async {
    print("Theming (M7's gates — an appearance switch must cost nothing):")
    let view = harness.documentView
    guard let dracula = try? MarkCore.theme(named: "dracula"),
        let gruvbox = try? MarkCore.theme(named: "gruvbox-dark")
    else {
        require(false, "the shipped themes resolve")
        return
    }

    // A document with a code block, a diagram, and some math in it, so the
    // colours being asserted on are the ones a reader actually looks at.
    let source = """
        # Themed

        Some prose with a [link](https://example.com) and `inline code`.

        ```rust
        fn main() { let x: u32 = 1; println!("{x}"); }
        ```

        ```mermaid
        flowchart TD
          A[Start] --> B{Choice}
          B -->|yes| C[Done]
        ```

        Math: $e^{i\\pi} + 1 = 0$

        - [ ] a task
        """
    guard let html = try? MarkCore.renderHTML(source: source, prefixBlocks: 0, theme: "gruvbox-dark")
    else {
        require(false, "rendering the themed fixture")
        return
    }
    await harness.js("return window.mark.setDocument(html, {});", ["html": html])
    _ = ThemeReport(await harness.js("return window.mark.setTheme(css);", ["css": gruvbox.css]))

    // --- gate 1: the appearance switch ------------------------------------
    let before = ShellStats(await harness.js("return window.mark.stats();"))
    var light: ThemeReport?
    var dark: ThemeReport?
    for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
        let started = DispatchTime.now().uptimeNanoseconds
        view.appearance = appearance
        view.webView.appearance = appearance
        // One frame for WebKit to notice and repaint. Nothing is *scheduled*
        // by us; this is only waiting for the compositor.
        try? await _Concurrency.Task.sleep(for: .milliseconds(120))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let colors = await harness.js("return window.mark.resolvedColors('.mk-blk');")
        let report = ThemeReport(
            await harness.js("return window.mark.setTheme(css);", ["css": gruvbox.css]))
        if (report?.dark ?? false) { dark = report } else { light = report }
        line(
            "appearance \(appearance?.name.rawValue ?? "?")",
            String(
                format: "resolved %@ on %@ in %.1f ms (wall clock, including the sleep)",
                ((colors as? [String: Any])?["color"] as? String) ?? "?",
                ((colors as? [String: Any])?["background"] as? String) ?? "?",
                elapsed)
        )
    }
    let after = ShellStats(await harness.js("return window.mark.stats();"))
    line("documents injected", "\(before?.documents ?? -1) -> \(after?.documents ?? -1)")
    line("themes installed", "\(before?.themes ?? -1) -> \(after?.themes ?? -1)")
    require(
        before?.documents == after?.documents,
        "an appearance switch injected no document (no re-render)")
    require(
        before?.themes == after?.themes,
        "an appearance switch installed no theme CSS (no IPC needed)")
    if let light, let dark {
        line("light background", light.background)
        line("dark background", dark.background)
        require(
            light.background != dark.background,
            "the two appearances resolve different colours")
        require(
            light.foreground != dark.foreground,
            "the two appearances resolve different text colours")
    } else {
        require(false, "both appearances were observed")
    }

    // --- gate 2: switching themes -----------------------------------------
    let started = DispatchTime.now().uptimeNanoseconds
    let applied = ThemeReport(
        await harness.js("return window.mark.setTheme(css);", ["css": dracula.css]))
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    line("mark theme dracula", String(format: "%.3f ms (one <style> assignment)", elapsed))
    line("resolved background", applied?.background ?? "?")
    require(applied?.applied == true, "the theme CSS was installed")
    require(
        applied?.background.replacingOccurrences(of: " ", with: "") == "#282a36",
        "dracula's background reached the page (got \(applied?.background ?? "nothing"))")
    let afterTheme = ShellStats(await harness.js("return window.mark.stats();"))
    require(
        afterTheme?.documents == after?.documents,
        "switching themes re-rendered nothing")
    require(
        dracula.codeStamp == gruvbox.codeStamp,
        "two shipped themes share a scope map, so no re-render is needed")

    // --- gate 5: the diagram, in both appearances -------------------------
    //
    // Back to gruvbox, which is a *pair*: the document was rendered against it,
    // so its two diagram copies are gruvbox-light and gruvbox-dark, and the two
    // snapshots below are the honest before/after of an appearance switch.
    // (Dracula above is unpaired — one theme for both appearances — which is
    // why applying it left a gruvbox-rendered diagram in place. In the app that
    // case re-renders the tab; here it is left visible on purpose, because it
    // is the one thing a `<style>` swap genuinely cannot fix.)
    _ = ThemeReport(await harness.js("return window.mark.setTheme(css);", ["css": gruvbox.css]))
    for (name, appearance) in [
        ("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua)),
    ] {
        view.appearance = appearance
        view.webView.appearance = appearance
        try? await _Concurrency.Task.sleep(for: .milliseconds(150))
        let visible = await harness.js(
            """
            var wrapper = document.querySelector('.mk-diagram');
            if (!wrapper) return null;
            var light = wrapper.querySelector('.mk-appear-light');
            var dark = wrapper.querySelector('.mk-appear-dark');
            var shown = null;
            if (light && getComputedStyle(light).display !== 'none') shown = 'light';
            if (dark && getComputedStyle(dark).display !== 'none') shown = 'dark';
            var svg = wrapper.querySelector('.mk-appear-' + (shown || 'light') + ' svg');
            var math = document.querySelector('math');
            return {
              shown: shown,
              svgWidth: svg ? svg.getBoundingClientRect().width : 0,
              svgHeight: svg ? svg.getBoundingClientRect().height : 0,
              mathColor: math ? getComputedStyle(math).color : '',
              mathWidth: math ? math.getBoundingClientRect().width : 0
            };
            """)
        guard let visible = visible as? [String: Any] else {
            require(false, "the diagram is in the document")
            continue
        }
        line(
            "\(name) diagram",
            String(
                format: "%@ copy shown, %.0fx%.0f pt; MathML %@ at %.0f pt wide",
                (visible["shown"] as? String) ?? "no",
                PaintReport.double(visible["svgWidth"]),
                PaintReport.double(visible["svgHeight"]),
                (visible["mathColor"] as? String) ?? "?",
                PaintReport.double(visible["mathWidth"]))
        )
        require(
            (visible["shown"] as? String) == name,
            "the \(name) copy of the diagram is the visible one")
        require(
            PaintReport.double(visible["svgWidth"]) > 1,
            "the visible diagram has a real box")
        require(
            PaintReport.double(visible["mathWidth"]) > 1,
            "the MathML has a real box")
        await snapshotDocument(view, named: "theme-\(name).png")
    }
    view.appearance = nil
    view.webView.appearance = nil
    print("")
}

/// Write a PNG of the document as WebKit composited it.
///
/// `WKWebView.takeSnapshot` goes through the compositor and works with the
/// screen locked, which `screencapture` does not — it returns an all-black
/// frame on this machine. `MARK_BENCH_SNAPSHOT_DIR` selects the directory.
@MainActor
func snapshotDocument(_ view: DocumentView, named name: String) async {
    let directory =
        ProcessInfo.processInfo.environment["MARK_BENCH_SNAPSHOT_DIR"] ?? "target"
    let image: NSImage? = await withCheckedContinuation { continuation in
        view.webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
    }
    guard let image, let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        line("snapshot", "\(name): takeSnapshot returned nothing")
        return
    }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        line("snapshot", "\(url.path) (\(Int(image.size.width))x\(Int(image.size.height)))")
    } catch {
        line("snapshot", "\(name): \(error)")
    }
}

@MainActor
func measureFirstPaint(_ harness: Harness, runs: Int) async -> (Stat, Stat, Stat, Stat, Stat, Int) {
    var core = Stat(), inject = Stat(), layout = Stat(), prefixLayout = Stat(), total = Stat()
    var blocks = 0
    let renderer = ProgressiveRenderer()

    for _ in 0..<runs {
        await harness.clear()
        let count = renderer.prefixBlockCount(viewportHeight: harness.viewportHeight)

        let started = DispatchTime.now().uptimeNanoseconds
        guard
            let prefix = try? MarkCore.renderHTML(source: harness.source, prefixBlocks: count)
        else {
            print("  core render failed: \(MarkCore.lastError() ?? "no message")")
            break
        }
        let rendered = DispatchTime.now().uptimeNanoseconds
        let report = PaintReport(
            await harness.js(
                "return window.mark.setDocument(html, meta);",
                ["html": prefix, "meta": ["path": harness.corpus.path]]))
        let finished = DispatchTime.now().uptimeNanoseconds

        guard let report else { continue }
        core.add(Double(rendered - started) / 1e6)
        inject.add(report.injectMs)
        layout.add(report.layoutMs)
        prefixLayout.add(report.prefixLayoutMs)
        total.add(Double(finished - started) / 1e6)
        blocks = report.blocks
        renderer.observe(meanBlockHeight: report.meanBlockHeight)
    }
    return (core, inject, layout, prefixLayout, total, blocks)
}

@MainActor
func measureNaive(_ harness: Harness, runs: Int) async -> (Stat, Stat) {
    var core = Stat(), total = Stat()
    for _ in 0..<runs {
        await harness.clear()
        let started = DispatchTime.now().uptimeNanoseconds
        guard let full = try? MarkCore.renderHTML(source: harness.source, prefixBlocks: 0) else {
            break
        }
        let rendered = DispatchTime.now().uptimeNanoseconds
        _ = PaintReport(
            await harness.js("return window.mark.setDocument(html, {});", ["html": full]))
        let finished = DispatchTime.now().uptimeNanoseconds
        core.add(Double(rendered - started) / 1e6)
        total.add(Double(finished - started) / 1e6)
    }
    return (core, total)
}

/// Inject a prepared HTML fragment and force layout of the whole thing.
///
/// Used for the class-vs-inline comparison, where the two documents are
/// byte-identical outside their code blocks.
@MainActor
func measureFragment(_ harness: Harness, html: String, runs: Int) async -> (Stat, Stat) {
    var inject = Stat(), layout = Stat()
    for _ in 0..<runs {
        await harness.clear()
        guard
            let report = PaintReport(
                await harness.js("return window.mark.setDocument(html, {});", ["html": html]))
        else { continue }
        inject.add(report.injectMs)
        layout.add(report.prefixLayoutMs)
    }
    return (inject, layout)
}

// MARK: - Main

@MainActor
func run() async -> Int32 {
    let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    let corpus = URL(
        fileURLWithPath: arguments.first ?? "bench/corpus/1mb.md"
    ).standardizedFileURL

    guard FileManager.default.fileExists(atPath: corpus.path) else {
        print("mark-bench: \(corpus.path) does not exist — run `python3 scripts/gen-corpus.py`")
        return 2
    }

    // ADR-4 first, and in its own window, because it is the only section here
    // that measures *memory*. Running it after the ADR-2 harness would charge
    // the 24-tab total for a 25th web view holding a 1 MB document, and the
    // gate would fail for a reason that has nothing to do with tabs.
    await runTabGates(corpus: corpus)

    let harness: Harness
    do {
        harness = try Harness(corpus: corpus)
    } catch {
        print("mark-bench: \(error)")
        return 2
    }
    await harness.start()

    let bytes = harness.source.utf8.count
    print("mark-bench — \(corpus.lastPathComponent), \(bytes) bytes")
    print("core \((try? MarkCore.version()) ?? "?"), viewport \(Int(harness.viewportHeight)) pt")
    print("")
    print("Note: WKWebView clamps `performance.now()` to 1 ms, so every number")
    print("labelled \"(JS)\" below is quantised to whole milliseconds. The TOTAL")
    print("rows are Swift-side `DispatchTime` wall clock and are not; the gate is")
    print("applied to those.")
    print("")

    // ---------------------------------------------------------------- probe
    print("WebKit capability probe (ADR-2 Context — these are load-bearing):")
    let probe = await harness.documentView.probe()
    require(
        probe?.requestIdleCallback == false,
        "requestIdleCallback is absent — the fill pump must stay on setTimeout")
    require(
        probe?.overflowAnchor == false,
        "overflow-anchor is unsupported — scroll anchoring must stay manual")
    require(
        probe?.contentVisibility == true,
        "content-visibility is supported and deliberately unused (measured 1.8x worse)")
    print("")

    // ------------------------------------------------------- viewport tunable
    print("First-paint block count is derived from viewport height, not hardcoded:")
    let heights = [400.0, 900.0, 1600.0, 2400.0]
    let counts = heights.map {
        ProgressiveRenderer.prefixBlockCount(
            viewportHeight: $0, blockHeight: ProgressiveRenderer.initialBlockHeight)
    }
    for (height, count) in zip(heights, counts) {
        line("viewport \(Int(height)) pt", "\(count) blocks")
    }
    require(Set(counts).count > 1, "the count changes with viewport height")
    require(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 }, "it is monotonic in height")
    print("")

    // ------------------------------------------------------------ first paint
    print("Progressive first paint (prefix, then fill) — the ADR-2 gate:")
    let runs = 8
    let (core, inject, layout, prefixLayout, total, blocks) = await measureFirstPaint(
        harness, runs: runs)
    line("prefix blocks", "\(blocks)")
    row("core render (prefix)", core)
    row("innerHTML (JS)", inject)
    row("layout, first block", layout)
    row("layout, whole prefix", prefixLayout)
    row("TOTAL core+inject+layout", total)
    print("")

    // ------------------------------------------------------------- background
    print("Background fill (setTimeout pump — requestIdleCallback does not exist):")
    if let full = try? MarkCore.renderHTML(source: harness.source, prefixBlocks: 0),
        let prefix = try? MarkCore.renderHTML(
            source: harness.source,
            prefixBlocks: ProgressiveRenderer.prefixBlockCount(
                viewportHeight: harness.viewportHeight,
                blockHeight: ProgressiveRenderer.initialBlockHeight)),
        let tail = ProgressiveRenderer.tail(full: full, prefix: prefix)
    {
        require(
            !tail.isEmpty,
            "the prefix render is a byte-prefix of the full render (tail is derivable)")
        let started = DispatchTime.now().uptimeNanoseconds
        let report = FillReport(await harness.js("return window.mark.appendTail(html);", ["html": tail]))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        line("tail bytes", "\(tail.utf8.count)")
        line("detached HTML parse", String(format: "%.3f ms", report?.parseMs ?? .nan))
        line("pump wall clock", String(format: "%.3f ms", report?.fillMs ?? .nan))
        line("blocks in document", "\(report?.blocks ?? -1)")
        line("swift-side round trip", String(format: "%.3f ms", elapsed))
    } else {
        require(false, "tail derivation: prefix render was not a prefix of the full render")
    }
    print("")

    // ------------------------------------------------------------------ naive
    print("Naive whole-document innerHTML, for the ratio ADR-2 is built on:")
    let (naiveCore, naiveTotal) = await measureNaive(harness, runs: 4)
    row("core render (full)", naiveCore)
    row("TOTAL core+inject+layout", naiveTotal)
    line(
        "progressive speedup",
        String(format: "%.1fx", naiveTotal.best / total.best))
    print("")

    // ------------------------------------------------------------- snapshot
    print("takeSnapshot round trip (the only number that touches the compositor):")
    await harness.clear()
    if let prefix = try? MarkCore.renderHTML(
        source: harness.source,
        prefixBlocks: ProgressiveRenderer.prefixBlockCount(
            viewportHeight: harness.viewportHeight,
            blockHeight: ProgressiveRenderer.initialBlockHeight))
    {
        let started = DispatchTime.now().uptimeNanoseconds
        _ = await harness.js("return window.mark.setDocument(html, {});", ["html": prefix])
        let snapshot: NSImage? = await withCheckedContinuation { continuation in
            harness.documentView.webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        line("inject + snapshot", String(format: "%.3f ms", elapsed))
        line("snapshot size", snapshot.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")
        if let snapshot, let out = ProcessInfo.processInfo.environment["MARK_BENCH_SNAPSHOT"] {
            if let tiff = snapshot.tiffRepresentation,
                let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            {
                try? png.write(to: URL(fileURLWithPath: out))
                line("snapshot written", out)
            }
        }
    }
    print("")

    // ------------------------------------------ highlighting format, three ways
    print("Highlighting markup: slot classes vs inline styles vs scope classes")
    print("(ADR-2 deferred this; M2 measured two of the three, M7 added the first):")
    let formatDir = corpus.deletingLastPathComponent()
    let slotURL = formatDir.appendingPathComponent("format.slot.html")
    let slotCSSURL = formatDir.appendingPathComponent("format.slot.css")
    let inlineURL = formatDir.appendingPathComponent("format.inline.html")
    let classedURL = formatDir.appendingPathComponent("format.classed.html")
    let cssURL = formatDir.appendingPathComponent("format.classed.css")
    if let slotHTML = try? String(contentsOf: slotURL, encoding: .utf8),
        let slotCSS = try? String(contentsOf: slotCSSURL, encoding: .utf8),
        let inlineHTML = try? String(contentsOf: inlineURL, encoding: .utf8),
        let classedHTML = try? String(contentsOf: classedURL, encoding: .utf8),
        let css = try? String(contentsOf: cssURL, encoding: .utf8)
    {
        // Each variant is only meaningful with its own stylesheet installed —
        // without it the selectors cost nothing to match.
        await installStyle(harness, id: "mk-fmt", css: slotCSS + css)

        let (slotInject, slotLayout) = await measureFragment(harness, html: slotHTML, runs: 4)
        let (inlineInject, inlineLayout) = await measureFragment(
            harness, html: inlineHTML, runs: 4)
        let (classedInject, classedLayout) = await measureFragment(
            harness, html: classedHTML, runs: 4)

        line("slot HTML bytes", "\(slotHTML.utf8.count)")
        line("inline HTML bytes", "\(inlineHTML.utf8.count)")
        line("classed HTML bytes", "\(classedHTML.utf8.count)")
        row("slot: innerHTML", slotInject)
        row("slot: layout", slotLayout)
        row("inline: innerHTML", inlineInject)
        row("inline: layout", inlineLayout)
        row("classed: innerHTML", classedInject)
        row("classed: layout", classedLayout)
        let slotTotal = slotInject.best + slotLayout.best
        let inlineTotal = inlineInject.best + inlineLayout.best
        let classedTotal = classedInject.best + classedLayout.best
        line("slot / inline size", String(format: "%.2fx", Double(slotHTML.utf8.count) / Double(inlineHTML.utf8.count)))
        line("classed / inline size", String(format: "%.2fx", Double(classedHTML.utf8.count) / Double(inlineHTML.utf8.count)))
        line("slot / inline time", String(format: "%.2fx", slotTotal / inlineTotal))
        line("classed / inline time", String(format: "%.2fx", classedTotal / inlineTotal))
        // The decision M7 acted on, restated as a check so it cannot rot into
        // folklore: the format the core emits must not be the slowest one.
        require(
            slotTotal <= classedTotal,
            String(
                format: "slot classes (%.1f ms) are not slower than scope classes (%.1f ms)",
                slotTotal, classedTotal))
        line(
            "decision",
            slotTotal <= inlineTotal
                ? "slot classes — smaller than inline AND re-theme for free"
                : "slot classes cost \(String(format: "%.2fx", slotTotal / inlineTotal)) of inline; free re-theming is why")
        await installStyle(harness, id: "mk-fmt", css: nil)
    } else {
        line(
            "skipped",
            "run `cd bench/highlight-format && cargo run --release -- ../corpus/1mb.md ../corpus/format`"
        )
    }
    print("")

    // ------------------------------------------------------------- theming
    await measureTheming(harness)

    // -------------------------------------------------------- scroll anchoring
    print("Scroll position survives a re-render (manual anchor, one rAF):")
    harness.documentView.open(corpus)
    try? await _Concurrency.Task.sleep(for: .milliseconds(1500))
    await harness.documentView.ensureFullyRendered()

    for target in [420.0, 9000.0] {
        _ = await harness.js("return window.mark.scrollTo(y);", ["y": target])
        let before = PaintReport.double(await harness.js("return window.pageYOffset;"))
        let report = await harness.documentView.reload()
        let after = PaintReport.double(await harness.js("return window.pageYOffset;"))
        let drift = abs(after - before)
        line(
            "target \(Int(target)) pt",
            String(
                format: "before %.0f  after %.0f  drift %.1f px  anchored=%@  syncTail=%@",
                before, after, drift,
                (report?.anchored ?? false) ? "yes" : "no",
                (report?.synchronousTail ?? false) ? "yes" : "no"))
        require(drift <= 2.0, "scroll drift at \(Int(target)) pt is <= 2 px (was \(drift))")
        await harness.documentView.ensureFullyRendered()
    }
    print("")

    // ----------------------------------------------------------------- M5
    // Last, and in its own window: it opens and closes documents, writes files,
    // and waits on FSEvents, none of which should be charged to the numbers
    // above.
    await runWatchGates(corpus: corpus)

    // ----------------------------------------------------------------- M8
    // The sidebar's own window, after everything else: it navigates the
    // developer's real tree and writes 400 fixture files, neither of which
    // should be charged to the numbers above.
    await runSidebarGates()

    // ----------------------------------------------------------------- M9
    // Last, because it types for a minute. Its own window, its own directory,
    // and nothing above is charged for it.
    await runEditorGates(corpus: corpus)

    // -------------------------------------------------------------- the gate
    print("Gate:")
    let gate = prefixLayout.samples.isEmpty ? total.best : total.best
    line("ADR-2 target", String(format: "%.3f ms", adrTargetMs))
    line("committed limit", String(format: "%.3f ms", firstPaintLimitMs))
    line("measured (best)", String(format: "%.3f ms", gate))
    line("measured (median)", String(format: "%.3f ms", total.median))
    require(
        total.median <= firstPaintLimitMs,
        "median time to visible \(String(format: "%.3f", total.median)) ms <= \(firstPaintLimitMs) ms"
    )
    print("")

    if failures.isEmpty {
        print("mark-bench: all checks passed")
        return 0
    }
    print("mark-bench: \(failures.count) check(s) failed")
    for failure in failures { print("  - \(failure)") }
    return 1
}

// A real NSApplication, because a WKWebView outside a window on screen does not
// lay out, and rAF does not fire when the app is not frontmost.
let application = NSApplication.shared
application.setActivationPolicy(.regular)

_Concurrency.Task { @MainActor in
    let status = await run()
    exit(status)
}

application.run()
