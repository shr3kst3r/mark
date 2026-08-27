import AppKit
import Foundation
import MarkKit

//
// M8's gates, measured rather than asserted by eye.
//
// The five things plan §2 M8 and the milestone brief require, and what each one
// here corresponds to:
//
//   1. navigating a 608k-file tree stays responsive, and directory reads stay
//      bounded (as `core/tests/tree_lazy.rs` asserts, from the Swift side)
//                                          → `measureNavigation`
//   2. badges appear progressively without blocking the tree, and are correct
//                                          → `measureBadges`
//   3. breadcrumb, root, and history survive a session restore
//                                          → `checkSessionRestore` here, and
//                                            `scripts/session-roundtrip.sh`
//                                            across a real quit and relaunch
//   4. the filter does not collapse user-expanded nodes
//                                          → `checkFilter`
//   5. ⌘⇧O reveals the active tab's file even outside the current root
//                                          → `checkReveal`
//
// **Why the tree is the developer's real one and not a fixture.** The number
// that makes this milestone hard is 608,597 files in `~/src`, and a fixture
// with 200 of them would pass an eager implementation. So the default root is
// the largest real tree on the machine, overridable with `MARK_BENCH_TREE`, and
// what is *asserted* is the read count — which is what makes the result
// meaningful on a machine whose home directory looks nothing like this one.
//
// **Why there is a screenshot here at all.** `screencapture` returns black
// while the screen is locked, which it has been for two milestones. An
// `NSView` snapshot through `cacheDisplay(in:to:)` does not go anywhere near
// the window server's screen capture path and works regardless, and the sidebar
// is AppKit, so `WKWebView.takeSnapshot` — M2's answer — is no help here.
//

// MARK: - Thresholds

/// How long the part of a root move **we own** may take: the directory read and
/// the data source's bookkeeping, up to but not including AppKit's layout.
///
/// This is the strict one, because it is the number an eager walk would blow
/// through by orders of magnitude. Measured on an idle machine at 1–2.5 ms for
/// `~/src`, and 4–20 ms with a release LTO link running on the other cores.
let sidebarNavigationModelLimitMs = 50.0

/// How long a root move may take end to end, *including a forced synchronous
/// `layoutSubtreeIfNeeded`*.
///
/// Deliberately loose, and it is worth saying why rather than letting it look
/// like a number chosen to pass. The layout half is AppKit building cell views,
/// it does not happen synchronously in the shipping app (it happens in the next
/// display cycle), and it is the most load-sensitive thing measured here: the
/// same six moves took 35–40 ms on an idle machine and 237–284 ms while a
/// `merman` release link was running on the other cores. Gating that tightly
/// would produce a benchmark that fails for reasons having nothing to do with
/// the sidebar. What this ceiling still catches is the failure the gate is
/// actually about — an eager walk of a 608k-file tree, which is seconds — and
/// the read-count assertion below catches it structurally regardless of timing.
let sidebarNavigationLimitMs = 500.0

/// How long the main thread may be blocked while badges are computed.
///
/// The number that matters is "does the sidebar keep scrolling"; one dropped
/// frame is 16.7 ms, so this is about three frames. Reading every markdown file
/// on the main thread would blow through it by two orders of magnitude —
/// research §2.8 measured 345 ms for 1,026 files.
let badgeMainThreadStallLimitMs = 50.0

/// How long queueing a screenful of badge requests may take on the main thread.
/// It is a dictionary lookup and an array append per row.
let badgeEnqueueLimitMs = 20.0

// MARK: - Counting lister

/// Wraps the real lister and counts directory reads, which is the only way to
/// catch an eager walk before a user does.
@MainActor
final class BenchCountingLister: DirectoryLister {
    private let inner = CoreDirectoryLister()

    var options: TreeListingOptions {
        get { inner.options }
        set { inner.options = newValue }
    }
    private(set) var listings: [String] = []

