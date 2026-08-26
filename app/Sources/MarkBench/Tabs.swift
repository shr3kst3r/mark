import AppKit
import Darwin
import Foundation
import MarkKit
import WebKit

//
// ADR-4's gates, measured rather than asserted by eye.
//
// The five things plan §2 M3 requires, and what each one here corresponds to:
//
//   1. memory within ~100 MB + ~52 MB x resident  → `measureResidentMemory`
//   2. tab switch ≤1 ms               → `measureTabSwitch`
//   3. VoiceOver can navigate the bar → `checkAccessibilityTree`
//   4. dehydration is invisible       → `checkDehydration`
//   5. session round trip             → `checkSessionRoundTrip`
//
// Gate 3 is the one to read carefully. **VoiceOver is not driven here.**
// Turning it on requires a user-granted Accessibility permission and there is
// no API to script it, so what is checked is the accessibility *tree* VoiceOver
// reads — role, label, selected state, `AXTabs`, and the close button as a
// pressable child. The tree is also printed, so a regression is visible in the
// output rather than only to someone wearing headphones.
//
// The memory number is the one most easily got wrong, and getting it wrong is
// how ADR-4 came to record a figure this benchmark cannot reproduce. Three
// things have to be right:
//
//   1. **Count the helper processes.** WebKit's content, GPU, and networking
//      processes are XPC services parented to launchd, not to us, so
//      `resident_size` of this process alone is a small fraction of the cost.
//      Research §2.7 reports "2 processes total" for 12 tabs, which is exactly
//      the number you get from GPU + Networking when the WebContent processes
//      are not counted at all.
//   2. **Do not sum `ps` RSS.** Twenty-four WebContent processes share a very
//      large amount of clean file-backed memory (the dyld cache, WebKit's own
//      text), and RSS charges every one of them for all of it. The sum is
//      reported below because it is what a naive measurement produces, and it
//      is labelled as the over-count it is.
//   3. **Use `phys_footprint`.** That is the ledger macOS itself charges for
//      memory limits and jetsam, it is what Activity Monitor's Memory column
//      shows, and it excludes clean shared pages. Cross-checked here against
//      system-wide `vm_statistics64` across a teardown, which agreed to within
//      a few percent.
//

// MARK: - Process memory

struct HelperProcess {
    let pid: Int32
    let residentBytes: UInt64
    let command: String
}

enum ProcessMemory {

    /// A process's `phys_footprint` — the ledger macOS charges for memory
    /// limits, and the only number here that can be summed across processes
    /// without double-counting shared pages.
    static func footprintBytes(_ pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    static func selfFootprintBytes() -> UInt64 {
        footprintBytes(ProcessInfo.processInfo.processIdentifier)
    }

    /// System-wide memory in use, for the cross-check that says whether
    /// `phys_footprint` is telling the truth.
    static func systemUsedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages =
            UInt64(stats.wire_count) + UInt64(stats.active_count) + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count) + UInt64(stats.compressor_page_count)
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return pages * UInt64(pageSize)
    }

    /// This process's resident size.
    static func selfResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Every WebKit XPC helper currently alive on the machine.
    ///
    /// `ps` rather than anything cleverer because a `WKWebView`'s content
    /// process id is SPI (`_webProcessIdentifier`), and reaching for SPI in a
    /// benchmark to save a `Process` invocation is a bad trade.
    static func webKitHelpers() -> [HelperProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 3,
                    let pid = Int32(fields[0]),
                    let rssKilobytes = UInt64(fields[1])
                else { return nil }
                let command = fields[2...].joined(separator: " ")
                guard command.contains("com.apple.WebKit") else { return nil }
                return HelperProcess(pid: pid, residentBytes: rssKilobytes * 1024, command: command)
            }
    }

    static func helperPIDs() -> Set<Int32> { Set(webKitHelpers().map(\.pid)) }
}

// MARK: - Harness

