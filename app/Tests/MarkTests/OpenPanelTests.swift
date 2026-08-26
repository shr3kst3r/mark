import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import MarkKit

/// What the open panels will let you choose.
///
/// This suite exists because of a defect that no other kind of test could see:
/// both panels filtered by `allowedContentTypes = [.plainText, .text]`, and
/// three of the five extensions mark treats as markdown have no declared UTI,
/// so they were drawn greyed out and could not be selected — while the sidebar
/// two inches away listed them undimmed and opened them fine.
@Suite("The open panels")
@MainActor
struct OpenPanelTests {

    private func fixture() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// All five, including the three the system has no opinion about.
    @Test(
        "every markdown extension is selectable",
        arguments: ["a.md", "a.markdown", "a.mdown", "a.mkd", "a.mdx", "a.MD"])
    func enablesEveryMarkdownExtension(name: String) throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try "# hello\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(MarkdownPanel.shared.panel(NSOpenPanel(), shouldEnable: url))
    }

    @Test("files that are not markdown are not selectable", arguments: ["a.rs", "a.png", "a"])
    func disablesEverythingElse(name: String) throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)

        #expect(!MarkdownPanel.shared.panel(NSOpenPanel(), shouldEnable: url))
    }

    /// Choosable because every other route in already treats a folder as a
    /// place: `mark open notes/` and a folder dropped on the window both root
    /// the sidebar there. ⌘O was the one route that refused.
    @Test("folders are selectable")
    func enablesDirectories() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(MarkdownPanel.shared.panel(NSOpenPanel(), shouldEnable: directory))
    }

    /// **The trap, pinned.**
    ///
    /// `2026-08-26-new-documents-are-files-on-disk` forbids deciding this from
    /// UTType, because a bundle's `UTImportedTypeDeclarations` are inert until
    /// LaunchServices has registered the app — so a UTType filter passes here
    /// and fails in `/Applications`, or the reverse. This test asserts the
    /// divergence directly: at least one extension mark accepts is one the
    /// system does *not* call plain text in this process. If that stops being
    /// true, the filter is still ours to own; if someone swaps the delegate for
    /// `allowedContentTypes`, the tests above start failing here first.
    @Test("the filter does not agree with LaunchServices, and must not depend on it")
    func doesNotDelegateToUTType() throws {
        let orphans = TreeNode.markdownExtensions.filter { ext in
            UTType(filenameExtension: ext)?.conforms(to: .plainText) != true
        }
        #expect(
            !orphans.isEmpty,
            """
            Every markdown extension now has a plain-text UTI in this process, \
            so this test can no longer demonstrate the divergence. That does not \
            make `allowedContentTypes` safe — it depends on LaunchServices \
            registration, which `swift test` does not have. Check why before \
            deleting anything.
            """)

        // And the panel enables them anyway.
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for ext in orphans {
            let url = directory.appendingPathComponent("orphan.\(ext)")
            try Data().write(to: url)
            #expect(MarkdownPanel.shared.panel(NSOpenPanel(), shouldEnable: url))
        }
    }

    /// A path that vanished between the panel listing it and the filter running
    /// is not selectable, rather than a crash or an optimistic `true`.
    @Test("a file that no longer exists is not selectable")
    func disablesMissingFiles() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(
            !MarkdownPanel.shared.panel(
                NSOpenPanel(), shouldEnable: directory.appendingPathComponent("gone.md")))
    }

    /// Both panels are built by the same factory, which is the point: they had
    /// drifted into one-file-no-folders and many-files-no-folders.
    @Test("an open panel takes several files and folders, starting where it was told")
    func openPanelIsConfiguredOnce() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let panel = MarkdownPanel.open(startingIn: directory)
        #expect(panel.canChooseFiles)
        #expect(panel.canChooseDirectories)
        #expect(panel.allowsMultipleSelection)
        #expect(panel.directoryURL == directory)
        #expect(panel.delegate === MarkdownPanel.shared)
    }

    @Test("a save panel offers a markdown name and can make folders")
    func savePanelIsConfigured() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let panel = MarkdownPanel.save(
            startingIn: directory, named: MarkdownPanel.defaultDocumentName)
        #expect(panel.directoryURL == directory)
        #expect(panel.nameFieldStringValue == MarkdownPanel.defaultDocumentName)
        #expect(panel.canCreateDirectories)
    }
}