    func entries(in directory: String) throws -> [TreeEntry] {
        listings.append(directory)
        return try inner.entries(in: directory)
    }

    var count: Int { listings.count }
    func reset() { listings.removeAll() }
}

// MARK: - Harness

@MainActor
final class SidebarHarness {

    let window: NSWindow
    let controller: TreeViewController
    let lister = BenchCountingLister()

    init(root: URL) {
        controller = TreeViewController(root: root, lister: lister)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // ADR-4's constraint applies to every window we make, not just the
        // app's: AppKit must never add a native tab bar.
        window.tabbingMode = .disallowed
        window.title = "mark-bench — sidebar"
        window.contentView = controller.view
        controller.viewDidLoad()
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        controller.outlineView.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
    }

    var rowNames: [String] {
        (0..<controller.outlineView.numberOfRows)
            .compactMap { (controller.outlineView.item(atRow: $0) as? TreeNode)?.name }
    }

    func node(named name: String) -> TreeNode? {
        (0..<controller.outlineView.numberOfRows)
            .compactMap { controller.outlineView.item(atRow: $0) as? TreeNode }
            .first { $0.name == name }
    }
}

/// The tree to navigate. The developer's real one by default, because 608k
/// files is the constraint and a fixture would not reproduce it.
@MainActor
func benchTreeRoot() -> URL {
    let manager = FileManager.default
    if let override = ProcessInfo.processInfo.environment["MARK_BENCH_TREE"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    let source = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("src")
    var isDirectory: ObjCBool = false
    if manager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
        return source
    }
    return URL(fileURLWithPath: manager.currentDirectoryPath)
}

// MARK: - 1. Navigation