/// A real ``MainWindowController`` — one window, split view, sidebar, tab bar —
/// driving real documents from real files.
///
/// Research §2.7's numbers were taken *"one window with a real split view and
/// sidebar, 256 KB per document"*, so anything less than the whole window here
/// would be measuring something else and comparing it to those numbers anyway.
@MainActor
final class TabBenchHarness {

    let controller: MainWindowController
    let directory: URL
    let sessionURL: URL
    private(set) var documents: [URL] = []

    init(corpus: URL, documentCount: Int, residentLimit: Int) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-bench-tabs-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionURL = directory.appendingPathComponent("session.json")

        // Distinct files, because a tab is identified by its path and opening
        // the same one twice is deliberately idempotent.
        let body = try String(contentsOf: corpus, encoding: .utf8)
        for index in 0..<documentCount {
            let url = directory.appendingPathComponent(String(format: "doc-%02d.md", index))
            // A known, distinct open-task count per document, so the badge
            // check has something falsifiable to compare against.
            let tasks = (0..<(index % 5 + 1)).map { "- [ ] open task \($0)\n" }.joined()
            try ("# Document \(index)\n\n\(tasks)\n" + body).write(
                to: url, atomically: true, encoding: .utf8)
            documents.append(url)
        }

        controller = MainWindowController(
            root: directory,
            session: Session(url: sessionURL, debounce: 0.05)
        )
        controller.tabs.residentLimit = residentLimit
        controller.window?.setContentSize(NSSize(width: 1200, height: 900))
        controller.window?.center()
    }

    deinit {
        let directory = self.directory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    var store: TabStore { controller.tabs }
    var bar: TabBarView { controller.tabBar }

    func show() {
        controller.showWindow(activating: true)
    }

    func close() {
        controller.tabs.closeAll()
        controller.window?.orderOut(nil)
        controller.window?.close()
    }

    /// Let the run loop breathe so autolayout, WebKit IPC, and the shell's
    /// `setTimeout` pump all get a turn.
    func settle(milliseconds: Int) async {
        try? await _Concurrency.Task.sleep(for: .milliseconds(milliseconds))
    }

    /// The scroll offset the page reports, for the rehydration check.
    func pageOffset(of tab: DocumentTab) async -> Double {
        guard let view = tab.documentView else { return .nan }
        let value = try? await view.call("return window.pageYOffset;")
        return PaintReport.double(value)
    }

    func scroll(_ tab: DocumentTab, to y: Double) async {
        guard let view = tab.documentView else { return }
        _ = try? await view.call("return window.mark.ensureFullyRendered();")
        _ = try? await view.call("return window.mark.scrollTo(y);", arguments: ["y": y])
        // The page reports scroll on a 120 ms throttle; wait for the report so
        // the tab's cached offset — the one dehydration reads — is current.
        await settle(milliseconds: 300)
    }
}

// MARK: - The gates

