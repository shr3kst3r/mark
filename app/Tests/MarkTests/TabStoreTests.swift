import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// ADR-4's hydrate/dehydrate state machine and MRU eviction — plan §5:
/// *"`TabStore` hydrate/dehydrate state machine, including selecting a
/// dehydrated tab and dehydrating the selected tab."*
@Suite("TabStore — the resident working set")
@MainActor
struct TabStoreTests {

    // MARK: - Opening and identity

    @Test("opening the same file twice selects the existing tab rather than duplicating it")
    func openIsIdempotent() throws {
        let harness = try TabHarness()
        let first = harness.open("a.md")
        let again = harness.open("a.md")
        #expect(harness.store.count == 1)
        #expect(first === again)
    }

    @Test("a non-standardized path is recognised as the same document")
    func pathsAreStandardized() throws {
        let harness = try TabHarness()
        let indirect = harness.fixture.directory
            .appendingPathComponent("b.md")
            .deletingLastPathComponent()
            .appendingPathComponent("./a.md")
        harness.store.open(harness.file(named: "a.md"))
        harness.store.open(indirect)
        #expect(harness.store.count == 1)
    }

    // MARK: - The state machine

    @Test("a new tab hydrates on selection and reports the three states in order")
    func hydrationStates() throws {
        let harness = try TabHarness()
        let tab = harness.open("a.md")

        // open() selects, and selection hydrates.
        #expect(tab.state == .hydrating)
        #expect(tab.documentView != nil)
        #expect(tab.webView != nil)
        #expect(harness.hydrator.hydrated == [tab.url])

        harness.store.notePainted(tab)
        #expect(tab.state == .hydrated)

        harness.store.dehydrate(tab)
        #expect(tab.state == .dehydrated)
        #expect(tab.documentView == nil)
        #expect(tab.webView == nil)
        #expect(harness.hydrator.dehydrated == [tab.url])
    }

    /// The case the plan calls out by name.
    @Test("dehydrating the selected tab is allowed, and re-selecting it rehydrates")
    func dehydrateThenReselectSelected() throws {
        let harness = try TabHarness()
        let tab = harness.open("a.md")
        harness.reportScroll(1234, on: tab)

        harness.store.dehydrate(tab)
        #expect(tab.state == .dehydrated)
        #expect(tab.scrollOffset == 1234, "the offset is captured on the way down")
        #expect(harness.store.selected === tab, "dehydration must not change the selection")

        harness.store.select(tab)
        #expect(tab.state == .hydrating)
        #expect(harness.hydrator.hydrated == [tab.url, tab.url])
        #expect(harness.hydrator.restoredOffsets.last == 1234, "the scroll offset must survive")
    }

    @Test("selecting a dehydrated tab rehydrates it with its scroll offset")
    func selectingDehydratedRehydrates() throws {
        let harness = try TabHarness(residentLimit: 1)
        let first = harness.open("a.md")
        harness.reportScroll(900, on: first)
        let second = harness.open("b.md")

        #expect(first.state == .dehydrated, "limit 1 must have evicted the first tab")
        #expect(second.state.isResident)
        #expect(first.scrollOffset == 900)

        harness.store.select(first)
        #expect(first.state.isResident)
        #expect(second.state == .dehydrated)
        #expect(harness.hydrator.restoredOffsets.last == 900)
        #expect(first.documentView?.scrollOffset == 900, "the view starts at the restored offset")
    }

    // MARK: - Eviction

    /// ADR-4: *"tabs beyond a resident working set (default 20, most recently
    /// used) are dehydrated"*.
    @Test("the resident working set never exceeds the limit, and evicts least-recently-used")
    func evictionIsMRU() throws {
        let harness = try TabHarness(residentLimit: 20)
        let urls = try harness.fixture.makeDocuments(count: 25)
        harness.openAll(urls)

        #expect(harness.store.count == 25)
        #expect(harness.store.residentCount == 20, "resident=\(harness.store.residentCount)")

        // The five opened first are the five least recently used.
        let evicted = harness.store.tabs.filter { $0.state == .dehydrated }.map(\.url)
        #expect(Set(evicted) == Set(urls.prefix(5)))
        #expect(harness.store.selected?.state.isResident == true)
    }

