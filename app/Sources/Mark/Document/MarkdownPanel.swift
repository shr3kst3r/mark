import AppKit
import Foundation

/// The one place that configures an open or save panel for markdown.
///
/// Both open panels used to build their own `NSOpenPanel` inline, and they had
/// drifted: ⌘T allowed multiple selection and started in the folder you were
/// reading, ⌘O did neither. Same act, two behaviours. This type is the shared
/// configuration, and `2026-08-26-new-documents-are-files-on-disk` makes it the
/// shared *answer to what markdown is* as well.
@MainActor
public final class MarkdownPanel: NSObject, NSOpenSavePanelDelegate {

    /// `NSOpenPanel.delegate` is `weak`, so the delegate cannot be a temporary
    /// made at the call site — it would be deallocated before the panel runs
    /// and every row would fall back to enabled.
    public static let shared = MarkdownPanel()

    private override init() { super.init() }

    // MARK: - Which files are selectable

    /// **Not `allowedContentTypes`, and this is the reason.**
    ///
    /// `2026-08-26-new-documents-are-files-on-disk`:
    ///
    /// > **What counts as markdown is `TreeDataSource.markdownExtensions`,
    /// > never UTType and never LaunchServices.**
    ///
    /// Three of the five extensions mark treats as markdown — `.mdown`, `.mkd`
    /// and `.mdx` — have no declared UTI. LaunchServices synthesises a `dyn.…`
    /// type for them that conforms only to `public.data`, so
    /// `allowedContentTypes = [.plainText]` draws them greyed out and refuses
    /// to select them, while the sidebar two inches away opens them happily.
    ///
    /// The assembled bundle declares those extensions
    /// (`UTImportedTypeDeclarations` in `scripts/assemble-bundle.sh`), which
    /// fixes Finder — but **a bundle's type declarations are inert until
    /// LaunchServices has registered it**. A UTType-based filter would
    /// therefore behave one way in `/Applications` and another under
    /// `swift test` and `swift run`, which is precisely the class of bug
    /// `2026-08-24-cli-app-unix-socket-ipc` refused to accept elsewhere: *"no
    /// class of bug that only appears unsigned"*.
    ///
    /// So the filter asks ``TreeNode/isMarkdown(_:)`` — the same list the
    /// sidebar draws from, mirrored into `core/src/tree.rs` and pinned there by
    /// `MarkCoreTests`. The next person to reach for the obvious idiom will
    /// find this comment and `OpenPanelTests` in the way.
    public nonisolated func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        // A directory is always selectable: it is either somewhere to descend
        // into or, for ⌘O, a place to root the sidebar.
        if isDirectory.boolValue { return true }
        return TreeNode.isMarkdown(url)
    }

    // MARK: - Panels

    /// An open panel: markdown files, folders, as many as you like.
    ///
    /// Folders are choosable because every other route into the app already
    /// treats one as a place — `mark open notes/` and a folder dropped on the
    /// window both root the sidebar there. ⌘O was the one route that refused.
    public static func open(startingIn directory: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = directory
        panel.delegate = shared
        return panel
    }

    /// A save panel for naming a document that does not exist yet.
    ///
    /// The extension is **not** enforced by the panel. `allowedContentTypes`
    /// would carry the same LaunchServices dependency as above, and would
    /// additionally refuse `.mdx` in a development build; ``markdownURL(for:)``
    /// applies the rule afterwards instead, identically everywhere.
    public static func save(startingIn directory: URL?, named name: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        return panel
    }

    // MARK: - Naming

    /// The default name offered for a new document.
    public static let defaultDocumentName = "Untitled.md"

    /// `url`, guaranteed to be a markdown filename.
    ///
    /// A name whose extension is not one of ours gets `.md` **appended**, so
    /// `notes` becomes `notes.md` and `notes.txt` becomes `notes.txt.md`. The
    /// ADR takes that surprise deliberately:
    ///
    /// > Accepted over the alternative, which is creating a file mark itself
    /// > then refuses to reopen and draws dimmed in its own sidebar.
    ///
    /// Appending rather than replacing keeps the name the reader typed intact,
    /// which matters when the "extension" was never one — `notes.2026-08-26`
    /// would otherwise lose its date.
    public static func markdownURL(for url: URL) -> URL {
        TreeNode.isMarkdown(url) ? url : url.appendingPathExtension("md")
    }

    /// What a save panel's answer actually means.
    ///
    /// **The hole that appending an extension opens.** `NSSavePanel` asks
    /// "replace?" about the name the reader typed. When ``markdownURL(for:)``
    /// changes that name, the panel confirmed the wrong file: type `notes`
    /// where `notes.md` already exists and the panel sees no collision,
    /// because `notes` does not exist. Creating then would destroy a note the
    /// reader never named.
    ///
    /// So a *changed* name that is already taken is refused, the rule
    /// `TreeViewController.drop(_:into:move:)` already applies — *"silently
    /// replacing a note with a same-named one from somewhere else is data loss
    /// that looks like a successful drop"*. A name typed in full still
    /// replaces, because there the panel has asked and the reader has
    /// answered.
    ///
    /// A pure function of the URL and the filesystem, so the rule is testable
    /// without a modal.
    public static func target(forChosen chosen: URL) -> NewDocumentTarget {
        let url = markdownURL(for: chosen)
        if url != chosen, FileManager.default.fileExists(atPath: url.path) {
            return .nameTaken(url)
        }
        return .create(url)
    }
}

/// Where ``MarkdownPanel/target(forChosen:)`` says a new document should go.
public enum NewDocumentTarget: Equatable, Sendable {
    /// Write here. The path may differ from what the reader typed, by an
    /// appended `.md`.
    case create(URL)
    /// Appending `.md` landed on a file that already exists, which the panel
    /// never asked about. Write nothing.
    case nameTaken(URL)
}
