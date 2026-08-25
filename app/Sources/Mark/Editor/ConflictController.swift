import AppKit
import Foundation

/// What the user was asked, and what they answered.
///
/// Separated from ``ConflictController`` so the state machine can be tested
/// without a modal on screen — a prompt nobody can dismiss is how a test suite
/// hangs in CI.
public enum ConflictChoice: Sendable, Equatable {
    case keepMine
    case takeTheirs
    /// Show me what changed, then ask again.
    case showDiff
}

/// Who puts the question on screen.
///
/// `2026-08-24-editing-pane-and-autosave`: *"On external conflict we prompt and
/// never guess."* The prompt is behind this protocol because the alternative —
/// `NSAlert` inline — makes the whole conflict path untestable, and this is the
/// path where being wrong loses somebody's work.
@MainActor
public protocol ConflictPresenter: AnyObject {
    /// Ask, and call `answer` exactly once.
    func presentConflict(
        _ conflict: Conflict, for url: URL, answer: @escaping (ConflictChoice) -> Void)

    /// Show the difference between the buffer and the file. The prompt is
    /// raised again afterwards.
    func presentDiff(_ diff: ConflictDiff, for url: URL, done: @escaping () -> Void)
}

/// A line-level unified diff between the buffer and the file.
///
/// Line-level rather than block-level on purpose: the core's block diff answers
/// *"which blocks must the DOM patch"*, which is the wrong question for a human
/// deciding whose version to keep. It is also computed in Swift rather than
/// over the ABI because ADR-1's surface is full and this is presentation, not
/// document semantics.
public struct ConflictDiff: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public enum Kind: String, Sendable { case same, mine, theirs }
        public let kind: Kind
        public let text: String
    }

    public let lines: [Line]
    public let added: Int
    public let removed: Int
    /// True when the diff was too large to compute exactly and was reduced to
    /// "these ranges differ". Saying so is better than showing a plausible
    /// diff that is not the real one.
    public let truncated: Bool

    /// The most a document may differ before the exact diff is abandoned.
    ///
    /// The LCS table is `O(mine × theirs)`; at 4,000 × 4,000 lines that is 16 M
    /// cells, which is about as much as a modal dialog can justify.
    static let cellBudget = 16_000_000

    public static func between(mine: String, theirs: String) -> ConflictDiff {
        let mineLines = mine.components(separatedBy: "\n")
        let theirLines = theirs.components(separatedBy: "\n")

        guard mineLines.count * theirLines.count <= cellBudget else {
            let added = max(0, theirLines.count - mineLines.count)
            let removed = max(0, mineLines.count - theirLines.count)
            return ConflictDiff(
                lines: [
                    .init(
                        kind: .same,
                        text:
                            "The two versions are too large to diff line by line "
                            + "(\(mineLines.count) lines here, \(theirLines.count) on disk)."
                    )
                ],
                added: added,
                removed: removed,
                truncated: true
            )
        }

        // Ordinary LCS. Common prefixes and suffixes are stripped first, which
        // is what makes the usual case — one edited paragraph in a long
        // document — cheap rather than quadratic.
        var head = 0
        while head < mineLines.count, head < theirLines.count,
            mineLines[head] == theirLines[head]
        {
            head += 1
        }
        var tail = 0
        while tail < mineLines.count - head, tail < theirLines.count - head,
            mineLines[mineLines.count - 1 - tail] == theirLines[theirLines.count - 1 - tail]
        {
            tail += 1
        }
        let mineMiddle = Array(mineLines[head..<(mineLines.count - tail)])
        let theirMiddle = Array(theirLines[head..<(theirLines.count - tail)])

        var table = [[Int]](
            repeating: [Int](repeating: 0, count: theirMiddle.count + 1),
            count: mineMiddle.count + 1)
        if !mineMiddle.isEmpty && !theirMiddle.isEmpty {
            for i in stride(from: mineMiddle.count - 1, through: 0, by: -1) {
                for j in stride(from: theirMiddle.count - 1, through: 0, by: -1) {
                    table[i][j] =
                        mineMiddle[i] == theirMiddle[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var lines: [Line] = []
        for index in 0..<head { lines.append(.init(kind: .same, text: mineLines[index])) }
        var added = 0
        var removed = 0
        var i = 0
        var j = 0
        while i < mineMiddle.count && j < theirMiddle.count {
            if mineMiddle[i] == theirMiddle[j] {
                lines.append(.init(kind: .same, text: mineMiddle[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                lines.append(.init(kind: .mine, text: mineMiddle[i]))
                removed += 1
                i += 1
            } else {
                lines.append(.init(kind: .theirs, text: theirMiddle[j]))
                added += 1
                j += 1
            }
        }
        while i < mineMiddle.count {
            lines.append(.init(kind: .mine, text: mineMiddle[i]))
            removed += 1
            i += 1
        }
        while j < theirMiddle.count {
            lines.append(.init(kind: .theirs, text: theirMiddle[j]))
            added += 1
            j += 1
        }
        for index in (mineLines.count - tail)..<mineLines.count {
            lines.append(.init(kind: .same, text: mineLines[index]))
        }
        return ConflictDiff(lines: lines, added: added, removed: removed, truncated: false)
    }
}

/// The conflict state machine: one prompt per conflict, and never a write.
///
/// `2026-08-24-editing-pane-and-autosave`:
///
/// > If the watcher reports content matching neither our buffer nor our
/// > last-written hash while the tab is dirty, autosave pauses and the user
/// > chooses: keep mine, take theirs, or show a diff. Autosave stays paused
/// > until the conflict is resolved.
///
/// Three properties this type is responsible for, each of which is a way to
/// lose work if it is got wrong:
///
/// * **One prompt at a time per document.** vim's `:w` produces two or three
///   FSEvents, and a second modal stacked on the first is how a user ends up
///   answering a question they cannot see.
/// * **"Show diff" is not an answer.** It shows, then asks again. A dialog that
///   dismissed on "show me" would leave autosave paused forever with nothing on
///   screen to explain why.
/// * **Nothing here writes.** ``Buffer/resolve(_:)`` either restarts the
///   ordinary debounce or replaces the buffer's text; the write, when it
///   happens, is the same 800 ms autosave as every other one.
@MainActor
public final class ConflictController {

    /// Strongly held, and that is the fix for an M9 bug rather than a
    /// preference (M10).
    ///
    /// This was `weak`, and every test passed because a test holds its own
    /// `let presenter` for the duration. The **app** does not:
    /// ``MainWindowController`` builds an ``AlertConflictPresenter`` inline and
    /// hands it over, so a weak reference dropped it before the first conflict
    /// ever arrived — and ``handle(_:for:)`` then took its no-presenter branch,
    /// leaving autosave paused with nothing on screen to say why. ADR-6's *"on
    /// external conflict we prompt and never guess"* was half true in the
    /// shipped build: never guessed, never prompted either. The compiler said
    /// so — *"weak reference will always be nil because the referenced object
    /// is deallocated here"* — for five milestones.
    ///
    /// No cycle: ``AlertConflictPresenter`` holds its window weakly, and a
    /// presenter never refers back to this controller.
    /// `conflictControllerKeepsItsPresenterAlive` pins it.
    public private(set) var presenter: (any ConflictPresenter)?

    /// Documents with a prompt currently on screen.
    private var pending: Set<URL> = []

    /// Every conflict raised, and how it was answered. For the log and for the
    /// benchmark's gate.
    public private(set) var raised = 0
    public private(set) var resolutions: [ConflictResolution] = []

    public init(presenter: (any ConflictPresenter)? = nil) {
        self.presenter = presenter
    }

    public func use(presenter: any ConflictPresenter) {
        self.presenter = presenter
    }

    /// A conflict was detected on `buffer`. Ask.
    public func handle(_ conflict: Conflict, for buffer: Buffer) {
        raised += 1
        guard !pending.contains(buffer.url) else {
            Log.core.info(
                "a conflict prompt is already open for \(buffer.url.lastPathComponent, privacy: .public); not stacking a second"
            )
            return
        }
        guard let presenter else {
            // No presenter means no way to ask, and the ADR forbids guessing.
            // The buffer stays dirty with autosave paused, which is the safe
            // half of the answer, and the log says why nothing is saving.
            Log.core.error(
                "\(buffer.url.lastPathComponent, privacy: .public) has an unresolved conflict and no way to ask about it; autosave stays paused"
            )
            return
        }
        pending.insert(buffer.url)
        ask(conflict, buffer: buffer, presenter: presenter)
    }

    private func ask(_ conflict: Conflict, buffer: Buffer, presenter: any ConflictPresenter) {
        presenter.presentConflict(conflict, for: buffer.url) { [weak self, weak buffer] choice in
            guard let self, let buffer else { return }
            switch choice {
            case .keepMine:
                self.finish(.keepMine, buffer: buffer)
            case .takeTheirs:
                self.finish(.takeTheirs, buffer: buffer)
            case .showDiff:
                let diff = ConflictDiff.between(mine: conflict.mine, theirs: conflict.theirs)
                Log.core.info(
                    "showing the conflict diff for \(buffer.url.lastPathComponent, privacy: .public): +\(diff.added) −\(diff.removed)\(diff.truncated ? " (truncated)" : "")"
                )
                presenter.presentDiff(diff, for: buffer.url) { [weak self, weak buffer] in
                    guard let self, let buffer else { return }
                    // Asked again, deliberately: seeing the difference is not
                    // choosing between the versions.
                    self.ask(conflict, buffer: buffer, presenter: presenter)
                }
            }
        }
    }

    private func finish(_ resolution: ConflictResolution, buffer: Buffer) {
        pending.remove(buffer.url)
        resolutions.append(resolution)
        buffer.resolve(resolution)
    }

    /// The tab closed, or the buffer went clean by other means.
    public func cancel(for url: URL) {
        pending.remove(url.standardizedFileURL)
    }

    public var hasPendingPrompt: Bool { !pending.isEmpty }
}

/// The real prompt: an `NSAlert` sheet on the window, and a scrolling diff.
///
/// A sheet rather than an application-modal dialog so the rest of the window
/// stays usable — the reader can look at the preview of what they typed while
/// deciding.
@MainActor
public final class AlertConflictPresenter: ConflictPresenter {

    private weak var window: NSWindow?

    public init(window: NSWindow?) {
        self.window = window
    }

    public func presentConflict(
        _ conflict: Conflict, for url: URL, answer: @escaping (ConflictChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(url.lastPathComponent) changed on disk"
        alert.informativeText = """
            You have unsaved changes to this document, and something else has \
            written to it. Autosave is paused until you choose.

            Yours: \(conflict.mine.utf8.count) bytes. On disk: \
            \(conflict.theirs.utf8.count) bytes.
            """
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Take Theirs")
        alert.addButton(withTitle: "Show Diff")

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: answer(.keepMine)
            case .alertSecondButtonReturn: answer(.takeTheirs)
            default: answer(.showDiff)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    public func presentDiff(_ diff: ConflictDiff, for url: URL, done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(url.lastPathComponent): \(diff.added) added, \(diff.removed) removed"
        alert.informativeText =
            diff.truncated
            ? "The versions are too large to diff line by line."
            : "Lines only in your buffer are marked −, lines only on disk +."
        alert.addButton(withTitle: "Back")

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        text.isEditable = false
        text.font = EditorPane.bodyFont
        let body = NSMutableAttributedString()
        for line in diff.lines {
            let prefix: String
            let colour: NSColor
            switch line.kind {
            case .same: prefix = "  "; colour = .secondaryLabelColor
            case .mine: prefix = "− "; colour = .systemRed
            case .theirs: prefix = "+ "; colour = .systemGreen
            }
            body.append(
                NSAttributedString(
                    string: prefix + line.text + "\n",
                    attributes: [.foregroundColor: colour, .font: EditorPane.bodyFont]))
        }
        text.textStorage?.setAttributedString(body)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll

        if let window {
            alert.beginSheetModal(for: window) { _ in done() }
        } else {
            _ = alert.runModal()
            done()
        }
    }
}