@MainActor
func runTabGates(corpus: URL) async {
    let tabCount = 24
    let corpus256 = corpus.deletingLastPathComponent().appendingPathComponent("256kb.md")
    let document = FileManager.default.fileExists(atPath: corpus256.path) ? corpus256 : corpus

    print("=== ADR-4: one window, custom tab bar, N resident web views ===")
    print("document: \(document.lastPathComponent), \(fileBytes(document)) bytes each")
    print("")

    let baselineHelpers = ProcessMemory.helperPIDs()
    let baselineSelf = ProcessMemory.selfResidentBytes()

    let harness: TabBenchHarness
    do {
        // 26 documents: 24 for the memory gate, plus two more so the
        // dehydration check has something to evict at a limit of 20.
        harness = try TabBenchHarness(
            corpus: document, documentCount: 26, residentLimit: 32)
    } catch {
        require(false, "tab harness: \(error)")
        return
    }
    harness.show()
    await harness.settle(milliseconds: 300)

    line("baseline, no web view", format(bytes: baselineSelf))

    // ------------------------------------------------------------- 24 tabs
    print("")
    print("Opening \(tabCount) tabs, all resident (ADR-4's N-resident-views design):")
    var firstOpenMs = 0.0
    var subsequentOpens = Stat()
    for (index, url) in harness.documents.prefix(tabCount).enumerated() {
        let started = DispatchTime.now().uptimeNanoseconds
        harness.store.open(url)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        if index == 0 { firstOpenMs = elapsed } else { subsequentOpens.add(elapsed) }
    }
    // Every tab is selected once so every document actually lays out, which is
    // what research §2.7's "each with a 256 KB doc rendered" means.
    for tab in harness.store.tabs {
        harness.store.select(tab)
        harness.controller.window?.displayIfNeeded()
    }
    await harness.settle(milliseconds: 4000)

    line("tabs open", "\(harness.store.count)")
    line("resident", "\(harness.store.residentCount)")
    line("first tab (WebContent spin-up)", String(format: "%.3f ms", firstOpenMs))
    row("subsequent tabs", subsequentOpens)

    func measureTotals() -> (footprint: UInt64, rss: UInt64, helpers: [HelperProcess]) {
        let helpers = ProcessMemory.webKitHelpers().filter { !baselineHelpers.contains($0.pid) }
        let footprint = ProcessMemory.selfFootprintBytes()
            + helpers.reduce(UInt64(0)) { $0 + ProcessMemory.footprintBytes($1.pid) }
        let rss = ProcessMemory.selfResidentBytes()
            + helpers.reduce(UInt64(0)) { $0 + $1.residentBytes }
        return (footprint, rss, helpers)
    }

    let measured = measureTotals()
    let contentProcesses = measured.helpers.filter { $0.command.contains("WebContent") }
    let totalMB = Double(measured.footprint) / 1_048_576

    print("")
    line("app process RSS", format(bytes: ProcessMemory.selfResidentBytes()))
    line("app process footprint", format(bytes: ProcessMemory.selfFootprintBytes()))
    line("WebKit helper processes", "\(measured.helpers.count)")
    line("  of which WebContent", "\(contentProcesses.count)")
    line(
        "median WebContent footprint",
        format(
            bytes: contentProcesses.isEmpty
                ? 0
                : contentProcesses.map { ProcessMemory.footprintBytes($0.pid) }.sorted()[
                    contentProcesses.count / 2]))
    line("sum of ps RSS (over-counts)", format(bytes: measured.rss))
    line("TOTAL phys_footprint", format(bytes: measured.footprint))
    line(
        "superseded ADR assumed",
        "102.0 MB total, ~1.2 MB/tab, 2 processes  (wrong — subtree walk)")
    line(
        "budget",
        String(format: "~100 MB + ~52 MB x %d resident", TabStore.defaultResidentLimit))

    // `2026-08-24-tab-residency-and-memory-model`: the memory bound is a formula,
    // not a constant, because a resident tab costs ~52 MB of WebContent process.
    // The superseded 110 MB gate was unreachable by any WKWebView design — the
    // floor with a single resident tab is ~152 MB.
    // This block deliberately holds *all* tabs resident to characterise the
    // per-tab cost, so it is gated on the formula's slope rather than on a total
    // the shipping default never reaches. The default's own total is gated by
    // the sweep below.
    let resident = harness.store.residentCount
    let budgetMB = tabMemoryBaselineMB + tabMemoryPerResidentMB * Double(resident)
    require(
        totalMB <= budgetMB * 1.25,
        String(
            format: "%d resident tabs at %.1f MB <= %.0f MB (~100 + ~52 x %d, +25%%)",
            resident, totalMB, budgetMB * 1.25, resident))

    let perTabMB = (totalMB - tabMemoryBaselineMB) / Double(max(resident, 1))
    line("measured cost per resident tab", String(format: "%.1f MB", perTabMB))
    require(
        perTabMB <= tabMemoryPerResidentMB * 1.4,
        String(
            format: "~%.0f MB per resident tab <= %.0f MB",
            perTabMB, tabMemoryPerResidentMB * 1.4))

    // One WebContent process per resident view is the *measured* behaviour, and
    // the thing the superseded ADR got backwards. Assert it so a future macOS
    // that actually coalesces shows up as a surprise rather than passing quietly.
    require(
        contentProcesses.count >= resident,
        "\(contentProcesses.count) WebContent process(es) for \(resident) resident "
            + "tab(s) — one each is the measured behaviour; fewer would mean WebKit "
            + "started coalescing and the residency default could be raised")

    // ------------------------------------------------ the resident-limit sweep
    //
    // ADR-4: *"The resident working set is a tunable, not a constant. 20 is a
    // starting point derived from ~1.2 MB per tab, not a measured optimum."*
    // The derivation is what this sweep measures. It is printed whether or not
    // the gate above passed, because if it failed this is the table a human
    // needs to decide what to do about it.
    print("")
    print("Cost of the resident working set, measured (24 tabs open throughout):")
    func column(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
    print("  " + column("limit", 10) + column("WebContent", 14) + column("footprint", 16) + "vs gate")
    var sweep: [(Int, Double)] = []
    for limit in [24, 20, 12, 6, 3, 2, 1] {
        harness.store.residentLimit = limit
        await harness.settle(milliseconds: 1200)
        let sample = measureTotals()
        let contents = sample.helpers.filter { $0.command.contains("WebContent") }.count
        let megabytes = Double(sample.footprint) / 1_048_576
        sweep.append((limit, megabytes))
        print(
            "  " + column("\(limit)", 10) + column("\(contents)", 14)
                + column(format(bytes: sample.footprint), 16)
                + (megabytes <= tabMemoryBaselineMB + tabMemoryPerResidentMB * Double(limit) * 1.25 ? "ok" : "OVER"))
    }
    let marginal =
        sweep.count > 1 && sweep[0].0 != sweep[sweep.count - 1].0
        ? (sweep[0].1 - sweep[sweep.count - 1].1)
            / Double(sweep[0].0 - sweep[sweep.count - 1].0)
        : .nan
    line("marginal cost per resident tab", String(format: "%.1f MB", marginal))
    line("ADR-4 Context assumed", "~1.2 MB")
    if let fits = sweep.last(where: { $0.1 <= tabMemoryBaselineMB + tabMemoryPerResidentMB * Double($0.0) * 1.25 })?.0 {
        line("largest limit inside the gate", "\(fits)")
    } else {
        line("largest limit inside the gate", "none — even 1 resident tab is over")
    }
    harness.store.residentLimit = 32
    await harness.settle(milliseconds: 1500)

    // -------------------------------------------------------- switch latency
    print("")
    print("Tab switch — show/hide of a resident view, no re-injection:")
    var showHide = Stat()
    var fullSelect = Stat()
    // Issue #7's addition to the switch: the sidebar selecting the row of the
    // document being switched to. It is inside `select + bar + chrome` below,
    // so the gate already covers it; it is broken out because "the switch got
    // slower" is not a useful thing to learn without knowing which half did.
    var sidebarFollow = Stat()
    let tabs = harness.store.tabs
    for round in 0..<6 {
        for (index, tab) in tabs.enumerated() {
            let previous = tabs[(index + tabs.count - 1) % tabs.count]

            // The whole user-visible path: store selection, MRU stamp,
            // eviction check, bar reload, window chrome.
            let selectStarted = DispatchTime.now().uptimeNanoseconds
            harness.store.select(tab)
            let selectElapsed = Double(DispatchTime.now().uptimeNanoseconds - selectStarted) / 1e6

            // And the part research §2.7 timed on its own.
            let started = DispatchTime.now().uptimeNanoseconds
            previous.documentView?.isHidden = true
            tab.documentView?.isHidden = false
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6

            // The sidebar's share, measured from a cleared selection so it
            // does the real work rather than the already-on-that-row no-op the
            // switch above just left it in.
            harness.controller.sidebar.follow(nil)
            let followStarted = DispatchTime.now().uptimeNanoseconds
            harness.controller.sidebar.follow(tab.url)
            let followElapsed =
                Double(DispatchTime.now().uptimeNanoseconds - followStarted) / 1e6

            if round > 0 {
                showHide.add(elapsed)
                fullSelect.add(selectElapsed)
                sidebarFollow.add(followElapsed)
            }
        }
    }
    row("show/hide only", showHide)
    row("select + bar + chrome", fullSelect)
    row("of which, sidebar follow", sidebarFollow)
    line("research §2.7 measured", "0.05 ms median, 0.23 ms worst")
    require(
        showHide.median <= tabSwitchLimitMs,
        String(format: "show/hide median %.4f ms <= %.1f ms", showHide.median, tabSwitchLimitMs))
    require(
        fullSelect.median <= tabSwitchLimitMs,
        String(
            format: "full select median %.4f ms <= %.1f ms", fullSelect.median, tabSwitchLimitMs))

    // ------------------------------------------------------- accessibility
    print("")
    await checkAccessibilityTree(harness)

    // --------------------------------------------------------- dehydration
    print("")
    await checkDehydration(harness)

    // ------------------------------------------------------------- session
    print("")
    await checkSessionRoundTrip(harness)

    // --------------------------------------------------------------- panes
    print("")
    await checkPanesAndWindows(harness)

    harness.close()
    await harness.settle(milliseconds: 200)
    print("")
}

// MARK: - Gate 3: the accessibility tree

@MainActor
func checkAccessibilityTree(_ harness: TabBenchHarness) async {
    print("Accessibility (ADR-4: \"a hand-drawn tab bar is invisible to VoiceOver")
    print("unless we implement NSAccessibility roles deliberately\"):")
    print("")
    // Give the metadata loads a moment so the labels carry task counts.
    await harness.settle(milliseconds: 500)
    harness.bar.reload()
    for line in harness.bar.accessibilityTreeDescription().split(separator: "\n").prefix(6) {
        print("  " + line)
    }
    if harness.bar.items.count > 5 { print("    … \(harness.bar.items.count - 5) more") }
    print("")

    require(
        harness.bar.accessibilityRole() == .tabGroup,
        "the bar reports AXTabGroup")
    require(
        (harness.bar.accessibilityTabs() as? [TabItemView])?.count == harness.store.count,
        "every tab is in AXTabs, so ⌃⌥→ can enumerate them")
    require(
        harness.bar.items.allSatisfy { $0.accessibilityRole() == .radioButton },
        "every tab reports AXRadioButton, the role NSTabView's own tabs use")
    require(
        harness.bar.items.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty },
        "every tab has a spoken label")
    require(
        harness.bar.items.filter { $0.isAccessibilitySelected() }.count == 1,
        "exactly one tab reports itself selected")
    require(
        harness.bar.items.allSatisfy { ($0.accessibilityChildren()?.first as? TabCloseButton) != nil },
        "every tab exposes its close button as a pressable child, hover or not")
    let labelled = harness.bar.items.filter { ($0.accessibilityLabel() ?? "").contains("open task") }
    require(
        !labelled.isEmpty,
        "\(labelled.count) tab labels announce their open-task count as well as their name")
    print("  note  VoiceOver itself is NOT driven here — there is no API to script it.")
    print("        What is checked is the tree VoiceOver reads.")
}

