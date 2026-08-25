import CoreServices
import CryptoKit
import Foundation

/// Reading a document's bytes, in the one place that knows how.
///
/// Two callers need identical behaviour and would otherwise drift: the render
/// path (``DocumentView``) and the watcher, which has to decide whether what it
/// just read is *the same document* as what is on screen. If one of them
/// fell back to a guessed encoding and the other did not, a latin-1 file would
/// re-render on every unrelated save forever, and nothing would say why.
public enum DocumentSource {

    /// The bytes at `url` as text.
    ///
    /// UTF-8 first, then Foundation's encoding guess — not every markdown file
    /// on a real disk is UTF-8. The error reported on total failure is the
    /// *UTF-8* one, because "not valid UTF-8 at byte N" is more useful than
    /// "the operation could not be completed".
    public static func read(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            var encoding = String.Encoding.utf8
            if let guessed = try? String(contentsOf: url, usedEncoding: &encoding) {
                Log.core.info("read \(url.lastPathComponent) as \(encoding.description)")
                return guessed
            }
            throw DocumentError.unreadable(path: url.path, underlying: error)
        }
    }

    /// The same, from bytes already in hand — the watcher reads `Data` so it can
    /// hash it without a second trip to the disk.
    static func decode(_ data: Data, from url: URL) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        if let guessed = try? String(contentsOf: url, usedEncoding: &encoding) {
            Log.core.info("read \(url.lastPathComponent) as \(encoding.description)")
            return guessed
        }
        throw DocumentError.unreadable(
            path: url.path,
            underlying: CocoaError(.fileReadInapplicableStringEncoding))
    }

    /// A content hash of `data`.
    ///
    /// The watcher compares this rather than the text, because editors emit
    /// 2–3 events per save (ADR-2) and re-rendering on a byte-identical file is
    /// the difference between "the document updated" and "the document
    /// flickered". SHA-256 rather than a cheap 64-bit mix because
    /// `2026-08-24-editing-pane-and-autosave` will compare these against hashes
    /// *we* wrote to decide whether a change is someone else's — a collision
    /// there would silently drop a conflict prompt.
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same, for text already in hand.
    public static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
}

/// What the watcher saw.
public enum FileChange: Sendable, Equatable {
    /// The file's bytes are different from the last ones we reported. `source`
    /// is the whole document — the watcher has already read it, and every
    /// consumer needs it.
    case changed(url: URL, source: String, hash: String)

    /// The file is gone, and stayed gone across the re-read retries. The tab
    /// keeps whatever it last rendered; nothing is closed and nothing is
    /// written.
    case vanished(url: URL)

    public var url: URL {
        switch self {
        case .changed(let url, _, _), .vanished(let url): return url
        }
    }
}

/// What FSEvents is actually given as its `info` pointer.
///
/// It exists so that the pointer the kernel service holds stays valid for the
/// life of the stream without keeping the ``FileWatcher`` itself alive — a
/// retained `self` would make `deinit` unreachable and the stream immortal,
/// and an unretained `self` is the use-after-free this box replaces.
///
/// The reference is weak, which is the load-bearing part: Swift's runtime
/// zeroes weak references as deinitialization *begins*, so a callback racing
/// teardown observes `nil` rather than a half-destroyed object. Nothing else
/// here is synchronized, because nothing else needs to be — the box is written
/// once at construction and only ever read.
final class EventSink {
    weak var owner: FileWatcher?
    init(owner: FileWatcher) { self.owner = owner }

    /// How many FSEvents callbacks have arrived for a watcher that was already
    /// gone.
    ///
    /// Every one of these is an instance of the crash M5 shipped: with
    /// `passUnretained`, each would have been a message to freed memory. It is
    /// counted rather than merely survived so a test can assert the race was
    /// *reached* — a teardown test that never actually races proves nothing,
    /// and this is the only way to tell the two apart from the outside. The
    /// increment is off the hot path: it happens only when the weak load has
    /// already come back nil.
    static let orphaned = Counter()

    /// A lock and an `Int`. `NSLock` rather than an actor because the
    /// increment happens inside an FSEvents callback, which is not an async
    /// context and must not become one.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }
}

