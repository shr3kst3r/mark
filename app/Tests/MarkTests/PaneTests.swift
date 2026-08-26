import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The two-pane model of `2026-08-26-multiple-windows-and-split-panes`.
@Suite("Panes — two documents, one tab bar")
@MainActor
struct PaneTests {

    /// The property that makes this change safe to land: with nothing split,
    /// the store behaves exactly as it did before panes existed.
    @Test("an unsplit store is indistinguishable from the old one")
    func unsplitIsUnchanged() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let store = harness.store
        #expect(!store.isSplit)
        #expect(store.focus == .primary)
        #expect(store.secondary == nil)
        #expect(store.selected === store.tabs[1])
        #expect(store.displayedTabs.count == 1)
        store.select(store.tabs[0])
        #expect(store.selected === store.tabs[0])
    }

    /// > **Never give one tab two views.** If a feature seems to need the same
    /// > document in two places at once, that is a new decision with a ~52 MB
    /// > price on it.
    ///
    /// The invariant, from three directions: splitting, showing the selected
    /// tab on the right, and showing the right pane's tab on the left.
    @Test("one tab is never in both panes")
    func noTabInBothPanes() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let store = harness.store

        store.splitRight()
        #expect(store.isSplit)
        #expect(store.primary !== store.secondary)

        // Asking for the left pane's document on the right **swaps** them
        // rather than duplicating it or emptying the left half.
        let left = try #require(store.primary)
        let right = try #require(store.secondary)
        store.show(left, in: .secondary)
        #expect(store.secondary === left)
        #expect(store.primary === right)
        #expect(
            store.displayedTabs.count
                == Set(store.displayedTabs.map(ObjectIdentifier.init)).count)
    }

    /// **The left pane is never empty while the right one is full.**
    ///
    /// A window in that state shows a blank left half and has no menu item that
    /// fixes it — ⇧⌘\\ keeps the focused pane, ⌘\\ refuses because the window is
    /// already split, and clicking a tab fills whichever pane has the focus.
    /// It was reachable by moving the only displayed document to the right.
    @Test("the left pane is never left empty with a document on the right")
    func primaryIsNeverEmptyAlone() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let store = harness.store
        let only = try #require(store.primary)
        #expect(!store.isSplit)

        // Nothing to swap with, so this must not become "blank on the left".
        store.show(only, in: .secondary)

        #expect(store.primary === only)
        #expect(store.secondary == nil)
        #expect(store.selected === only)
        #expect(store.focus == .primary)
    }

    @Test("swapping panes follows the document, not the side")
    func swapFollowsTheDocument() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let store = harness.store
        store.splitRight()
        let left = try #require(store.primary)
        let right = try #require(store.secondary)
        #expect(store.selected === left)

        #expect(store.swapPanes())

        #expect(store.primary === right)
        #expect(store.secondary === left)
        // The reader was acting on `left`; they still are, from the other side.
        #expect(store.selected === left)
        #expect(store.focus == .secondary)
    }

    @Test("split right needs two tabs and takes the most recently used other one")
    func splitRightPicksTheCompanion() throws {
        let single = try TabHarness(files: ["a.md"])
        #expect(single.store.splitRight() == false, "one document cannot be split against itself")
        #expect(!single.store.isSplit)

        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let store = harness.store
        // b was selected before c, so it is the most recently used *other* tab.
        store.select(store.tabs[1])
        store.select(store.tabs[2])
        #expect(store.splitRight())
        #expect(store.secondary === store.tabs[1])
        // The focus does not move: splitting is "show me that too", not "take
        // me over there".
        #expect(store.focus == .primary)
        #expect(store.selected === store.tabs[2])
    }

    /// `selected` means "the focused pane's tab", which is what lets the window
    /// title, the find bar and every socket command carry on unchanged.
    @Test("the focus decides what selected means, and the tab bar follows it")
    func focusDrivesSelection() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let store = harness.store
        store.splitRight()
        let right = try #require(store.secondary)

        store.moveFocus(to: .secondary)
        #expect(store.selected === right)

        // Selecting now lands in the right-hand pane, which is the whole point
        // of one tab bar driving two panes.
        let third = harness.open("c.md")
        #expect(store.secondary === third)
        #expect(store.primary !== third)
    }

    @Test("focusing an empty pane is refused rather than blanking the selection")
    func cannotFocusAnEmptyPane() throws {
        let harness = try TabHarness(files: ["a.md"])
        let store = harness.store
        store.moveFocus(to: .secondary)
        #expect(store.focus == .primary)
        #expect(store.selected != nil, "every menu item would grey out")
    }

    @Test("closing the right pane's tab collapses the split rather than refilling it")
    func closingSecondaryCollapses() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let store = harness.store
        store.splitRight()
        let right = try #require(store.secondary)
        store.close(right)

        #expect(!store.isSplit)
        #expect(store.focus == .primary)
        #expect(store.selected != nil)
    }

    @Test("closing the left pane's tab promotes the right one instead of leaving a gap")
    func closingPrimaryPromotesSurvivor() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let store = harness.store
        store.splitRight()
        let left = try #require(store.primary)
        let right = try #require(store.secondary)
        store.close(left)

        #expect(!store.isSplit)
        #expect(store.primary === right)
        #expect(store.selected === right)
    }

    @Test("closing the split keeps the focused pane's document")
    func closeSplitKeepsFocused() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let store = harness.store
        store.splitRight()
        let right = try #require(store.secondary)
        store.moveFocus(to: .secondary)
        store.closeSplit()

        #expect(!store.isSplit)
        #expect(store.selected === right)
        #expect(store.focus == .primary)
    }

    /// The bar has to say which two of six documents are on screen, or a split
    /// window is unreadable.
    @Test("the tab bar marks the other pane's tab as a companion")
    func barShowsTheCompanion() throws {
        let harness = try TabHarness(files: ["a.md", "b.md", "c.md"])
        let store = harness.store
        store.splitRight()
        harness.bar.reload()

        let companion = try #require(store.secondary)
        let items = harness.bar.items
        let companionItems = items.filter(\.isCompanion)
        #expect(companionItems.count == 1)
        #expect(companionItems.first?.tab === companion)
        // And it is not *also* drawn as selected — that would make two tabs
        // look current.
        #expect(companionItems.first?.isSelected == false)
    }
}
