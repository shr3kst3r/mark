import Foundation

/// Why a buffer's text changed, which decides what the rest of the app does
/// about it.
public enum EditOrigin: Sendable, Equatable {
    /// The user typed. Marks the buffer dirty and starts both clocks.
    case typing
    /// A checkbox was clicked in the preview while the tab was dirty. Same as
    /// typing for the file, but the preview must catch up *now* rather than in
    /// 250 ms — a checkbox that takes a quarter of a second to tick reads as a
    /// missed click.
    case checkbox
    /// The file changed underneath a **clean** buffer, or the user chose
    /// "take theirs". The buffer is following the disk, so it does not become
    /// dirty and nothing is scheduled.
    case external
}

/// Where a buffer's text came from and where it is going, for the log line.
public struct BufferSaveReport: Sendable, Equatable {
    public let bytes: Int
    /// The canonical path written — not the path asked for, when that is a
    /// symlink.
    public let path: String
    public let hash: String
    public let seconds: Double
}

/// An external change that matches neither our buffer nor anything we wrote.
public struct Conflict: Sendable, Equatable {
    /// What is on disk now.
    public let theirs: String
    public let theirHash: String
    /// What the buffer held when the conflict was raised.
    public let mine: String
    public let detectedAt: Date

    public init(theirs: String, theirHash: String, mine: String, detectedAt: Date = Date()) {
        self.theirs = theirs
        self.theirHash = theirHash
        self.mine = mine
        self.detectedAt = detectedAt
    }
}

/// What the user chose. There is no "merge": ADR-6 rejects guessing.
public enum ConflictResolution: String, Sendable, Equatable {
    /// The buffer wins. Autosave resumes and the next debounce writes it.
    case keepMine
    /// The disk wins. The buffer becomes the file's contents and clean.
    /// **Nothing is written** — this is the resolution that must never write.
    case takeTheirs
}

/// What happened to an external change that reached a buffer.
public enum ExternalChange: Sendable, Equatable {
    /// We wrote it. Nothing to do — and this should already have been
    /// suppressed one layer down, in ``FileWatcher/noteWrittenContent(_:to:)``.
    case ours
    /// The tab was clean, so the file is truth and the buffer follows it.
    case adopted
    /// Someone else wrote exactly what we hold. Not a conflict: the buffer is
    /// simply no longer dirty.
    case converged
    /// Neither ours nor equal to the buffer, while dirty. Autosave is now
    /// paused.
    case conflicted(Conflict)
}

/// Why a save did not happen.
public enum BufferError: Error, CustomStringConvertible {
    case core(path: String, underlying: any Error)
    case conflicted(path: String)

    public var description: String {
        switch self {
        case .core(let path, let underlying):
            return "\(path): saving failed: \(String(describing: underlying))"
        case .conflicted(let path):
            return
                "\(path): a conflict is unresolved; autosave is paused and nothing will be written"
        }
    }
}

/// Where the document's bytes live while a tab is being edited.
///
/// `2026-08-24-editing-pane-and-autosave` makes this type the answer to the
/// question every other feature has to ask first:
///
/// > **While a tab is dirty, the buffer is the source of truth**, and the
/// > preview renders from the buffer rather than from the file. When a tab is
/// > clean, the file is truth, exactly as before.
///
/// Everything with a corruption shape lives here rather than being spread
/// across the editor, the watcher and the tab:
///
/// * **Two clocks, not one.** Autosave fires 800 ms after typing stops, as the
///   ADR requires. The *preview* fires at 250 ms, because M5 measured
///   `mark_diff_json` plus the two `*_json` re-stamp calls at 10–15 ms for a
///   1 MB document — fine at save cadence, not at typing cadence. Separating
///   them is what keeps a keystroke from waiting on a diff.
/// * **Every write records its hash**, and ``onWillWrite`` hands it to the
///   watcher *before* the bytes land, so the event our own save produces is
///   already accounted for when it arrives. A miss here is a cursor that jumps
///   while typing.
/// * **Hashes we have seen are remembered**, not just the last one. A failed
///   write, a save that lands twice, and a checkbox toggle that reverts a
///   previous one all produce content we originated, and treating any of them
///   as someone else's edit would raise a conflict prompt over nothing.
/// * **A conflict pauses autosave and is never resolved by writing.**
/// * **A dirty buffer holds an exclusive `flock(2)` on its document**, and a
///   clean one holds none. `2026-08-25-flock-write-locking` supersedes M9's
///   "the CLI may still write a file the GUI holds dirty": a terminal
///   `mark check` against a document with unsaved edits now fails loudly and
///   names this process, instead of succeeding into a dialog on someone else's
///   screen. See ``syncLock()``, which is where the whole of that lives.
///
/// The disk is touched in exactly one place, ``save()``, which goes through
/// `mark_write_json` → `core::tasks::write_atomically`.
@MainActor
public final class Buffer {