@MainActor
func measureNavigation(_ harness: SidebarHarness, root: URL) {
    print("Navigating a real tree (the gate: bounded directory reads, not a walk):")
    line("root", root.path)
    line("top-level rows", "\(harness.rowNames.count)")
    require(
        harness.lister.count == 1,
        "showing a root reads exactly one directory (read \(harness.lister.count))")

    var moves = Stat()
    var models = Stat()
    var reads: [Int] = []

    // Model and layout are timed separately because they fail differently. The
    // model half is the directory read and the data source's bookkeeping — if
    // *that* is slow, something is walking. The layout half is AppKit building
    // cell views, which is where the first version of this benchmark found
    // 414 ms of per-path `NSWorkspace.icon(forFile:)` hiding (see
    // ``SidebarIcons``). Reporting one number would have hidden which.
    func move(_ label: String, _ body: () -> Bool) {
        harness.lister.reset()
        let started = DispatchTime.now().uptimeNanoseconds
        let moved = body()
        let modelled = DispatchTime.now().uptimeNanoseconds
        harness.window.layoutIfNeeded()
        harness.controller.outlineView.layoutSubtreeIfNeeded()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        guard moved else {
            line(label, "did not move")
            return
        }
        moves.add(elapsed)
        models.add(Double(modelled - started) / 1e6)
        reads.append(harness.lister.count)
        line(
            label,
            String(
                format: "%7.3f ms total (%6.3f ms model)   %d dir read(s)   %d rows", elapsed,
                Double(modelled - started) / 1e6, harness.lister.count,
                harness.rowNames.count))
    }

    // The loop plan §2 M8 names: up, look, back down.
    move("⌘↑ to the parent") { harness.controller.navigateToParent() }
    move("⌘[ back") { harness.controller.navigateBack() }
    move("⌘] forward") { harness.controller.navigateForward() }
    move("⌘[ back again") { harness.controller.navigateBack() }

    // And descending into the first subdirectory as the new root, which is the
    // other half of "move the root".
    if let directory = (0..<harness.controller.outlineView.numberOfRows)
        .compactMap({ harness.controller.outlineView.item(atRow: $0) as? TreeNode })
        .first(where: \.isDirectory)
    {
        move("descend into \(directory.name)/") { harness.controller.navigate(to: directory.url) }
        move("⌘[ back out") { harness.controller.navigateBack() }
    }

    row("root move, model + layout", moves)
    row("root move, model only", models)
    line("icon cache", "\(SidebarIcons.hits) hit / \(SidebarIcons.misses) miss")
    require(
        reads.allSatisfy { $0 == 1 },
        "every root move read exactly one directory (read \(reads))")
    require(
        models.worst <= sidebarNavigationModelLimitMs,
        "the slowest root move's own work, \(String(format: "%.3f", models.worst)) ms, is <= \(sidebarNavigationModelLimitMs) ms"
    )
    require(
        moves.worst <= sidebarNavigationLimitMs,
        "the slowest root move including a forced layout, \(String(format: "%.3f", moves.worst)) ms, is <= \(sidebarNavigationLimitMs) ms"
    )

    // Expanding a disclosure triangle is one read, and expanding a *deep* chain
    // is one read per level — bounded by path depth, not by tree size.
    harness.lister.reset()
    if let directory = (0..<harness.controller.outlineView.numberOfRows)
        .compactMap({ harness.controller.outlineView.item(atRow: $0) as? TreeNode })
        .first(where: \.isDirectory)
    {
        let started = DispatchTime.now().uptimeNanoseconds
        harness.controller.outlineView.expandItem(directory)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        line(
            "expand \(directory.name)/",
            String(format: "%7.3f ms   %d dir read(s)", elapsed, harness.lister.count))
        require(
            harness.lister.count == 1,
            "expanding one directory reads exactly one directory (read \(harness.lister.count))")
        harness.controller.outlineView.collapseItem(directory)
    }

    // Filtering and sorting are pure operations over listings already in
    // memory. This is the assertion that would fail the moment someone made the
    // filter "helpfully" search unexpanded directories.
    harness.lister.reset()
    let filterStarted = DispatchTime.now().uptimeNanoseconds
    for prefix in ["r", "re", "rea", "read"] { harness.controller.filter = prefix }
    harness.controller.filter = ""
    for sort in TreeSort.allCases { harness.controller.sort = sort }
    harness.controller.sort = .name
    let filterElapsed = Double(DispatchTime.now().uptimeNanoseconds - filterStarted) / 1e6
    line("4 filter keystrokes + 3 sorts", String(format: "%7.3f ms", filterElapsed))
    require(
        harness.lister.count == 0,
        "filtering and sorting read no directories (read \(harness.lister.listings))")
    print("")
}

// MARK: - 2. Badges

/// A directory of markdown files with known task counts, for the badge gate.
@MainActor
func makeBadgeCorpus(files: Int) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mark-bench-badges-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<files {
        var body = "# document \(index)\n\nProse with a literal [ ] bracket in it.\n\n"
        for open in 0..<(index % 7) { body += "- [ ] open \(open)\n" }
        for done in 0..<(index % 3) { body += "- [x] done \(done)\n" }
        try (body + "\n").write(
            to: directory.appendingPathComponent(String(format: "doc-%04d.md", index)),
            atomically: true, encoding: .utf8)
    }
    return directory
}

