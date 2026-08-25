import AppKit
import Foundation
import WebKit

/// Where a tab is in ADR-4's hydration state machine.
///
/// > The dehydration policy adds a state machine — hydrated, dehydrated,
/// > rehydrating — and every feature touching a tab must tolerate a tab whose
/// > DOM does not currently exist.
///
/// The three cases are exactly those. ``hydrating`` is the one that is easy to
/// forget: the ``DocumentView`` exists and is attached, but its shell page may
/// not have loaded and its document has certainly not painted, so the DOM is
/// still not there to be queried.
public enum HydrationState: String, Sendable, Equatable {
    /// No web view. The tab is a path, a scroll offset, a title, and task
    /// counts — nothing else.
    case dehydrated
    /// A web view exists and the document has been asked for, but nothing has
    /// painted yet.
    case hydrating
    /// A web view exists and the document has painted at least its prefix.
    case hydrated

    /// Whether this state owns a `WKWebView`, and therefore counts against
    /// ADR-4's resident working set.
    public var isResident: Bool { self != .dehydrated }
}

/// What the *core* knows about a document, as opposed to what its DOM knows.
///
/// ADR-4's constraint, and the reason this type exists at all:
///
/// > **No feature may assume a tab's web view exists.** Anything operating
/// > across all open documents goes through the core against the file on disk.
///
/// The tab bar's open-task badge is precisely such a feature — a dehydrated
/// tab still shows a correct count, because the count comes from
/// `mark_tasks_json` over the bytes on disk and never from a DOM query.
public struct DocumentMetadata: Sendable, Equatable {

    /// Open and total task counts, straight from `mark_tasks_json`.
    public let tasks: TaskCounts

    /// The document's own first heading, when it has one. Used for the tooltip
    /// and the accessibility description, not for the tab's label — the label
    /// is the filename, which is what every tab bar on this platform shows and
    /// what M2 already puts in the window title.
    public let documentTitle: String?

    /// Every heading, in document order, with the anchors the rendered page
    /// carries.
    ///
    /// Here rather than on ``DocumentView`` for the reason ADR-4 gives as a
    /// constraint: *"no feature may assume a tab's web view exists"*. The
    /// sidebar's table of contents is exactly such a feature — it draws for the
    /// selected tab, and a tab can be selected before its document has painted
    /// — so its input is the core's answer about the bytes, not a DOM query.
    ///
    /// Free, in the sense that matters: ``documentTitle`` was already a `toc`
    /// call, and this keeps the result instead of throwing all but the first
    /// entry away.
    public let headings: [Heading]

    public init(tasks: TaskCounts, documentTitle: String?, headings: [Heading] = []) {
        self.tasks = tasks
        self.documentTitle = documentTitle
        self.headings = headings
    }

    /// The same, for bytes already in hand.
    ///
    /// The dirty-buffer path. `2026-08-24-editing-pane-and-autosave` is
    /// explicit that *"nothing may read the file for rendering, task counts, or
    /// search on a dirty tab"*, and a tab's badge is exactly a task count — so
    /// while a buffer is dirty the badge is computed from **its** bytes, not
    /// from the file's.
    public static func load(source: String) throws -> DocumentMetadata {
        let tasks = try MarkCore.tasks(source: source)
        let headings = (try? MarkCore.toc(source: source)) ?? []
        let heading = headings.first(where: { $0.level == 1 })?.text ?? headings.first?.text
        return DocumentMetadata(
            tasks: TaskCounts(
                open: tasks.filter { !$0.checked }.count,
                total: tasks.count
            ),
            documentTitle: heading?.isEmpty == true ? nil : heading,
            headings: headings
        )
    }