    /// ADR-6: *"Autosave writes 800 ms after typing stops."*
    public static let autosaveDebounce: TimeInterval = 0.800

    /// The preview's own, much shorter debounce. Not in the ADR — it is the
    /// implementation answer to the cost M5 measured, and the ADR leaves the
    /// mechanism open.
    public static let previewDebounce: TimeInterval = 0.250

    /// How many of our own content hashes are remembered. Generous: each is 64
    /// bytes, and the cost of forgetting one is a false conflict prompt.
    static let rememberedHashes = 16

    public let url: URL

    /// The document. **Authoritative whenever ``isDirty`` is true.**
    public private(set) var text: String

    /// ``text``'s length in UTF-16 units, maintained incrementally.
    ///
    /// The editor speaks UTF-16 and this buffer speaks Swift `String`, so an
    /// incremental edit needs a length in the editor's units to validate
    /// against — and computing it from the text each time would reintroduce
    /// exactly the per-keystroke walk of the whole document that
    /// ``applyEdit(replacing:with:)`` exists to avoid. It is also the
    /// divergence check: if this and `NSTextStorage.length` ever disagree, the
    /// two copies of the document have drifted apart and the editor
    /// resynchronises.
    public private(set) var utf16Length: Int

    /// What the file held the last time we knew: at open, at every successful
    /// save, and after "take theirs".
    public private(set) var savedText: String {
        didSet { savedUtf16Length = savedText.utf16.count }
    }

    /// ``savedText``'s length in UTF-16 units — the cheap half of "is this tab
    /// dirty?", see ``applyEdit(replacing:with:)``.
    private var savedUtf16Length: Int = 0

    public private(set) var isDirty: Bool = false

    /// The unresolved conflict, if any. Autosave is paused while this is set.
    public private(set) var conflict: Conflict?

    public var isConflicted: Bool { conflict != nil }

    /// Content hashes this buffer originated — the file's contents at open,
    /// plus every set of bytes we have written. Insertion-ordered so the
    /// oldest is dropped first.
    private var knownHashes: [String] = []

    /// The `flock(2)` this buffer holds while it is dirty, and only while it is
    /// dirty. `nil` means we hold nothing — which for a clean tab is the
    /// correct and required state. Released by `deinit` when the tab closes,
    /// by the kernel if we crash first.
    private var lock: DocumentLock?

    /// Whether this buffer is holding a lock on the document *as it is on disk
    /// right now*.
    ///
    /// The `isCurrent` half is the point: after an autosave the document is a
    /// different inode, and a lock on the old one is held on an orphan that no
    /// longer answers to the path. A test that only asked `lock != nil` would
    /// pass against exactly the bug ``syncLock()`` exists to prevent.
    public var holdsWriteLock: Bool { lock?.isCurrent ?? false }

    // MARK: Callbacks

    /// The buffer's text changed. The preview is *not* updated from here — see
    /// ``onPreviewDue``, which is debounced.
    public var onChange: ((EditOrigin) -> Void)?

    /// The preview may now be brought up to date, from `text`.
    public var onPreviewDue: ((String) -> Void)?

    /// About to write these bytes. The watcher is told here, before the write,
    /// so a fast FSEvents delivery cannot beat the bookkeeping.
    public var onWillWrite: ((String) -> Void)?

    /// A save landed.
    public var onSaved: ((BufferSaveReport) -> Void)?

