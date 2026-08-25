import Foundation
import Testing

@testable import MarkKit

/// `2026-08-25-flock-write-locking`, from the app's side.
///
/// Two things make these tests worth more than their assertions suggest.
///
/// **They use a real second process.** `flock` is per open file description, so
/// a second attempt inside this process would be testing a kernel detail rather
/// than the thing the ADR is about, which is one `mark` excluding another. The
/// second process here is the actual `mark-cli`, so what is being checked is
/// the shipped refusal — exit status 6 and a message naming a pid — and not a
/// re-implementation of it.
///
/// **They ask whether the lock is held *after* a write.** The ADR:
///
/// > The lock must be re-acquired after every autosave, because the atomic
/// > write replaces the inode. A missed re-acquire is silent: the file simply
/// > becomes writable again while the buffer is still dirty. **This is the
/// > sharp edge.**
///
/// `Buffer.holdsWriteLock` is deliberately `lock?.isCurrent`, not `lock != nil`,
/// so that a lock stranded on the orphaned inode reads as *not held* — and the
/// CLI probe below would catch it even if that property lied.
@MainActor
struct DocumentLockTests {

    /// The release `mark-cli`, which `just swift-test` has built by the time
    /// this runs (`swift-test` depends on `build-rust`).
    static let cli: String = {
        // .../app/Tests/MarkTests/DocumentLockTests.swift -> repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("target/release/mark-cli").path
    }()

    /// `mark check --item 0 --toggle` in a real second process.
    ///
    /// - Returns: its exit status and stderr. Status 6 is
    ///   `2026-08-25-flock-write-locking`'s "another mark holds this document".
    @discardableResult
    static func check(_ url: URL) throws -> (status: Int32, stderr: String) {
        try #require(
            FileManager.default.isExecutableFile(atPath: cli),
            "\(cli) is missing — `just swift-test` builds it; a bare `swift test` does not"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["check", url.path, "--item", "0", "--toggle"]
        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }

    @Test("a clean tab holds no lock, however long it has been open")
    func aCleanTabHoldsNothing() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer()
        #expect(!buffer.holdsWriteLock)