/// FSEvents over the *directories* holding the open documents.
///
/// Every design choice here is one of ADR-2's constraints, and each of them is
/// a silent failure rather than a crash if it is got wrong:
///
/// * **FSEvents, not kqueue.** vim, VS Code, IntelliJ and Sublime all save via
///   a temp file and an atomic rename, so the **inode changes**. kqueue holds a
///   descriptor on the inode and goes permanently silent at that point — the
///   file appears to stop changing forever. FSEvents watches *paths* and
///   survives it. (Watchexec recommends kqueue on macOS; that advice is wrong
///   for this use.)
/// * **Watch the parent directory, not the file.** The only way to survive
///   delete-and-recreate, which is the same save pattern seen from the other
///   side.
/// * **Debounce 25–50 ms**, because a single save emits two or three events.
/// * **Content-hash before reporting**, because coalescing means we are told
///   "something happened here" and not "these bytes changed".
/// * **Never trust the event kind — re-stat and re-read.** FSEvents coalesces,
///   reorders, and drops. The flags are logged and otherwise unused.
/// * **Retry a short or empty read.** Truncate-then-write leaves a window in
///   which the file is genuinely 0 bytes, and reporting that window as the
///   document is how a watcher blanks someone's notes on screen.
///
/// A document reached through a **symlink** is watched in both places: the
/// directory holding the link, and the directory holding its target. A write
/// through `mark_toggle` resolves the symlink before renaming (the M1 review
/// bug), so the only event produced lands next to the *target*, and a watcher
/// looking only at the link's directory would never fire.
public final class FileWatcher: @unchecked Sendable {

    /// ADR-2's window: *"debounce 25–50 ms"*. 30 ms sits inside it with room
    /// for a slow disk, and is short enough that a save feels immediate.
    public static let defaultDebounce: TimeInterval = 0.030

    /// How many times a short, empty, or missing read is retried before it is
    /// believed.
    ///
    /// `truncate` + `write` is not atomic, so there is a real window where a
    /// file that is about to hold 40 KB holds 0 bytes. Six attempts 15 ms apart
    /// covers ~90 ms of that window; past there the file really is empty or
    /// really is gone, and saying so is the honest answer.
    public static let readRetries = 6
    public static let readRetryDelay: TimeInterval = 0.015

    /// Delivered on the main actor, in the order the changes were observed.
    private let handler: @Sendable @MainActor (FileChange) -> Void

    private let debounce: TimeInterval

    /// Everything below this line is touched **only** on `queue`, which is
    /// serial and is also the queue FSEvents delivers on. That is the whole of
    /// this class's thread safety: no locks, one queue, and the public entry
    /// points hop onto it.
    private let queue = DispatchQueue(label: "dev.mark.watch", qos: .utility)

    /// One entry per watched document.
    private struct Watched {
        /// Directories whose events mean "re-read this": the link's parent and,
        /// when different, the target's parent.
        let directories: Set<String>
        /// The last content we reported. `nil` means "not read yet", so the
        /// first event after a vanish reports the file as changed again.
        var hash: String?
        /// Whether the last read found the file missing, so a reappearance is
        /// reported even if the bytes are unchanged.
        var missing: Bool = false
    }

    private var watched: [URL: Watched] = [:]
    private var stream: FSEventStreamRef?

    /// The box FSEvents holds, retained for exactly as long as the stream is.
    /// Released on ``queue`` together with the stream it belongs to, never
    /// from an arbitrary thread — see ``EventSink``.
    private var sink: Unmanaged<EventSink>?

    private var streamDirectories: Set<String> = []
    private var scanScheduled = false
    private var suspects: Set<URL> = []

    /// How many times each suspect has read back empty or missing. Cleared the
    /// moment it reads back usable.
    private var attempts: [URL: Int] = [:]

    /// The hash of no bytes at all, so "the file is empty" can be told from
    /// "the file was empty before" without special cases.
    private static let emptyHash = DocumentSource.hash(Data())

    /// Counters for the log line at the end of every scan. A watcher that has
    /// gone silent and a watcher that is firing constantly look identical from
    /// the outside, and both are bugs.
    private var eventCount = 0
    private var scanCount = 0
    private var reportedCount = 0

    public init(
        debounce: TimeInterval = FileWatcher.defaultDebounce,
        onChange: @escaping @Sendable @MainActor (FileChange) -> Void
    ) {
        precondition(debounce >= 0, "a negative debounce is not a debounce")
        self.debounce = debounce
        self.handler = onChange
    }

    /// The stream and its ``EventSink``, as one value that can cross a queue.
    private struct StreamHandle: @unchecked Sendable {
        let stream: FSEventStreamRef
        let sink: UnsafeMutableRawPointer?
    }