    /// A save failed, or was refused because a conflict is open.
    public var onSaveFailed: ((BufferError) -> Void)?

    /// A conflict was detected. The prompt is raised by the caller —
    /// ``ConflictController`` — because a buffer that puts a modal on screen
    /// is untestable.
    public var onConflict: ((Conflict) -> Void)?

    /// ``isDirty`` changed. Drives the tab bar's dot and, crucially, ADR-6's
    /// *"a dirty tab is never dehydrated"*.
    public var onDirtyChanged: ((Bool) -> Void)?

    // MARK: Timers

    private var autosaveWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?

    /// Injectable so a test can drive the debounce without sleeping for a
    /// second per assertion, and so the 60-second gate can run at a realistic
    /// cadence without a 60-second test.
    /// Not `private`: `PreferencesTests` asserts that a new buffer picks the
    /// preference up rather than the constant, and there is no other way to see
    /// which one it took.
    let autosaveDelay: TimeInterval
    private let previewDelay: TimeInterval

    public init(
        url: URL,
        text: String,
        autosaveDelay: TimeInterval = Buffer.autosaveDebounce,
        previewDelay: TimeInterval = Buffer.previewDebounce
    ) {
        self.url = url.standardizedFileURL
        self.text = text
        self.utf16Length = text.utf16.count
        self.savedText = text
        self.savedUtf16Length = self.utf16Length
        self.autosaveDelay = autosaveDelay
        self.previewDelay = previewDelay
        remember(DocumentSource.hash(text))
    }

    /// Read the file and open a buffer on it.
    ///
    /// The default delay is the *preference* rather than the constant, so a
    /// change in Settings reaches the next document opened without a relaunch.
    /// `Buffer.autosaveDebounce` is still the fallback and still the number the
    /// ADR names; the preference only moves it.
    public static func open(
        url: URL,
        autosaveDelay: TimeInterval = Preferences.autosaveDelay(),
        previewDelay: TimeInterval = Buffer.previewDebounce
    ) throws -> Buffer {
        Buffer(
            url: url,
            text: try DocumentSource.read(url),
            autosaveDelay: autosaveDelay,
            previewDelay: previewDelay
        )
    }

    // MARK: - Editing

    /// Apply one edit — the shape a keystroke actually has.
    ///
    /// **The performance fix that makes a 1 MB document typeable.** The obvious
    /// implementation of "the editor changed" is to take `NSTextView.string`
    /// and hand the whole thing over. Measured on the 1 MB corpus, that costs
    /// **86–108 ms per keystroke** on the main thread: bridging a megabyte of
    /// `NSString` and transcoding it to contiguous UTF-8, once per character.
    /// Splicing the same edit into the Swift string instead is a `memmove`.
    ///
    /// `range` is in **UTF-16 units**, because that is what `NSTextStorage`
    /// deals in and this is called from its delegate.
    ///
    /// - Returns: `false` when the range does not fit the buffer, which means
    ///   the buffer and the text view have diverged. The caller resynchronises
    ///   from the text view rather than carrying on with bytes that are now a
    ///   guess.
    @discardableResult
    public func applyEdit(replacing range: NSRange, with replacement: String) -> Bool {
        var start = text.startIndex
        var end = text.startIndex
        var fits = range.location >= 0 && range.length >= 0
            && range.location + range.length <= utf16Length
        if fits {
            start = String.Index(utf16Offset: range.location, in: text)
            end = String.Index(utf16Offset: range.location + range.length, in: text)
            fits = start <= end && end <= text.endIndex
        }
        guard fits else {
            Log.core.error(
                "\(self.url.lastPathComponent, privacy: .public): an editor edit at \(range.location)+\(range.length) does not fit a buffer of \(self.utf16Length) UTF-16 units; resynchronising"
            )
            return false
        }
        text.replaceSubrange(start..<end, with: replacement)
        utf16Length += replacement.utf16.count - range.length
        // Length first, contents only if the lengths match: `text != savedText`
        // is a megabyte-sized comparison on the 1 MB corpus, and almost every
        // keystroke changes the length, so this turns the common case into an
        // integer compare. The full comparison still runs for a same-length
        // edit, which is how undoing back to the saved bytes makes the tab
        // clean again.
        setDirty(utf16Length != savedUtf16Length || text != savedText)
        scheduleAutosave()
        onChange?(.typing)
        schedulePreview()
        return true
    }

