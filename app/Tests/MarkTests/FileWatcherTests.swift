import Foundation
import Testing

@testable import MarkKit

/// Everything the watcher reported, in order.
@MainActor
final class ChangeLog {
    private(set) var changes: [FileChange] = []

    func record(_ change: FileChange) { changes.append(change) }

    var sources: [String] {
        changes.compactMap {
            if case .changed(_, let source, _) = $0 { return source }
            return nil
        }
    }

    func changes(for url: URL) -> [FileChange] {
        changes.filter { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    /// Wait until `predicate` holds, or give up.
    ///
    /// Polled rather than continuation-based: FSEvents delivers when it
    /// delivers, several changes can arrive for one save, and a test that
    /// resumed on the first one would assert against a half-finished picture.
    /// The timeout is generous because this is a real kernel service, not a
    /// stub — a slow machine is not a failure.
    @discardableResult
    func wait(
        timeout: Duration = .seconds(10),
        for predicate: @escaping @MainActor ([FileChange]) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate(changes) { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(20))
        }
        return predicate(changes)
    }

    /// Give any *further* change a chance to arrive, for the assertions that
    /// are about something **not** happening.
    func settle(_ duration: Duration = .milliseconds(600)) async {
        try? await _Concurrency.Task.sleep(for: duration)
    }
}

/// A boolean two threads can share, without an actor.
///
/// The writers in the teardown test are plain `DispatchQueue` blocks on
/// purpose — a `Task` would be scheduled by the cooperative pool and would not
/// keep the pressure on FSEvents that the race needs.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// A temp directory, a watcher, and the log it writes to.
@MainActor
final class WatchHarness {
    let directory: URL
    let log = ChangeLog()
    private(set) var watcher: FileWatcher!

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = self.log
        watcher = FileWatcher { change in log.record(change) }
    }

