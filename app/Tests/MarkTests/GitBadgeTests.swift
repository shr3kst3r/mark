import AppKit
import Foundation
import Testing

@testable import MarkKit

/// `+12 −3` in the directory view, and what it is allowed to cost.
///
/// `2026-08-28-git-badges-ride-the-sidebar-poll` names one constraint as the one
/// that regresses silently:
///
/// > The laziness assertions extend to git. `SidebarPollTests` must gain the git
/// > equivalent of `quietPollReadsNothing`: a quiet poll over a repository whose
/// > index has not moved runs **no** git process.
///
/// ``quietPollRunsNoGit`` is that. Everything else here exists because the
/// service's whole design is "per repository, not per file", and every one of
/// these assertions is a way that could quietly become "per file" again.
///
/// The query is faked rather than real. That is not to avoid `git` — the core's
/// own `git_fixture.rs` runs it for real — it is because *counting invocations*
/// is the property under test, and nothing about the real binary makes that
/// countable.
@Suite("Sidebar — git badges")
@MainActor
struct GitBadgeTests {

    /// A `GitQuerying` that counts, and answers whatever it is told to.
    final class CountingQuery: GitQuerying, @unchecked Sendable {
        var report: GitReport
        var baseText: String?
        /// Bumped by the caller to simulate a commit, a stage, or a checkout.
        var stamp = GitStamp(index: 1, head: 1)

        private(set) var statusCalls = 0
        private(set) var stampCalls = 0
        private(set) var baseCalls = 0
        private(set) var countCalls = 0
        private(set) var statusPaths: [String] = []

        init(report: GitReport, baseText: String? = nil) {
            self.report = report
            self.baseText = baseText
        }

        func status(path: String) throws -> GitReport {
            statusCalls += 1
            statusPaths.append(path)
            return report
        }

        func stamp(indexPath: String, headPath: String) -> GitStamp {
            stampCalls += 1
            return stamp
        }

        func base(path: String) throws -> GitBase {
            baseCalls += 1
            return GitBase(
                repo: report.repo?.root, head: report.repo?.head, branch: nil,
                tracked: baseText != nil, base: baseText)
        }

        func counts(base: String, new: String) throws -> (added: Int, removed: Int) {
            countCalls += 1
            let old = base.isEmpty ? 0 : base.split(separator: "\n", omittingEmptySubsequences: false).count
            let now = new.isEmpty ? 0 : new.split(separator: "\n", omittingEmptySubsequences: false).count
            return (max(0, now - old), max(0, old - now))
        }

        /// Lines a file "contains", for the untracked-count path. Keyed by
        /// path so a test can say what a row should end up badged with.
        var lineCounts: [String: Int] = [:]
        private(set) var lineCountCalls = 0

        func lineCount(path: String) -> Int? {
            lineCountCalls += 1
            return lineCounts[path]
        }

        func reset() {
            statusCalls = 0
            lineCountCalls = 0
            stampCalls = 0
            baseCalls = 0
            countCalls = 0
            statusPaths.removeAll()
        }
    }

    private func repo(root: String, head: String = "abc1234") -> GitRepo {
        GitRepo(
            root: root,
            gitDir: root + "/.git",
            indexPath: root + "/.git/index",
            headPath: root + "/.git/HEAD",
            head: head,
            branch: "main")
    }

