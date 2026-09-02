import AppKit
import Foundation
import Testing

@testable import MarkKit

/// What points *at* this document.
///
/// Contents answers "what is in this note" and Tasks answers "what is left in
/// it" — both questions about the document alone, and both free, because the
/// calls behind them are ones the tab badge already pays for. This one is not
/// free: it walks the tree. So half of these are about the core's answer and
/// half are about the pane not paying for it when nobody is looking.
@Suite("Backlinks")
@MainActor
struct BacklinksTests {

    private func fixture() throws -> (root: URL, target: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-backlinks-\(UUID().uuidString)")
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

        let target = notes.appendingPathComponent("runbook.md")
        try "# Runbook\n".write(to: target, atomically: true, encoding: .utf8)
        try "# Index\n\n## Ops\n\nsee [the runbook](runbook.md)\n".write(
            to: notes.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try "# Top\n\n[deploy steps](notes/runbook.md#install)\n".write(
            to: root.appendingPathComponent("top.md"), atomically: true, encoding: .utf8)
        try "# Other\n\nmentions runbook.md in prose only\n".write(
            to: root.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        return (root, target)
    }

    // ---- the core's answer -------------------------------------------------

    @Test("a reference from anywhere below the root is found")
    func referencesAreFound() throws {
        let (root, target) = try fixture()
        let found = try MarkCore.backlinks(root: root.path, target: target.path)
        #expect(found.count == 2, "\(found)")

        // Matching is on the *resolved* path, so a link written from a sibling
        // directory and one written from beside it both count.
        let texts = Set(found.map(\.text))
        #expect(texts == ["the runbook", "deploy steps"])
    }

    @Test("a mention in prose is not a link")
    func proseIsNotALink() throws {
        let (root, target) = try fixture()
        let found = try MarkCore.backlinks(root: root.path, target: target.path)
        #expect(!found.contains { $0.path.hasSuffix("other.md") })
    }

    @Test("a reference carries the section it sits under and any fragment")
    func referencesCarryContext() throws {
        let (root, target) = try fixture()
        let found = try MarkCore.backlinks(root: root.path, target: target.path)

        let fromIndex = try #require(found.first { $0.text == "the runbook" })
        #expect(fromIndex.heading == "Index > Ops")
        #expect(fromIndex.fragment == nil)

        let fromTop = try #require(found.first { $0.text == "deploy steps" })
        #expect(fromTop.fragment == "install", "a #fragment still points here")
    }

    @Test("a document does not link to itself")
    func noSelfLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-backlinks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("notes.md")
        try "# Notes\n\n[top](notes.md)\n".write(to: target, atomically: true, encoding: .utf8)

        // A table of contents would otherwise fill the list with the document
        // itself.
        #expect(try MarkCore.backlinks(root: root.path, target: target.path).isEmpty)
    }

    // ---- the pane ----------------------------------------------------------

    @Test("the pane fills for the document it was given")
    func thePaneFills() async throws {
        let (root, target) = try fixture()
        let pane = BacklinksViewController()
        _ = pane.view

        pane.show(target, root: root)
        #expect(pane.isSearching, "it should say it is working")
        try await _Concurrency.Task.sleep(for: .milliseconds(700))
        #expect(!pane.isSearching)
        #expect(pane.links.count == 2, "\(pane.links)")
        #expect(pane.table.numberOfRows == 2)
    }

    @Test("no document means no walk")
    func noDocumentNoWalk() {
        let pane = BacklinksViewController()
        _ = pane.view
        pane.show(nil, root: nil)
        #expect(!pane.isSearching)
        #expect(pane.links.isEmpty)
    }

    @Test("an answer for a document that is no longer showing is dropped")
    func staleAnswersAreDropped() async throws {
        let (root, target) = try fixture()
        let other = root.appendingPathComponent("other.md")

        let pane = BacklinksViewController()
        _ = pane.view
        pane.show(target, root: root)
        // Switched before the first walk can land. Showing one note's backlinks
        // under another's name is worse than showing none.
        pane.show(other, root: root)
        try await _Concurrency.Task.sleep(for: .milliseconds(700))

        #expect(pane.document == other)
        #expect(pane.links.isEmpty, "nothing links to other.md: \(pane.links)")
    }

    @Test("picking a row reports the file and the byte to scroll to")
    func pickingARow() async throws {
        let (root, target) = try fixture()
        var opened: (URL, Int)?
        let pane = BacklinksViewController()
        _ = pane.view
        pane.onSelect = { url, offset in opened = (url, offset) }

        pane.show(target, root: root)
        try await _Concurrency.Task.sleep(for: .milliseconds(700))
        pane.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pane.table.onReturn?()

        let result = try #require(opened)
        #expect(result.1 == pane.links[0].offset)
        #expect(result.0.path == pane.links[0].path)
    }

    @Test("the pane is the document pane's third tab")
    func itIsATab() {
        // And on the same ⌃⌘ row as its siblings, which `MenuBarTests`'
        // uniqueness check guards.
        #expect(DocumentPaneController.Mode.allCases.count == 3)
        #expect(DocumentPaneController.Mode.links.title == "Links")
    }
}