// MARK: - Gate 4: dehydration is invisible

@MainActor
func checkDehydration(_ harness: TabBenchHarness) async {
    print("Dehydration (ADR-4: resident working set, default 20, MRU eviction):")

    harness.store.residentLimit = TabStore.defaultResidentLimit
    for url in harness.documents { harness.store.open(url) }
    await harness.settle(milliseconds: 1500)

    let dehydrated = harness.store.tabs.filter { $0.state == .dehydrated }
    line("tabs open", "\(harness.store.count)")
    line("resident limit", "\(harness.store.residentLimit)")
    line("resident", "\(harness.store.residentCount)")
    line("dehydrated", "\(dehydrated.count)")
    require(
        harness.store.residentCount <= harness.store.residentLimit,
        "the resident working set is bounded at \(harness.store.residentLimit)")
    require(!dehydrated.isEmpty, "opening \(harness.store.count) tabs evicted the oldest")

    // The badge, while the DOM does not exist. ADR-4 calls this the constraint
    // most likely to be violated silently.
    guard let victim = dehydrated.first else { return }
    let expected = (try? MarkCore.tasks(
        source: (try? String(contentsOf: victim.url, encoding: .utf8)) ?? ""))?
        .filter { !$0.checked }.count
    line("dehydrated tab", victim.title)
    line("  its web view", victim.webView == nil ? "nil (as it must be)" : "STILL PRESENT")
    line("  badge shows", victim.openTaskCount.map(String.init) ?? "none")
    line("  mark_tasks_json says", expected.map(String.init) ?? "?")
    require(victim.webView == nil, "a dehydrated tab holds no web view")
    require(
        victim.openTaskCount == (expected == 0 ? nil : expected),
        "its badge still matches mark_tasks_json — the count comes from the file, not the DOM")

    // Rehydration, with the reader's place.
    let target = 2400.0
    harness.store.select(victim)
    await harness.settle(milliseconds: 1200)
    await harness.scroll(victim, to: target)
    let before = await harness.pageOffset(of: victim)
    line("scrolled to", String(format: "%.0f pt (cached %.0f)", before, victim.scrollOffset))

    // Push it back out by touching every other tab.
    for tab in harness.store.tabs where tab != victim { harness.store.select(tab) }
    require(
        victim.state == .dehydrated,
        "the scrolled tab was evicted again, so rehydration is what is measured next")
    let cached = victim.scrollOffset
    line("offset kept while dehydrated", String(format: "%.0f pt", cached))

    let started = DispatchTime.now().uptimeNanoseconds
    harness.store.select(victim)
    let hydrateMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    await harness.settle(milliseconds: 2500)
    let after = await harness.pageOffset(of: victim)

    line("rehydrate, view allocation", String(format: "%.3f ms", hydrateMs))
    line("research measured", "~8–9 ms to first paint, ~27 ms to fill")
    line("scroll restored to", String(format: "%.0f pt (wanted %.0f)", after, before))
    require(victim.state.isResident, "selecting a dehydrated tab rehydrates it")
    require(
        abs(after - before) <= 4,
        String(format: "scroll came back to within 4 px (drift %.1f)", abs(after - before)))
    require(
        victim.openTaskCount == (expected == 0 ? nil : expected),
        "the badge is unchanged across the round trip")
}

