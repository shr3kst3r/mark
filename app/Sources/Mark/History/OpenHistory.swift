import Foundation

/// One file, and when it was last deliberately opened.
///
/// A **path**, never a security-scoped bookmark
/// (`2026-08-26-opened-file-history`), carrying forward the position
/// ``SessionTab/path`` already takes: *"a moved file should reopen as 'missing'
/// rather than silently follow a rename the user did not ask us to track."*
public struct OpenHistoryEntry: Equatable, Sendable {

    /// Standardized, exactly as tab identity is
    /// (`MainWindowController.swift:334`), so `/a/./b.md` and `/a/b.md` are one
    /// file rather than two entries for the same document.
    public let url: URL

    /// When it was last opened. Updated in place on a re-open rather than
    /// producing a second entry — this is a history of *files*, not of events.
    public var lastOpened: Date

    public init(url: URL, lastOpened: Date) {
        self.url = url.standardizedFileURL
        self.lastOpened = lastOpened
    }
}

/// Which files were deliberately opened, most recent first.
///
/// `2026-08-26-opened-file-history`. mark already had two histories of the
/// wrong noun — ``Navigator`` remembers sidebar *roots*, and ``TabStore``'s MRU
/// ranks the tabs that are *still open* and forgets a tab the moment it closes.
/// This is the one about documents, and it outlives the tab, the window, and
/// the launch.
///
/// Deliberately free of AppKit and of the filesystem, for the reason
/// ``Navigator`` gives about itself: what this owns is the *semantics* — what
/// counts as an open, what deduplication means, what the cap evicts — which is
/// the part that is easy to get subtly wrong and impossible to see in a
/// screenshot. **It never stats a path.** Whether a file still exists is
/// ``HistoryWindowController``'s question, asked while the window is on screen
/// and not before.
///
/// Two rules from the ADR are not visible in this file and are enforced by its
/// callers, so they are written down here as well:
///
/// * **A preview open records nothing.** The sidebar's single click is a skim,
///   and `TabStore.open` already models a skim as not the same act as opening —
///   forty clicks down a folder leave one tab, and they leave no history.
/// * **Session restore records nothing.** Restoring tabs is the app
///   remembering, not the user opening. This holds today because
///   ``TabStore/restore(_:)`` builds tabs directly rather than calling
///   ``TabStore/open(_:preview:)``, which is a *rule* and not a happy accident:
///   route restore through the open path without suppressing this and every
///   relaunch stamps every restored tab with the launch time, turning the
///   history into a list of launches. `MainWindowControllerTests` fails the
///   build if that happens.
///
/// **There is deliberately no `OpenHistory.shared`.** The history is
/// application-wide, which is the sort of thing this codebase usually spells
/// with a singleton — ``ResidencyGovernor/shared``, ``ThemeController/shared``.
/// It is not spelled that way here, because a shared *default* is a default
/// that writes the user's real history from a test: `just swift-test` does not
/// set `MARK_SESSION_FILE`, so a `WindowCoordinator()` built in a test saves to
/// the developer's own `session.json`, and every window built without an
/// explicit history would have quietly recorded its fixture paths into it.
///
/// Instead the one instance the application has is owned by
/// ``WindowCoordinator`` and handed to each window it makes or adopts. A window
/// built without one — `mark-bench`, a test — records into a private history
/// that goes nowhere. `MainWindowControllerTests` pins that isolation. Please
/// do not add the singleton back.
@MainActor
public final class OpenHistory {

    /// **64, the same number ``Navigator/historyLimit`` uses**, for the same
    /// two reasons it gives — the list is persisted, and *"an unbounded list of
    /// every directory visited in a long session is both a large file and a
    /// small privacy leak in a tool that reads private notes."* A list of every
    /// **file** opened is that leak, sharper.
    ///
    /// The ADR fixes that there *is* a cap. The integer is a detail; moving it
    /// supersedes nothing.
    public static let defaultLimit = 64

    /// How many files this history remembers.
    public let limit: Int

    /// Most recently opened first.
    public private(set) var entries: [OpenHistoryEntry] = []

    /// Called after any change the session file should learn about.
    ///
    /// Deliberately **not** fired by ``restore(_:)``: restoring is reading the
    /// session file, and answering it with a write is a loop with a debounce in
    /// the middle.
    public var onChange: ((OpenHistory) -> Void)?

    public init(limit: Int = OpenHistory.defaultLimit) {
        self.limit = max(1, limit)
    }

    // MARK: - Reading

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// The entry for `url`, if this history has one.
    public func entry(for url: URL) -> OpenHistoryEntry? {
        let standardized = url.standardizedFileURL
        return entries.first { $0.url == standardized }
    }

    // MARK: - Writing

    /// Note that a file was opened.
    ///
    /// Re-opening a file **moves** its entry to the front and updates its
    /// timestamp; it never appends a second. The oldest entries fall off the
    /// end once the list is over ``limit``.
    ///
    /// - Parameter date: injected so tests do not race a clock.
    public func record(_ url: URL, at date: Date = Date()) {
        let entry = OpenHistoryEntry(url: url, lastOpened: date)
        entries.removeAll { $0.url == entry.url }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeSubrange(limit...) }
        // `lastPathComponent`, never the full path: this tool reads private
        // notes, and `Log.watch`'s "paths only, never contents" does not go far
        // enough for a log line that would otherwise record where they live.
        Log.app.info(
            "history: \(entry.url.lastPathComponent, privacy: .public) (\(self.entries.count) of \(self.limit))"
        )
        onChange?(self)
    }

    /// Forget one file — ⌫ in the history window.
    public func remove(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard entries.contains(where: { $0.url == standardized }) else { return }
        entries.removeAll { $0.url == standardized }
        onChange?(self)
    }

    /// Forget everything.
    ///
    /// The only way to forget, and irreversible — which is why the window puts
    /// a confirmation in front of it. Logged with the count discarded, because
    /// someone reporting *"it lost my history"* needs to be able to tell a bug
    /// from a button they pressed.
    public func clear() {
        guard !entries.isEmpty else { return }
        Log.app.info("history cleared (\(self.entries.count) discarded)")
        entries.removeAll()
        onChange?(self)
    }

    /// Adopt what the session file held, newest first.
    ///
    /// Truncated to ``limit`` on the way in, so a hand-edited session file — or
    /// one written by a build with a larger cap — cannot leave this holding
    /// more than it promises.
    public func restore(_ restored: [OpenHistoryEntry]) {
        entries = Array(restored.prefix(limit))
    }
}

// MARK: - The session file

extension OpenHistory {

    /// This history as the session file spells it.
    public var sessionEntries: [SessionHistoryEntry] {
        entries.map {
            SessionHistoryEntry(
                path: $0.url.path,
                lastOpened: $0.lastOpened.timeIntervalSince1970
            )
        }
    }

    /// Adopt what a session file held.
    ///
    /// An entry with an empty path is dropped rather than restored as a URL
    /// pointing at the current directory — a hand-edited or truncated file
    /// should cost the reader one row, never a row that opens the wrong thing.
    public func restore(session restored: [SessionHistoryEntry]) {
        restore(
            restored.compactMap { entry in
                guard !entry.path.isEmpty else { return nil }
                return OpenHistoryEntry(
                    url: URL(fileURLWithPath: entry.path),
                    lastOpened: Date(timeIntervalSince1970: entry.lastOpened)
                )
            }
        )
    }
}
