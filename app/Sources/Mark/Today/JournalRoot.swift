import Foundation

/// A directory that is laid out as a journal: dated dailies under `daily/` and
/// one directory per effort under `projects/`.
///
/// `2026-08-31-today-page`. The **Today** window is the only thing in the app
/// that knows this layout exists, and this is the only type that knows how to
/// recognise one. Everything downstream is handed a value of this type and
/// never looks at a path component again.
public struct JournalRoot: Equatable, Sendable {

    /// The directory holding `daily/` and `projects/`.
    public let url: URL

    public var daily: URL { url.appendingPathComponent(JournalRoot.dailyDirectory) }
    public var projects: URL { url.appendingPathComponent(JournalRoot.projectsDirectory) }

    public init(url: URL) {
        self.url = url
    }

    /// The two directories whose presence *is* the definition.
    ///
    /// Both are required. `daily/` alone matches a great many note trees and
    /// `projects/` alone matches most source repositories; the pair is
    /// specific enough that the walk below cannot wander into somebody's code
    /// checkout and call it a journal.
    public static let dailyDirectory = "daily"
    public static let projectsDirectory = "projects"

    /// How far up the walk goes before giving up.
    ///
    /// A bound rather than "until `/`" because the walk runs on the main actor
    /// when a window opens, and a start directory 60 levels deep should cost a
    /// bounded number of `stat`s. Nothing real is this deep; the number exists
    /// so the loop cannot be unbounded, not because 24 is meaningful.
    public static let maximumAscent = 24

    /// The journal `start` is in, or `nil`.
    ///
    /// The sidebar's root is the start (the answer to *"how should the page
    /// find your journal"*), and it is routinely pointed at somewhere **inside**
    /// the journal — `projects/`, or `daily/2026/08` — so the search is an
    /// ascent rather than a test of one directory. A worktree is found the same
    /// way and on its own terms: `.worktrees/journal-mellow` has both
    /// directories, so it is its own journal and its dailies are the ones you
    /// see, which is the answer that matches what is checked out in the window
    /// you asked from.
    ///
    /// - Parameter start: a directory, or a file whose directory is used.
    public static func find(
        from start: URL,
        fileManager: FileManager = .default
    ) -> JournalRoot? {
        var directory = directoryPart(of: start, fileManager: fileManager)
        for _ in 0..<maximumAscent {
            if holdsAJournal(directory, fileManager: fileManager) {
                return JournalRoot(url: directory)
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            // `/` is its own parent, which is how the walk ends on a machine
            // where nothing above the start is a journal.
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
        return nil
    }

    /// Whether this exact directory is a journal root.
    public static func holdsAJournal(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        isDirectory(directory.appendingPathComponent(dailyDirectory), fileManager: fileManager)
            && isDirectory(
                directory.appendingPathComponent(projectsDirectory), fileManager: fileManager)
    }

    /// `start` itself when it is a directory, its parent when it is a file.
    ///
    /// Symlinks are resolved because `/tmp` is one on macOS, which is where
    /// every test's fixture journal lives; comparing an unresolved
    /// `/tmp/…` path against a resolved `/private/tmp/…` one is the classic
    /// way for a fixture to pass in isolation and fail in the suite.
    private static func directoryPart(of start: URL, fileManager: FileManager) -> URL {
        let resolved = start.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return resolved
        }
        return resolved.deletingLastPathComponent().standardizedFileURL
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
