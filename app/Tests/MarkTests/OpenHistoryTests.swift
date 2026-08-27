import Foundation
import Testing

@testable import MarkKit

/// The opened-file history's semantics (`2026-08-26-opened-file-history`).
///
/// No AppKit and no filesystem, matching the type under test — which is the
/// same posture `NavigatorTests` takes for the same reason: what is being
/// asserted here is *what counts as an open*, which is the part that is easy to
/// get subtly wrong and impossible to see in a screenshot.
@Suite("The opened-file history")
@MainActor
struct OpenHistoryTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test("it lists the most recently opened file first")
    func mostRecentFirst() {
        let history = OpenHistory()
        history.record(url("/notes/a.md"))
        history.record(url("/notes/b.md"))
        history.record(url("/notes/c.md"))
        #expect(history.entries.map(\.url.lastPathComponent) == ["c.md", "b.md", "a.md"])
    }

    /// A history of **files**, not of open events: opening the same document
    /// twice moves it, and the list does not grow.
    @Test("re-opening a file moves it to the front and updates its timestamp")
    func reopeningMovesRatherThanAppends() {
        let history = OpenHistory()
        let then = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        history.record(url("/notes/a.md"), at: then)
        history.record(url("/notes/b.md"), at: then)
        history.record(url("/notes/a.md"), at: now)

        #expect(history.count == 2)
        #expect(history.entries.first?.url.lastPathComponent == "a.md")
        #expect(history.entries.first?.lastOpened == now)
    }

    /// The cap exists because the list is persisted, and because *"an unbounded
    /// list of every directory visited in a long session is both a large file
    /// and a small privacy leak in a tool that reads private notes"* —
    /// `Navigator`'s words, about a weaker version of this list.
    @Test("the cap holds, and it evicts the oldest")
    func theCapHolds() {
        let history = OpenHistory(limit: 4)
        for index in 0..<10 { history.record(url("/notes/\(index).md")) }
        #expect(history.count == 4)
        #expect(history.entries.map(\.url.lastPathComponent) == ["9.md", "8.md", "7.md", "6.md"])
    }

    @Test("the default cap is Navigator's 64")
    func defaultCapMatchesNavigator() {
        #expect(OpenHistory.defaultLimit == Navigator.historyLimit)
        #expect(OpenHistory().limit == 64)
    }

    /// Tab identity is `url.standardizedFileURL` (`MainWindowController:334`),
    /// and a history that disagreed would show one document as two rows.
    @Test("URLs are standardized, so one document is one entry")
    func urlsAreStandardized() {
        let history = OpenHistory()
        history.record(url("/notes/a.md"))
        history.record(url("/notes/./a.md"))
        history.record(url("/notes/sub/../a.md"))
        #expect(history.count == 1)
    }

    /// The store owns semantics and nothing else: 64 `stat`s belong to the
    /// window, while it is on screen, and not to every recorded open.
    @Test("recording never touches the filesystem")
    func recordingDoesNotStat() {
        let history = OpenHistory()
        let missing = url("/nowhere/at/all/\(UUID().uuidString).md")
        history.record(missing)
        #expect(history.count == 1)
        #expect(history.entry(for: missing) != nil)
    }

    @Test("clearing empties it and reports the change")
    func clearing() {
        let history = OpenHistory()
        var changes = 0
        history.record(url("/notes/a.md"))
        history.onChange = { _ in changes += 1 }
        history.record(url("/notes/b.md"))
        #expect(changes == 1)

        history.clear()
        #expect(history.isEmpty)
        #expect(changes == 2)

        // Nothing to forget is not a change, so it does not schedule a write.
        history.clear()
        #expect(changes == 2)
    }

    @Test("one file can be forgotten on its own")
    func forgettingOne() {
        let history = OpenHistory()
        history.record(url("/notes/a.md"))
        history.record(url("/notes/b.md"))
        history.remove(url("/notes/a.md"))
        #expect(history.entries.map(\.url.lastPathComponent) == ["b.md"])
        // Forgetting something that is not there changes nothing.
        var changes = 0
        history.onChange = { _ in changes += 1 }
        history.remove(url("/notes/zzz.md"))
        #expect(changes == 0)
    }

    /// Restoring is *reading* the session file. Answering it with a write would
    /// be a loop with a debounce in the middle.
    @Test("restoring does not report a change")
    func restoringIsSilent() {
        let history = OpenHistory()
        var changes = 0
        history.onChange = { _ in changes += 1 }
        history.restore([OpenHistoryEntry(url: url("/notes/a.md"), lastOpened: Date())])
        #expect(history.count == 1)
        #expect(changes == 0)
    }

    @Test("a restored list longer than the cap is truncated on the way in")
    func restoreRespectsTheCap() {
        let history = OpenHistory(limit: 3)
        history.restore(
            (0..<10).map {
                OpenHistoryEntry(url: url("/notes/\($0).md"), lastOpened: Date())
            })
        #expect(history.count == 3)
    }

    // MARK: - The session file

    @Test("it round-trips through the session file's shape")
    func roundTrip() {
        let history = OpenHistory()
        let when = Date(timeIntervalSince1970: 1_756_000_000)
        history.record(url("/notes/a.md"), at: when)
        history.record(url("/notes/b.md"), at: when)

        let restored = OpenHistory()
        restored.restore(session: history.sessionEntries)

        #expect(restored.entries.map(\.url) == history.entries.map(\.url))
        #expect(restored.entries.first?.lastOpened == when)
    }

    /// A hand-edited or truncated file should cost the reader one row, never a
    /// row that opens the wrong thing.
    @Test("an entry with no path is dropped rather than restored as the working directory")
    func emptyPathsAreDropped() {
        let history = OpenHistory()
        history.restore(
            session: [
                SessionHistoryEntry(path: "", lastOpened: 0),
                SessionHistoryEntry(path: "/notes/a.md", lastOpened: 0),
            ])
        #expect(history.entries.map(\.url.lastPathComponent) == ["a.md"])
    }
}