    /// Replace the buffer's contents.
    ///
    /// The single entry point for every kind of change, so "did this make the
    /// tab dirty?" and "does the preview need updating?" are answered in one
    /// place rather than at each call site.
    public func replaceContents(_ newText: String, origin: EditOrigin = .typing) {
        guard newText != text || origin == .external else { return }
        text = newText
        utf16Length = newText.utf16.count

        switch origin {
        case .typing, .checkbox:
            setDirty(text != savedText)
            scheduleAutosave()
        case .external:
            savedText = newText
            remember(DocumentSource.hash(newText))
            setDirty(false)
            cancelAutosave()
        }

        onChange?(origin)

        switch origin {
        case .checkbox, .external:
            // A click and a reload are both "the reader is looking at it right
            // now"; waiting out a debounce would look like a dropped event.
            previewWork?.cancel()
            previewWork = nil
            onPreviewDue?(text)
        case .typing:
            schedulePreview()
        }
    }

    // MARK: - Saving

    /// Write the buffer, now, if there is anything to write.
    ///
    /// Called by the autosave debounce, by ⌘S, and by
    /// `applicationWillTerminate` — the last of which is why it is synchronous
    /// rather than async: at quit there is no runloop left to await on.
    @discardableResult
    public func save() -> Bool {
        cancelAutosave()
        guard isDirty else { return false }
        guard conflict == nil else {
            // ADR-6: *"Autosave is paused while a conflict is unresolved.
            // Never resolve a conflict by writing."*
            let error = BufferError.conflicted(path: url.path)
            Log.core.error("\(String(describing: error), privacy: .public)")
            onSaveFailed?(error)
            return false
        }

        let contents = text
        let hash = DocumentSource.hash(contents)
        // Before the write, not after: FSEvents can deliver our own event
        // while `write_atomically`'s rename is still returning, and a watcher
        // that has not been told yet will report it as someone else's change.
        remember(hash)
        onWillWrite?(contents)

        let state = Log.signposter.beginInterval("autosave")
        defer { Log.signposter.endInterval("autosave", state) }

        // Hand the lock to the core for the duration of the write, and take it
        // back — on the *new* inode — afterwards.
        //
        // Both halves are forced. `write_atomically` takes the document's
        // `flock` for itself, and `flock` is per open file description, so our
        // own hold would refuse our own autosave. And the write renames a new
        // inode over the path, so the descriptor we let go of is not the one we
        // need back. `2026-08-25-flock-write-locking`: *"The lock must be
        // re-acquired after every autosave […] A missed re-acquire is silent:
        // the file simply becomes writable again while the buffer is still
        // dirty. This is the sharp edge."*
        //
        // `defer`, not a line after the write, because a *failed* save leaves
        // the buffer dirty too — and a dirty buffer silently holding nothing is
        // the exact failure this is guarding.
        lock = nil
        defer { syncLock() }

        do {
            let measured = try timed { try MarkCore.save(contents, to: url.path) }
            let receipt = measured.value
            savedText = contents
            setDirty(text != savedText)
            let report = BufferSaveReport(
                bytes: receipt.bytes ?? contents.utf8.count,
                path: receipt.path ?? url.path,
                hash: hash,
                seconds: measured.seconds
            )
            Log.core.info(
                """
                autosaved \(self.url.lastPathComponent, privacy: .public): \
                \(report.bytes) bytes to \(report.path, privacy: .public) \
                (\(report.hash.prefix(8), privacy: .public)) in \
                \(report.seconds * 1000, privacy: .public) ms
                """
            )
            Log.stage("autosave", measured.seconds, detail: "bytes=\(report.bytes)")
            onSaved?(report)
            return true
        } catch {
            // The bytes are still in the buffer and the tab is still dirty, so
            // nothing is lost — but the hash stays remembered on purpose: the
            // file holds *older* content we also originated, and forgetting
            // that would turn the next watcher event into a false conflict.
            let failure = BufferError.core(path: url.path, underlying: error)
            Log.core.error("\(String(describing: failure), privacy: .public)")
            onSaveFailed?(failure)
            return false
        }
    }

