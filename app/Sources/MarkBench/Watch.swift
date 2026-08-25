import AppKit
import Foundation
import MarkKit
import WebKit

//
// M5's gates, in a real window.
//
// The unit suite (`MarkTests`) already covers the watcher, the write path, and
// the patch, and it covers them faster. What it cannot cover is **geometry**: a
// `WKWebView` with no window has `window.innerHeight == 0`, so nothing there can
// say whether the reader's place survived a patch. That is the whole of what
// this file adds, plus a second, independent run of the round trip and the trap
// against a window that is actually on screen.
//
//   1. the round trip        — click → one byte → watcher → patch, no jump
//   2. the trap              — a checkbox in a block the patch kept writes the
//                              task the user clicked, not its neighbour
//   3. external save         — vim-style temp-file-plus-rename, inode swapped
//   4. one visible change    — write/watch/patch is one patch, not a re-render
//   5. a symlinked document  — the real file is edited, the link stays a link
//   6. scroll survives       — shallow and deep, including an insert *above*
//                              the reader, which is the case the anchor exists
//                              for
//
// Gate 7 (a watcher event for a dehydrated tab) needs no window and lives in
// `WatchRoundTripTests`, where it can assert on the tab's state directly.
//

// MARK: - Harness

@MainActor
final class WatchBenchHarness {

    let controller: MainWindowController
    let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "mark-bench-watch-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = MainWindowController(
            root: directory,
            session: Session(
                url: directory.appendingPathComponent("session.json"), debounce: 0.05)
        )
        controller.window?.setContentSize(NSSize(width: 1100, height: 900))
        controller.window?.center()
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

    /// vim, VS Code, IntelliJ and Sublime all save like this: temp file, then
    /// `rename(2)` over the target. The inode changes, which is what kqueue
    /// cannot survive and FSEvents can.
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
        await settle(milliseconds: 120)
        return tab
    }

    func settle(milliseconds: Int) async {
        try? await _Concurrency.Task.sleep(for: .milliseconds(milliseconds))
    }

    @discardableResult
    func waitUntil(
        _ what: String,
        seconds: Double = 10,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            await settle(milliseconds: 20)
        }
        print("      timed out waiting for \(what)")
        return false
    }

    /// A real click on the nth checkbox **in document order on screen** —
    /// deliberately not "the box whose data-mk-idx is n", because whether those
    /// two agree is exactly what the trap is about.
    @discardableResult
    func clickCheckbox(at position: Int, in tab: DocumentTab) async -> Bool {
        guard let view = tab.documentView else { return false }
        let clicked = try? await view.call(
            """
            var boxes = document.querySelectorAll('#mk-doc input.mk-task');
            if (!boxes[at]) return false;
            boxes[at].click();
            return true;
            """, arguments: ["at": position])
        return (clicked as? Bool) ?? false
    }

    func contents(of name: String) -> String {
        (try? String(contentsOf: url(name), encoding: .utf8)) ?? ""
    }
}

/// `{blk, offset, scroll}` — the anchor `shell.js` records before a patch and
/// corrects against afterwards.
struct Anchor {
    let blk: String
    let offset: Double
    let scroll: Double

    init?(_ value: Any?) {
        guard let d = value as? [String: Any], let blk = d["blk"] as? String else { return nil }
        self.blk = blk
        offset = PaintReport.double(d["offset"])
        scroll = PaintReport.double(d["scroll"])
    }
}

@MainActor
func anchor(of tab: DocumentTab) async -> Anchor? {
    guard let view = tab.documentView else { return nil }
    return Anchor(try? await view.call("return window.mark._captureAnchor();"))
}

// MARK: - The gates

@MainActor
func runWatchGates(corpus: URL) async {
    print("M5 — checkbox write-back, the file watcher, and incremental patching:")

    let harness: WatchBenchHarness
    do {
        harness = try WatchBenchHarness()
    } catch {
        require(false, "M5 harness: \(error)")
        return
    }
    harness.show()
    await harness.settle(milliseconds: 200)

    await watchGateRoundTrip(harness)
    await watchGateTheTrap(harness)
    await watchGateExternalSave(harness)
    await watchGateSymlink(harness)
    await watchGateScroll(harness, corpus: corpus)

    harness.close()
    print("")
}