@MainActor
func measureBadges(files: Int = 400) async {
    print("Per-file task badges — lazy, background, and progressive (the M8 gate):")
    let corpus: URL
    do {
        corpus = try makeBadgeCorpus(files: files)
    } catch {
        require(false, "badge corpus: \(error)")
        return
    }
    defer { try? FileManager.default.removeItem(at: corpus) }

    let harness = SidebarHarness(root: corpus)
    harness.show()
    defer { harness.close() }

    let urls = (0..<files).map {
        corpus.appendingPathComponent(String(format: "doc-%04d.md", $0))
    }
    line("markdown files", "\(files)")
    line("directory reads to list them", "\(harness.lister.count)")

    // Let AppKit's first display pass of a 400-row outline view finish before
    // anything is timed. It is real work — and it is *window setup*, not badge
    // work, so charging it to the badge stall would report a 118 ms block that
    // no badge caused. Reported rather than silently skipped, because "the
    // sidebar takes 100 ms to appear" is worth knowing on its own.
    let settleStarted = DispatchTime.now().uptimeNanoseconds
    try? await _Concurrency.Task.sleep(for: .milliseconds(400))
    line(
        "first display pass + settle",
        String(format: "%7.3f ms", Double(DispatchTime.now().uptimeNanoseconds - settleStarted) / 1e6))

    // What a draw pass costs: one `badge(for:)` lookup and one `request(_:)`
    // per visible row. Charged for every file at once, which is far more than
    // a screenful.
    let service = harness.controller.badges
    let enqueueStarted = DispatchTime.now().uptimeNanoseconds
    for url in urls { service.request(url) }
    let enqueueMs = Double(DispatchTime.now().uptimeNanoseconds - enqueueStarted) / 1e6
    line("enqueue \(files) requests", String(format: "%7.3f ms", enqueueMs))
    require(
        enqueueMs <= badgeEnqueueLimitMs,
        "queueing \(files) badges costs \(String(format: "%.3f", enqueueMs)) ms <= \(badgeEnqueueLimitMs) ms on the main thread"
    )
    // The *last* file, not the first: rows near the top were already drawn by
    // the display pass above, and their badges have had 400 ms to land.
    require(
        service.badge(for: urls[files - 1]) == nil,
        "request() queues work rather than computing it inline")

    // Main-thread responsiveness *while* the badges are computed. A 1 ms
    // repeating hop; the largest gap between two hops is how long the main
    // thread was unavailable, which is what "without blocking the tree" means.
    var gaps = Stat()
    var last = DispatchTime.now().uptimeNanoseconds
    var firstBadgeMs: Double?
    let baseline = service.computed
    let started = last
    let deadline = ContinuousClock.now + .seconds(30)

    while ContinuousClock.now < deadline {
        try? await _Concurrency.Task.sleep(for: .milliseconds(1))
        let now = DispatchTime.now().uptimeNanoseconds
        gaps.add(Double(now - last) / 1e6)
        last = now
        if firstBadgeMs == nil, service.computed > baseline {
            firstBadgeMs = Double(now - started) / 1e6
        }
        if service.queueDepth == 0 && service.computed >= files { break }
    }
    let totalMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6

    line("badges already computed", "\(baseline) (from the first display pass)")
    line("time to first badge", String(format: "%7.3f ms", firstBadgeMs ?? .nan))
    line("time to all \(files) badges", String(format: "%7.3f ms", totalMs))
    line(
        "per badge",
        String(format: "%7.3f ms", totalMs / Double(max(1, service.computed - baseline))))
    row("main-thread hop gap", gaps)
    require(
        gaps.worst <= badgeMainThreadStallLimitMs,
        "the longest main-thread stall while badging was \(String(format: "%.3f", gaps.worst)) ms <= \(badgeMainThreadStallLimitMs) ms"
    )
    require(
        firstBadgeMs != nil && (firstBadgeMs ?? .infinity) < totalMs,
        "badges arrive progressively — the first lands well before the last")

    // Correctness, against the core over the same bytes. A fast badge that is
    // wrong is worse than no badge.
    var checked = 0
    var wrong: [String] = []
    for url in urls {
        guard let badge = service.badge(for: url) else {
            wrong.append("\(url.lastPathComponent): no badge")
            continue
        }
        guard let source = try? String(contentsOf: url, encoding: .utf8),
            let tasks = try? MarkCore.tasks(source: source)
        else { continue }
        // Outstanding over active, not unchecked over total: cancelled items
        // are terminal but not ticked, so `!checked` and "still to do" are
        // different questions since `2026-08-27-five-task-states`, and the
        // badge answers the second one.
        let expected = TaskCounts(tasks)
        if badge.outstanding != expected.outstanding || badge.active != expected.active {
            wrong.append(
                "\(url.lastPathComponent): \(badge.outstanding)/\(badge.active) != \(expected.outstanding)/\(expected.active)"
            )
        }
        checked += 1
    }
    line("badges checked against the core", "\(checked)")
    require(wrong.isEmpty, "every badge matches mark_tasks_json (\(wrong.prefix(3).joined(separator: "; ")))")

    // The visual half of the badge gate. `screencapture` has returned black
    // since the screen was locked two milestones ago; an `NSView` snapshot does
    // not go through the window server's capture path and works regardless.
    harness.controller.listingOptions = TreeListingOptions(
        showsNonMarkdown: true, showsHidden: false)
    try? FileManager.default.createDirectory(
        at: corpus.appendingPathComponent("subfolder"), withIntermediateDirectories: true)
    try? Data("png".utf8).write(to: corpus.appendingPathComponent("diagram.png"))
    harness.controller.refresh()
    harness.controller.outlineView.layoutSubtreeIfNeeded()
    for url in urls.prefix(40) { harness.controller.badges.request(url) }
    try? await _Concurrency.Task.sleep(for: .milliseconds(400))
    snapshotSidebar(harness, suffix: "badges")
    print("")
}