    private func scheduleAutosave() {
        cancelAutosave()
        guard isDirty, conflict == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.autosaveWork != nil else { return }
            self.autosaveWork = nil
            self.save()
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: work)
    }

    private func cancelAutosave() {
        autosaveWork?.cancel()
        autosaveWork = nil
    }

    /// The preview's clock is a **throttle**, not a debounce.
    ///
    /// This is the same trap ``FileWatcher`` documents on its own scan
    /// scheduling, and it bites harder here: a trailing debounce that restarts
    /// on every keystroke never fires at all while someone is typing steadily,
    /// so the "live preview" would freeze for exactly as long as the user kept
    /// typing and update only when they stopped. A throttle fires
    /// `previewDelay` after the *first* edit of a burst and every
    /// `previewDelay` after that.
    ///
    /// **Autosave is the opposite on purpose**: ADR-6 says *"autosave writes
    /// 800 ms after typing stops"*, which is a trailing debounce, and writing
    /// mid-word every 800 ms is exactly what that ADR rejects in its
    /// "fixed-interval autosave" alternative.
    private func schedulePreview() {
        guard previewWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewWork != nil else { return }
            self.previewWork = nil
            self.onPreviewDue?(self.text)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + previewDelay, execute: work)
    }

    /// Whether a write is currently pending. For the quit path and for tests.
    public var hasPendingSave: Bool { autosaveWork != nil }

    // MARK: - The disk changing underneath

    /// The watcher saw `source` on disk. Decide what it means.
    ///
    /// The three-way test the ADR spells out: *"If the watcher reports content
    /// matching neither our buffer nor our last-written hash while the tab is
    /// dirty, autosave pauses and the user chooses."* Both halves of "neither"
    /// are checked here, and "our last-written hash" is a small history rather
    /// than one value — see ``knownHashes``.
    @discardableResult
    public func fileChanged(source: String, hash: String) -> ExternalChange {
        // Whoever wrote it almost certainly renamed a new inode over the path —
        // that is what an atomic save is — so a lock we were holding is now on
        // an orphan. Every exit from this function can leave the buffer dirty,
        // so the re-acquire is a `defer` rather than a line in one branch.
        defer { syncLock() }
        if knownHashes.contains(hash) {
            Log.watch.debug(
                "\(self.url.lastPathComponent, privacy: .public) changed to bytes we wrote; ignored"
            )
            return .ours
        }
        guard isDirty else {
            // Clean tab: the file is truth, exactly as it was before M9.
            replaceContents(source, origin: .external)
            return .adopted
        }
        if source == text {
            // Someone else arrived at our text. Not a conflict, and the tab is
            // no longer dirty — writing it again would be pointless churn.
            savedText = source
            remember(hash)
            cancelAutosave()
            setDirty(false)
            Log.watch.info(
                "\(self.url.lastPathComponent, privacy: .public) was changed to exactly what the buffer holds; the tab is clean"
            )
            return .converged
        }

        let conflict = Conflict(theirs: source, theirHash: hash, mine: text)
        self.conflict = conflict
        cancelAutosave()
        Log.watch.error(
            """
            \(self.url.lastPathComponent, privacy: .public) changed on disk while the buffer was \
            dirty and matches neither the buffer nor anything we wrote \
            (theirs \(hash.prefix(8), privacy: .public), \(source.utf8.count) bytes; \
            mine \(DocumentSource.hash(self.text).prefix(8), privacy: .public), \
            \(self.text.utf8.count) bytes) — autosave is paused until this is resolved
            """
        )
        onConflict?(conflict)
        return .conflicted(conflict)
    }

    /// Apply the user's choice and let autosave run again.
    public func resolve(_ resolution: ConflictResolution) {
        guard let conflict else { return }
        self.conflict = nil
        switch resolution {
        case .keepMine:
            // Deliberately not a write: resolving restarts the ordinary
            // debounce, and the ordinary debounce is what writes.
            Log.core.info(
                "conflict on \(self.url.lastPathComponent, privacy: .public) resolved: keeping the buffer"
            )
            // Their bytes are no longer news — remembering them stops the same
            // conflict being raised twice for one external save.
            remember(conflict.theirHash)
            setDirty(text != savedText)
            scheduleAutosave()
        case .takeTheirs:
            Log.core.info(
                "conflict on \(self.url.lastPathComponent, privacy: .public) resolved: taking the file"
            )
            replaceContents(conflict.theirs, origin: .external)
        }
    }

    // MARK: - Bookkeeping

    private func setDirty(_ value: Bool) {
        guard value != isDirty else { return }
        isDirty = value
        Log.tabs.debug(
            "\(self.url.lastPathComponent, privacy: .public) is now \(value ? "dirty" : "clean")")
        syncLock()
        onDirtyChanged?(value)
    }

    /// Hold the document's write lock **iff** the buffer is dirty, on whatever
    /// inode the path points at right now.
    ///
    /// The whole of `2026-08-25-flock-write-locking`'s app-side decision, in
    /// one function so there is one place to be wrong:
    ///
    /// > The GUI holds an exclusive `flock(2)` on a document for exactly as
    /// > long as its buffer is dirty, and releases it when the buffer becomes
    /// > clean. A clean tab — however long it has been open — holds no lock.
    ///
    /// Called on every dirty/clean transition, after every save, and after
    /// every external change, because all three can invalidate the answer. It
    /// is deliberately idempotent and cheap — a `stat` when a lock is held,
    /// nothing at all when one is not — so calling it defensively is free.
    ///
    /// **Re-acquisition, not just acquisition.** A held lock that is no longer
    /// `isCurrent` is a lock on an orphaned inode: our own autosave produces
    /// that state every time, and so does `vim` saving over the file. Dropping
    /// it before re-opening is required rather than tidy — `flock` is per open
    /// file description, so we would otherwise be refused by ourselves.
    ///
    /// **Failure is not fatal and not silent.** If another `mark` has the
    /// document, we log it and stay dirty and unlocked; the autosave that
    /// follows is refused by the core, with the holder's pid, through
    /// ``onSaveFailed``. Refusing to keep the user's bytes because we could not
    /// take a lock would be a far worse trade.
    private func syncLock() {
        guard isDirty else {
            if lock != nil {
                Log.core.debug(
                    "released the write lock on \(self.url.lastPathComponent, privacy: .public): the tab is clean"
                )
                lock = nil
            }
            return
        }

        if let held = lock {
            if held.isCurrent { return }
            // `info`, not `debug`, and it is the one line here that earns it:
            // this is the only place the sharp edge is visible from telemetry.
            // It is also rare — a *successful* save leaves the tab clean, so
            // this fires when someone else replaced the file underneath a dirty
            // buffer, which is exactly the moment worth being able to see later.
            Log.core.info(
                """
                the write lock on \(self.url.lastPathComponent, privacy: .public) is held on a \
                replaced inode — re-acquiring on the current file
                """
            )
            lock = nil
        }

        do {
            lock = try DocumentLock.acquire(url)
            Log.core.debug(
                "holding the write lock on \(self.url.lastPathComponent, privacy: .public) while it is dirty"
            )
        } catch {
            lock = nil
            Log.core.error(
                """
                \(self.url.lastPathComponent, privacy: .public) is dirty but its write lock could \
                not be taken: \(String(describing: error), privacy: .public) — the next autosave \
                will be refused and will say who has it
                """
            )
        }
    }

    private func remember(_ hash: String) {
        guard !knownHashes.contains(hash) else { return }
        knownHashes.append(hash)
        if knownHashes.count > Self.rememberedHashes {
            knownHashes.removeFirst(knownHashes.count - Self.rememberedHashes)
        }
    }

    /// Whether `hash` is content this buffer originated. For tests and for the
    /// window controller's belt-and-braces check in front of the watcher's.
    public func originated(_ hash: String) -> Bool { knownHashes.contains(hash) }
}