    @Test("the selected tab is never evicted, even at a limit of one")
    func selectedIsNeverEvicted() throws {
        let harness = try TabHarness(residentLimit: 1)
        harness.openAll(try harness.fixture.makeDocuments(count: 6))
        #expect(harness.store.residentCount == 1)
        #expect(harness.store.selected?.state.isResident == true)
    }

    /// ADR-4: *"The resident working set is a tunable, not a constant."*
    @Test("lowering the limit at runtime evicts immediately")
    func limitIsATunable() throws {
        let harness = try TabHarness(residentLimit: 20)
        harness.openAll(try harness.fixture.makeDocuments(count: 10))
        #expect(harness.store.residentCount == 10)

        harness.store.residentLimit = 3
        #expect(harness.store.residentCount == 3)

        harness.store.residentLimit = 0  // clamped — the selected tab needs one
        #expect(harness.store.residentLimit == 1)
        #expect(harness.store.residentCount == 1)
    }

    @Test("dehydration releases the web view from the shared message router")
    func dehydrationUnregistersTheWebView() throws {
        let harness = try TabHarness()
        let before = WebViewFactory.routedWebViewCount
        let tab = harness.open("a.md")
        #expect(WebViewFactory.routedWebViewCount == before + 1)
        harness.store.dehydrate(tab)
        #expect(WebViewFactory.routedWebViewCount == before)
    }

    /// The bug the router exists to prevent, asserted directly: with one shared
    /// `WKWebViewConfiguration` there is one content controller and one handler
    /// slot, so a per-view `add(handler:name:)` would leave only the newest tab
    /// receiving `ready` — and every other tab would sit blank with nothing in
    /// the log.
    @Test("every resident tab's web view is routed, not just the most recent")
    func everyWebViewIsRouted() throws {
        let harness = try TabHarness()
        // Raised above the default so this measures *routing*, not eviction —
        // at `2026-08-24-tab-residency-and-memory-model`'s default of 3, two of
        // these five would be dehydrated and the count would be a coincidence.
        harness.store.residentLimit = 5
        let before = WebViewFactory.routedWebViewCount
        harness.openAll(try harness.fixture.makeDocuments(count: 5))
        #expect(WebViewFactory.routedWebViewCount == before + 5)
    }

    // MARK: - The badge, from the core, while dehydrated

    /// The constraint ADR-4 says is *"the most likely to be violated
    /// silently"*: a dehydrated tab has no DOM, and its badge must still be
    /// right because it comes from `mark_tasks_json` over the file on disk.
    @Test("a dehydrated tab still reports a correct open-task badge")
    func badgeSurvivesDehydration() async throws {
        let harness = try TabHarness(residentLimit: 1)
        let a = harness.open("a.md")
        let d = harness.open("d.md")

        #expect(await harness.waitForMetadata(of: [a, d]), "metadata never arrived")

        #expect(a.state == .dehydrated, "limit 1 should have evicted a.md")
        #expect(a.webView == nil)
        #expect(a.openTaskCount == TabFixture.openTaskCounts["a.md"])
        #expect(a.metadata?.tasks.total == 5)
        #expect(d.openTaskCount == TabFixture.openTaskCounts["d.md"])
    }

    @Test("a document with no open tasks shows no badge")
    func noBadgeWithoutOpenTasks() async throws {
        let harness = try TabHarness()
        let c = harness.open("c.md")
        #expect(await harness.waitForMetadata(of: [c]))
        #expect(c.metadata?.tasks.total == 2)
        #expect(c.openTaskCount == nil)
    }

    /// The prose-bracket regression from research §2.4, asserted from the tab
    /// layer because that is where a wrong count would actually be seen.
    @Test("a literal [ ] in prose is not counted in the badge")
    func proseBracketIsNotATask() async throws {
        let harness = try TabHarness()
        let b = harness.open("b.md")
        #expect(await harness.waitForMetadata(of: [b]))
        #expect(b.metadata?.tasks.total == 3, "one open, two checked, zero from the prose bracket")
    }

    @Test("a tab whose file has vanished keeps its last known badge instead of crashing")
    func metadataFailureIsSurvivable() async throws {
        let harness = try TabHarness()
        let a = harness.open("a.md")
        #expect(await harness.waitForMetadata(of: [a]))
        let known = a.openTaskCount

        try FileManager.default.removeItem(at: a.url)
        a.refreshMetadata()
        try await _Concurrency.Task.sleep(for: .milliseconds(200))
        #expect(a.openTaskCount == known)
    }

