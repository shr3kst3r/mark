import AppKit
import Foundation

/// Renaming, duplicating, trashing, and making folders — from the sidebar.
///
/// The tree had no context menu at all. You could see a file, open it, and
/// nothing else; renaming one meant going to Finder, and a notes directory is a
/// thing people reorganise. The breadcrumb bar already had **New Document
/// Here…**, which made the absence on the rows themselves read as an oversight
/// rather than a decision.
///
/// # The rule these all obey
///
/// **Refuse rather than clobber.** It is the rule the whole write path is built
/// on — `2026-08-25-flock-write-locking` refuses a CLI write to a document a
/// window holds unsaved changes to, and `tasks::toggle` re-verifies the byte
/// span before writing one byte. Moving or deleting a file is a larger action
/// than either, so:
///
/// * a document with **unsaved changes** cannot be renamed, duplicated over, or
///   trashed — the buffer would be writing to a path that no longer means what
///   it meant;
/// * a destination that **already exists** is refused, never overwritten;
/// * trashing goes through `NSWorkspace.recycle`, so it is in the Trash and
///   Finder can put it back. Nothing here calls `removeItem`.
///
/// Every refusal is a named error the caller shows, because the failure mode
/// this is guarding against — a rename that silently did nothing — is worse
/// than the dialog.
@MainActor
public enum FileOperations {

    public enum OperationError: LocalizedError {
        case unsavedChanges(URL)
        case alreadyExists(URL)
        case emptyName
        case invalidName(String)
        case failed(URL, any Error)

        public var errorDescription: String? {
            switch self {
            case .unsavedChanges(let url):
                return "\u{201C}\(url.lastPathComponent)\u{201D} has unsaved changes."
            case .alreadyExists(let url):
                return "\u{201C}\(url.lastPathComponent)\u{201D} already exists."
            case .emptyName:
                return "The name cannot be empty."
            case .invalidName(let name):
                return "\u{201C}\(name)\u{201D} is not a usable name."
            case .failed(let url, let error):
                return "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .unsavedChanges:
                return "Save it first, or close its tab."
            case .alreadyExists:
                return "Choose a different name."
            case .invalidName:
                return "A name cannot contain a slash or a colon."
            default:
                return nil
            }
        }
    }

    /// Whether a name can be a filename here.
    ///
    /// A `/` is a path separator and a `:` is one to Finder — both silently
    /// produce a file somewhere other than where the reader meant. A leading
    /// `.` is allowed: a dotfile is a legitimate thing to make, and the sidebar
    /// has a switch for showing them.
    public static func isUsableName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed == "." || trimmed == ".." { return false }
        return !trimmed.contains("/") && !trimmed.contains(":")
    }

    /// Rename `url` to `name`, in the same directory.
    ///
    /// - Parameter isDirty: whether the app holds unsaved changes for a path.
    ///   Passed in rather than reached for, so this type has no opinion about
    ///   where tabs live and can be tested without any.
    /// - Returns: the new URL.
    @discardableResult
    public static func rename(
        _ url: URL, to name: String, isDirty: (URL) -> Bool
    ) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OperationError.emptyName }
        guard isUsableName(trimmed) else { throw OperationError.invalidName(trimmed) }
        guard !isDirty(url) else { throw OperationError.unsavedChanges(url) }

        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        // A rename that only changes case is a move onto itself on a
        // case-insensitive volume, which `fileExists` would call a collision.
        if destination.path.caseInsensitiveCompare(url.path) != .orderedSame {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw OperationError.alreadyExists(destination)
            }
        }
        guard destination.path != url.path else { return url }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw OperationError.failed(url, error)
        }
        return destination
    }

    /// Copy `url` beside itself, as `name copy.md`, `name copy 2.md`, …
    @discardableResult
    public static func duplicate(_ url: URL, isDirty: (URL) -> Bool) throws -> URL {
        guard !isDirty(url) else { throw OperationError.unsavedChanges(url) }

        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let destination = availableName(in: directory, base: base, extension: ext)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw OperationError.failed(url, error)
        }
        return destination
    }

    /// Move `url` to the Trash.
    ///
    /// `NSWorkspace.recycle`, never `removeItem`: this is a viewer for
    /// somebody's notes, and an action that cannot be undone does not belong in
    /// a context menu one row away from Open.
    public static func trash(_ url: URL, isDirty: (URL) -> Bool) throws {
        guard !isDirty(url) else { throw OperationError.unsavedChanges(url) }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            throw OperationError.failed(url, error)
        }
    }

    /// Make a folder inside `directory`.
    @discardableResult
    public static func makeFolder(in directory: URL, named name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OperationError.emptyName }
        guard isUsableName(trimmed) else { throw OperationError.invalidName(trimmed) }

        let destination = directory.appendingPathComponent(trimmed)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw OperationError.alreadyExists(destination)
        }
        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false)
        } catch {
            throw OperationError.failed(destination, error)
        }
        return destination
    }

    /// `base copy.ext`, then `base copy 2.ext`, … — the first one not taken.
    ///
    /// Finder's naming, because a duplicate that appears under a name the
    /// reader recognises is one they can find again.
    static func availableName(in directory: URL, base: String, extension ext: String) -> URL {
        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            return directory.appendingPathComponent(name)
        }
        var url = candidate(" copy")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate(" copy \(counter)")
            counter += 1
            // A directory with thousands of copies is not a case worth looping
            // forever over; fall back to something unique.
            if counter > 1000 {
                return candidate(" copy \(UUID().uuidString.prefix(8))")
            }
        }
        return url
    }

    /// Ask for a name, with the extension pre-selected the way Finder does.
    ///
    /// An alert with an accessory text field rather than a sheet of our own:
    /// this is a one-field question, and the platform has a control for it.
    public static func askForName(
        title: String,
        message: String?,
        initial: String,
        confirm: String,
        in window: NSWindow?,
        then completion: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = "Name"
        alert.accessoryView = field
        // Without this the first Tab moves focus out of the field the alert
        // exists to collect.
        alert.window.initialFirstResponder = field

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(response == .alertFirstButtonReturn && !name.isEmpty ? name : nil)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
            // Selecting the base name and not the extension, which is what
            // renaming in Finder does and what someone renaming `notes.md`
            // to `runbook.md` wants.
            selectBaseName(in: field, of: initial)
        } else {
            selectBaseName(in: field, of: initial)
            finish(alert.runModal())
        }
    }

    private static func selectBaseName(in field: NSTextField, of name: String) {
        guard let editor = field.currentEditor() else { return }
        let stem = (name as NSString).deletingPathExtension
        editor.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }
}