/// Gate 1 and gate 4: click → one byte → watcher → patch, exactly once, with
/// the reader's place intact.
@MainActor
func watchGateRoundTrip(_ harness: WatchBenchHarness) async {
    let name = "round-trip.md"
    let source = "# Tasks\n\n- [ ] first\n\nsome prose in between\n\n- [ ] second\n\ntail\n"
    guard (try? harness.write(source, to: name)) != nil, let tab = await harness.open(name),
        let view = tab.documentView
    else {
        require(false, "M5 gate 1: the document did not open")
        return
    }

    let before = (try? Data(contentsOf: tab.url)) ?? Data()
    let statsBefore = await view.stats()
    let scrollBefore = PaintReport.double(try? await view.call("return window.pageYOffset;"))

    await snapshot(tab, named: "m5-1-before-click.png")
    let clicked = await harness.clickCheckbox(at: 1, in: tab)
    require(clicked, "gate 1: the second checkbox was clickable")

    let wrote = await harness.waitUntil("the file to change") {
        (try? Data(contentsOf: tab.url)) != before
    }
    require(wrote, "gate 1: clicking a checkbox wrote the file")

    let after = (try? Data(contentsOf: tab.url)) ?? Data()
    let differing = zip(before, after).filter { $0 != $1 }.count
    require(
        after.count == before.count && differing == 1,
        "gate 1: exactly one byte changed (\(differing) differing, \(before.count) → \(after.count) bytes)"
    )
    require(
        harness.contents(of: name)
            == "# Tasks\n\n- [ ] first\n\nsome prose in between\n\n- [x] second\n\ntail\n",
        "gate 1: the task the user clicked is the one that changed")

    let patched = await harness.waitUntil("the DOM to catch up") {
        let checked = try? await view.call(
            "return document.querySelectorAll('#mk-doc input.mk-task[checked]').length;")
        return ((checked as? NSNumber)?.intValue ?? 0) == 1
    }
    require(patched, "gate 1: the watcher patched the document")
    await snapshot(tab, named: "m5-2-after-watcher-patch.png")

    await harness.settle(milliseconds: 400)
    let statsAfter = await view.stats()
    let patches = (statsAfter?.patches ?? 0) - (statsBefore?.patches ?? 0)
    let injections =
        (statsAfter?.documents ?? 0) - (statsBefore?.documents ?? 0)
        + (statsAfter?.replacements ?? 0) - (statsBefore?.replacements ?? 0)
    require(
        patches == 1 && injections == 0,
        "gate 4: one visible change — \(patches) patch(es), \(injections) whole-document injection(s)"
    )
    require(
        (statsAfter?.blocks ?? -1) == (statsBefore?.blocks ?? -2),
        "gate 1: no duplicated block (\(statsBefore?.blocks ?? -1) → \(statsAfter?.blocks ?? -1))")

    let scrollAfter = PaintReport.double(try? await view.call("return window.pageYOffset;"))
    require(
        abs(scrollAfter - scrollBefore) <= 2,
        "gate 1: no scroll jump (\(scrollBefore) → \(scrollAfter))")
}

/// Gate 2, the one that matters most: a checkbox in a block the patch left
/// untouched must write the task the user clicked and not its neighbour.
@MainActor
func watchGateTheTrap(_ harness: WatchBenchHarness) async {
    let name = "trap.md"
    let old = "- [ ] second\n\ntrailing\n"
    let new = "- [ ] first\n\n***\n\n- [ ] second\n\ntrailing\n"
    guard (try? harness.write(old, to: name)) != nil, let tab = await harness.open(name),
        let view = tab.documentView
    else {
        require(false, "M5 gate 2: the document did not open")
        return
    }

    _ = try? await view.call(
        "document.querySelector('#mk-doc [data-blk]').__witness = 1; return true;")
    try? harness.saveAtomically(new, to: name)
    let updated = await harness.waitUntil("the external edit") { view.renderedSource == new }
    require(updated, "gate 2: the inserted task arrived in the document")

    let witness = try? await view.call(
        "var b = document.querySelectorAll('#mk-doc [data-blk]'); return b[b.length - 2].__witness;")
    require(
        (witness as? NSNumber)?.intValue == 1,
        "gate 2: the block below the edit was kept, not re-rendered — the patch is node-preserving")

    await snapshot(tab, named: "m5-3-trap-before-click.png")
    _ = await harness.clickCheckbox(at: 1, in: tab)
    let wrote = await harness.waitUntil("the write") { harness.contents(of: name) != new }
    require(wrote, "gate 2: the click wrote")
    _ = await harness.waitUntil("the trap patch") {
        view.renderedSource == harness.contents(of: name)
    }
    await snapshot(tab, named: "m5-4-trap-after-click.png")
    require(
        harness.contents(of: name) == "- [ ] first\n\n***\n\n- [x] second\n\ntrailing\n",
        "gate 2: the task the user clicked was written, not its neighbour — \(harness.contents(of: name).debugDescription)"
    )
}