/// A checkbox click on a **dirty** tab.
///
/// The seam M5 left, filled: `2026-08-24-editing-pane-and-autosave` says
///
/// > **Checkbox clicks while dirty apply to the buffer, not the file.** The
/// > core's byte-range toggle runs against the buffer's bytes and the result
/// > re-enters the buffer, which autosave then persists. A checkbox click on a
/// > clean tab keeps writing the file directly, unchanged.
///
/// Both halves are here, and which one runs is decided by ``Buffer/isDirty``
/// at click time rather than by a flag someone has to remember to flip. A
/// clean tab is delegated to ``FileTaskWriter`` untouched, so M5's path is
/// still M5's path.
///
/// The span check is the same one `FileTaskWriter` makes, against the buffer's
/// bytes instead of the file's — and it is worth exactly as much here as there:
/// `TaskWriterTests.spanCheckAloneIsNotEnough` shows it cannot catch every
/// stale index. What *does* catch them is that the preview is re-stamped from
/// `mark_tasks_json` over the same buffer it is rendered from, so its indices
/// and the buffer's cannot drift.
public final class BufferTaskWriter: TaskWriteTarget, @unchecked Sendable {

    /// `@unchecked Sendable` with a main-actor body: ``TaskWriteTarget`` is a
    /// nonisolated protocol (M5 wrote it that way for `FileTaskWriter`, which
    /// is stateless), and the only caller is ``DocumentView``'s script-bridge
    /// handler, which is `@MainActor`. `assumeIsolated` states that rather than
    /// hoping.
    private let buffer: Buffer
    private let file: any TaskWriteTarget