    /// Read `url` and ask the core about it.
    ///
    /// `nonisolated` and free of AppKit on purpose: it is called from a
    /// background task so opening a tab does not stall the main thread on a
    /// file read, and calling it from the main actor would defeat that.
    public static func load(url: URL) throws -> DocumentMetadata {
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            var encoding = String.Encoding.utf8
            guard let guessed = try? String(contentsOf: url, usedEncoding: &encoding) else {
                throw DocumentError.unreadable(path: url.path, underlying: error)
            }
            source = guessed
        }
        let tasks = try MarkCore.tasks(source: source)
        let headings = (try? MarkCore.toc(source: source)) ?? []
        let heading =
            headings.first(where: { $0.level == 1 })?.text
            ?? headings.first?.text
        return DocumentMetadata(
            tasks: TaskCounts(
                open: tasks.filter { !$0.checked }.count,
                total: tasks.count
            ),
            documentTitle: heading?.isEmpty == true ? nil : heading,
            headings: headings
        )
    }
}

/// One open document.
///
/// Per plan §1: *"one tab: path, scroll, `WKWebView?`"*. The `?` is the whole
/// point — ADR-4 bounds memory by tearing the web view down for tabs outside
/// the resident working set, so every field here except ``documentView`` must
/// survive that teardown and be usable without it.
@MainActor
public final class DocumentTab: Identifiable {

    /// Stable across dehydration, reordering, and a session round trip within
    /// one run. Session restore mints new ids, which is why ``url`` and not
    /// ``id`` is what identifies a document across launches.
    public let id = UUID()

    /// The file this tab shows. Standardized, so `./README.md` and
    /// `/abs/README.md` are recognised as the same document.
    public let url: URL

    /// The tab bar's label: the filename.
    public var title: String { url.lastPathComponent }

    /// Whether this tab is the **preview** tab — VS Code's italic single-slot
    /// tab, opened by a single click in the sidebar and replaced by the next
    /// single click rather than accumulating.
    ///
    /// The invariant ``TabStore`` maintains is *at most one preview tab in the
    /// bar*, which is what makes clicking down a directory of notes cost one
    /// tab instead of forty. It is a property of the tab rather than of the
    /// store because it has to survive reordering, a session round trip, and
    /// ADR-4's dehydration — a preview tab evicted for memory is still a
    /// preview tab when it comes back.
    ///
    /// Cleared, never set, by ``promote()``: promotion is one-way. A permanent
    /// tab does not decay back into a preview one, because every way of
    /// promoting is the user saying *keep this*.
    public private(set) var isPreview: Bool = false

    /// The core's view of the document. `nil` until the first load finishes;
    /// the badge simply does not draw until then.
    public private(set) var metadata: DocumentMetadata?

    /// Open task count for the badge, or `nil` when unknown or zero.
    public var openTaskCount: Int? {
        guard let open = metadata?.tasks.open, open > 0 else { return nil }
        return open
    }

    /// `window.pageYOffset` for this document.
    ///
    /// Kept current from the page's throttled `scroll` messages rather than
    /// read on demand, because it has to be readable *synchronously* at two
    /// moments when an async round trip to the page is not available: when the
    /// web view is being torn down, and in `applicationWillTerminate`.
    public var scrollOffset: Double = 0

    public private(set) var state: HydrationState = .dehydrated

    /// The resident web view's host, or `nil` when dehydrated.
    public private(set) var documentView: DocumentView?

    /// ADR-4's resident view. `nil` when dehydrated — callers must handle that
    /// rather than force-unwrapping.
    public var webView: WKWebView? { documentView?.webView }

    /// The unsaved buffer, once this tab has been edited.
    ///
    /// Lives here rather than on ``DocumentView`` for the reason
    /// `2026-08-24-editing-pane-and-autosave` gives as a constraint — *"the
    /// editor pane must not assume a `WKWebView` exists"* — and because the
    /// buffer has to outlive anything ADR-4 might tear down. It is `nil` until
    /// the editor is opened on this tab.
    public private(set) var buffer: Buffer?

    /// ADR-6's central question, asked by eviction, by the tab bar, by the
    /// badge, and by every write path: **is this tab dirty?**
    public var isDirty: Bool { buffer?.isDirty ?? false }

