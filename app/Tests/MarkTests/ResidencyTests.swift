import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The memory bound of `2026-08-26-multiple-windows-and-split-panes`, asserted
/// rather than commented.
///
/// Every test here is one of the two ways this change could be wrong in a way
/// nobody notices until a user reports it: a document going blank while being
/// read, or the app quietly using three times the memory it says it does.
@Suite("Residency — one budget for the whole app")
@MainActor
struct ResidencyTests {

    /// > **A per-window limit multiplies the budget by the window count while
    /// > continuing to report the old number.**
    ///
    /// The single most likely way to get this change wrong, and the reason
    /// ``ResidencyGovernor`` exists at all. Two stores stand in for two
    /// windows; between them they may hold three web views, not three each.
    @Test("two windows share one budget — they do not get one each")
    func budgetIsApplicationWide() throws {
        let governor = ResidencyGovernor(limit: 3)
        let left = try TabHarness(governor: governor)
        let right = try TabHarness(governor: governor)

        for url in try left.fixture.makeDocuments(count: 4, prefix: "left") {
            left.store.open(url)
        }
        for url in try right.fixture.makeDocuments(count: 4, prefix: "right") {
            right.store.open(url)
        }

        let resident = left.store.residentCount + right.store.residentCount
        #expect(resident <= 3, "two windows held \(resident) web views against a limit of 3")
        #expect(governor.residentCount == resident)
        // ~52 MB each, so the difference between passing and failing here is
        // ~264 MB against ~470 MB.
        #expect(governor.estimatedFootprintMB == 100 + 52 * resident)
    }

    /// The eviction victim is the least recently used tab **in the
    /// application**, which may be in the other window. A per-store ranking
    /// would evict from whichever window happened to overflow.
    ///
    /// The left window holds two tabs so it has one that is *not* on screen —
    /// its selected tab is displayed and therefore exempt, which is the point
    /// of `displayedTabsSurviveEviction` and would otherwise mask this.
    @Test("the eviction victim can be in the other window")
    func mruSpansWindows() throws {
        let governor = ResidencyGovernor(limit: 3)
        let left = try TabHarness(governor: governor)
        let right = try TabHarness(governor: governor)

        // Opened first, then pushed off screen by `d.md`, so it is the app's
        // least recently used tab and nothing is showing it.
        let stale = left.store.open(left.file(named: "a.md"))
        left.store.open(left.file(named: "d.md"))
        right.store.open(right.file(named: "b.md"))

        #expect(stale.state.isResident, "still within the limit")

        // The overflow happens in the *right* window; the victim is in the
        // left one.
        let newest = right.store.open(right.file(named: "c.md"))

        #expect(!stale.state.isResident, "the app's least recently used tab survived")
        #expect(newest.state.isResident)
        #expect(left.hydrator.dehydrated.contains(stale.url))
        #expect(governor.residentCount == 3)
    }

    /// The third exemption, and the one this change added.
    ///
    /// A tab in the other pane is on screen and is **not** `selected`. Evicting
    /// it takes the web view out from under a document somebody is reading —
    /// the pane goes blank, and it looks like a WebKit bug rather than an
    /// accounting one.
    @Test("a displayed tab that is not selected is never evicted")
    func displayedTabsSurviveEviction() throws {
        let harness = try TabHarness(residentLimit: 2)
        let groups = harness.makeGroups()
        let store = harness.store
        store.open(harness.file(named: "a.md"))
        store.open(harness.file(named: "b.md"))
        // With groups, "displayed and not selected" is a *window* state rather
        // than a store one: the unfocused group's selection is on screen, and
        // `selected` — the thing every menu item means — is the focused
        // group's. Exactly the state the third exemption exists for.
        #expect(groups.splitRight())
        #expect(groups.focusOther())
        let unfocused = try #require(groups.unfocused?.selected)

        #expect(groups.focused.selected !== unfocused)
        #expect(groups.displayedTabs.count == 2)

        // Enough new tabs to overflow twice over, opened into the focused
        // group. The other group's document is not the tab any menu acts on, so
        // only the displayed-tab rule saves it.
        for url in try harness.fixture.makeDocuments(count: 4, prefix: "flood") {
            groups.focused.open(url)
        }

        #expect(
            unfocused.state.isResident,
            "the other group's document was dehydrated under the reader")
        #expect(unfocused.isDisplayed)
    }

    /// The limit is a target that on-screen work outranks — stated in the ADR
    /// as an accepted cost, so it is asserted rather than hoped for.
    @Test("displayed tabs may push the working set past the limit")
    func displayedTabsMayExceedTheLimit() throws {
        let governor = ResidencyGovernor(limit: 1)
        let harness = try TabHarness(governor: governor)
        let groups = harness.makeGroups()
        harness.store.open(harness.file(named: "a.md"))
        harness.store.open(harness.file(named: "b.md"))
        #expect(groups.splitRight())

        let left = try #require(groups.groups[0].selected)
        let right = try #require(groups.groups[1].selected)
        #expect(left.state.isResident)
        #expect(right.state.isResident)
        #expect(governor.residentCount == 2, "a limit of 1 cannot mean one blank pane")
    }

    /// Carried forward from the superseded ADR, and still true: unsaved work is
    /// never dehydrated. Asserted here because the exemption moved house.
    @Test("a dirty tab is still exempt after the move to the governor")
    func dirtyTabsSurviveEviction() throws {
        let harness = try TabHarness(residentLimit: 1)
        let store = harness.store
        let dirty = store.open(harness.file(named: "a.md"))
        let buffer = try Buffer.open(url: dirty.url, autosaveDelay: 60, previewDelay: 60)
        buffer.replaceContents("# edited\n")
        dirty.attach(buffer: buffer)
        #expect(dirty.isDirty)

        for url in try harness.fixture.makeDocuments(count: 3, prefix: "flood") {
            store.open(url)
        }
        #expect(dirty.state.isResident)
    }

    /// A window closing must stop counting against the budget, or the app
    /// slowly convinces itself it is full.
    @Test("a closed window's store drops out of the accounting")
    func unregisteringFreesTheBudget() throws {
        let governor = ResidencyGovernor(limit: 4)
        let keep = try TabHarness(governor: governor)
        keep.store.open(keep.file(named: "a.md"))

        do {
            let temporary = try TabHarness(governor: governor)
            temporary.store.open(temporary.file(named: "b.md"))
            #expect(governor.registeredStores.count == 2)
            #expect(governor.residentCount == 2)
            temporary.store.closeAll()
        }

        #expect(governor.residentCount == 1)
    }

    @Test("MARK_RESIDENT_TABS still refuses nonsense rather than clamping oddly")
    func configuredLimitIsSane() {
        // The parse moved from `TabStore` to `ResidencyGovernor`; the aliases
        // are what keep every existing caller working.
        #expect(TabStore.defaultResidentLimit == ResidencyGovernor.defaultLimit)
        #expect(TabStore.configuredResidentLimit == ResidencyGovernor.configuredLimit)
        #expect(ResidencyGovernor.defaultLimit == 3)
        #expect(ResidencyGovernor(limit: 0).limit == 1)
    }
}
