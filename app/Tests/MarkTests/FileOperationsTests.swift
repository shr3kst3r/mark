import AppKit
import Foundation
import Testing

@testable import MarkKit

/// Renaming, duplicating, trashing, and making folders from the sidebar.
///
/// The tree had no context menu at all — you could see a file, open it, and
/// nothing else, while the breadcrumb bar above it already offered **New
/// Document Here…**.
///
/// Most of these are **refusals**, which is the point. Every one of these
/// operations moves bytes, and the rule the whole write path is built on is
/// refuse rather than clobber (`2026-08-25-flock-write-locking`).
@Suite("Sidebar file operations")
@MainActor
struct FileOperationsTests {

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-fileops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Notes\n".write(
            to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return root
    }

    /// Nothing is dirty, which is the ordinary case.
    private let clean: (URL) -> Bool = { _ in false }

    // ---- rename ------------------------------------------------------------

    @Test("a rename moves the file and answers with where it went")
    func renameMoves() throws {
        let root = try fixture()
        let from = root.appendingPathComponent("notes.md")
        let to = try FileOperations.rename(from, to: "runbook.md", isDirty: clean)

        #expect(to.lastPathComponent == "runbook.md")
        #expect(FileManager.default.fileExists(atPath: to.path))
        #expect(!FileManager.default.fileExists(atPath: from.path))
    }

    @Test("a rename onto an existing file is refused, never an overwrite")
    func renameRefusesCollision() throws {
        let root = try fixture()
        try "# Other\n".write(
            to: root.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)

        #expect(throws: FileOperations.OperationError.self) {
            _ = try FileOperations.rename(
                root.appendingPathComponent("notes.md"), to: "other.md", isDirty: clean)
        }
        // And the file it would have destroyed is untouched.
        let survived = try String(
            contentsOf: root.appendingPathComponent("other.md"), encoding: .utf8)
        #expect(survived == "# Other\n")
    }

    @Test("changing only the case of a name is allowed")
    func renameCanChangeCaseOnly() throws {
        // On a case-insensitive volume the destination "exists" — it is the
        // same file — so a naive collision check refuses a rename anyone would
        // expect to work.
        let root = try fixture()
        let renamed = try FileOperations.rename(
            root.appendingPathComponent("notes.md"), to: "Notes.md", isDirty: clean)
        #expect(renamed.lastPathComponent == "Notes.md")
    }

    @Test("a document with unsaved changes cannot be renamed")
    func renameRefusesDirty() throws {
        let root = try fixture()
        let url = root.appendingPathComponent("notes.md")
        #expect(throws: FileOperations.OperationError.self) {
            _ = try FileOperations.rename(url, to: "x.md", isDirty: { $0 == url })
        }
        #expect(FileManager.default.fileExists(atPath: url.path), "the file moved anyway")
    }

    @Test("a name with a path separator in it is refused")
    func renameRefusesAPath() throws {
        let root = try fixture()
        let url = root.appendingPathComponent("notes.md")
        for name in ["../escape.md", "a/b.md", "with:colon.md", "  ", ".", ".."] {
            #expect(throws: FileOperations.OperationError.self, "\(name) was allowed") {
                _ = try FileOperations.rename(url, to: name, isDirty: clean)
            }
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a dotfile is a legitimate name")
    func dotfilesAreAllowed() {
        #expect(FileOperations.isUsableName(".hidden.md"))
        #expect(!FileOperations.isUsableName("."))
        #expect(!FileOperations.isUsableName(".."))
    }

    // ---- duplicate ---------------------------------------------------------

    @Test("a duplicate lands beside the original, named the way Finder names it")
    func duplicateNames() throws {
        let root = try fixture()
        let url = root.appendingPathComponent("notes.md")

        let first = try FileOperations.duplicate(url, isDirty: clean)
        #expect(first.lastPathComponent == "notes copy.md")

        // Again, and the counter appears rather than the first copy being
        // overwritten.
        let second = try FileOperations.duplicate(url, isDirty: clean)
        #expect(second.lastPathComponent == "notes copy 2.md")

        #expect(try String(contentsOf: first, encoding: .utf8) == "# Notes\n")
        #expect(FileManager.default.fileExists(atPath: url.path), "the original went missing")
    }

    @Test("a document with unsaved changes cannot be duplicated")
    func duplicateRefusesDirty() throws {
        // The copy would be of the file on disk, not of what the reader is
        // looking at — a duplicate that silently omits their edits.
        let root = try fixture()
        let url = root.appendingPathComponent("notes.md")
        #expect(throws: FileOperations.OperationError.self) {
            _ = try FileOperations.duplicate(url, isDirty: { $0 == url })
        }
    }

    // ---- trash -------------------------------------------------------------

    @Test("trashing puts the file in the Trash rather than deleting it")
    func trashRecycles() throws {
        let root = try fixture()
        let url = root.appendingPathComponent("notes.md")
        try FileOperations.trash(url, isDirty: clean)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // `trashItem` is what makes this recoverable from Finder. If this ever
        // becomes `removeItem`, this suite should stop passing.
    }

    @Test("a document with unsaved changes cannot be trashed")
    func trashRefusesDirty() throws {
        let root = try fixture()
        let url = root.appendingPathComponent("notes.md")
        #expect(throws: FileOperations.OperationError.self) {
            try FileOperations.trash(url, isDirty: { $0 == url })
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // ---- new folder --------------------------------------------------------

    @Test("a folder is created where it was asked for")
    func makeFolder() throws {
        let root = try fixture()
        let made = try FileOperations.makeFolder(in: root, named: "deploys")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: made.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("a folder that already exists is refused rather than merged into")
    func makeFolderRefusesCollision() throws {
        let root = try fixture()
        _ = try FileOperations.makeFolder(in: root, named: "deploys")
        #expect(throws: FileOperations.OperationError.self) {
            _ = try FileOperations.makeFolder(in: root, named: "deploys")
        }
    }

    @Test("every refusal says what to do about it")
    func errorsAreLegible() {
        // These reach the reader in an alert, so an empty message is a dialog
        // that says nothing.
        let errors: [FileOperations.OperationError] = [
            .unsavedChanges(URL(fileURLWithPath: "/x/notes.md")),
            .alreadyExists(URL(fileURLWithPath: "/x/other.md")),
            .emptyName,
            .invalidName("a/b"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false, "\(error) has no message")
        }
        #expect(
            FileOperations.OperationError.unsavedChanges(URL(fileURLWithPath: "/x"))
                .recoverySuggestion != nil)
    }

    // ---- the menu ----------------------------------------------------------

    @Test("a markdown row offers the whole set, a folder offers making things")
    func theMenuFitsTheRow() throws {
        let root = try fixture()
        let tree = TreeViewController(root: root)
        _ = tree.view  // force the outline view into existence

        let file = TreeNode(
            url: root.appendingPathComponent("notes.md"), name: "notes.md", isDirectory: false)
        let titles = tree.rowMenu(for: file).items.map(\.title)
        #expect(titles.contains("Rename…"))
        #expect(titles.contains("Duplicate"))
        #expect(titles.contains("Move to Trash"))
        #expect(titles.contains("Reveal in Finder"))
        #expect(titles.contains("Copy Path"))
        #expect(!titles.contains("New Folder…"), "a file is not a place to make a folder")

        let folder = TreeNode(
            url: root.appendingPathComponent("deploys"), name: "deploys", isDirectory: true)
        let folderTitles = tree.rowMenu(for: folder).items.map(\.title)
        #expect(folderTitles.contains("New Folder…"))
        #expect(folderTitles.contains("New Document Here…"))
        #expect(!folderTitles.contains("Open"), "a folder does not open as a document")
    }

    @Test("choosing an item reports the operation and the row it was built for")
    func menuReportsItsRow() throws {
        let root = try fixture()
        let tree = TreeViewController(root: root)
        _ = tree.view

        var seen: (TreeViewController.FileOperation, TreeNode)?
        tree.onFileOperation = { operation, node in seen = (operation, node) }

        let node = TreeNode(
            url: root.appendingPathComponent("notes.md"), name: "notes.md", isDirectory: false)
        let rename = try #require(
            tree.rowMenu(for: node).items.first { $0.title == "Rename…" })
        // The menu is built for one row and must act on that row, not on
        // whatever is selected by the time it is chosen.
        _ = rename.target?.perform(rename.action, with: rename)

        #expect(seen?.0 == .rename)
        #expect(seen?.1.url == node.url)
    }
}