    /// Wait for the service's background hop to land. The work queue is real,
    /// so the answer arrives a tick later — which is the behaviour, not an
    /// artefact: a badge must never be computed on the draw path.
    private func settle() async {
        for _ in 0..<50 {
            await _Concurrency.Task.yield()
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The gate

    /// **The gate.** A poll over a repository whose stamps have not moved runs
    /// no `git` process at all.
    @Test("a quiet poll runs no git process")
    func quietPollRunsNoGit() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "weekly.md", status: .modified, added: 12, removed: 3)
                ]))
        let service = GitBadgeService(query: query)
        service.request(for: URL(fileURLWithPath: "/notes/weekly.md"))
        await settle()
        #expect(query.statusCalls == 1, "discovery should have queried once")

        query.reset()
        #expect(service.poll().isEmpty, "a quiet poll claimed a repository was stale")
        #expect(service.poll().isEmpty)
        #expect(service.poll().isEmpty)
        await settle()

        #expect(
            query.statusCalls == 0,
            "three quiet polls ran \(query.statusCalls) git process(es)")
        // It did stat: the gate is two syscalls, not zero work.
        #expect(query.stampCalls == 3, "the gate should be checked once per poll")
    }

    @Test("a poll re-queries only after the index or HEAD moves")
    func aMovedStampIsRequeried() async throws {
        let query = CountingQuery(
            report: GitReport(repo: repo(root: "/notes"), changes: []))
        let service = GitBadgeService(query: query)
        service.request(for: URL(fileURLWithPath: "/notes/a.md"))
        await settle()
        query.reset()

        #expect(service.poll().isEmpty)
        // A commit, a stage, a checkout — anything that moves the index.
        query.stamp = GitStamp(index: 2, head: 1)
        #expect(service.poll() == ["/notes"], "a moved index should be re-queried")
        await settle()
        #expect(query.statusCalls == 1)

        // And then quiet again, because the answer refreshed the stamp with it.
        query.reset()
        #expect(service.poll().isEmpty, "the stamp should have been adopted")
        #expect(query.statusCalls == 0)
    }

    /// A directory with no repository must not pay a process per redraw. The
    /// negative answer is cached exactly as firmly as a positive one.
    @Test("a directory that is not in a repository is asked about once")
    func aNonRepositoryIsAskedOnce() async throws {
        let query = CountingQuery(report: GitReport(repo: nil, changes: []))
        let service = GitBadgeService(query: query)
        let url = URL(fileURLWithPath: "/plain/notes.md")

        for _ in 0..<20 { service.request(for: url) }
        await settle()

        #expect(query.statusCalls == 1, "asked \(query.statusCalls) times for one directory")
        #expect(service.badge(for: url) == nil)
        // And a poll has nothing to gate on, so it stats nothing either.
        #expect(service.poll().isEmpty)
        #expect(query.stampCalls == 0)
    }

    /// Twenty rows in one folder are one query, not twenty. This is the whole
    /// reason the service is keyed by repository.
    @Test("many rows in one directory cost one query")
    func manyRowsCostOneQuery() async throws {
        let query = CountingQuery(
            report: GitReport(repo: repo(root: "/notes"), changes: []))
        let service = GitBadgeService(query: query)
        for index in 0..<20 {
            service.request(for: URL(fileURLWithPath: "/notes/file\(index).md"))
        }
        await settle()
        #expect(query.statusCalls == 1, "20 rows ran \(query.statusCalls) queries")
    }

    // MARK: - What it says

    @Test("a modified file badges its added and removed lines")
    func aModifiedFileBadgesCounts() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "weekly.md", status: .modified, added: 12, removed: 3)
                ]))
        let service = GitBadgeService(query: query)
        service.request(for: URL(fileURLWithPath: "/notes/weekly.md"))
        await settle()

        let badge = try #require(service.badge(for: URL(fileURLWithPath: "/notes/weekly.md")))
        #expect(badge.status == .modified)
        #expect(badge.label == "+12 \u{2212}3")
    }

    @Test("a clean file has no badge at all")
    func aCleanFileHasNoBadge() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "weekly.md", status: .modified, added: 1, removed: 0)
                ]))
        let service = GitBadgeService(query: query)
        service.request(for: URL(fileURLWithPath: "/notes/clean.md"))
        await settle()
        // A marker on every unchanged row is noise, not information.
        #expect(service.badge(for: URL(fileURLWithPath: "/notes/clean.md")) == nil)
    }

    /// The contract that must never drift into `+0 −0`.
    @Test("a binary file shows its status rather than a false zero")
    func aBinaryFileShowsItsStatus() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "logo.png", status: .modified, added: nil, removed: nil)
                ]))
        let service = GitBadgeService(query: query)
        service.request(for: URL(fileURLWithPath: "/notes/logo.png"))
        await settle()

        let badge = try #require(service.badge(for: URL(fileURLWithPath: "/notes/logo.png")))
        #expect(badge.added == nil, "a changed binary must not claim a line count")
        #expect(badge.label == "modified")
        #expect(badge.label != "+0 \u{2212}0", "that would be a lie about a changed file")
    }

    /// A note you just wrote is the row the whole feature is most for, so it
    /// gets a number and not just a word — `2026-08-28-git-badges-ride-the-sidebar-poll`
    /// puts that count **per visible row**, because `git diff --numstat` reports
    /// nothing for a file with no blob to compare against.
    @Test("an untracked file is counted, per row, as all additions")
    func anUntrackedFileIsCounted() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "ideas.md", status: .untracked, added: nil, removed: 0)
                ]))
        query.lineCounts = ["/notes/ideas.md": 4]
        let service = GitBadgeService(query: query)
        let url = URL(fileURLWithPath: "/notes/ideas.md")

        service.request(for: url)
        await settle()
        // The repository query answers first and has no number for it, so the
        // row reads "new" — the honest intermediate state.
        #expect(service.badge(for: url)?.status == .untracked)

        // The row is drawn again, which is what schedules the count.
        service.request(for: url)
        await settle()
        #expect(
            service.badge(for: url)?.label == "+4 \u{2212}0",
            "a new note should be badged with its own length")
    }

    /// The count is a *file read*, so it must never happen for a row nobody is
    /// looking at — the one per-file cost in a per-repository service.
    @Test("only untracked rows that were drawn are counted")
    func onlyDrawnUntrackedRowsAreCounted() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "a.md", status: .untracked, added: nil, removed: 0),
                    GitChange(path: "b.md", status: .untracked, added: nil, removed: 0),
                    GitChange(path: "c.md", status: .modified, added: 1, removed: 1),
                ]))
        query.lineCounts = ["/notes/a.md": 2, "/notes/b.md": 9]
        let service = GitBadgeService(query: query)

        // Only `a.md` is ever drawn.
        service.request(for: URL(fileURLWithPath: "/notes/a.md"))
        await settle()
        service.request(for: URL(fileURLWithPath: "/notes/a.md"))
        await settle()

        #expect(service.badge(for: URL(fileURLWithPath: "/notes/a.md"))?.label == "+2 \u{2212}0")
        #expect(
            query.lineCountCalls == 1,
            "read \(query.lineCountCalls) files for one visible untracked row")
        // And a tracked row is never read at all: it already had its numbers.
        #expect(service.badge(for: URL(fileURLWithPath: "/notes/c.md"))?.label == "+1 \u{2212}1")
    }

    @Test("a file in a subdirectory resolves against the repository root")
    func aNestedFileResolves() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(
                        path: "deep/nested/weekly.md", status: .modified, added: 4, removed: 1)
                ]))
        let service = GitBadgeService(query: query)
        let url = URL(fileURLWithPath: "/notes/deep/nested/weekly.md")
        service.request(for: url)
        await settle()
        #expect(service.badge(for: url)?.label == "+4 \u{2212}1")
    }

    /// The bug the demo run found, against a **real** symlink.
    ///
    /// `git rev-parse --show-toplevel` resolves symlinks and
    /// `core/src/tree.rs` deliberately does not — "a symlinked notes directory
    /// keeps the name the user typed" — so a notes folder reached through one
    /// gives the app `/tmp/notes/weekly.md` while git calls the root
    /// `/private/tmp/notes`. A prefix match between the two finds nothing, and
    /// every badge in that repository silently disappears. That is what the app
    /// actually did the first time it was run on a repository under `$TMPDIR`.
    ///
    /// A real directory and a real symlink, because the resolution happens
    /// through the filesystem: fake paths would exercise the fallback and prove
    /// nothing.
    @Test("a repository reached through a symlink still badges its rows")
    func aSymlinkedRootStillBadges() async throws {
        let manager = FileManager.default
        let real = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-symlink-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(
            at: real.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: real) }

        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-link-\(UUID().uuidString)", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? manager.removeItem(at: link) }

        // git would answer with the resolved path; the app holds the link.
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: real.resolvingSymlinksInPath().path),
                changes: [
                    GitChange(path: "weekly.md", status: .modified, added: 12, removed: 3)
                ]))
        let service = GitBadgeService(query: query)
        let url = link.appendingPathComponent("weekly.md")
        service.request(for: url)
        await settle()

        #expect(
            service.badge(for: url)?.label == "+12 \u{2212}3",
            "a badge must survive the two spellings of one directory")
    }

    /// The same, one level down: the root is found by walking up from the
    /// directory that was asked about, not by arithmetic against git's answer.
    @Test("a symlinked root is recovered from a subdirectory too")
    func aSymlinkedRootFromASubdirectory() async throws {
        let manager = FileManager.default
        let real = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-symlink-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(
            at: real.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try manager.createDirectory(
            at: real.appendingPathComponent("deep/nested"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: real) }

        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-link-\(UUID().uuidString)", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? manager.removeItem(at: link) }

        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: real.resolvingSymlinksInPath().path),
                changes: [
                    GitChange(
                        path: "deep/nested/weekly.md", status: .modified, added: 4, removed: 1)
                ]))
        let service = GitBadgeService(query: query)
        let url = link.appendingPathComponent("deep/nested/weekly.md")
        service.request(for: url)
        await settle()
        #expect(service.badge(for: url)?.label == "+4 \u{2212}1")
    }

    // MARK: - Failure

    /// A repository that cannot be queried goes quiet and **stays** quiet:
    /// otherwise an unreadable or hung repository is re-queried every two
    /// seconds for the life of the window.
    @Test("a failed query is not retried on the next poll")
    func aFailedQueryGoesQuiet() async throws {
        struct Failing: GitQuerying {
            let counter: Counter
            final class Counter: @unchecked Sendable { var calls = 0 }
            func status(path: String) throws -> GitReport {
                counter.calls += 1
                throw CoreError(function: "mark_git_json", detail: "timed out")
            }
            func stamp(indexPath: String, headPath: String) -> GitStamp {
                GitStamp(index: nil, head: nil)
            }
            func base(path: String) throws -> GitBase {
                throw CoreError(function: "mark_git_json", detail: "timed out")
            }
            func counts(base: String, new: String) throws -> (added: Int, removed: Int) {
                (0, 0)
            }
            func lineCount(path: String) -> Int? { nil }
        }
        let counter = Failing.Counter()
        let service = GitBadgeService(query: Failing(counter: counter))
        service.request(for: URL(fileURLWithPath: "/notes/a.md"))
        await settle()
        #expect(counter.calls == 1)

        for _ in 0..<5 { _ = service.poll() }
        await settle()
        #expect(counter.calls == 1, "a failed repository was retried \(counter.calls) times")
    }

    /// ⌘R is the documented way back for a repository that went quiet.
    @Test("invalidateAll gives a quiet repository another chance")
    func refreshRevivesAQuietRepository() async throws {
        let query = CountingQuery(
            report: GitReport(repo: repo(root: "/notes"), changes: []))
        let service = GitBadgeService(query: query)
        service.request(for: URL(fileURLWithPath: "/notes/a.md"))
        await settle()
        query.reset()

        service.invalidateAll()
        service.request(for: URL(fileURLWithPath: "/notes/a.md"))
        await settle()
        #expect(query.statusCalls == 1, "⌘R should re-ask")
    }

    // MARK: - The dirty buffer

    /// ADR-6: nothing may read the file for a count on a dirty tab. A git badge
    /// is a count of the same kind, and the claim it makes — "this far from what
    /// is committed" — is exactly the one that goes wrong if it describes disk.
    @Test("a dirty buffer is counted instead of the file on disk")
    func aDirtyBufferWins() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "weekly.md", status: .modified, added: 1, removed: 0)
                ]),
            baseText: "one\ntwo\n")
        let service = GitBadgeService(query: query)
        let url = URL(fileURLWithPath: "/notes/weekly.md")
        service.request(for: url)
        await settle()
        #expect(service.badge(for: url)?.label == "+1 \u{2212}0", "the on-disk answer")

        // Four lines in the buffer against two committed.
        service.dirtySource = { _ in "one\ntwo\nthree\nfour\n" }
        service.recountDirty(url)
        await settle()

        let badge = try #require(service.badge(for: url))
        #expect(badge.added == 2, "the buffer's answer, not the file's: \(badge)")
    }

    @Test("saving drops the dirty override")
    func savingDropsTheOverride() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "weekly.md", status: .modified, added: 1, removed: 0)
                ]),
            baseText: "one\n")
        let service = GitBadgeService(query: query)
        let url = URL(fileURLWithPath: "/notes/weekly.md")
        service.request(for: url)
        await settle()

        service.dirtySource = { _ in "one\ntwo\nthree\n" }
        service.recountDirty(url)
        await settle()
        #expect(service.badge(for: url)?.added == 2)

        // The tab was saved: there are no unsaved bytes any more, so the
        // repository's own answer is the truth again.
        service.dirtySource = { _ in nil }
        service.recountDirty(url)
        await settle()
        #expect(service.badge(for: url)?.label == "+1 \u{2212}0")
    }

    /// The base blob costs ~7 ms and cannot change while `HEAD` does not, so a
    /// buffer being retyped must not re-read it per keystroke.
    @Test("HEAD's bytes are read once while the oid holds")
    func theBaseIsCached() async throws {
        let query = CountingQuery(
            report: GitReport(
                repo: repo(root: "/notes"),
                changes: [
                    GitChange(path: "weekly.md", status: .modified, added: 1, removed: 0)
                ]),
            baseText: "one\n")
        let service = GitBadgeService(query: query)
        let url = URL(fileURLWithPath: "/notes/weekly.md")
        service.request(for: url)
        await settle()

        var typed = "one\n"
        service.dirtySource = { _ in typed }
        for extra in 1...8 {
            typed += "line \(extra)\n"
            service.recountDirty(url)
            await settle()
        }
        #expect(
            query.baseCalls == 1,
            "eight keystrokes read HEAD \(query.baseCalls) time(s)")
        #expect(query.countCalls >= 8, "but every one of them recounted")
    }
}