        // The ADR's reason for that rule, checked rather than assumed:
        // *"Holding one for every open document would make the app hostile to
        // the CLI it is meant to be driven by."*
        let (status, stderr) = try Self.check(fixture.url)
        #expect(status == 0, "a CLI write to an open-but-clean document was refused: \(stderr)")
        #expect(try fixture.contents().contains("- [x] one"))
        withExtendedLifetime(buffer) {}
    }

    @Test("typing takes the lock, and a second mark is refused by pid")
    func typingTakesTheLock() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)  // long enough not to fire
        buffer.replaceContents("# Doc\n\n- [ ] one\n\nunsaved words\n")
        #expect(buffer.isDirty)
        #expect(buffer.holdsWriteLock, "a dirty buffer must hold its document")

        let (status, stderr) = try Self.check(fixture.url)
        #expect(status == 6, "a locked document must refuse with 6, not \(status): \(stderr)")
        #expect(
            stderr.contains("\(ProcessInfo.processInfo.processIdentifier)"),
            "the refusal does not name this process: \(stderr)")
        #expect(stderr.contains("locked for writing"), "\(stderr)")
    }

    /// The lock tracks dirtiness *across* a write, and lands on the inode the
    /// write created rather than the one it destroyed.
    ///
    /// Honest about what it does and does not cover: because `save()` is
    /// synchronous, a *successful* save always leaves the tab clean, so the
    /// re-acquire here is the one ``Buffer/setDirty(_:)`` performs on the next
    /// edit. The case where the re-acquire in ``Buffer/save()`` itself is
    /// load-bearing — a save that fails and leaves the buffer dirty — is
    /// [`theLockSurvivesAFailedSave`], and that is the one that fails if the
    /// re-acquire is removed.
    @Test("after an autosave, a still-dirty document is locked on its new inode")
    func theLockSurvivesAnAutosave() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.05)
        var saves = 0
        buffer.onSaved = { _ in saves += 1 }

        // Keep it dirty across the save: type, let the debounce write, then
        // type again before asking. Without the second edit the buffer would be
        // clean afterwards and correctly holding nothing, which would make this
        // test vacuous.
        buffer.replaceContents("# Doc\n\n- [ ] one\n\nfirst\n")
        #expect(await fixture.waitUntil("the first autosave") { saves == 1 })
        buffer.replaceContents("# Doc\n\n- [ ] one\n\nfirst and second\n")
        #expect(buffer.isDirty)

        #expect(
            buffer.holdsWriteLock,
            "the lock was not re-acquired after the autosave replaced the inode")

        // And the same question asked of the kernel by another process, since
        // `holdsWriteLock` is our own bookkeeping and could be wrong.
        let (status, stderr) = try Self.check(fixture.url)
        #expect(
            status == 6,
            "after an autosave the document was writable again while still dirty: \(status) \(stderr)"
        )
    }

    /// **The sharp edge**, in the one state that actually reaches it.
    ///
    /// > The lock must be re-acquired after every autosave, because the atomic
    /// > write replaces the inode. **A missed re-acquire is silent**: the file
    /// > simply becomes writable again while the buffer is still dirty.
    ///
    /// A save that *fails* is the state where that goes wrong and nothing else
    /// covers for it: the buffer keeps the user's bytes, stays dirty, and never
    /// crosses a dirty/clean boundary — so if ``Buffer/save()`` does not take
    /// the lock back itself, the document silently becomes writable while a
    /// window is holding unsaved edits to it. Deleting the `defer` in `save()`
    /// makes exactly this test fail and no other.
    ///
    /// The failure is manufactured by making the *directory* unwritable, which
    /// is what `write_atomically` needs for its temp file. The document itself
    /// stays readable, so the lock is unaffected — which is the point.
    @Test("a failed save leaves the buffer dirty and still holding the lock")
    func theLockSurvivesAFailedSave() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)
        var failures: [BufferError] = []
        buffer.onSaveFailed = { failures.append($0) }
        buffer.replaceContents("# Doc\n\n- [ ] one\n\nunsaved words\n")
        #expect(buffer.holdsWriteLock)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        }

        #expect(buffer.save() == false, "the write was supposed to fail")
        #expect(failures.count == 1)
        #expect(buffer.isDirty, "a failed save must keep the user's bytes")
        #expect(
            buffer.holdsWriteLock,
            "the document was left unlocked while the buffer is still dirty — the ADR's sharp edge"
        )

        // Confirmed against the kernel, not just our bookkeeping. The directory
        // goes back to writable first, so the probe fails for lock reasons or
        // not at all.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        let (status, stderr) = try Self.check(fixture.url)
        #expect(status == 6, "a second mark walked into a dirty document: \(status) \(stderr)")
    }

    @Test("saving lets go of the lock, so the CLI can write again")
    func savingReleasesTheLock() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 0.05)
        buffer.replaceContents("# Doc\n\n- [ ] one\n\nwords\n")
        #expect(buffer.holdsWriteLock)

        #expect(await fixture.waitUntil("the tab to go clean") { !buffer.isDirty })
        #expect(!buffer.holdsWriteLock, "a clean tab is still holding the document")

        let (status, stderr) = try Self.check(fixture.url)
        #expect(status == 0, "the lock outlived the buffer's dirty state: \(stderr)")
    }

    @Test("closing a dirty tab releases the lock with it")
    func closingReleasesTheLock() async throws {
        let fixture = try BufferFixture()
        do {
            let buffer = try fixture.buffer(autosave: 5.0)
            buffer.replaceContents("# Doc\n\n- [ ] one\n\nabandoned\n")
            #expect(buffer.holdsWriteLock)
            let (status, _) = try Self.check(fixture.url)
            #expect(status == 6)
        }
        // The buffer is gone; so is the descriptor, so is the lock. Nothing ran
        // to make that true.
        let (status, stderr) = try Self.check(fixture.url)
        #expect(status == 0, "a closed tab left its lock behind: \(stderr)")
    }

    @Test("undoing back to the saved bytes releases the lock")
    func goingCleanByUndoReleasesTheLock() async throws {
        let fixture = try BufferFixture()
        let original = try fixture.contents()
        let buffer = try fixture.buffer(autosave: 5.0)
        buffer.replaceContents(original + "typed\n")
        #expect(buffer.holdsWriteLock)
        buffer.replaceContents(original)
        #expect(!buffer.isDirty)
        #expect(!buffer.holdsWriteLock, "a buffer edited back to clean is still holding")
    }

    /// The ADR keeps the conflict prompt precisely because this is true:
    ///
    /// > **The lock is advisory, so it protects `mark` from `mark` and nothing
    /// > else.** A user who assumes their file is protected from `vim` is wrong.
    ///
    /// So: an external writer gets through the lock, and the M9 prompt — which
    /// is now the *only* defence against it — still fires.
    @Test("an editor that ignores the lock still gets through, and still raises the prompt")
    func anAdvisoryLockDoesNotStopVim() async throws {
        let fixture = try BufferFixture()
        let buffer = try fixture.buffer(autosave: 5.0)
        var conflicts: [Conflict] = []
        buffer.onConflict = { conflicts.append($0) }

        buffer.replaceContents("# Doc\n\n- [ ] one\n\nmy unsaved words\n")
        #expect(buffer.holdsWriteLock)

        // `saveExternally` is temp-file-plus-rename, which is what vim does and
        // which takes no lock at all. It succeeds, and it must.
        let theirs = "# Doc\n\n- [ ] one\n\ntheir words from vim\n"
        try fixture.saveExternally(theirs)
        #expect(try fixture.contents() == theirs, "the advisory lock blocked a non-mark writer")

        let outcome = buffer.fileChanged(source: theirs, hash: DocumentSource.hash(theirs))
        guard case .conflicted = outcome else {
            Issue.record("the conflict prompt did not fire for a non-mark writer: \(outcome)")
            return
        }
        #expect(conflicts.count == 1)

        // And the lock followed the document onto its new inode, rather than
        // being left on the orphan the rename created.
        #expect(
            buffer.holdsWriteLock,
            "after an external replace the lock is stranded on the old inode")
        let (status, _) = try Self.check(fixture.url)
        #expect(status == 6, "the buffer is still dirty, so the document is still ours")
    }

    @Test("a lock names the inode, not the path")
    func aLockFollowsTheInode() throws {
        let fixture = try BufferFixture()
        let lock = try DocumentLock.acquire(fixture.url)
        #expect(lock.isHeld)
        #expect(lock.isCurrent)

        try fixture.saveExternally("# Replaced\n")
        #expect(lock.isHeld, "the kernel still holds it — on an orphan")
        #expect(!lock.isCurrent, "a stranded lock must not claim to cover the document")

        lock.close()
        #expect(!lock.isHeld)
        #expect(!lock.isCurrent)
    }

    @Test("a second lock in this process is refused rather than silently granted")
    func selfConflictIsReal() throws {
        let fixture = try BufferFixture()
        let held = try DocumentLock.acquire(fixture.url)
        #expect(held.isHeld)
        #expect(throws: DocumentLockError.self) {
            _ = try DocumentLock.acquire(fixture.url)
        }
        // Which is exactly why `Buffer.save()` hands the lock to the core
        // instead of holding it across the write: the core would be refused by
        // us.
        held.close()
        let again = try DocumentLock.acquire(fixture.url)
        #expect(again.isHeld)
    }
}
