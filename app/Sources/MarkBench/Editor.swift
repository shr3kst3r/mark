import AppKit
import Foundation
import MarkKit
import WebKit

//
// M9's gates, in a real window: three panes, a real `NSTextView`, a real
// `WKWebView`, a real file watcher, and a real clock.
//
// The unit suite covers the state machine — dirty/clean, conflict, suppression,
// eviction — and covers it in milliseconds. What it cannot cover is **time and
// geometry**: whether typing continuously for a minute into a megabyte stays
// interactive, whether the caret stays put when an external save lands
// underneath it, and what the three panes actually look like. That is this
// file.
//
//   1. 60 s of continuous typing in a 1 MB document, with a vim-style external
//      save landing partway through: no lost edits, no cursor jumps, no
//      truncation, and a conflict prompt that is raised exactly once
//   2. typing latency, p50/p95/max, against a committed limit
//   3. the cost M5 flagged: `mark_diff_json` + the two `*_json` re-stamp calls
//      on a 1 MB document, measured on the main actor and off it
//   4. self-write suppression across the whole run: our own autosaves must
//      produce no watcher events at all
//   5. a snapshot of the three-pane layout, composited from a native
//      `cacheDisplay` and a `WKWebView.takeSnapshot`
//

/// How long the typing gate runs. 60 s is the ADR's number; the override exists
/// so a developer iterating on this file does not wait a minute per run.
let editorTypingSeconds: Double = {
    guard let raw = ProcessInfo.processInfo.environment["MARK_BENCH_EDITOR_SECONDS"],
        let value = Double(raw), value > 0
    else { return 60 }
    return value
}()

/// One keystroke every 60 ms — about 16 characters a second, which is a fast
/// touch typist and therefore the case worth measuring.
let editorKeystrokeInterval: Duration = .milliseconds(60)

/// The committed ceiling for a keystroke's main-thread cost, in milliseconds.
///
/// A 60 Hz frame is 16.7 ms, and the limit sits below it: a keystroke that
/// costs less than a frame cannot be the reason typing feels behind. Measured
/// on this machine over 30 s of continuous typing in the 1 MB corpus: median
/// 3.16 ms, p95 7.67 ms, worst 11.86 ms. The limit is set at 12 ms rather than
/// at the measurement so a busy CI machine does not flake, and it still catches
/// every regression this milestone has actually hit — the whole-document
/// snapshot per keystroke (86–108 ms), `NSTextStorage.mutableString` (8.7 ms),
/// and the diff back on the main actor (10–15 ms of *median*).
///
/// **The worst-case limit is deliberately loose**, at ten frames. Repeated runs
/// on an otherwise-busy machine produce a single-keystroke outlier of 50–115 ms
/// while the median stays between 1.5 and 6.9 ms — one scheduler hiccup, not a
/// regression, and gating on it would produce a flaky build rather than a
/// signal. The p95 above is the number that moves when something is actually
/// wrong.
let typingLatencyP95LimitMs = 12.0
let typingLatencyMaxLimitMs = 150.0

@MainActor
final class EditorBenchHarness {