    /// Tear the stream down **on the queue that delivers its callbacks**.
    ///
    /// M5 wrote this as three synchronous calls in `deinit`, from whatever
    /// thread released the last reference. That is a use-after-free, and it
    /// crashed: `swiftpm-testing-helper-2026-08-24-223632.ips` is a SIGSEGV in
    /// `FileWatcher.eventsArrived` reached from `root_dir_event_callback` on
    /// `dev.mark.watch`, reproducing about 1 run in 16 of the Swift suite. Two
    /// bugs combined to produce it, and both are fixed here:
    ///
    /// 1. FSEvents was handed `Unmanaged.passUnretained(self)`, so the
    ///    callback resurrected a `FileWatcher` that had already been
    ///    deallocated. It now gets an ``EventSink`` box holding a **weak**
    ///    reference: after `deinit` begins, a weak load yields `nil` and the
    ///    callback does nothing, which is the whole of the safety argument.
    /// 2. `deinit` stopped and invalidated the stream from an arbitrary
    ///    thread, which can run *concurrently with a callback already
    ///    executing*. Teardown is now dispatched onto ``queue``, which is
    ///    serial and is the queue FSEvents delivers on, so a callback and its
    ///    teardown cannot overlap by construction.
    ///
    /// `async`, not `sync`: the last reference can legitimately be released
    /// *on* this queue — a scan block holds a strong `self` for its duration —
    /// and `queue.sync` from there is a deadlock. Nothing of `self` is
    /// captured; the stream and the box are passed by value.
    private static func teardown(
        stream: FSEventStreamRef, sink: Unmanaged<EventSink>?, on queue: DispatchQueue
    ) {
        // Both pointers travel as one `@unchecked Sendable` value: neither
        // `FSEventStreamRef` nor a raw pointer is `Sendable`, and this closure
        // crosses a queue. Unchecked is honest here — the whole point of
        // dispatching to `queue` is that these become single-threaded again.
        let handle = StreamHandle(stream: stream, sink: sink?.toOpaque())
        queue.async {
            FSEventStreamStop(handle.stream)
            FSEventStreamInvalidate(handle.stream)
            FSEventStreamRelease(handle.stream)
            // After the release, because releasing the stream is what
            // guarantees no further callback will read the box.
            if let boxed = handle.sink {
                Unmanaged<EventSink>.fromOpaque(boxed).release()
            }
        }
    }

    deinit {
        if let stream {
            Self.teardown(stream: stream, sink: sink, on: queue)
        }
    }

    // MARK: - The watch set

    /// Watch exactly these documents, and nothing else.
    ///
    /// Idempotent, and cheap when the set has not changed: the FSEvents stream
    /// is only torn down and rebuilt when the set of *directories* changes, so
    /// opening a second file in a directory already being watched costs
    /// nothing.
    ///
    /// Synchronous on purpose. On return the stream is armed, so a caller that
    /// opens a document and then writes to it cannot lose the event to a race
    /// with its own setup.
    public func setWatched(_ urls: Set<URL>) {
        queue.sync {
            let standardized = Set(urls.map { $0.standardizedFileURL })
            // Collected first: mutating a dictionary while iterating its own
            // keys view is the kind of thing that works until it does not.
            for url in watched.keys.filter({ !standardized.contains($0) }) {
                watched.removeValue(forKey: url)
                suspects.remove(url)
                attempts.removeValue(forKey: url)
            }
            for url in standardized where watched[url] == nil {
                watched[url] = Watched(
                    directories: Self.directories(for: url),
                    hash: (try? Data(contentsOf: url)).map(DocumentSource.hash)
                )
            }
            rebuildStreamIfNeeded()
        }
    }

    /// Stop entirely. The watcher restarts if something is watched again.
    public func stop() {
        queue.sync {
            watched.removeAll()
            suspects.removeAll()
            rebuildStreamIfNeeded()
        }
    }

    /// The documents currently watched. For tests and for `mark doctor`.
    public var watchedURLs: Set<URL> {
        queue.sync { Set(watched.keys) }
    }

    /// The directories the FSEvents stream is actually rooted at.
    ///
    /// Exposed because "we are watching the file's directory, not the file" is
    /// the constraint most easily lost in a refactor, and it is invisible from
    /// the outside otherwise.
    public var watchedDirectories: Set<String> {
        queue.sync { streamDirectories }
    }