/// Gate 3: a `vim`-style save while the document is open.
@MainActor
func watchGateExternalSave(_ harness: WatchBenchHarness) async {
    let name = "external.md"
    guard (try? harness.write("# Notes\n\nbefore\n", to: name)) != nil,
        let tab = await harness.open(name), let view = tab.documentView
    else {
        require(false, "M5 gate 3: the document did not open")
        return
    }

    let inodeBefore = inode(of: tab.url)
    try? harness.saveAtomically("# Notes\n\nafter\n", to: name)
    let inodeAfter = inode(of: tab.url)
    require(inodeBefore != inodeAfter, "gate 3: the save really did swap the inode")

    let updated = await harness.waitUntil("the patch") {
        view.renderedSource == "# Notes\n\nafter\n"
    }
    require(updated, "gate 3: the watcher survived the inode swap and the document updated")

    // ...and again, because one rename proves nothing: kqueue would have
    // reported the first and gone silent.
    try? harness.saveAtomically("# Notes\n\nagain\n", to: name)
    let second = await harness.waitUntil("the second patch") {
        view.renderedSource == "# Notes\n\nagain\n"
    }
    require(second, "gate 3: a second atomic save is seen too (not kqueue's one-shot behaviour)")
}

/// Gate 5: a symlinked document toggles the real file and leaves the link a
/// link — the M1 review's `fs::rename` bug, on the path a click now takes.
@MainActor
func watchGateSymlink(_ harness: WatchBenchHarness) async {
    let realName = "symlink-target.md"
    guard (try? harness.write("# Real\n\n- [ ] a task\n", to: realName)) != nil else {
        require(false, "M5 gate 5: could not write the target")
        return
    }
    let link = harness.url("symlink.md")
    try? FileManager.default.removeItem(at: link)
    do {
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: harness.url(realName))
    } catch {
        require(false, "M5 gate 5: could not create the symlink: \(error)")
        return
    }

    guard let tab = await harness.open("symlink.md") else {
        require(false, "M5 gate 5: the symlinked document did not open")
        return
    }
    _ = await harness.clickCheckbox(at: 0, in: tab)
    let wrote = await harness.waitUntil("the write") {
        harness.contents(of: realName).contains("[x]")
    }
    require(wrote, "gate 5: the toggle reached the real file through the symlink")
    require(
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            == harness.url(realName).path,
        "gate 5: the symlink is still a symlink (fs::rename would have replaced it)")

    let patched = await harness.waitUntil("the patch for the symlinked document") {
        tab.documentView?.renderedSource == harness.contents(of: realName)
    }
    require(
        patched,
        "gate 5: the watcher saw a write that landed next to the symlink's *target*")
}