// MARK: - 3, 4, 5 — filter, reveal, session

@MainActor
func checkFilterAndReveal() {
    print("Filter, reveal, and the session round trip:")
    let fixture: URL
    do {
        fixture = try makeSidebarFixture()
    } catch {
        require(false, "sidebar fixture: \(error)")
        return
    }
    defer { try? FileManager.default.removeItem(at: fixture) }

    let root = fixture.appendingPathComponent("project", isDirectory: true)
    let harness = SidebarHarness(root: root)
    harness.show()
    defer { harness.close() }

    // --- 4. the filter does not collapse what the user expanded
    guard let docs = harness.node(named: "docs") else {
        require(false, "the fixture's docs/ is not in the sidebar")
        return
    }
    harness.controller.outlineView.expandItem(docs)
    guard let deep = harness.node(named: "deep") else {
        require(false, "the fixture's docs/deep/ is not in the sidebar")
        return
    }
    harness.controller.outlineView.expandItem(deep)
    let expandedBefore =
        harness.controller.outlineView.isItemExpanded(docs)
        && harness.controller.outlineView.isItemExpanded(deep)

    harness.lister.reset()
    for prefix in ["d", "de", "dee"] { harness.controller.filter = prefix }
    let stillExpanded =
        harness.controller.outlineView.isItemExpanded(docs)
        && harness.controller.outlineView.isItemExpanded(deep)
    line("rows under filter \"dee\"", harness.rowNames.joined(separator: " "))
    require(expandedBefore, "the fixture's two directories were expanded to begin with")
    require(stillExpanded, "an incremental filter does not collapse what the user expanded")
    require(
        harness.lister.count == 0, "filtering read no directories (\(harness.lister.listings))")
    harness.controller.filter = ""

    // --- 5. ⌘⇧O reveals a file outside the current root
    let outside = fixture.appendingPathComponent("elsewhere/outside.md")
    harness.lister.reset()
    let started = DispatchTime.now().uptimeNanoseconds
    let revealed = harness.controller.reveal(outside)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    line("⌘⇧O to a file outside the root", String(format: "%7.3f ms   %d dir read(s)", elapsed, harness.lister.count))
    require(revealed, "reveal found and selected a file outside the current root")
    require(
        harness.controller.selectedNode?.url.lastPathComponent == "outside.md",
        "the revealed row is the one selected")
    require(
        harness.controller.navigator.canGoBack,
        "the root move a reveal performs is undoable with ⌘[")

    // --- 3. root, breadcrumb, and history survive a restore, in process
    let snapshot = harness.controller.snapshot()
    let restoredHarness = SidebarHarness(root: URL(fileURLWithPath: NSTemporaryDirectory()))
    restoredHarness.controller.restore(snapshot)
    line("restored root", restoredHarness.controller.root.path)
    line("restored breadcrumb", restoredHarness.controller.breadcrumbBar.crumbTitles.joined(separator: " › "))
    line("restored back stack", "\(restoredHarness.controller.navigator.back.count)")
    require(
        restoredHarness.controller.root.path == snapshot.root.path,
        "the root survives a restore")
    require(
        restoredHarness.controller.breadcrumbBar.crumbTitles
            == restoredHarness.controller.navigator.breadcrumb.map(\.name),
        "the breadcrumb bar shows the restored root's components")
    require(
        restoredHarness.controller.navigator.back.map(\.path) == snapshot.back.map(\.path),
        "the back stack survives a restore")

    // --- the snapshot. `cacheDisplay` rather than `screencapture`, which
    // returns black while the screen is locked.
    snapshotSidebar(harness)
    print("")
}