    /// Tell the watcher what a file's contents are *without* reporting a
    /// change.
    ///
    /// Not used in M5 — the checkbox round trip deliberately lets the watcher
    /// see its own write, so the resulting patch is the single visible change.
    /// It exists because `2026-08-24-editing-pane-and-autosave` requires it:
    /// *"Every write records its content hash, and the watcher suppresses
    /// matches"*, at 800 ms autosave cadence where seeing your own write means
    /// re-rendering under the cursor.
    public func noteWrittenContent(_ source: String, to url: URL) {
        queue.sync {
            let url = url.standardizedFileURL
            guard var entry = watched[url] else { return }
            entry.hash = DocumentSource.hash(source)
            entry.missing = false
            watched[url] = entry
        }
    }

    // MARK: - The stream

    /// Every directory whose events could mean this document changed.
    ///
    /// Resolved with `realpath`, because FSEvents reports resolved paths:
    /// `NSTemporaryDirectory()` is `/var/folders/…`, which is a symlink, and
    /// every event for it arrives as `/private/var/folders/…`. Comparing
    /// unresolved paths gives a watcher that arms successfully and never
    /// matches anything.
    private static func directories(for url: URL) -> Set<String> {
        var result: Set<String> = []
        let parent = url.deletingLastPathComponent()
        result.insert(resolve(parent.path))
        // A symlinked document: `mark_toggle` canonicalizes before renaming, so
        // the write lands next to the *target* and produces no event at all in
        // the link's own directory.
        let target = url.resolvingSymlinksInPath()
        if target.path != url.standardizedFileURL.path {
            result.insert(resolve(target.deletingLastPathComponent().path))
        }
        return result
    }

