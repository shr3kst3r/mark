import AppKit
import Foundation
import Testing

@testable import MarkKit

/// VS Code's preview tab, as a set of properties rather than a description.
///
/// The behaviour is easy to state and easy to get subtly wrong: *clicking down
/// a directory of notes must cost one tab, and nothing the user has committed
/// to may be taken away by the next click.* Everything below is one of those
/// two halves — the single slot, or a promotion route that has to survive it.
@Suite("Preview tabs — one slot for skimming, four ways to keep")
@MainActor
struct PreviewTabTests {

    // MARK: - The single slot

    @Test("a permanent open is the default, so nothing that already worked changed")
    func permanentIsTheDefault() throws {
        let harness = try TabHarness()
        let tab = harness.store.open(harness.file(named: "a.md"))
        #expect(!tab.isPreview)
        #expect(harness.store.previewTab == nil)
    }

    @Test("clicking down a directory of markdown files leaves exactly one tab")
    func previewOpensReuseTheSameSlot() throws {
        let harness = try TabHarness()
        for name in ["a.md", "b.md", "c.md", "d.md"] {
            harness.store.open(harness.file(named: name), preview: true)
        }
        #expect(harness.store.count == 1, "four skims must not leave four tabs")
        #expect(harness.store.selected?.title == "d.md")
        #expect(harness.store.previewTab === harness.store.selected)
    }

    @Test("the replacement lands in the slot the outgoing preview held")
    func previewKeepsItsIndex() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        // Select the first tab so an ordinary open would insert at index 1.
        harness.store.select(index: 0)
        harness.store.open(harness.file(named: "c.md"), preview: true)
        #expect(harness.store.tabs.map(\.title) == ["a.md", "c.md", "b.md"])

        harness.store.open(harness.file(named: "d.md"), preview: true)
        #expect(
            harness.store.tabs.map(\.title) == ["a.md", "d.md", "b.md"],
            "the new preview takes the old one's index rather than moving to the end")
    }

    @Test("a permanent tab is never displaced by a preview open")
    func permanentTabsSurvivePreviews() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        harness.store.open(harness.file(named: "c.md"), preview: true)
        harness.store.open(harness.file(named: "d.md"), preview: true)
        #expect(harness.store.tabs.map(\.title) == ["a.md", "b.md", "d.md"])
    }

    @Test("re-previewing the file already in the preview slot is a no-op, not a churn")
    func previewingTheSameFileTwice() throws {
        let harness = try TabHarness()
        let first = harness.store.open(harness.file(named: "a.md"), preview: true)
        let again = harness.store.open(harness.file(named: "a.md"), preview: true)
        #expect(first === again)
        #expect(first.isPreview)
        #expect(harness.store.count == 1)
    }

    @Test("the outgoing preview tab's web view is actually released")
    func replacingAPreviewDehydratesIt() throws {
        let harness = try TabHarness()
        let stale = harness.store.open(harness.file(named: "a.md"), preview: true)
        #expect(stale.state.isResident)
        harness.store.open(harness.file(named: "b.md"), preview: true)
        #expect(stale.state == .dehydrated)
        #expect(harness.hydrator.dehydrated == [stale.url])
        #expect(harness.hydrator.liveWebViewCount == 1)
    }

    @Test("replacing the preview fires one selection, at the incoming tab")
    func replacingASelectedPreviewSelectsOnlyTheNewTab() throws {
        let harness = try TabHarness(files: ["a.md"])
        let recorder = SelectionRecorder()
        harness.store.delegate = recorder
        harness.store.open(harness.file(named: "b.md"), preview: true)
        recorder.selections.removeAll()

        let incoming = harness.store.open(harness.file(named: "c.md"), preview: true)
        #expect(
            recorder.selections.map(\.?.title) == ["c.md"],
            "a flash of some third document is exactly what routing through close() would cause")
        #expect(harness.store.selected === incoming)
    }

    // MARK: - Promotion

    @Test("a permanent open of the file being previewed promotes it in place")
    func permanentOpenPromotes() throws {
        let harness = try TabHarness()
        let tab = harness.store.open(harness.file(named: "a.md"), preview: true)
        let again = harness.store.open(harness.file(named: "a.md"))
        #expect(again === tab, "promotion must not mint a second tab on the same file")
        #expect(!tab.isPreview)
        #expect(harness.store.count == 1)

        // And now the slot is genuinely free again.
        harness.store.open(harness.file(named: "b.md"), preview: true)
        #expect(harness.store.tabs.map(\.title) == ["a.md", "b.md"])
    }

    @Test("promotion is one-way: a preview open of a permanent tab leaves it permanent")
    func promotionIsOneWay() throws {
        let harness = try TabHarness(files: ["a.md"])
        harness.store.open(harness.file(named: "a.md"), preview: true)
        #expect(harness.store.tabs[0].isPreview == false)
        #expect(harness.store.previewTab == nil)
    }

    @Test("dragging a tab to a new position keeps it")
    func reorderPromotes() throws {
        let harness = try TabHarness(files: ["a.md", "b.md"])
        let preview = harness.store.open(harness.file(named: "c.md"), preview: true)
        let from = try #require(harness.store.index(of: preview))
        harness.store.move(from: from, to: 0)
        #expect(!preview.isPreview)
        #expect(harness.store.tabs.map(\.title) == ["c.md", "a.md", "b.md"])
    }

    @Test("a double click on the tab promotes it")
    func doubleClickPromotes() throws {
        let harness = try TabHarness()
        let tab = harness.store.open(harness.file(named: "a.md"), preview: true)
        #expect(harness.store.promote(tab))
        #expect(!tab.isPreview)
        #expect(!harness.store.promote(tab), "promoting twice reports no change")
    }

    @Test("promoting a tab that is not in this store does nothing")
    func promotingAStrayTabIsRefused() throws {
        let harness = try TabHarness()
        let stray = DocumentTab(url: harness.file(named: "a.md"), isPreview: true)
        #expect(!harness.store.promote(stray))
        #expect(stray.isPreview)
    }

    @Test("closing the preview tab frees the slot rather than stranding it")
    func closingThePreviewFreesTheSlot() throws {
        let harness = try TabHarness(files: ["a.md"])
        let preview = harness.store.open(harness.file(named: "b.md"), preview: true)
        harness.store.close(preview)
        #expect(harness.store.previewTab == nil)
        harness.store.open(harness.file(named: "c.md"), preview: true)
        #expect(harness.store.count == 2)
    }

    // MARK: - The invariant

    @Test("at most one preview tab exists no matter how the tabs were opened")
    func atMostOnePreviewTab() throws {
        let harness = try TabHarness()
        for name in ["a.md", "b.md", "c.md", "d.md"] {
            harness.store.open(harness.file(named: name), preview: true)
            harness.store.open(harness.file(named: name))
            harness.store.open(harness.file(named: name), preview: true)
        }
        #expect(harness.store.tabs.filter(\.isPreview).count <= 1)
    }
}

/// Records what the store selected, in order, so a test can assert that
/// replacing a preview tab does **not** select some third document on the way.
@MainActor
final class SelectionRecorder: TabStoreDelegate {
    var selections: [DocumentTab?] = []
    func tabStoreDidChangeTabs(_ store: TabStore) {}
    func tabStore(_ store: TabStore, didSelect tab: DocumentTab?, previous: DocumentTab?) {
        selections.append(tab)
    }
}