    let controller: MainWindowController
    let directory: URL
    let presenter: ScriptedConflictPresenter

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "mark-bench-editor-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = MainWindowController(
            root: directory,
            session: Session(
                url: directory.appendingPathComponent("session.json"), debounce: 0.5)
        )
        controller.window?.setContentSize(NSSize(width: 1400, height: 900))
        controller.window?.center()
        presenter = ScriptedConflictPresenter()
        controller.conflicts.use(presenter: presenter)
    }

    deinit {
        let directory = self.directory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func show() { controller.showWindow(activating: true) }

    func close() {
        controller.tabs.closeAll()
        controller.window?.orderOut(nil)
        controller.window?.close()
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    @discardableResult
    func write(_ source: String, to name: String) throws -> URL {
        let url = self.url(name)
        try source.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// The way vim saves: temp file, then `rename(2)` over the target.
    func saveAtomically(_ source: String, to name: String) throws {
        let temp = directory.appendingPathComponent(".\(name).swp-\(UUID().uuidString)")
        try source.write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url(name), withItemAt: temp)
    }

    func open(_ name: String) async -> DocumentTab? {
        controller.open(url(name))
        let tab = controller.tabs.tab(for: url(name))
        await tab?.documentView?.awaitReady()
        await tab?.documentView?.ensureFullyRendered()
        await settle(milliseconds: 200)
        return tab
    }

    func settle(milliseconds: Int) async {
        try? await _Concurrency.Task.sleep(for: .milliseconds(milliseconds))
    }

    func contents(of name: String) -> String {
        (try? String(contentsOf: url(name), encoding: .utf8)) ?? ""
    }
}

/// Answers conflict prompts from a script, and counts them.
///
/// A modal in a benchmark would hang the run; what is being measured is the
/// state machine's behaviour, not `NSAlert`'s.
@MainActor
final class ScriptedConflictPresenter: ConflictPresenter {
    var answer: ConflictChoice = .keepMine
    private(set) var prompts = 0
    private(set) var diffs = 0
    private(set) var promptedFiles: [String] = []

    func presentConflict(
        _ conflict: Conflict, for url: URL, answer handler: @escaping (ConflictChoice) -> Void
    ) {
        prompts += 1
        promptedFiles.append(url.lastPathComponent)
        handler(answer)
    }

    func presentDiff(_ diff: ConflictDiff, for url: URL, done: @escaping () -> Void) {
        diffs += 1
        done()
    }
}

// MARK: - The measurements

/// M5's number, re-measured: the core work behind one preview patch.
@MainActor
func measureDiffCost(_ source: String) {
    print("The cost M5 flagged — one preview patch's core work on a 1 MB document:")
    let edited = source.replacingOccurrences(
        of: "\n", with: "\nan edit that moves every byte below it\n", options: [], range:
            source.startIndex..<source.index(source.startIndex, offsetBy: 200))

    var onMain = Stat()
    for _ in 0..<5 {
        let measured = try? timed { () -> Int in
            let script = try MarkCore.diff(old: source, new: edited)
            let tasks = try MarkCore.tasksJSON(source: edited)
            let headings = try MarkCore.tocJSON(source: edited)
            return script.json.count + tasks.count + headings.count
        }
        if let measured { onMain.add(measured.seconds * 1000) }
    }
    row("diff + tasks + toc", onMain)

    // The editor's own per-parse cost, split into the core's half and the
    // decode: "the editor feels laggy" has a different answer depending on
    // which of the two is dominant.
    var structureJSON = Stat()
    var structureDecoded = Stat()
    for _ in 0..<5 {
        if let raw = try? timed({ try MarkCore.tasksBlocksJSON(source: source) }) {
            structureJSON.add(raw.seconds * 1000)
        }
        if let decoded = try? timed({ try MarkCore.structure(source: source) }) {
            structureDecoded.add(decoded.seconds * 1000)
        }
    }
    row("editor parse: core JSON", structureJSON)
    row("editor parse: + decode", structureDecoded)
    line(
        "M5 measured",
        "10–15 ms on the main actor for 1 MB — fine at save cadence, three dropped frames at typing cadence"
    )
    line(
        "where it runs now",
        "a detached task at userInitiated priority (DocumentView.performApply)")
    print("")
}

/// The gate: 60 s of typing, an external save partway through.
@MainActor
func measureContinuousTyping(_ harness: EditorBenchHarness, corpus: String) async {
    print(
        "Typing continuously for \(Int(editorTypingSeconds)) s in a \(corpus.utf8.count / 1024) KB document:"
    )

    guard let tab = await harness.open("typing.md") else {
        require(false, "the corpus document did not open")
        return
    }
    harness.controller.setEditorVisible(true)
    guard let buffer = tab.buffer else {
        require(false, "opening the editor did not make a buffer")
        return
    }
    let textView = harness.controller.editor.textView
    await harness.settle(milliseconds: 300)

    // Type into the middle of the first paragraph, so every keystroke moves
    // every byte offset below it — the expensive case, and the one where a
    // stale span would corrupt a checkbox write.
    let caretStart = 40
    textView.setSelectedRange(NSRange(location: caretStart, length: 0))

    let sentence = Array("the quick brown fox jumps over the lazy dog. ")
    var typed = ""
    var latency = Stat()
    var caretJumps = 0
    var lostEdits = 0

    let externalAt = editorTypingSeconds / 2
    var externalDone = false
    var externalText = ""
    let watcherEventsBefore = harness.controller.externalChangesSeen

    // What each autosave costs, because it happens **on the main actor**: the
    // core writes a megabyte through a temp file and `fsync`s it, and that
    // lands wherever the typist happens to be. The plan's §3 asks the write
    // path to be conservative, so it is synchronous by choice, and this is the
    // number that says what that choice costs.
    var saveCost = Stat()
    buffer.onSaved = { report in saveCost.add(report.seconds * 1000) }

    var worstAt: (cost: Double, at: Double) = (0, 0)
    let started = Date()
    var index = 0
    while Date().timeIntervalSince(started) < editorTypingSeconds {
        let character = String(sentence[index % sentence.count])
        index += 1

        let caretBefore = textView.selectedRange().location
        let began = DispatchTime.now().uptimeNanoseconds
        textView.insertText(character, replacementRange: NSRange(location: caretBefore, length: 0))
        let cost = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        latency.add(cost)
        if cost > worstAt.cost { worstAt = (cost, Date().timeIntervalSince(started)) }
        typed += character

        // The caret must have advanced by exactly one character, and by
        // nothing else: a re-render under the cursor shows up here as a jump
        // back to 0 or to wherever the document was replaced.
        let caretAfter = textView.selectedRange().location
        if caretAfter != caretBefore + (character as NSString).length { caretJumps += 1 }
        // And every character typed so far is still in the buffer, in order.
        if !buffer.text.contains(typed) { lostEdits += 1 }

        if !externalDone, Date().timeIntervalSince(started) >= externalAt {
            externalDone = true
            externalText = "# Written by vim halfway through\n\n" + corpus
            try? harness.saveAtomically(externalText, to: "typing.md")
            print(
                "  external save landed at \(String(format: "%.1f", Date().timeIntervalSince(started))) s"
            )
        }

        try? await _Concurrency.Task.sleep(for: editorKeystrokeInterval)
    }

    // Let the last debounce fire.
    _ = await waitUntilTrue(seconds: 5) { !buffer.isDirty || buffer.isConflicted }
    await harness.settle(milliseconds: 400)

    let elapsed = Date().timeIntervalSince(started)
    line("typed", "\(typed.count) characters over \(String(format: "%.1f", elapsed)) s")
    row("keystroke latency", latency, unit: "ms")
    row("autosave (main actor)", saveCost, unit: "ms")
    line("autosaves", "\(saveCost.samples.count)")
    line(
        "worst keystroke",
        String(
            format: "%.2f ms at t=%.1f s (the external save landed at t=%.1f s)", worstAt.cost,
            worstAt.at, externalAt))
    line(
        "editor parse (last)",
        String(format: "%.2f ms", harness.controller.editor.lastHighlightSeconds * 1000))
    line(
        "keystroke: buffer splice",
        String(format: "%.2f ms", harness.controller.editor.lastKeystrokeSeconds * 1000))
    line("resynchronisations", "\(harness.controller.editor.resynchronisations)")
    line("  of which: substring", String(format: "%.2f ms", harness.controller.editor.lastSubstringSeconds * 1000))
    line("  of which: splice", String(format: "%.2f ms", harness.controller.editor.lastSpliceSeconds * 1000))
    line("highlight passes", "\(harness.controller.editor.highlightPasses)")
    line(
        "preview diff (last)",
        String(format: "%.2f ms", (tab.documentView?.lastDiffSeconds ?? 0) * 1000))

    // ---- no lost edits
    require(lostEdits == 0, "every character typed stayed in the buffer (\(lostEdits) losses)")
    require(
        buffer.text.contains(typed),
        "the buffer holds the whole typed run of \(typed.count) characters")
    let expected = String(corpus.prefix(caretStart)) + typed + String(corpus.dropFirst(caretStart))
    require(
        buffer.text == expected,
        "the buffer is exactly the original document with the typed run inserted at byte \(caretStart)"
    )

    // ---- no cursor jumps
    require(caretJumps == 0, "the caret never jumped (\(caretJumps) jumps)")

    // ---- the editor and the buffer never drifted apart
    require(
        harness.controller.editor.resynchronisations == 0,
        "the buffer tracked the text view exactly, with no resynchronisation "
            + "(\(harness.controller.editor.resynchronisations) needed)")

    // ---- the conflict prompt
    require(
        harness.presenter.prompts == 1,
        "the external save raised exactly one conflict prompt (raised \(harness.presenter.prompts))"
    )
    require(
        harness.controller.conflicts.resolutions == [.keepMine],
        "the prompt was answered once, with keep-mine")

    // ---- self-write suppression across the whole run
    let watcherEvents = harness.controller.externalChangesSeen - watcherEventsBefore
    line("watcher events during the run", "\(watcherEvents)")
    require(
        watcherEvents >= 1,
        "the external save was seen (the watcher reported \(watcherEvents) event(s))")
    require(
        watcherEvents <= 3,
        "only the external save reached the watcher — our own autosaves were suppressed "
            + "(\(watcherEvents) events for one external save; vim's rename can produce 2–3)"
    )

    // ---- no truncation
    let onDisk = harness.contents(of: "typing.md")
    require(!onDisk.isEmpty, "the file on disk is not empty")
    require(
        onDisk == buffer.text,
        "the file on disk is exactly the buffer (\(onDisk.utf8.count) vs \(buffer.text.utf8.count) bytes)"
    )
    require(
        (try? MarkCore.tasks(source: onDisk)) != nil,
        "the file on disk is a parseable document")

    // ---- and it stayed interactive
    require(
        latency.p95 <= typingLatencyP95LimitMs,
        String(
            format: "p95 keystroke latency %.2f ms <= %.1f ms", latency.p95,
            typingLatencyP95LimitMs))
    require(
        latency.max <= typingLatencyMaxLimitMs,
        String(
            format: "worst keystroke %.2f ms <= %.1f ms", latency.max, typingLatencyMaxLimitMs))
    print("")
}

/// The three panes, as a picture.
///
/// `screencapture` returns an all-black frame on this machine — the screen has
/// been locked for the last four milestones — and `WKWebView.takeSnapshot`
/// covers only the preview. So the two halves are composited: the window's view
/// hierarchy through `cacheDisplay`, which renders natively and does not go
/// through the window server, and the web view's own snapshot drawn into the
/// rectangle it occupies. Anything drawn by WebKit is genuinely WebKit's
/// output; everything else is AppKit's.
@MainActor
func snapshotThreePanes(_ harness: EditorBenchHarness, named name: String) async {
    guard let window = harness.controller.window, let root = window.contentView else {
        require(false, "the window has no content view to snapshot")
        return
    }
    root.layoutSubtreeIfNeeded()
    await harness.settle(milliseconds: 300)

    guard root.bounds.width > 1, root.bounds.height > 1,
        let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)
    else {
        require(false, "the window has no drawable bounds")
        return
    }
    root.cacheDisplay(in: root.bounds, to: rep)

    // The sidebar half, drawn on its own.
    //
    // `NSSplitViewItem(sidebarWithViewController:)` puts the tree behind an
    // `NSVisualEffectView`, and vibrancy is composited by the window server
    // rather than drawn by the view — so `cacheDisplay` over the whole content
    // view leaves that region blank. M8 hit the same thing and snapshotted the
    // sidebar separately; here the separate snapshot is drawn back into place.
    let sidebarView = harness.controller.sidebar.view
    if sidebarView.bounds.width > 1, sidebarView.bounds.height > 1,
        let sidebarRep = sidebarView.bitmapImageRepForCachingDisplay(in: sidebarView.bounds)
    {
        sidebarView.cacheDisplay(in: sidebarView.bounds, to: sidebarRep)
        let frame = sidebarView.convert(sidebarView.bounds, to: root)
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            sidebarRep.draw(in: frame)
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // The preview half, from WebKit's own compositor.
    if let webView = harness.controller.tabs.selected?.documentView?.webView {
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        if let image {
            let frame = webView.convert(webView.bounds, to: root)
            let flipped = NSRect(
                x: frame.origin.x,
                y: root.bounds.height - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height)
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                image.draw(in: flipped)
                context.flushGraphics()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            line("snapshot", "takeSnapshot returned nothing; the preview half will be blank")
        }
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        require(false, "the snapshot could not be encoded")
        return
    }
    let directory = ProcessInfo.processInfo.environment["MARK_BENCH_SNAPSHOT_DIR"] ?? "target"
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try png.write(to: url)
    } catch {
        require(false, "writing the snapshot failed: \(error)")
        return
    }
    line("three-pane snapshot", "\(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh), \(png.count) bytes)")

    // A locked screen's `screencapture` output is a black rectangle, and it
    // would be indistinguishable from a real snapshot in a file listing.
    var colours = Set<UInt32>()
    let step = max(1, rep.pixelsHigh / 80)
    for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            guard let colour = rep.colorAt(x: x, y: y) else { continue }
            colours.insert(
                UInt32(colour.redComponent * 255) << 16 | UInt32(colour.greenComponent * 255) << 8
                    | UInt32(colour.blueComponent * 255))
        }
    }
    line("distinct sampled colours", "\(colours.count)")
    require(colours.count > 4, "the snapshot is not a blank rectangle")
}

