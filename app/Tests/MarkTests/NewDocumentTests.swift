import AppKit
import Foundation
import Testing

@testable import MarkKit

/// Making a document, per `2026-08-26-new-documents-are-files-on-disk`.
///
/// Every test drives ``MainWindowController/createDocument(at:)`` rather than
/// ``MainWindowController/newDocument(_:)``: `runModal()` cannot run under
/// `swift test`, which is why the ADR's action is split into the half that runs
/// a panel and the half that does the work.
@Suite("New documents are files on disk")
@MainActor
struct NewDocumentTests {

    // MARK: - The file

    @Test("creates an empty file at the chosen URL")
    func createsAnEmptyFile() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let url = fixture.directory.appendingPathComponent("new.md")

        #expect(!FileManager.default.fileExists(atPath: url.path))
        try controller.createDocument(at: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "")
    }

    /// The ADR is explicit that there is no template: *"No template, no seeded
    /// heading, no front matter."* Pinned because a seeded `# Title` is the
    /// obvious thing for someone to add later, and it is content the reader
    /// then has to delete.
    @Test("the new document has no seeded content")
    func createsNoTemplate() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let url = fixture.directory.appendingPathComponent("empty.md")

        try controller.createDocument(at: url)
        let data = try Data(contentsOf: url)
        #expect(data.isEmpty)
    }

    // MARK: - The tab

    /// > opens the result as a permanent tab in the **focused group**
    ///
    /// Permanent, not preview: the preview slot is for skimming, and a file the
    /// reader has just named is the opposite of that.
    @Test("opens a permanent tab in the focused group")
    func opensAPermanentTab() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let url = fixture.directory.appendingPathComponent("permanent.md")

        let tab = try controller.createDocument(at: url)

        #expect(!tab.isPreview)
        #expect(controller.tabs.selected === tab)
        #expect(controller.groups.group(of: tab) === controller.groups.focused)
        #expect(tab.url == url.standardizedFileURL)
    }

    /// > The editor pane is shown and takes the keyboard, because a document
    /// > that was just made has nothing to read.
    ///
    /// The one route that opens the pane for you. Everywhere else *"a document
    /// opens read-only until you ask to edit it"* still holds.
    @Test("shows the editor and gives it the keyboard")
    func opensTheEditorFocused() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        #expect(!controller.isEditorVisible)

        try controller.createDocument(at: fixture.directory.appendingPathComponent("edit.md"))

        #expect(controller.isEditorVisible)
        #expect(controller.window?.firstResponder === controller.editor.textView)
    }

    // MARK: - Naming

    /// The rule from ``MarkdownPanel/markdownURL(for:)``. `.md` is **appended**
    /// rather than substituted, so a name that was never an extension —
    /// `notes.2026-08-26` — keeps its tail.
    @Test(
        "a name that is not markdown gets .md appended",
        arguments: [
            ("notes", "notes.md"),
            ("notes.txt", "notes.txt.md"),
            ("notes.2026-08-26", "notes.2026-08-26.md"),
            ("notes.md", "notes.md"),
            ("notes.markdown", "notes.markdown"),
            ("notes.mdown", "notes.mdown"),
            ("notes.mkd", "notes.mkd"),
            ("notes.mdx", "notes.mdx"),
            // The list is compared case-insensitively, here as in the sidebar.
            ("notes.MD", "notes.MD"),
        ])
    func appendsMarkdownExtension(input: String, expected: String) {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(input)
        #expect(MarkdownPanel.markdownURL(for: url).lastPathComponent == expected)
    }

    @Test("the default offered name is a markdown name")
    func defaultNameIsMarkdown() {
        let url = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent(MarkdownPanel.defaultDocumentName)
        #expect(TreeNode.isMarkdown(url))
    }

    /// **The hole appending an extension opens.**
    ///
    /// `NSSavePanel` confirms a replacement for the name the reader typed. Type
    /// `notes` where `notes.md` exists and it asks nothing, because `notes`
    /// does not exist — and then the appended `.md` lands on a file the reader
    /// never named. Refused, per the same rule the sidebar's drop applies.
    @Test("appending .md onto an existing file is refused, not confirmed")
    func refusesAnAppendedNameThatIsTaken() throws {
        let fixture = try TabFixture()
        let existing = fixture.file(named: "a.md")
        let typed = fixture.directory.appendingPathComponent("a")

        #expect(MarkdownPanel.target(forChosen: typed) == .nameTaken(existing))
    }

    /// The reader typed the extension, so the panel has already asked and been
    /// answered. Replacing is theirs to choose.
    @Test("a name typed in full still replaces")
    func fullNameStillReplaces() throws {
        let fixture = try TabFixture()
        let existing = fixture.file(named: "a.md")

        #expect(MarkdownPanel.target(forChosen: existing) == .create(existing))
    }

    @Test("an appended name that is free is created")
    func appendedFreeNameIsCreated() throws {
        let fixture = try TabFixture()
        let typed = fixture.directory.appendingPathComponent("brand-new")

        #expect(
            MarkdownPanel.target(forChosen: typed)
                == .create(fixture.directory.appendingPathComponent("brand-new.md")))
    }

    // MARK: - The lock

    /// **The one that matters**, and the reason creation goes through
    /// `MarkCore.save` rather than `FileManager.createFile`.
    ///
    /// A save panel can name a file that already exists — the reader clicks
    /// Replace. `2026-08-25-flock-write-locking` requires that *"every path
    /// that writes a user's document takes the lock first"*, so replacing a
    /// document another `mark` holds dirty must be refused rather than
    /// clobbered.
    ///
    /// A real `flock(2)` taken by this process, not a stub: the lock is a
    /// kernel fact, and a fake one would pass whether or not the production
    /// path ever calls `flock`.
    @Test("refuses to overwrite a document another process holds, and writes nothing")
    func refusesALockedTarget() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let url = fixture.directory.appendingPathComponent("held.md")
        let original = "# Do not lose me\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        #expect(throws: (any Error).self) {
            try controller.createDocument(at: url)
        }
        // Nothing was written, and nothing was truncated on the way to failing.
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        #expect(controller.tab(for: url) == nil)
    }

    /// The ordinary Replace case, with nobody holding the file: it is a write
    /// like any other, and the document that comes back is the empty one.
    @Test("replaces an unlocked existing file")
    func replacesAnUnlockedFile() throws {
        let fixture = try TabFixture()
        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let url = fixture.file(named: "a.md")
        #expect(try !String(contentsOf: url, encoding: .utf8).isEmpty)

        try controller.createDocument(at: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "")
    }

    // MARK: - Where it lands

    /// A document created outside the sidebar's root still opens. It does not
    /// move the root — that is ⌘⇧O's job, and a new file in `/tmp` silently
    /// relocating the tree would lose the reader's place.
    @Test("a document made outside the root opens without moving the root")
    func doesNotMoveTheSidebarRoot() throws {
        let fixture = try TabFixture()
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-elsewhere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        let controller = MainWindowController(root: fixture.directory, session: fixture.session)
        let root = controller.sidebar.root

        let tab = try controller.createDocument(at: elsewhere.appendingPathComponent("away.md"))

        #expect(controller.tabs.selected === tab)
        #expect(controller.sidebar.root == root)
    }
}
