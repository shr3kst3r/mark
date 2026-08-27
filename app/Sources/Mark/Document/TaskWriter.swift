import Foundation

/// A checkbox click, as the page described it.
///
/// The three positional fields come straight off the clicked element —
/// `data-mk-idx`, `data-mk-start`, `data-mk-end` — and are ADR-1's checkbox
/// contract verbatim:
///
/// > **Checkbox identity is `(file, task-index)` in document order,** and the
/// > byte span is authoritative. Anything that reorders tasks invalidates
/// > indices held across an edit.
///
/// Both halves are carried, and both are checked before anything is written.
/// The index alone would be enough only if nothing ever edited the file, and
/// the span alone would not tell us *which* task the index refers to.
public struct TaskToggle: Sendable, Equatable {
    /// `data-mk-idx`: position in document order.
    public let index: Int
    /// `data-mk-start ..< data-mk-end`: the marker's byte span in the file the
    /// page was rendered from.
    public let span: Range<Int>
    /// The state the *rendered* HTML said the box was in, read from the
    /// `data-mk-state` content attribute — which a click does not change.
    ///
    /// A state rather than a boolean since `2026-08-27-five-task-states`: with
    /// five states there is no `checked` property for the browser to have
    /// flipped, so the page reports both states by name and this is the one it
    /// was showing.
    public let rendered: TaskState
    /// The state the user just asked for. The page derives it — plain click
    /// toggles, ⌥-click cancels — and the context menu names it outright.
    public let desired: TaskState

    public init(index: Int, span: Range<Int>, rendered: TaskState, desired: TaskState) {
        self.index = index
        self.span = span
        self.rendered = rendered
        self.desired = desired
    }
}

/// What a write did.
public struct TaskWriteResult: Sendable, Equatable {
    public let index: Int
    /// The state on disk after the write.
    public let state: TaskState
    /// "The state is terminal" — done *or* cancelled. Derived from ``state``
    /// rather than carried separately, because two fields that can disagree
    /// about the same byte is how a badge starts lying.
    public var checked: Bool { state.isTerminal }
    /// The single byte the write changed — the character between the brackets.
    public let byteOffset: Int
    /// True when the write happened but the page had been rendered from
    /// *different* bytes than the file holds. The write is still correct (the
    /// span was verified), but the DOM is stale and the caller must re-render:
    /// if the file already held the state the user asked for, no byte changed,
    /// so the watcher will never fire and nothing else will fix the display.
    public let renderWasStale: Bool
}

/// Why a checkbox click did **not** write.
///
/// Every case means the same thing — *we did not touch the file* — and each is
/// plan §3's rule made a type:
///
/// > Toggle target index out of range: … never write a guessed byte.
/// > File changed on disk between render and toggle: re-parse before writing;
/// > if the byte at the target span is no longer a task marker, refuse and
/// > re-render.
public enum TaskWriteRefusal: Error, CustomStringConvertible {
    /// The document has no task with this index any more.
    case noSuchTask(index: Int, total: Int, path: String)

    /// Task `index` exists, but it is not where the page thought it was. The
    /// page is rendered from bytes that are no longer on disk, so its index is
    /// not the identity the ADR guarantees, and writing it would flip a
    /// neighbour.
    case spanMoved(index: Int, expected: Range<Int>, found: Range<Int>, path: String)

    /// The file could not be read at all.
    case unreadable(path: String, underlying: any Error)

    /// The core refused or failed — including its own `MarkerMoved`, which is
    /// the same check again against the bytes it re-read for itself.
    case core(function: String, detail: String, path: String)

    public var description: String {
        switch self {
        case .noSuchTask(let index, let total, let path):
            return
                "\(path): no task \(index); the document has \(total) — refusing to write a guessed byte"
        case .spanMoved(let index, let expected, let found, let path):
            return """
                \(path): task \(index) is at bytes \(found.lowerBound)..\(found.upperBound) now, \
                not \(expected.lowerBound)..\(expected.upperBound) as rendered — the file changed \
                underneath the page; refusing to write and re-rendering
                """
        case .unreadable(let path, let underlying):
            return "\(path): \(underlying.localizedDescription)"
        case .core(let function, let detail, let path):
            return "\(path): \(function) refused: \(detail)"
        }
    }
}