@MainActor
func waitUntilTrue(seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await _Concurrency.Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: - The editor following the preview

/// The gate for "scroll the preview, the editor comes with it".
///
/// Only measurable here. Both halves of the mapping are geometry: the page
/// finds the block under its viewport top, which needs a laid-out `WKWebView`
/// in a window on screen, and the pane resolves that byte offset to a line,
/// which needs TextKit to have laid the document out. The unit suite drives the
/// same path with a synthesised scroll report and can assert on the *mapping*;
/// what it cannot assert is that the number the page sends is the block the
/// reader is looking at.
@MainActor
func measureEditorFollowingThePreview(_ harness: EditorBenchHarness) async {
    print("The editor following the preview:")

    // Short paragraphs, one line each in both panes, each saying where it is —
    // so "which paragraph is at the top" is readable from either side without
    // a second layout model to be wrong about.
    var source = ""
    var starts: [Int] = []
    for index in 0..<600 {
        starts.append(source.utf8.count)
        source += "Paragraph \(index) of the document.\n\n"
    }
    do {
        try harness.write(source, to: "following.md")
    } catch {
        require(false, "the follow document could not be written: \(error)")
        return
    }
    guard let tab = await harness.open("following.md"), let view = tab.documentView else {
        require(false, "the follow document did not open")
        return
    }
    harness.controller.setEditorVisible(true)
    await view.ensureFullyRendered()
    await harness.settle(milliseconds: 300)

    let pane = harness.controller.editor
    /// The paragraph number at the top of the editor's viewport, read out of
    /// the text itself rather than out of a coordinate.
    func editorTopParagraph() -> Int? {
        guard let layoutManager = pane.textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager,
            let fragment = layoutManager.textLayoutFragment(
                for: CGPoint(x: 0, y: pane.scrollOffset - pane.textView.textContainerOrigin.y))
        else { return nil }
        let start = contentManager.offset(
            from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        let end = contentManager.offset(
            from: contentManager.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard end > start else { return nil }
        let text = (pane.textView.string as NSString)
            .substring(with: NSRange(location: start, length: end - start))
        guard text.hasPrefix("Paragraph ") else { return nil }
        return Int(text.dropFirst("Paragraph ".count).prefix { $0.isNumber })
    }

    /// Which paragraph a byte offset is in.
    func paragraph(containing byte: Int) -> Int {
        var found = 0
        for (index, start) in starts.enumerated() where start <= byte { found = index }
        return found
    }

    var followLatency = Stat()
    var worstDrift = 0

    for target in [600.0, 3_000.0, 9_000.0, 1_200.0] as [Double] {
        let before = pane.scrollOffset
        let began = Date()
        _ = try? await view.call("return window.mark.scrollTo(y);", arguments: ["y": target])
        // The page reports on its own throttle; this is what the reader waits.
        let moved = await waitUntilTrue(seconds: 3) { pane.scrollOffset != before }
        let elapsed = Date().timeIntervalSince(began) * 1000
        guard moved else {
            require(false, "the editor did not follow a scroll to \(Int(target)) pt")
            continue
        }
        followLatency.add(elapsed)

        // `int`, not `double`: a page that reported nothing comes back as -1
        // here and as a NaN there, and `Int(NaN)` is a trap rather than a
        // failed check.
        let reported = PaintReport.int(try? await view.call("return window.mark.sourceTop();"))
        guard reported >= 0 else {
            require(false, "the page could not say where it is at \(Int(target)) pt")
            continue
        }
        let expected = paragraph(containing: reported)
        let shown = editorTopParagraph()
        let drift = shown.map { abs($0 - expected) } ?? 999
        worstDrift = max(worstDrift, drift)
        line(
            "preview at \(Int(target)) pt",
            "source byte \(reported) (paragraph \(expected)); editor shows "
                + (shown.map(String.init) ?? "nothing") + "; \(String(format: "%.0f", elapsed)) ms"
        )
        require(
            drift <= 1,
            "the editor is showing paragraph \(shown.map(String.init) ?? "nothing") "
                + "where the preview is showing \(expected)")
    }

    // And typing above the reader's place must not drag the pane back. A patch
    // that moves the blocks above the viewport makes the page scroll itself to
    // hold that place; the reader has not gone anywhere, and an editor they
    // have scrolled elsewhere — to their caret, here — must stay where it is.
    // The page suppresses the source position on exactly that report; see
    // `reportScroll`'s `held`.
    _ = try? await view.call("return window.mark.scrollTo(y);", arguments: ["y": 9_000.0])
    _ = await waitUntilTrue(seconds: 3) { pane.scrollOffset > 1_000 }
    let awayFromTheCaret = pane.scrollOffset
    pane.textView.setSelectedRange(NSRange(location: 0, length: 0))
    pane.textView.insertText(
        "# Inserted above everything\n\nAnd a paragraph under it.\n\n",
        replacementRange: NSRange(location: 0, length: 0))
    let atTheCaret = pane.scrollOffset
    _ = await waitUntilTrue(seconds: 5) { tab.documentView?.renderedSource == tab.buffer?.text }
    await harness.settle(milliseconds: 600)
    line(
        "typing above the viewport",
        "editor was at \(Int(awayFromTheCaret)) pt, went to the caret at "
            + "\(Int(atTheCaret)) pt, ended at \(Int(pane.scrollOffset)) pt")
    require(
        abs(pane.scrollOffset - atTheCaret) <= 24,
        "the editor stayed with the caret while typing above the preview's viewport")

    row("follow latency", followLatency, unit: "ms")
    line("worst paragraph drift", "\(worstDrift)")
    // The page throttles its scroll reports to 120 ms, so this is what the
    // reader's trackpad is waiting for and the number to watch if the follow
    // ever starts to feel behind.
    require(
        followLatency.median <= 400,
        "the editor follows within 400 ms (the page reports every 120 ms)")

    // Closed rather than left open: this gate typed into the document, and
    // closing is what writes the buffer and hands the web view back before the
    // snapshot below opens its own.
    harness.controller.tabs.close(tab)
    print("")
}

// MARK: - The preview following the editor

/// The gate for the other direction: scroll the source, the rendered document
/// comes with it.
///
/// Only measurable here, and more so than its mirror. Both ends are geometry —
/// TextKit has to have laid the source out for the pane to say which line is at
/// its top, and the page has to be laid out in a window for a block to have a
/// rectangle — and the unit suite can drive each end but not the pair. What it
/// cannot assert is the property the reader actually has: that the paragraph
/// they scrolled the source to is the paragraph the preview is showing.
@MainActor
func measureThePreviewFollowingTheEditor(_ harness: EditorBenchHarness) async {
    print("The preview following the editor:")

    var source = ""
    var starts: [Int] = []
    for index in 0..<600 {
        starts.append(source.utf8.count)
        source += "Paragraph \(index) of the document.\n\n"
    }
    do {
        try harness.write(source, to: "leading.md")
    } catch {
        require(false, "the lead document could not be written: \(error)")
        return
    }
    guard let tab = await harness.open("leading.md"), let view = tab.documentView else {
        require(false, "the lead document did not open")
        return
    }
    harness.controller.setEditorVisible(true)
    await view.ensureFullyRendered()
    await harness.settle(milliseconds: 300)

    let pane = harness.controller.editor

    /// Which paragraph a byte offset is in.
    func paragraph(containing byte: Int) -> Int {
        var found = 0
        for (index, start) in starts.enumerated() where start <= byte { found = index }
        return found
    }

    /// The paragraph the *preview* is showing, read out of the DOM rather than
    /// out of the mapping under test.
    func previewTopParagraph() async -> Int? {
        let text = try? await view.call(
            """
            var blocks = document.getElementById('mk-doc').children;
            for (var i = 0; i < blocks.length; i++) {
              if (blocks[i].getBoundingClientRect().bottom > 0) return blocks[i].textContent;
            }
            return '';
            """)
        guard let text = (text as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            text.hasPrefix("Paragraph ")
        else { return nil }
        return Int(text.dropFirst("Paragraph ".count).prefix { $0.isNumber })
    }

    /// Scroll the pane the way a hand on a trackpad does — the clip view moves
    /// and the bounds change carries it from there. Not through the pane's own
    /// scrolling, which is the path the *preview* drives and the one that stays
    /// deliberately quiet.
    func scrollPane(to y: CGFloat) {
        guard let scrollView = pane.textView.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var leadLatency = Stat()
    var worstDrift = 0

    for target in [900.0, 4_500.0, 13_000.0, 1_800.0] as [CGFloat] {
        let before = view.scrollOffset
        let began = Date()
        scrollPane(to: target)
        // The pane reports on its own 120 ms throttle; this is what the reader
        // waits before the page moves.
        let moved = await waitUntilTrue(seconds: 3) { view.scrollOffset != before }
        let elapsed = Date().timeIntervalSince(began) * 1000
        guard moved else {
            require(false, "the preview did not follow a source scroll to \(Int(target)) pt")
            continue
        }
        leadLatency.add(elapsed)
        await harness.settle(milliseconds: 200)

        // Both sides read once everything has settled, and the pane's side read
        // *here* rather than straight after the scroll. TextKit 2 estimates the
        // height of what it has not laid out, so the line the pane believes is
        // at its top a millisecond after a jump is not always the line that is
        // there once the layout is real — and the question this gate asks is
        // what the reader ends up looking at, in both panes, when the scrolling
        // stops.
        guard let reported = pane.sourceTopByte else {
            require(false, "the pane could not say where it is at \(Int(target)) pt")
            continue
        }
        let expected = paragraph(containing: reported)
        let shown = await previewTopParagraph()
        let drift = shown.map { abs($0 - expected) } ?? 999
        worstDrift = max(worstDrift, drift)
        line(
            "editor at \(Int(target)) pt",
            "source byte \(reported) (paragraph \(expected)); preview shows "
                + (shown.map(String.init) ?? "nothing") + "; \(String(format: "%.0f", elapsed)) ms"
        )
        require(
            drift <= 1,
            "the preview is showing paragraph \(shown.map(String.init) ?? "nothing") "
                + "where the editor is showing \(expected)")
    }

    // And the two directions pointed at each other must not chase each other.
    // Each pane stays quiet about the scroll the other one caused it to make;
    // without that, one flick of the trackpad has the panes converging on a
    // position neither of them was asked for, over as many hops as the rounding
    // keeps changing the answer.
    scrollPane(to: 7_000)
    _ = await waitUntilTrue(seconds: 3) { view.scrollOffset > 0 }
    await harness.settle(milliseconds: 600)
    let restingPage = view.scrollOffset
    let restingPane = pane.scrollOffset
    await harness.settle(milliseconds: 800)
    line(
        "left alone for 800 ms",
        "preview \(Int(restingPage)) → \(Int(view.scrollOffset)) pt, "
            + "editor \(Int(restingPane)) → \(Int(pane.scrollOffset)) pt")
    require(
        view.scrollOffset == restingPage && pane.scrollOffset == restingPane,
        "neither pane moves once the reader stops")

    row("lead latency", leadLatency, unit: "ms")
    line("worst paragraph drift", "\(worstDrift)")
    // The pane throttles its reports to 120 ms, the same as the page throttles
    // its own — so this is the number to watch if leading ever feels behind,
    // and it should sit alongside the follow latency above rather than beyond
    // it.
    require(
        leadLatency.median <= 400,
        "the preview follows within 400 ms (the pane reports every 120 ms)")

    harness.controller.tabs.close(tab)
    print("")
}

// MARK: - Entry point

@MainActor
func runEditorGates(corpus: URL) async {
    print("=== M9: the editing pane and autosave ===")
    print("")

    let source = (try? String(contentsOf: corpus, encoding: .utf8)) ?? "# empty\n"
    measureDiffCost(source)

    let harness: EditorBenchHarness
    do {
        harness = try EditorBenchHarness()
        try harness.write(source, to: "typing.md")
    } catch {
        require(false, "the editor harness could not be built: \(error)")
        return
    }
    harness.show()
    await harness.settle(milliseconds: 300)

    await measureContinuousTyping(harness, corpus: source)

    await measureEditorFollowingThePreview(harness)

    await measureThePreviewFollowingTheEditor(harness)

    // A small document for the picture: a megabyte of generated corpus makes an
    // unreadable screenshot, and what the snapshot is evidence *of* is the
    // three-pane layout with text in the editor and a preview reflecting it.
    let sample = """
        # Three panes

        The **editor** on the right holds this document's markdown source. The
        preview in the middle re-renders through ADR-2's block diff as it is
        typed, one block at a time.

        - [x] sidebar
        - [x] preview
        - [ ] editor

        ```rust
        fn main() {
            println!("highlighted from the core's block byte ranges");
        }
        ```

        > Autosave writes 800 ms after typing stops.
        """
    do {
        try harness.write(sample, to: "three-panes.md")
    } catch {
        require(false, "the sample document could not be written: \(error)")
    }
    if let tab = await harness.open("three-panes.md") {
        harness.controller.setEditorVisible(true)
        await harness.settle(milliseconds: 200)
        // Type into it, so the snapshot shows the editor and the preview
        // holding the *same* live document rather than two loaded copies.
        let textView = harness.controller.editor.textView
        let insertion = (sample as NSString).range(of: "- [ ] editor").location + 12
        textView.setSelectedRange(NSRange(location: insertion, length: 0))
        for character in " — typed live, previewed live" {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
            try? await _Concurrency.Task.sleep(for: .milliseconds(12))
        }
        _ = await waitUntilTrue(seconds: 3) {
            tab.documentView?.renderedSource == tab.buffer?.text
        }
        await harness.settle(milliseconds: 400)
        await snapshotThreePanes(harness, named: "mark-three-panes.png")
    } else {
        require(false, "the sample document did not open")
    }

    harness.close()
    print("")
}