// MARK: - Gate 5: session round trip

@MainActor
func checkSessionRoundTrip(_ harness: TabBenchHarness) async {
    print("Session (ADR-4: our own JSON file, never NSWindowRestoration):")

    harness.controller.saveSessionNow()
    let session = Session(url: harness.sessionURL)
    guard let saved = session.loadOrLogging() else {
        require(false, "the session file was not written to \(harness.sessionURL.path)")
        return
    }
    line("session file", harness.sessionURL.lastPathComponent)
    line("bytes", "\(fileBytes(harness.sessionURL))")
    line("tabs recorded", "\(saved.tabs.count)")
    line("selected index", saved.selectedIndex.map(String.init) ?? "none")
    line(
        "non-zero scroll offsets",
        "\(saved.tabs.filter { $0.scrollOffset > 0 }.count)")

    let expectedOrder = harness.store.tabs.map(\.url.path)
    let expectedSelection = harness.store.selectedIndex
    let expectedOffsets = harness.store.tabs.map {
        $0.documentView?.scrollOffset ?? $0.scrollOffset
    }

    // A fresh controller reading the file from disk — the same code path a
    // relaunch takes. The *process* round trip is `just bench-app`'s final
    // step, which launches the app twice for real.
    let reopened = MainWindowController(
        root: harness.directory, session: Session(url: harness.sessionURL))
    reopened.restore(saved)

    require(reopened.tabs.tabs.map(\.url.path) == expectedOrder, "tab order survives the round trip")
    require(reopened.tabs.selectedIndex == expectedSelection, "the selection survives")
    require(
        reopened.tabs.tabs.map(\.scrollOffset) == expectedOffsets,
        "every scroll offset survives")
    require(
        reopened.tabs.residentCount == 1,
        "restoring \(saved.tabs.count) tabs costs one web view, not \(saved.tabs.count)")
    require(
        reopened.window?.isRestorable == false,
        "the window opts out of NSWindowRestoration, so only our file restores")

    reopened.tabs.closeAll()
    reopened.window?.close()
}

