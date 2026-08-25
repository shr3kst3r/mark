import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The gate ADR-4 names as *"the debt most likely to be skipped"*, asserted.
///
/// Plan §2 M3 requires VoiceOver to be able to navigate the bar. VoiceOver
/// itself cannot be driven from a test process — turning it on needs a
/// user-granted Accessibility permission and there is no API to script it — so
/// what is asserted here is the tree VoiceOver reads: roles, labels, selected
/// state, `AXTabs`, and the pressable close button. That is stated plainly in
/// the milestone report rather than dressed up as "VoiceOver was tested".
@Suite("TabBarView — accessibility, overflow, reorder arithmetic")
@MainActor
struct TabBarTests {

    // MARK: - Accessibility

    @Test("the bar is an AXTabGroup whose tabs are its AXTabs")
    func barIsATabGroup() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let bar = harness.bar
        #expect(bar.isAccessibilityElement())
        #expect(bar.accessibilityRole() == .tabGroup)
        #expect(bar.accessibilityLabel() == "Open documents")
        let tabs = try #require(bar.accessibilityTabs() as? [TabItemView])
        #expect(tabs.count == 3)
        #expect(tabs.map { $0.accessibilityRole() } == [.radioButton, .radioButton, .radioButton])
        let children = try #require(bar.accessibilityChildren())
        #expect(children.count == 3)
    }

    @Test("each tab announces its filename and its open-task count")
    func tabsAnnounceTitleAndTasks() async throws {
        let harness = try TabHarness(files: ["a.md", "c.md"])
        let (bar, store) = (harness.bar, harness.store)
        #expect(await harness.waitForMetadata(of: store.tabs), "metadata never arrived")
        bar.reload()

        let labels = bar.items.map { $0.accessibilityLabel() ?? "" }
        #expect(labels.contains("a.md, 3 open tasks"))
        #expect(labels.contains("c.md"), "a document with no open tasks announces just its name")

        let descriptions = bar.items.map { $0.accessibilityValueDescription() ?? "" }
        #expect(descriptions.contains("3 of 5 tasks open"))
        #expect(descriptions.contains("0 of 2 tasks open"))
    }

    @Test("exactly one tab reports itself as selected, and it is the store's")
    func selectionIsInTheAccessibilityTree() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let (bar, store) = (harness.bar, harness.store)
        let selectedItems = bar.items.filter { $0.isAccessibilitySelected() }
        #expect(selectedItems.count == 1)
        #expect(selectedItems.first?.tab === store.selected)

        store.select(index: 0)
        bar.reload()
        #expect(bar.items.filter { $0.isAccessibilitySelected() }.count == 1)
        #expect(bar.items[0].isAccessibilitySelected())
        #expect(bar.accessibilityValue() as? TabItemView === bar.items[0])
    }

    @Test("pressing a tab through the accessibility API selects it")
    func accessibilityPressSelects() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let (bar, store) = (harness.bar, harness.store)
        store.select(index: 0)
        #expect(bar.items[2].accessibilityPerformPress())
        #expect(store.selectedIndex == 2)
    }

    /// The affordance that would be a hand-built-bar bug: the ✕ is only
    /// *drawn* on hover, so a VoiceOver user who never moves the pointer must
    /// still be able to reach and press it.
    @Test("each tab exposes a pressable close button regardless of hover")
    func closeButtonIsReachable() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let (bar, store) = (harness.bar, harness.store)
        let item = bar.items[1]
        let children = try #require(item.accessibilityChildren())
        #expect(children.count == 1)
        let close = try #require(children.first as? TabCloseButton)
        #expect(close.accessibilityRole() == .button)
        #expect(close.accessibilityLabel() == "Close b.md")
        #expect(close.isHidden, "not drawn — but still reachable")

        #expect(close.accessibilityPerformPress())
        #expect(store.count == 2)
        #expect(!store.tabs.contains { $0.title == "b.md" })
    }

    @Test("the overflow control announces how many documents it hides")
    func overflowIsAnnounced() throws {
        let harness = try TabHarness(barWidth: 500)
        harness.openAll(try harness.fixture.makeDocuments(count: 12))
        let bar = harness.bar

        let children = try #require(bar.accessibilityChildren())
        let overflow = try #require(children.last as? TabOverflowButton)
        #expect(overflow.accessibilityRole() == .popUpButton)
        #expect(overflow.accessibilityLabel()?.hasSuffix("more documents") == true)
        #expect(bar.overflowTabs.count == 12 - bar.visibleCount)
    }

    // MARK: - Overflow layout

    @Test("every tab is drawn when they all fit, capped at the maximum width")
    func layoutWhenEverythingFits() {
        let layout = TabBarView.plan(
            tabCount: 3, selectedIndex: 0, firstVisible: 0, availableWidth: 900)
        #expect(layout.visibleCount == 3)
        #expect(layout.firstVisible == 0)
        #expect(layout.tabWidth == TabBarView.maximumTabWidth)
    }

    @Test("tabs shrink to share the bar before overflow kicks in")
    func layoutShrinksFirst() {
        let layout = TabBarView.plan(
            tabCount: 6, selectedIndex: 0, firstVisible: 0, availableWidth: 900)
        #expect(layout.visibleCount == 6)
        #expect(layout.tabWidth == 150)
        #expect(layout.tabWidth >= TabBarView.minimumTabWidth)
    }

    /// ADR-4 names *"tab overflow when 30 documents are open"* as ours to get
    /// right.
    @Test("thirty documents in a 900 pt bar overflow rather than shrinking to nothing")
    func thirtyDocumentsOverflow() {
        let layout = TabBarView.plan(
            tabCount: 30, selectedIndex: 0, firstVisible: 0, availableWidth: 900)
        #expect(layout.visibleCount < 30)
        #expect(layout.tabWidth >= TabBarView.minimumTabWidth)
        #expect(layout.visibleCount == 7)
    }

    /// The invariant most easily lost in an overflow implementation.
    @Test("the selected tab is always inside the visible window, scrolling either way")
    func selectedTabStaysVisible() {
        for selected in 0..<30 {
            let layout = TabBarView.plan(
                tabCount: 30, selectedIndex: selected, firstVisible: 0, availableWidth: 900)
            let visible = layout.firstVisible..<(layout.firstVisible + layout.visibleCount)
            #expect(visible.contains(selected), "selection \(selected) fell out of \(visible)")
        }
        // And coming back the other way, from a window already scrolled right.
        for selected in stride(from: 29, through: 0, by: -1) {
            let layout = TabBarView.plan(
                tabCount: 30, selectedIndex: selected, firstVisible: 23, availableWidth: 900)
            let visible = layout.firstVisible..<(layout.firstVisible + layout.visibleCount)
            #expect(visible.contains(selected), "selection \(selected) fell out of \(visible)")
        }
    }

    @Test("a bar too narrow for even one tab still draws one")
    func degenerateWidth() {
        let layout = TabBarView.plan(
            tabCount: 5, selectedIndex: 4, firstVisible: 0, availableWidth: 40)
        #expect(layout.visibleCount == 1)
        #expect(layout.firstVisible == 4)
    }

    @Test("an empty bar plans nothing rather than dividing by zero")
    func emptyLayout() {
        let layout = TabBarView.plan(
            tabCount: 0, selectedIndex: nil, firstVisible: 0, availableWidth: 900)
        #expect(layout.visibleCount == 0)
    }

    // MARK: - Reorder arithmetic

    /// The drag itself needs synthesised `NSEvent`s to test; the arithmetic it
    /// drives does not, and the arithmetic is where an off-by-one lives.
    @Test("the drop index follows the dragged tab's centre across the bar")
    func dropIndex() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"], barWidth: 600)
        let bar = harness.bar
        let width = 200.0  // 600 / 3
        #expect(bar.dropIndex(forCenterX: 10) == 0)
        #expect(bar.dropIndex(forCenterX: width * 1.5) == 1)
        #expect(bar.dropIndex(forCenterX: width * 2.5) == 2)
        #expect(bar.dropIndex(forCenterX: 100_000) == 2, "clamped to the last tab")
        #expect(bar.dropIndex(forCenterX: -500) == 0, "clamped to the first tab")
    }

    @Test("the bar redraws its items in the store's order after a reorder")
    func reorderReloadsInOrder() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let (bar, store) = (harness.bar, harness.store)
        let originalTitles = bar.items.compactMap { $0.tab?.title }
        store.move(from: 0, to: 2)
        bar.reload()
        let titles = bar.items.compactMap { $0.tab?.title }
        #expect(titles == [originalTitles[1], originalTitles[2], originalTitles[0]])
    }

}