    deinit {
        watcher?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    @discardableResult
    func write(_ source: String, to name: String) throws -> URL {
        let url = self.url(name)
        try source.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// A save the way vim, VS Code, IntelliJ and Sublime all do it: write a
    /// temp file next to the target, then `rename(2)` over it. **The inode
    /// changes**, which is the case kqueue cannot survive.
    func saveAtomically(_ source: String, to name: String) throws {
        let temp = directory.appendingPathComponent(".\(name).swp-\(UUID().uuidString)")
        try source.write(to: temp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url(name), withItemAt: temp)
    }
}

@Suite("FileWatcher — FSEvents, not kqueue")
@MainActor
struct FileWatcherTests {

    // MARK: - The shape of the watch

    /// ADR-2: *"watch the parent directory, not the file"* — the only way to
    /// survive delete-and-recreate. Invisible from the outside otherwise, and
    /// the first thing a refactor would get wrong.
    @Test("the stream is rooted at the parent directory, never at the file")
    func watchesTheDirectory() throws {
        let harness = try WatchHarness()
        let url = try harness.write("# A\n", to: "a.md")
        harness.watcher.setWatched([url])

        let directories = harness.watcher.watchedDirectories
        #expect(directories.count == 1)
        #expect(!directories.contains(url.path))
        // Fully resolved, because FSEvents reports resolved paths and
        // `NSTemporaryDirectory()` is `/var/folders/…`, a symlink to
        // `/private/var/folders/…`. Note that `URL.resolvingSymlinksInPath()`
        // is *not* the right tool for the comparison: it deliberately strips a
        // `/private` prefix, so it would report the unresolved form and this
        // assertion would fail against a watcher that is behaving correctly.
        #expect(directories.first == realpath(harness.directory.path))
    }

    @Test("two documents in one directory share one stream root")
    func oneRootPerDirectory() throws {
        let harness = try WatchHarness()
        let a = try harness.write("# A\n", to: "a.md")
        let b = try harness.write("# B\n", to: "b.md")
        harness.watcher.setWatched([a, b])
        #expect(harness.watcher.watchedDirectories.count == 1)
        #expect(harness.watcher.watchedURLs.count == 2)
    }

    // MARK: - Seeing changes

    @Test("an ordinary write is reported, with the new contents")
    func plainWrite() async throws {
        let harness = try WatchHarness()
        let url = try harness.write("# A\n\nbefore\n", to: "a.md")
        harness.watcher.setWatched([url])

        try harness.write("# A\n\nafter\n", to: "a.md")
        #expect(await harness.log.wait { !$0.isEmpty })
        #expect(harness.log.sources.last == "# A\n\nafter\n")
    }

    /// **The load-bearing test of the FSEvents-not-kqueue decision.**
    ///
    /// Every editor this app is meant to sit alongside saves by writing a temp
    /// file and renaming it over the target, so the inode changes on every
    /// save. A kqueue watcher holds a descriptor on the *old* inode and goes
    /// permanently silent — and silently: the first save looks like it worked,
    /// because kqueue reports the delete, and every save after it is lost.
    ///
    /// So this saves twice. One rename proves nothing.
    @Test("an atomic temp-file-plus-rename save is seen, and so is the next one")
    func atomicRenameSurvives() async throws {
        let harness = try WatchHarness()
        let url = try harness.write("# A\n\none\n", to: "a.md")
        let firstInode = try inode(of: url)
        harness.watcher.setWatched([url])

        try harness.saveAtomically("# A\n\ntwo\n", to: "a.md")
        #expect(await harness.log.wait { $0.contains { $0.url == url.standardizedFileURL } })
        #expect(harness.log.sources.last == "# A\n\ntwo\n")
        #expect(try inode(of: url) != firstInode, "the save did not actually swap the inode")

        let afterFirst = harness.log.changes.count
        try harness.saveAtomically("# A\n\nthree\n", to: "a.md")
        #expect(
            await harness.log.wait { $0.count > afterFirst },
            "the watcher went silent after the inode changed — this is the kqueue failure mode")
        #expect(harness.log.sources.last == "# A\n\nthree\n")
    }

    @Test("delete and recreate is reported")
    func deleteAndRecreate() async throws {
        let harness = try WatchHarness()
        let url = try harness.write("# A\n\nbefore\n", to: "a.md")
        harness.watcher.setWatched([url])

        try FileManager.default.removeItem(at: url)
        #expect(await harness.log.wait { $0.contains { if case .vanished = $0 { return true } else { return false } } })

        try harness.write("# A\n\nrecreated\n", to: "a.md")
        #expect(await harness.log.wait { $0.contains { if case .changed = $0 { return true } else { return false } } })
        #expect(harness.log.sources.last == "# A\n\nrecreated\n")
    }

    /// A file that goes away and comes back with the *same* bytes is still
    /// news, so the stored hash is cleared on a vanish. Without that, a `git
    /// checkout` that restores the current contents would leave the tab
    /// convinced the file is missing.
    @Test("a file that comes back byte-identical is still reported")
    func reappearingIdenticalFile() async throws {
        let harness = try WatchHarness()
        let body = "# A\n\nunchanged\n"
        let url = try harness.write(body, to: "a.md")
        harness.watcher.setWatched([url])

        try FileManager.default.removeItem(at: url)
        #expect(await harness.log.wait { $0.contains { if case .vanished = $0 { return true } else { return false } } })
        try harness.write(body, to: "a.md")
        #expect(await harness.log.wait { $0.contains { if case .changed = $0 { return true } else { return false } } })
    }

    // MARK: - Not seeing non-changes

    /// ADR-2: *"content-hash before re-rendering"*. Editors emit two or three
    /// events per save, and `touch`, `chmod`, and a save that changed nothing
    /// all produce events. Re-rendering on those is the difference between "the
    /// document updated" and "the document flickers whenever anything happens
    /// in this folder".
    @Test("a write with identical content is not reported")
    func identicalContentIsNotReported() async throws {
        let harness = try WatchHarness()
        let body = "# A\n\nsame\n"
        let url = try harness.write(body, to: "a.md")
        harness.watcher.setWatched([url])

        try harness.write(body, to: "a.md")
        try harness.saveAtomically(body, to: "a.md")
        _ = FileManager.default.createFile(
            atPath: harness.url("unrelated.txt").path, contents: Data("noise".utf8))
        await harness.log.settle()
        #expect(harness.log.changes.isEmpty, "reported \(harness.log.changes)")
    }

    @Test("a change to one document is not reported for its neighbour")
    func neighboursAreNotConfused() async throws {
        let harness = try WatchHarness()
        let a = try harness.write("# A\n", to: "a.md")
        let b = try harness.write("# B\n", to: "b.md")
        harness.watcher.setWatched([a, b])

        try harness.write("# A\n\nedited\n", to: "a.md")
        #expect(await harness.log.wait { !$0.isEmpty })
        await harness.log.settle()
        #expect(harness.log.changes(for: a).count == 1)
        #expect(harness.log.changes(for: b).isEmpty)
    }

    @Test("unwatching stops delivery")
    func unwatch() async throws {
        let harness = try WatchHarness()
        let url = try harness.write("# A\n", to: "a.md")
        harness.watcher.setWatched([url])
        harness.watcher.setWatched([])
        #expect(harness.watcher.watchedDirectories.isEmpty)

        try harness.write("# A\n\nedited\n", to: "a.md")
        await harness.log.settle()
        #expect(harness.log.changes.isEmpty)
    }

    // MARK: - The truncate window

    /// `truncate` + `write` is not atomic, so between the two the file is
    /// genuinely 0 bytes. A watcher that believes the first read it gets will
    /// hand the app an empty document and blank the reader's notes on screen —
    /// briefly, and terrifyingly.
    @Test("the empty window of a truncate-then-write is never reported as the document")
    func truncateThenWrite() async throws {
        let harness = try WatchHarness()
        let url = try harness.write("# A\n\nbefore\n", to: "a.md")
        harness.watcher.setWatched([url])

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.synchronize()
        // Long enough to be inside the retry budget and to overlap the debounce,
        // short enough that the retries are not spent.
        try? await _Concurrency.Task.sleep(for: .milliseconds(45))
        try handle.write(contentsOf: Data("# A\n\nafter\n".utf8))
        try handle.synchronize()
        try handle.close()

        #expect(await harness.log.wait { !$0.isEmpty })
        await harness.log.settle()
        #expect(
            !harness.log.sources.contains(""),
            "the watcher reported the truncate window as an empty document")
        #expect(harness.log.sources.last == "# A\n\nafter\n")
    }