    // MARK: - Ordering

    @Test("reordering moves a tab and leaves the selection on the same document")
    func reorder() throws {
        let harness = try TabHarness()
        let urls = try harness.fixture.makeDocuments(count: 4)
        harness.openAll(urls)
        let selected = harness.store.selected

        harness.store.move(from: 0, to: 3)
        #expect(harness.store.tabs.map(\.url) == [urls[1], urls[2], urls[3], urls[0]])
        #expect(harness.store.selected === selected)

        harness.store.move(from: 3, to: 0)
        #expect(harness.store.tabs.map(\.url) == urls)
    }

    @Test("a new tab opens to the right of the selected one, like every tab bar")
    func insertionPosition() throws {
        let harness = try TabHarness()
        let a = harness.open("a.md")
        harness.open("b.md")
        harness.store.select(a)
        harness.open("c.md")
        #expect(harness.store.tabs.map(\.title) == ["a.md", "c.md", "b.md"])
    }

    // MARK: - Cycling and key equivalents

    @Test("⌃⇥ and ⌃⇧⇥ cycle and wrap")
    func cycling() throws {
        let harness = try TabHarness()
        harness.openAll(try harness.fixture.makeDocuments(count: 3))
        harness.store.select(index: 0)

        harness.store.selectNext()
        #expect(harness.store.selectedIndex == 1)
        harness.store.selectNext()
        harness.store.selectNext()
        #expect(harness.store.selectedIndex == 0, "next wraps")
        harness.store.selectPrevious()
        #expect(harness.store.selectedIndex == 2, "previous wraps")
    }

    @Test("⌘9 selects the last tab, not the ninth")
    func commandNineIsLast() throws {
        let harness = try TabHarness()
        harness.openAll(try harness.fixture.makeDocuments(count: 12))

        harness.store.selectByKeyEquivalent(number: 3)
        #expect(harness.store.selectedIndex == 2)
        harness.store.selectByKeyEquivalent(number: 9)
        #expect(harness.store.selectedIndex == 11)
    }

    @Test("a key equivalent past the end of the list does nothing")
    func keyEquivalentOutOfRange() throws {
        let harness = try TabHarness()
        harness.open("a.md")
        let before = harness.store.selected
        harness.store.selectByKeyEquivalent(number: 5)
        #expect(harness.store.selected === before)
    }

    // MARK: - Closing

    @Test("closing the selected tab falls back to the most recently used survivor")
    func closeSelectsMRU() throws {
        let harness = try TabHarness()
        let urls = try harness.fixture.makeDocuments(count: 3)
        harness.openAll(urls)

        harness.store.select(index: 0)
        harness.store.select(index: 2)
        let b = harness.store.tabs[1]
        harness.store.select(b)
        harness.store.close(b)

        #expect(harness.store.count == 2)
        #expect(harness.store.selected?.url == urls[2], "the tab read most recently before b")
    }

    @Test("closing every tab leaves an empty store with no selection")
    func closeAllLeavesNothingSelected() throws {
        let harness = try TabHarness()
        let urls = try harness.fixture.makeDocuments(count: 3)
        harness.openAll(urls)
        for tab in harness.store.tabs { harness.store.close(tab) }

        #expect(harness.store.isEmpty)
        #expect(harness.store.selected == nil)
        #expect(harness.store.residentCount == 0)
        #expect(Set(harness.hydrator.dehydrated) == Set(urls))
    }

    @Test("the resident limit is overridable from the environment, not a constant in source")
    func residentLimitIsConfigurable() {
        // Asserts the shape of the tunable *and* the value, because the value
        // is load-bearing: `2026-08-24-tab-residency-and-memory-model` set it to
        // 3 after measuring a resident tab at ~52 MB rather than the superseded
        // ADR's ~1.2 MB. 20 would be ~1.16 GB. `MARK_RESIDENT_TABS` overrides.
        #expect(TabStore.defaultResidentLimit == 3)
        #expect(TabStore.configuredResidentLimit >= 1)
        #expect(TabStore(residentLimit: 7).residentLimit == 7)
    }
}
