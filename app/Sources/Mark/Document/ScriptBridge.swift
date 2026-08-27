import Foundation
import WebKit

/// Everything the page can say to the app.
///
/// Kept as one closed enum with one decoder so that the seam M5 needs — a
/// checkbox click carrying its own byte span, straight from ADR-1's checkbox
/// contract — already exists and is already tested, rather than being invented
/// against a live web view later.
public enum ShellMessage: Equatable, Sendable {
    /// `shell.js` has installed `window.mark`. Nothing may be injected before
    /// this arrives.
    case ready

    /// A `.mk-task` checkbox was clicked, or a state was picked for it.
    ///
    /// `start` and `end` are the marker's byte span in the file on disk, put
    /// there by the core (`data-mk-start` / `data-mk-end`). `index` is the
    /// other half of ADR-1's `(file, task-index)` identity.
    ///
    /// Two states, not one, and both by **name** since
    /// `2026-08-27-five-task-states`: *"`shell.js` reports `state` and
    /// `renderedState` as strings instead of `checked`/`rendered` booleans,
    /// because with five states the browser can no longer compute the requested
    /// state for us during pre-click activation."* `renderedState` is what the
    /// core emitted, read from the `data-mk-state` content attribute, which a
    /// click never touches; `state` is what the page derived the user is asking
    /// for. Carrying both is what lets the write path tell "the user wants this
    /// done" apart from "the page is showing bytes the file no longer has".
    case toggle(index: Int, start: Int, end: Int, state: TaskState, renderedState: TaskState)

    /// A `.mk-task` checkbox was right-clicked: show the state picker.
    ///
    /// `2026-08-27-five-task-states` makes reaching a state other than done
    /// explicit — *"⌥-click or the context menu in the app"* — and the menu has
    /// to be an `NSMenu` in the app rather than markup in the page, because
    /// `2026-08-24-rust-side-math-and-diagrams` allows the page no JavaScript
    /// of its own and a menu drawn in the document would be exactly that.
    ///
    /// `x` and `y` are in the page's client coordinates, which is what the web
    /// view can convert; the same three positional fields ride along so the
    /// menu's chosen item goes down the ordinary ``TaskToggle`` path with
    /// nothing re-queried.
    case taskMenu(
        index: Int, start: Int, end: Int, renderedState: TaskState, x: Double, y: Double)

    /// A link was clicked. Handled in Swift so `mark` never navigates away
    /// from the shell page — ADR-2 rejects document teardown outright.
    case link(href: String)

    /// The page scrolled. `y` is `window.pageYOffset` — **not**
    /// `document.body.scrollTop`, which returns 0 in `WKWebView` (ADR-2).
    ///
    /// Pushed on a 120 ms throttle rather than queried, because ADR-4's two
    /// consumers — dehydrating a tab, and writing the session file from
    /// `applicationWillTerminate` — both need the offset at a moment when an
    /// async round trip to the page is not available.
    ///
    /// `source` is where the top of the viewport is in the *document source*,
    /// as a UTF-8 byte offset, read off the `data-mk-start` / `data-mk-end` of
    /// the block the viewport top sits in. The editor pane follows it. `nil`
    /// when the page has nothing to map — an error page, or a document with no
    /// blocks in it yet — which is a different thing from byte 0 and is kept
    /// different all the way down: a missing position moves no pane, where a
    /// zero would yank the editor to the top of the file.
    case scroll(y: Double, source: Int?)

    /// `MARK_TRACE=1` timings reported back from the page.
    case metrics(name: String, milliseconds: Double)
}

/// Why a message from the page could not be understood.
///
/// A typed error rather than a silent `return`: a malformed message means
/// `shell.js` and this file have drifted, which is a bug worth seeing in the
/// log rather than a click that quietly does nothing.
public struct ShellMessageError: Error, CustomStringConvertible, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { "unusable message from shell.js: \(reason)" }
}

/// What the app does about a message from the page.
@MainActor
public protocol ScriptBridgeDelegate: AnyObject {
    func scriptBridge(_ bridge: ScriptBridge, didReceive message: ShellMessage)
}

/// `WKScriptMessageHandler` for the single `mark` message channel.
///
/// The handler is deliberately thin: it decodes, logs, and forwards. Decoding
/// is a static function so the wire format can be tested without a `WKWebView`,
/// a window, or a run loop.
public final class ScriptBridge: NSObject, WKScriptMessageHandler {

    /// The one handler name. `window.webkit.messageHandlers.mark`.
    public static let messageName = "mark"

    public weak var delegate: (any ScriptBridgeDelegate)?