/// The fixture `checkFilterAndReveal` navigates.
@MainActor
func makeSidebarFixture() throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mark-bench-sidebar-\(UUID().uuidString)", isDirectory: true)
    let manager = FileManager.default
    for relative in ["project/docs/deep", "project/notes", "elsewhere"] {
        try manager.createDirectory(
            at: base.appendingPathComponent(relative), withIntermediateDirectories: true)
    }
    let documents = [
        "project/readme.md": 2,
        "project/docs/deep/detail.md": 1,
        "project/docs/design.md": 4,
        "project/notes/today.md": 0,
        "elsewhere/outside.md": 3,
    ]
    for (relative, open) in documents {
        var body = "# \(relative)\n\n"
        for index in 0..<open { body += "- [ ] open \(index)\n" }
        try (body + "\n").write(
            to: base.appendingPathComponent(relative), atomically: true, encoding: .utf8)
    }
    return base
}

/// An `NSView` snapshot of the sidebar, written as a PNG.
///
/// `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` renders the
/// view hierarchy into a bitmap directly and does not go through the window
/// server's screen-capture path, so it works with the screen locked — which
/// `screencapture` does not, and which is why the last two milestones have no
/// visual evidence attached to them.
@MainActor
func snapshotSidebar(_ harness: SidebarHarness, suffix: String = "") {
    let view = harness.controller.view
    view.layoutSubtreeIfNeeded()
    harness.controller.outlineView.layoutSubtreeIfNeeded()
    // What the breadcrumb bar actually laid out, not what the model says it
    // should have. The two came apart once already, and the snapshot is the
    // only thing that would have shown it.
    let bar = harness.controller.breadcrumbBar!
    line("breadcrumb bar frame", "\(NSStringFromRect(bar.frame))")
    line("crumbs in the model", harness.controller.navigator.breadcrumb.map(\.name).joined(separator: " › "))
    line("crumbs laid out", bar.visibleCrumbTitles.joined(separator: " › "))
    require(
        !bar.visibleCrumbTitles.isEmpty,
        "the breadcrumb bar laid out at least the current directory")
    guard view.bounds.width > 1, view.bounds.height > 1,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
        require(false, "the sidebar view has no drawable bounds to snapshot")
        return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        require(false, "the sidebar snapshot could not be encoded")
        return
    }
    let base =
        ProcessInfo.processInfo.environment["MARK_BENCH_SIDEBAR_SNAPSHOT"]
        ?? "target/mark-sidebar.png"
    let destination =
        suffix.isEmpty
        ? base
        : base.replacingOccurrences(of: ".png", with: "-\(suffix).png")
    let url = URL(fileURLWithPath: destination)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try png.write(to: url)
    } catch {
        require(false, "writing the sidebar snapshot failed: \(error)")
        return
    }
    line("sidebar snapshot", "\(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh), \(png.count) bytes)")
    // A black image is what `screencapture` produces on a locked screen, and it
    // would be indistinguishable from a real one in a file listing. Counting
    // distinct colours is enough to tell "the sidebar drew" from "the sidebar
    // is a rectangle".
    var colours = Set<UInt32>()
    let step = max(1, rep.pixelsHigh / 64)
    for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            guard let colour = rep.colorAt(x: x, y: y) else { continue }
            let packed =
                UInt32(colour.redComponent * 255) << 16 | UInt32(colour.greenComponent * 255) << 8
                | UInt32(colour.blueComponent * 255)
            colours.insert(packed)
        }
    }
    line("distinct sampled colours", "\(colours.count)")
    require(colours.count > 1, "the sidebar snapshot is not a blank rectangle")
}