    public init(buffer: Buffer, file: any TaskWriteTarget = FileTaskWriter.shared) {
        self.buffer = buffer
        self.file = file
    }

    public func apply(_ toggle: TaskToggle, to url: URL) throws -> TaskWriteResult {
        try MainActor.assumeIsolated {
            guard buffer.isDirty else {
                return try file.apply(toggle, to: url)
            }

            let source = buffer.text
            let path = url.path
            let tasks: [Task]
            do {
                tasks = try MarkCore.tasks(source: source)
            } catch let error as CoreError {
                throw TaskWriteRefusal.core(
                    function: error.function, detail: error.detail ?? "no message", path: path)
            }
            guard toggle.index >= 0, toggle.index < tasks.count else {
                throw TaskWriteRefusal.noSuchTask(
                    index: toggle.index, total: tasks.count, path: path)
            }
            let task = tasks[toggle.index]
            guard task.start == toggle.span.lowerBound, task.end == toggle.span.upperBound else {
                throw TaskWriteRefusal.spanMoved(
                    index: toggle.index,
                    expected: toggle.span,
                    found: task.start..<task.end,
                    path: path
                )
            }

            let receipt: WriteReceipt
            do {
                receipt = try MarkCore.toggleInBuffer(
                    source, index: toggle.index, action: toggle.desired.action)
            } catch let error as CoreError {
                throw TaskWriteRefusal.core(
                    function: error.function, detail: error.detail ?? "no message", path: path)
            }
            guard let edited = receipt.source, receipt.written == false else {
                // The core is documented to write nothing when no path is
                // given. If that ever stops being true, a dirty tab has just
                // had its file overwritten, which is the one thing this class
                // exists to prevent.
                throw TaskWriteRefusal.core(
                    function: "mark_write_json",
                    detail: "a buffer toggle reported written=\(receipt.written)",
                    path: path
                )
            }

            buffer.replaceContents(edited, origin: .checkbox)
            Log.core.info(
                """
                checkbox \(toggle.index) in \(url.lastPathComponent, privacy: .public) is now \
                \(receipt.state?.rawValue ?? toggle.desired.rawValue, privacy: .public) in the \
                buffer, not the file — the tab is dirty and autosave will persist it
                """
            )
            return TaskWriteResult(
                index: toggle.index,
                state: receipt.state ?? toggle.desired,
                byteOffset: receipt.offset ?? (task.start + 1),
                // The preview is rendered from the buffer while dirty, so it
                // cannot have been rendered from bytes the buffer does not
                // have — unless the page is showing a state the buffer
                // disagrees with, which is exactly what this flag means.
                renderWasStale: task.state != toggle.rendered
            )
        }
    }
}