    /// The bytes this tab's document currently *is*: the buffer's while dirty,
    /// the file's otherwise.
    ///
    /// > While a tab is dirty, the buffer is the source of truth.
    public var authoritativeSource: String? {
        guard let buffer, buffer.isDirty else { return nil }
        return buffer.text
    }

    /// MRU stamp, assigned by ``TabStore`` on every selection. Eviction picks
    /// the smallest.
    var lastUsed: UInt64 = 0

    /// Generation counter for in-flight metadata loads, so a slow read for an
    /// old revision cannot overwrite a newer one.
    private var metadataGeneration: UInt64 = 0

    public init(url: URL, isPreview: Bool = false) {
        self.url = url.standardizedFileURL
        self.isPreview = isPreview
    }

    /// Make this tab permanent.
    ///
    /// - Returns: whether anything changed, so callers on a hot path — the
    ///   drag loop calls this on every step of a reorder — can skip the
    ///   delegate churn when it did not.
    @discardableResult
    func promote() -> Bool {
        guard isPreview else { return false }
        isPreview = false
        Log.tabs.debug("promote \(self.title, privacy: .public) out of preview")
        return true
    }

    // MARK: - Hydration

    func attach(_ view: DocumentView) {
        documentView = view
        state = .hydrating
    }

    func notePainted() {
        if documentView != nil { state = .hydrated }
    }

    /// Drop the web view. Returns it so the caller can take it out of the view
    /// hierarchy; the tab keeps everything else.
    @discardableResult
    func detach() -> DocumentView? {
        let view = documentView
        if let view { scrollOffset = view.scrollOffset }
        documentView = nil
        state = .dehydrated
        return view
    }

    // MARK: - Metadata

    /// Re-read the file and refresh the badge.
    ///
    /// Off the main thread, because it reads and parses the whole file. This is
    /// the ADR-4-mandated path: the badge is a function of the bytes on disk,
    /// so it works identically for a hydrated and a dehydrated tab.
    public func refreshMetadata(completion: (@MainActor () -> Void)? = nil) {
        metadataGeneration += 1
        let generation = metadataGeneration
        let url = self.url
        // Captured on the main actor, before the hop: while this tab is dirty
        // the buffer is truth, and reading the file here would badge the tab
        // with counts the reader cannot see.
        let dirtySource = authoritativeSource
        _Concurrency.Task.detached(priority: .utility) { [weak self] in
            let loaded =
                dirtySource.flatMap { try? DocumentMetadata.load(source: $0) }
                ?? (dirtySource == nil ? try? DocumentMetadata.load(url: url) : nil)
            await MainActor.run {
                guard let self, generation == self.metadataGeneration else { return }
                if let loaded {
                    self.metadata = loaded
                } else {
                    Log.tabs.info(
                        "metadata unavailable for \(url.lastPathComponent, privacy: .public)")
                }
                completion?()
            }
        }
    }

    /// Give this tab its editing buffer. Called once, when the editor is first
    /// opened on it.
    func attach(buffer: Buffer) {
        self.buffer = buffer
    }

    /// Drop the buffer. The tab is closing, or its edits have been discarded.
    func detachBuffer() {
        buffer = nil
    }

    /// Set the metadata directly. For tests and for the session restore path,
    /// where the counts are already known.
    public func applyMetadata(_ metadata: DocumentMetadata) {
        metadataGeneration += 1
        self.metadata = metadata
    }
}

/// Identity is the object, not the URL — two tabs on the same file would be a
/// bug in ``TabStore/open(_:)``, not something equality should paper over.
///
/// `nonisolated` on both members so the conformance itself is not main-actor
/// isolated: `tabs.firstIndex(of:)` and `Set<DocumentTab>` need `==` and
/// `hash(into:)` to satisfy the *nonisolated* protocol requirements, and
/// neither touches any isolated state.
extension DocumentTab: Equatable, Hashable {
    public nonisolated static func == (lhs: DocumentTab, rhs: DocumentTab) -> Bool {
        lhs === rhs
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