    // MARK: - Symlinks

    /// A symlinked note is the case that would otherwise be silently broken.
    /// `mark_toggle` canonicalizes the path before renaming — the M1 review's
    /// fix — so a checkbox write lands next to the symlink's *target* and
    /// produces no event at all in the directory holding the link.
    @Test("a document reached through a symlink is watched where its target lives")
    func symlinkedDocument() async throws {
        let harness = try WatchHarness()
        let real = try harness.write("# Real\n\none\n", to: "real.md")
        let elsewhere = harness.directory.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = elsewhere.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        harness.watcher.setWatched([link])
        #expect(
            harness.watcher.watchedDirectories.count == 2,
            "both the link's directory and its target's are watched: \(harness.watcher.watchedDirectories)"
        )

        try harness.write("# Real\n\ntwo\n", to: "real.md")
        #expect(
            await harness.log.wait { !$0.isEmpty },
            "a write to the target produced no change for the link")
        #expect(harness.log.changes.first?.url == link.standardizedFileURL)
        #expect(harness.log.sources.last == "# Real\n\ntwo\n")
    }

    // MARK: - Self-write suppression, for M9

    /// Not used in M5 — the checkbox round trip deliberately lets the watcher
    /// see its own write, so the resulting patch is the single visible change.
    /// It is tested now because
    /// `2026-08-24-editing-pane-and-autosave` makes it a constraint at 800 ms
    /// autosave cadence, and a suppression bug there is a cursor that jumps
    /// while typing.
    @Test("content noted as ours is not reported back to us")
    func selfWriteSuppression() async throws {
        let harness = try WatchHarness()
        let url = try harness.write("# A\n\nbefore\n", to: "a.md")
        harness.watcher.setWatched([url])

        let ours = "# A\n\nwritten by us\n"
        harness.watcher.noteWrittenContent(ours, to: url)
        try harness.write(ours, to: "a.md")
        await harness.log.settle()
        #expect(harness.log.changes.isEmpty)

        // ...and someone else's write still is.
        try harness.write("# A\n\nwritten by vim\n", to: "a.md")
        #expect(await harness.log.wait { !$0.isEmpty })
    }

    // MARK: - Teardown, which is where it crashed

    /// The M5-era use-after-free, exercised on purpose.
    ///
    /// `swiftpm-testing-helper-2026-08-24-223632.ips`: SIGSEGV in
    /// `FileWatcher.eventsArrived` reached from `root_dir_event_callback` on
    /// `dev.mark.watch`, reproducing about **1 run in 16** of the whole Swift
    /// suite and once as a SIGABRT inside `FileWatcher.deinit`. M7 root-caused
    /// it and correctly left it alone; M9's autosave fires the watcher every
    /// 800 ms, which turns a rare race into a likely one.
    ///
    /// The shape that matters, and the reason a happy-path teardown assertion
    /// would not have caught it: the last reference is dropped **while events
    /// are in flight**, and more events land *after* the drop. Writes continue
    /// on a background queue across the release so the callback and `deinit`
    /// genuinely overlap rather than merely happening in the same test.
    ///
    /// Verified to fail before the fix: reverting `FileWatcher` to
    /// `passUnretained` + synchronous teardown in `deinit` crashes this test.
    @Test("a watcher released while its stream is delivering does not crash")
    func teardownDuringCallback() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-watch-teardown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<8).map { index -> URL in
            let url = directory.appendingPathComponent("racing-\(index).md")
            try "# start\n".write(to: url, atomically: false, encoding: .utf8)
            return url
        }

        let before = EventSink.orphaned.count
        let writers = DispatchQueue(
            label: "test.watch.writers", qos: .userInitiated, attributes: .concurrent)
        for round in 0..<64 {
            // A 1 ms debounce so a scan block is very likely to be queued
            // behind the callback when the watcher goes away underneath both.
            var watcher: FileWatcher? = FileWatcher(debounce: 0.001) { _ in }
            watcher?.setWatched(Set(urls))

            let stop = ManagedAtomicFlag()
            for (index, url) in urls.enumerated() {
                writers.async {
                    var counter = 0
                    while !stop.isSet {
                        try? "# round \(round) file \(index) write \(counter)\n".write(
                            to: url, atomically: false, encoding: .utf8)
                        counter += 1
                    }
                }
            }

            // Long enough for FSEvents to arm and start delivering into the
            // callback, short enough that it is still delivering.
            try? await _Concurrency.Task.sleep(for: .milliseconds(20))
            // The drop. No `stop()` first: that is exactly the case M5's
            // `deinit` could not survive.
            watcher = nil
            // Events keep arriving for a stream whose owner is gone.
            try? await _Concurrency.Task.sleep(for: .milliseconds(10))
            stop.set()
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        // Surviving is only half of it. A teardown test that never actually
        // races is a test that proves nothing, so the race is *counted*: each
        // of these is a callback that arrived for a watcher that no longer
        // exists, which under M5's `passUnretained` was a message to freed
        // memory.
        let orphaned = EventSink.orphaned.count - before
        #expect(
            orphaned > 0,
            "no callback arrived after a watcher was released — the race this test exists for was never reached"
        )
        #expect(FileManager.default.fileExists(atPath: urls[0].path))
    }

    /// The same race from the other side: the watcher survives, but its
    /// *stream* is rebuilt underneath in-flight callbacks. `setWatched` is
    /// called from the main thread while FSEvents is delivering on its own
    /// queue, which is what opening and closing tabs during an autosave storm
    /// looks like.
    @Test("rebuilding the stream while events are in flight is safe")
    func rebuildDuringCallback() async throws {
        let harness = try WatchHarness()
        let urls = try (0..<6).map { try harness.write("# \($0)\n", to: "f\($0).md") }
        let writing = _Concurrency.Task.detached(priority: .utility) {
            var index = 0
            while !_Concurrency.Task.isCancelled {
                try? "# \(index)\n".write(
                    to: urls[index % urls.count], atomically: false, encoding: .utf8)
                index += 1
                try? await _Concurrency.Task.sleep(for: .microseconds(300))
            }
        }
        for round in 0..<60 {
            // Every other round changes the *directory* set, which is what
            // actually forces a stream rebuild.
            let sub = harness.directory.appendingPathComponent("sub-\(round)", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let extra = sub.appendingPathComponent("extra.md")
            try "# extra\n".write(to: extra, atomically: false, encoding: .utf8)
            harness.watcher.setWatched(Set(urls + (round.isMultiple(of: 2) ? [extra] : [])))
            try? await _Concurrency.Task.sleep(for: .milliseconds(4))
        }
        writing.cancel()
        await writing.value
        harness.watcher.stop()
        #expect(harness.watcher.watchedURLs.isEmpty)
    }

    private func realpath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