// MARK: - Formatting

func format(bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

func fileBytes(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
}


// MARK: - Gate 6: two documents on screen, and a window of their own

/// `2026-08-26-multiple-windows-and-split-panes`, against real laid-out
/// geometry.
///
/// The unit suites cover the model — which tab is in which pane, what survives
/// eviction, what the session file says. What they abstract away is the half
/// that can only be wrong on screen: whether the two panes actually get
/// non-overlapping frames, whether the divider lands between them, and whether
/// a popped-out window ends up with the document *and* its live web view. That
/// is what this checks, and it writes a PNG so the geometry is inspectable
/// rather than only asserted.
@MainActor
func checkPanesAndWindows(_ harness: TabBenchHarness) async {
    print("Panes and windows (2026-08-26-multiple-windows-and-split-panes):")

    let store = harness.store
    let container = harness.controller.documentContainer

    // A clean two-document start, whatever the gates above left behind.
    store.closeAll()
    for url in harness.documents.prefix(2) { store.open(url) }
    await harness.settle(milliseconds: 200)

    require(store.splitRight(), "the window split")
    harness.controller.window?.layoutIfNeeded()
    container.layoutSubtreeIfNeeded()
    // Long enough for the *second* pane's document to finish ADR-2's
    // prefix-then-fill open. The first snapshot taken here showed a rendered
    // left pane and a black right one, which is exactly what a split that
    // lays out correctly and never paints would look like — so the paint is
    // now waited for and asserted rather than assumed.
    await harness.settle(milliseconds: 1200)

    guard let left = store.primary?.documentView, let right = store.secondary?.documentView
    else {
        require(false, "both panes hold a hydrated document view")
        return
    }

    line("container", NSStringFromRect(container.bounds))
    line("left pane", NSStringFromRect(left.frame))
    line("right pane", NSStringFromRect(right.frame))

    // The geometry the unit tests cannot see. Two documents that overlap, or
    // one with no width, is a split that "works" in the model and shows one
    // document on screen.
    require(!left.isHidden && !right.isHidden, "both panes are visible")
    require(left.frame.width > 1 && right.frame.width > 1, "neither pane is collapsed to nothing")
    require(!left.frame.intersects(right.frame), "the panes do not overlap")
    require(left.frame.maxX <= right.frame.minX, "the left pane is left of the right one")
    require(
        abs(left.frame.height - container.bounds.height) < 1
            && abs(right.frame.height - container.bounds.height) < 1,
        "both panes are full height")
    let gap = right.frame.minX - left.frame.maxX
    line("divider gap", String(format: "%.1f pt", gap))
    require(gap >= DocumentContainerView.dividerWidth, "there is room for the divider between them")

    // Both on screen means both resident, whatever the limit says. This is the
    // ADR's third eviction exemption, seen from the window rather than the
    // store.
    require(
        store.displayedTabs.allSatisfy { $0.state.isResident },
        "every displayed document holds its web view")

    // Resident, visible and correctly framed still does not mean *painted*.
    // `.hydrated` is set by `notePainted`, which the page reports only once it
    // has actually drawn its prefix — so this is the difference between a
    // split that works and one that shows a blank half.
    for pane in Pane.allCases {
        guard let tab = store.panes.tab(in: pane) else { continue }
        line("\(pane.rawValue) state", tab.state.rawValue)
        require(
            tab.state == .hydrated,
            "the \(pane.rawValue) pane's document has painted, not just hydrated")
    }

    // And the DOM is really there, asked of the page rather than inferred from
    // our own state machine.
    for pane in Pane.allCases {
        guard let view = store.panes.tab(in: pane)?.documentView else { continue }
        let blocks = await view.renderedBlockCount()
        line("\(pane.rawValue) blocks in the DOM", "\(blocks)")
        require(blocks > 0, "the \(pane.rawValue) pane has rendered blocks in its DOM")
    }

    snapshotDocumentArea(harness, suffix: "split")

    // ---------------------------------------------------------- pop-out
    let coordinator = WindowCoordinator()
    let source = harness.controller
    // The harness built its controller directly, so the coordinator has to be
    // told about it before it can move a tab out of it.
    coordinator.adopt(source)

    guard let moving = store.secondary else {
        require(false, "there is a right-hand document to pop out")
        return
    }
    let movingURL = moving.url
    let movingView = moving.documentView
    let popped = coordinator.popOut(moving, from: source)
    await harness.settle(milliseconds: 300)

    guard let popped else {
        require(false, "the tab moved into a window of its own")
        return
    }
    line("windows", "\(coordinator.count)")
    line("popped document", movingURL.lastPathComponent)

    require(coordinator.count == 2, "there are two windows")
    require(popped.tabs.tabs.contains(moving), "the document is in the new window")
    require(!source.tabs.tabs.contains(moving), "and no longer in the old one")
    require(!source.tabs.isSplit, "the split it left behind collapsed")
    require(
        moving.documentView === movingView,
        "the live web view moved rather than being remade — a pop-out keeps the DOM")
    require(moving.state.isResident, "the popped document still holds its web view")
    require(popped.isSidebarCollapsed, "the popped-out window starts with its sidebar collapsed")
    require(
        popped.window?.tabbingMode == .disallowed,
        "the new window disallows native tabbing too")
    require(
        popped.tabs.governor === source.tabs.governor,
        "both windows share one residency budget")

    popped.close()
    await harness.settle(milliseconds: 100)
}

/// A PNG of the document area, so the split's geometry is inspectable.
///
/// `cacheDisplay` rather than `screencapture`, for the reason
/// ``snapshotSidebar`` gives: it renders the view hierarchy into a bitmap
/// directly and works with the screen locked.
///
/// **What it cannot show, stated plainly because it looks like a bug.** A
/// `WKWebView` is layer-hosted and composited by WebKit, and `cacheDisplay`
/// mirrors only one of the two panes' remote layers: the left pane comes out
/// rendered and **the right pane comes out black**, every time, on a split
/// where both documents have demonstrably painted.
///
/// That is a property of the capture, not of the app. Do not read the black
/// half as a pane that failed to render — the gate above asks each pane's
/// *page* how many blocks are in its DOM, which is the evidence that actually
/// distinguishes the two, and both report the same count.
///
/// What this image is good for is the geometry: the divider, the focus stripe,
/// and where the two frames sit are drawn by our own code, and they are the
/// part that can be wrong without a test noticing.
@MainActor
func snapshotDocumentArea(_ harness: TabBenchHarness, suffix: String) {
    let view = harness.controller.documentContainer
    view.layoutSubtreeIfNeeded()
    guard view.bounds.width > 1, view.bounds.height > 1,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
        require(false, "the document area has drawable bounds to snapshot")
        return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        require(false, "the document-area snapshot could not be encoded")
        return
    }
    let base =
        ProcessInfo.processInfo.environment["MARK_BENCH_PANE_SNAPSHOT"]
        ?? "target/mark-panes.png"
    let destination = base.replacingOccurrences(of: ".png", with: "-\(suffix).png")
    let url = URL(fileURLWithPath: destination)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? png.write(to: url)
    line("snapshot", destination)
}