/// Gate 6: the reader's place survives a watcher-driven patch, shallow and
/// deep.
///
/// Two shapes, because they fail differently. An edit that changes no layout
/// height must leave `pageYOffset` untouched. An edit that **inserts a block
/// above the reader** must move `pageYOffset` by exactly the height it added,
/// so that the block the reader was looking at stays where it was — which is
/// the property ADR-2's manual anchor exists for, and the one a naive
/// re-render loses.
@MainActor
func watchGateScroll(_ harness: WatchBenchHarness, corpus: URL) async {
    let name = "scroll.md"
    guard let body = try? String(contentsOf: corpus, encoding: .utf8),
        (try? harness.write("# Scrolling\n\nintro paragraph\n\n" + body, to: name)) != nil,
        let tab = await harness.open(name), let view = tab.documentView
    else {
        require(false, "M5 gate 6: the corpus document did not open")
        return
    }
    await view.ensureFullyRendered()
    await harness.settle(milliseconds: 200)

    for target in [420.0, 9000.0] {
        _ = try? await view.call("return window.mark.scrollTo(y);", arguments: ["y": target])
        await harness.settle(milliseconds: 60)

        // 1. An edit that changes content but not layout height.
        let before = PaintReport.double(try? await view.call("return window.pageYOffset;"))
        let anchorBefore = await anchor(of: tab)
        let edited = "# Scrolling\n\nINTRO paragraph\n\n" + body
        try? harness.saveAtomically(edited, to: name)
        _ = await harness.waitUntil("the patch at \(Int(target)) pt") {
            view.renderedSource == edited
        }
        await harness.settle(milliseconds: 120)
        let after = PaintReport.double(try? await view.call("return window.pageYOffset;"))
        let anchorAfter = await anchor(of: tab)
        line(
            "same-height edit @\(Int(target))",
            String(
                format: "before %.0f  after %.0f  drift %.1f px  block %@",
                before, after, abs(after - before),
                anchorAfter?.blk == anchorBefore?.blk ? "held" : "moved"))
        require(
            abs(after - before) <= 2,
            "gate 6: scroll drift at \(Int(target)) pt is <= 2 px (was \(abs(after - before)))")
        require(
            anchorAfter?.blk == anchorBefore?.blk,
            "gate 6: the reader is still looking at the same block at \(Int(target)) pt")

        // 2. An insert *above* the reader: `pageYOffset` must move, the reader
        //    must not.
        let insertedBefore = await anchor(of: tab)
        let grown =
            "# Scrolling\n\nINTRO paragraph\n\nan inserted paragraph that was not here before\n\n"
            + body
        try? harness.saveAtomically(grown, to: name)
        _ = await harness.waitUntil("the insert-above patch at \(Int(target)) pt") {
            view.renderedSource == grown
        }
        await harness.settle(milliseconds: 120)
        let insertedAfter = await anchor(of: tab)
        let scrollDelta =
            PaintReport.double(try? await view.call("return window.pageYOffset;")) - after
        let offsetDrift = abs((insertedAfter?.offset ?? .nan) - (insertedBefore?.offset ?? .nan))
        line(
            "insert above @\(Int(target))",
            String(
                format: "pageYOffset moved %.0f px, the reader's block moved %.1f px",
                scrollDelta, offsetDrift))
        require(
            insertedAfter?.blk == insertedBefore?.blk && offsetDrift <= 2,
            "gate 6: an insert above the reader at \(Int(target)) pt left them on the same block, within 2 px"
        )
        if target > 1000 {
            require(
                scrollDelta > 2,
                "gate 6: the anchor correction actually ran (pageYOffset moved \(scrollDelta) px)")
        }

        // Put the document back for the next offset.
        try? harness.saveAtomically("# Scrolling\n\nintro paragraph\n\n" + body, to: name)
        _ = await harness.waitUntil("the document to be restored") {
            view.renderedSource?.hasPrefix("# Scrolling\n\nintro paragraph") == true
        }
    }
}

/// Write a PNG of what the document actually looks like, when
/// `MARK_BENCH_SNAPSHOT_DIR` is set.
///
/// `WKWebView.takeSnapshot` renders through the compositor and works with the
/// screen locked, which `screencapture` does not — it returns an all-black
/// frame. That distinction has come up before on this machine, so the visual
/// evidence for a milestone is taken from the web view rather than from the
/// display.
@MainActor
func snapshot(_ tab: DocumentTab, named name: String) async {
    guard let directory = ProcessInfo.processInfo.environment["MARK_BENCH_SNAPSHOT_DIR"],
        let webView = tab.documentView?.webView
    else { return }
    let image: NSImage? = await withCheckedContinuation { continuation in
        webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
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
        try png.write(to: url)
        line("snapshot", url.path)
    } catch {
        line("snapshot", "\(name): \(error)")
    }
}

@MainActor
func inode(of url: URL) -> UInt64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}