// MARK: - Entry point

@MainActor
func runSidebarGates() async {
    print("=== M8: the directory viewer ===")
    print("")

    let root = benchTreeRoot()
    // Cold, so the icon cache's first fill is charged to the first move rather
    // than being pre-warmed by a previous section of the benchmark.
    SidebarIcons.reset()
    let harness = SidebarHarness(root: root)
    harness.show()
    measureNavigation(harness, root: root)
    harness.close()

    await measureBadges()
    checkFilterAndReveal()
    checkPathBar()
}

/// The path bar at widths that do not fit, which is the case the first cut got
/// wrong in a way no test at one width would have caught.
///
/// Three things are measured rather than asserted by eye:
///
///   * what the bar *lays out* at a realistic sidebar width, next to what the
///     model says the path is — the two came apart once already;
///   * that the crumbs it hides are the middle ones, and that they are still
///     reachable from the ellipsis menu;
///   * that a chevron menu costs exactly one directory read, which is the
///     constraint that makes sibling menus affordable on a 608k-file tree at
///     all.
@MainActor
func checkPathBar() {
    print("The path bar under pressure:")
    let deep = URL(fileURLWithPath: "/usr/local/share/man/man1", isDirectory: true)
    let harness = SidebarHarness(root: deep)
    harness.show()
    let bar = harness.controller.breadcrumbBar!

    for width in [420, 300, 240, 180, 120] {
        harness.window.setContentSize(NSSize(width: CGFloat(width), height: 720))
        harness.window.layoutIfNeeded()
        bar.layoutSubtreeIfNeeded()
        line(
            "at \(width)pt",
            bar.visibleCrumbTitles.joined(separator: " › ")
                + (bar.overflowedCrumbTitles.isEmpty
                    ? "" : "   (\(bar.overflowedCrumbTitles.count) behind …)"))
        require(
            bar.visibleCrumbTitles.last == deep.lastPathComponent,
            "at \(width)pt the current folder is still shown")
        require(
            Set(bar.visibleCrumbTitles + bar.overflowedCrumbTitles) == Set(bar.crumbTitles),
            "at \(width)pt every crumb is either shown or behind the ellipsis")
        if bar.visibleCrumbTitles.count > 1 {
            require(
                bar.visibleCrumbTitles.first == "/",
                "at \(width)pt the root is pinned rather than truncated away")
        }
        require(
            bar.makeOverflowMenu().items.count == bar.overflowedCrumbTitles.count,
            "at \(width)pt the ellipsis menu reaches every hidden crumb")
    }

    // Back to a width a real sidebar is actually set to, so the picture shows
    // the interesting state — root, ellipsis, tail — rather than the degenerate
    // one the sweep ends on.
    harness.window.setContentSize(NSSize(width: 300, height: 720))
    harness.window.layoutIfNeeded()
    bar.layoutSubtreeIfNeeded()

    harness.lister.reset()
    let menu = bar.makeSiblingMenu(forCrumbAt: 1)
    line(
        "a chevron menu",
        "\(menu?.items.count ?? 0) item(s)   \(harness.lister.count) dir read(s)")
    require(harness.lister.count <= 1, "a chevron menu reads at most its own directory")

    snapshotSidebar(harness, suffix: "pathbar")
    harness.close()
    print("")
}