    public func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        do {
            let decoded = try ScriptBridge.decode(message.body)
            delegate?.scriptBridge(self, didReceive: decoded)
        } catch {
            // A malformed message means `shell.js` and this file have drifted.
            // Log it; do not act on a message we could not read.
            Log.shell.error("\(String(describing: error), privacy: .public)")
        }
    }

    /// Decode one `postMessage` body.
    ///
    /// `WKScriptMessage.body` is a plist-ish bridge of the JS value, so numbers
    /// arrive as `NSNumber` and there is no `Codable` path into it without a
    /// re-serialization round trip that would cost more than this.
    ///
    /// `nonisolated` because conforming to `WKScriptMessageHandler` makes this
    /// class `@MainActor`, and a pure decode of a dictionary has no business
    /// requiring the main actor — the tests call it directly.
    nonisolated public static func decode(_ body: Any) throws -> ShellMessage {
        guard let payload = body as? [String: Any] else {
            throw ShellMessageError("body is \(type(of: body)), expected an object")
        }
        guard let kind = payload["kind"] as? String else {
            throw ShellMessageError("no `kind`")
        }

        switch kind {
        case "ready":
            return .ready

        case "toggle":
            let (index, start, end, rendered) = try task(in: payload, kind: "toggle")
            guard let name = payload["state"] as? String else {
                // Absent means `shell.js` is older than this binary, which can
                // only happen if the two have drifted. Inferring it from the
                // rendered state would work for a plain click and quietly turn
                // an ⌥-click into a tick.
                throw ShellMessageError("toggle is missing the requested state")
            }
            guard let state = TaskState(rawValue: name) else {
                throw ShellMessageError("toggle carries unknown state \(name)")
            }
            return .toggle(
                index: index, start: start, end: end, state: state, renderedState: rendered)

        case "taskMenu":
            let (index, start, end, rendered) = try task(in: payload, kind: "taskMenu")
            guard let x = (payload["x"] as? NSNumber)?.doubleValue, x.isFinite,
                let y = (payload["y"] as? NSNumber)?.doubleValue, y.isFinite
            else {
                throw ShellMessageError("taskMenu is missing a finite x/y")
            }
            return .taskMenu(
                index: index, start: start, end: end, renderedState: rendered, x: x, y: y)

        case "link":
            guard let href = payload["href"] as? String, !href.isEmpty else {
                throw ShellMessageError("link has no href")
            }
            return .link(href: href)

        case "scroll":
            guard let y = (payload["y"] as? NSNumber)?.doubleValue, y.isFinite else {
                throw ShellMessageError("scroll is missing a finite y")
            }
            // Absent is the normal case for a page that cannot map itself, so
            // it is not an error; a `src` that is present and unusable is, and
            // is dropped rather than rounded into a byte offset the editor
            // would scroll to.
            var source: Int? = nil
            if payload["src"] != nil {
                guard let byte = integer(payload["src"]), byte >= 0 else {
                    throw ShellMessageError("scroll carries an unusable src")
                }
                source = byte
            }
            return .scroll(y: max(0, y), source: source)

        case "metrics":
            guard let name = payload["name"] as? String,
                let milliseconds = (payload["ms"] as? NSNumber)?.doubleValue
            else {
                throw ShellMessageError("metrics is missing name/ms")
            }
            return .metrics(name: name, milliseconds: milliseconds)

        default:
            throw ShellMessageError("unknown kind \(kind)")
        }
    }

    /// The four fields a click and a right-click on a checkbox both carry:
    /// ADR-1's `(index, span)` identity, and the state the page is showing.
    ///
    /// Shared so the two messages cannot disagree about what a valid marker
    /// reference looks like — the second one arrived a milestone later, and the
    /// checks here are the ones that stop a malformed message becoming a
    /// guessed byte.
    nonisolated private static func task(
        in payload: [String: Any], kind: String
    ) throws -> (index: Int, start: Int, end: Int, rendered: TaskState) {
        guard let index = integer(payload["index"]),
            let start = integer(payload["start"]),
            let end = integer(payload["end"])
        else {
            throw ShellMessageError("\(kind) is missing index/start/end")
        }
        guard index >= 0 else {
            // The core writes usize::MAX for a marker it could not place;
            // that is a core bug, not something to write a byte for.
            throw ShellMessageError("\(kind) carries an unplaced task index")
        }
        guard start < end else {
            throw ShellMessageError("\(kind) span \(start)..\(end) is not a range")
        }
        guard start >= 0 else {
            throw ShellMessageError("\(kind) span starts at \(start)")
        }
        guard let name = payload["renderedState"] as? String else {
            throw ShellMessageError("\(kind) is missing the rendered state")
        }
        guard let rendered = TaskState(rawValue: name) else {
            throw ShellMessageError("\(kind) carries unknown rendered state \(name)")
        }
        return (index, start, end, rendered)
    }

    /// JS has one number type, so an index can arrive as either an integer or a
    /// double-valued `NSNumber`. Reject anything non-integral rather than
    /// truncating a byte offset.
    nonisolated private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded() else { return nil }
        return number.intValue
    }
}