/// Where a checkbox click is applied.
///
/// A protocol with one implementation, on purpose.
/// `2026-08-24-editing-pane-and-autosave` requires that
///
/// > **Checkbox clicks while dirty apply to the buffer, not the file.** The
/// > core's byte-range toggle runs against the buffer's bytes and the result
/// > re-enters the buffer […] A checkbox click on a clean tab keeps writing the
/// > file directly, unchanged.
///
/// M9 slots a buffer-backed implementation in front of ``FileTaskWriter`` at
/// this seam. Nothing above it needs to know which one it is talking to, which
/// is what stops "is this tab dirty?" from having to be asked in the click
/// handler.
public protocol TaskWriteTarget: AnyObject, Sendable {
    /// Apply `toggle` to the document at `url`.
    ///
    /// - Throws: ``TaskWriteRefusal``. A throw always means nothing was
    ///   written.
    func apply(_ toggle: TaskToggle, to url: URL) throws -> TaskWriteResult
}

/// The file on disk, through the core.
///
/// This is the only place in the app that writes a user's document, and it is
/// deliberately thin: every dangerous part of the write already lives in the
/// core and is property-tested there.
///
/// * `mark_toggle` **re-reads and re-parses the file itself** before writing,
///   so the index is checked against current bytes rather than trusted.
/// * It changes exactly one byte — the character between the brackets — and the
///   document's length is unchanged.
/// * It writes through a temp file and a rename, and **canonicalizes the path
///   first**, so a symlinked note is edited rather than replaced by a regular
///   file. That last part is the M1 review's finding, and it is why this does
///   not open the file itself.
///
/// What is added here is the check the core cannot make: that the span the
/// *page* was rendered from is still where that task lives. The core knows what
/// the file says; only the app knows what the reader was looking at.
public final class FileTaskWriter: TaskWriteTarget {

    public static let shared = FileTaskWriter()

    public init() {}

    public func apply(_ toggle: TaskToggle, to url: URL) throws -> TaskWriteResult {
        let path = url.path

        // Re-parse immediately before writing (plan §3). The bytes read here
        // are not the bytes written — the core re-reads for itself — so this is
        // a check, not a read-modify-write.
        let source: String
        do {
            source = try DocumentSource.read(url)
        } catch {
            throw TaskWriteRefusal.unreadable(path: path, underlying: error)
        }

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

        // The span matches, so the index really does name the task the user
        // clicked. The *state* disagreeing is a different thing: it means the
        // page is showing bytes the file no longer has. Writing the state the
        // user asked for is still right — it is what they clicked, at a span we
        // just verified — but the display has to be resynced afterwards, since
        // an already-correct file changes no byte and so produces no watcher
        // event.
        //
        // A state comparison rather than a boolean one since
        // `2026-08-27-five-task-states`: a page showing `[/]` where the file
        // now says `[?]` is stale, and both of those are "not checked".
        let renderWasStale = task.state != toggle.rendered

        // The named state rather than "flip whatever is there": the user asked
        // for one, and this makes a click idempotent if it is somehow delivered
        // twice. It is also what makes ⌥-click and the context menu ordinary —
        // they name a different state and nothing else about the path changes.
        let state: TaskState
        do {
            state = try MarkCore.toggle(
                path: path,
                index: toggle.index,
                action: toggle.desired.action
            )
        } catch let error as CoreError {
            throw TaskWriteRefusal.core(
                function: error.function, detail: error.detail ?? "no message", path: path)
        }

        return TaskWriteResult(
            index: toggle.index,
            state: state,
            // The marker is `[ ]`, `[x]`, `[X]`, `[/]`, `[-]` or `[?]`; the byte
            // that moves is the one between the brackets.
            byteOffset: task.start + 1,
            renderWasStale: renderWasStale
        )
    }
}