    private static func resolve(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func rebuildStreamIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        let wanted = Set(watched.values.flatMap { $0.directories })
        guard wanted != streamDirectories else { return }

        if let stream {
            // Already on `queue`, so this is serialized with the callback for
            // free; it goes through the same path as `deinit` so there is one
            // teardown, not two.
            Self.teardown(stream: stream, sink: sink, on: queue)
            self.stream = nil
            self.sink = nil
        }
        streamDirectories = wanted
        guard !wanted.isEmpty else {
            Log.watch.debug("watcher idle: nothing open")
            return
        }

        // Retained, and released by `teardown(stream:sink:on:)` after the
        // stream that reads it is gone. Unretained is what crashed M5's
        // version; a retained *box* rather than a retained `self` is what
        // keeps `deinit` reachable at all.
        let sink = Unmanaged.passRetained(EventSink(owner: self))
        var context = FSEventStreamContext(
            version: 0,
            info: sink.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        // `fileEvents` gives per-file paths instead of directory-level ones,
        // `noDefer` delivers the first event of a burst immediately (the
        // debounce below is ours, so FSEvents' own latency is set to zero), and
        // `watchRoot` reports the watched directory itself being moved or
        // replaced — which is what a `git checkout` of a whole tree looks like.
        let flags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
            | UInt32(kFSEventStreamCreateFlagWatchRoot)

        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, paths, flags, _ in
                    guard let info else { return }
                    // The box is alive for as long as the stream is, and its
                    // reference to the watcher is weak: a callback that races
                    // deallocation loads `nil` and returns, rather than
                    // sending a message to freed memory.
                    let sink = Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue()
                    guard let watcher = sink.owner else {
                        EventSink.orphaned.increment()
                        return
                    }
                    let cfPaths = unsafeBitCast(paths, to: NSArray.self)
                    var reported: [(String, FSEventStreamEventFlags)] = []
                    reported.reserveCapacity(count)
                    for index in 0..<count {
                        guard let path = cfPaths[index] as? String else { continue }
                        reported.append((path, flags[index]))
                    }
                    watcher.eventsArrived(reported)
                },
                &context,
                Array(wanted) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0,
                flags
            )
        else {
            Log.watch.fault(
                "FSEventStreamCreate failed for \(wanted.count) director\(wanted.count == 1 ? "y" : "ies"); external changes will not be seen"
            )
            sink.release()
            streamDirectories = []
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            Log.watch.fault("FSEventStreamStart failed; external changes will not be seen")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            sink.release()
            streamDirectories = []
            return
        }
        stream = created
        self.sink = sink
        Log.watch.info(
            "watching \(wanted.count) director\(wanted.count == 1 ? "y" : "ies") for \(self.watched.count) document(s)"
        )
    }

    // MARK: - Events

    /// Called by the FSEvents callback, on `queue`.
    ///
    /// The flags are **logged and otherwise ignored**. FSEvents coalesces,
    /// reorders and drops, and `kFSEventStreamEventFlagItemRemoved` for a temp
    /// file is indistinguishable from the same flag for the document. What the
    /// event is trusted for is one thing only: *something happened in this
    /// directory*.
    private func eventsArrived(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        dispatchPrecondition(condition: .onQueue(queue))
        eventCount += events.count

        for (path, _) in events {
            for (url, entry) in watched where entry.directories.contains(where: {
                path == $0 || path.hasPrefix($0 + "/")
            }) {
                suspects.insert(url)
            }
        }
        guard !suspects.isEmpty else { return }

        // Throttle rather than reset-on-every-event: a burst schedules exactly
        // one scan `debounce` from its *first* event. A trailing debounce that
        // restarts on each event never fires at all while something writes
        // continuously, which is precisely what an editor doing a multi-chunk
        // save looks like.
        guard !scanScheduled else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.scan()
        }
    }

    /// Re-read every suspect file and report the ones whose bytes changed.
    ///
    /// A short, empty, or missing read is **not** believed on the first
    /// attempt: `truncate` + `write` is not atomic, so there is a real window
    /// in which a file that is about to hold 40 KB holds nothing, and
    /// reporting that window as the document is how a watcher blanks someone's
    /// notes on screen. Such a file goes back in the suspect set and the whole
    /// scan is re-scheduled.
    ///
    /// The retry is a re-schedule rather than a sleep on purpose: this queue is
    /// the one ``setWatched(_:)`` blocks on, and opening a tab while some other
    /// file is mid-save must not stall the main thread for the length of the
    /// retry budget.
    private func scan() {
        dispatchPrecondition(condition: .onQueue(queue))
        scanScheduled = false
        let candidates = suspects
        suspects.removeAll()
        guard !candidates.isEmpty else { return }
        scanCount += 1

        var retrying: Set<URL> = []
        for url in candidates {
            guard let entry = watched[url] else {
                attempts.removeValue(forKey: url)
                continue
            }
            let previouslyEmpty = entry.hash == Self.emptyHash
            let data = try? Data(contentsOf: url, options: [.uncached])
            let usable = data.map { !$0.isEmpty || previouslyEmpty } ?? false
            let spent = (attempts[url] ?? 0) + 1 >= Self.readRetries

            if usable, let data {
                attempts.removeValue(forKey: url)
                report(data, at: url, entry: entry)
            } else if spent {
                attempts.removeValue(forKey: url)
                if let data {
                    // Really empty, rather than a write in flight.
                    Log.watch.info(
                        "\(url.lastPathComponent, privacy: .public) is still empty after \(Self.readRetries) reads; reporting it as empty"
                    )
                    report(data, at: url, entry: entry)
                } else {
                    reportVanished(at: url, entry: entry)
                }
            } else {
                attempts[url] = (attempts[url] ?? 0) + 1
                retrying.insert(url)
            }
        }

        if !retrying.isEmpty {
            suspects.formUnion(retrying)
            scanScheduled = true
            queue.asyncAfter(deadline: .now() + Self.readRetryDelay) { [weak self] in
                self?.scan()
            }
        }
        Log.watch.debug(
            "scan \(self.scanCount): \(candidates.count) candidate(s), \(retrying.count) retrying, \(self.reportedCount) reported so far, \(self.eventCount) raw event(s)"
        )
    }

    private func report(_ data: Data, at url: URL, entry: Watched) {
        dispatchPrecondition(condition: .onQueue(queue))
        let hash = DocumentSource.hash(data)
        guard hash != entry.hash || entry.missing else { return }
        guard let source = try? DocumentSource.decode(data, from: url) else {
            Log.watch.error(
                "\(url.lastPathComponent, privacy: .public) changed but could not be decoded as text"
            )
            return
        }
        var updated = entry
        updated.hash = hash
        updated.missing = false
        watched[url] = updated
        reportedCount += 1
        deliver(.changed(url: url, source: source, hash: hash))
    }

    private func reportVanished(at url: URL, entry: Watched) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !entry.missing else { return }
        var updated = entry
        updated.missing = true
        // Cleared so that a file which comes back byte-identical still reports
        // as a change: "it went away and came back" is news even when the bytes
        // are not.
        updated.hash = nil
        watched[url] = updated
        reportedCount += 1
        deliver(.vanished(url: url))
    }

    /// Hand a change to the main actor, preserving order.
    ///
    /// `DispatchQueue.main.async` rather than `Task { @MainActor in … }`
    /// because unstructured tasks have no ordering guarantee between them: two
    /// changes to the same document could arrive at the tab in the wrong order,
    /// leaving the older source rendered. The main queue is FIFO, and it *is*
    /// the main actor's executor, which is what makes `assumeIsolated` sound
    /// here.
    private func deliver(_ change: FileChange) {
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(change)
            }
        }
    }
}
