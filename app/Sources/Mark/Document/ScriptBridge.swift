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

    /// A `.mk-task` checkbox was clicked.
    ///
    /// `start` and `end` are the marker's byte span in the file on disk, put
    /// there by the core (`data-mk-start` / `data-mk-end`). `index` is the
    /// other half of ADR-1's `(file, task-index)` identity.
    ///
    /// Two states, not one. `checked` is what the user is asking for — the
    /// `checked` **property**, which the browser has already flipped by the
    /// time the click handler runs. `rendered` is what the *core* emitted, read
    /// from the `checked` **content attribute**, which a click never touches.
    /// Carrying both is what lets the write path tell "the user wants this on"
    /// apart from "the page is showing bytes the file no longer has", instead
    /// of inferring the second from the first and hoping the activation
    /// behaviour never changes.
    case toggle(index: Int, start: Int, end: Int, checked: Bool, rendered: Bool)

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
    case scroll(y: Double)

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
            guard let index = integer(payload["index"]),
                let start = integer(payload["start"]),
                let end = integer(payload["end"])
            else {
                throw ShellMessageError("toggle is missing index/start/end")
            }
            guard index >= 0 else {
                // The core writes usize::MAX for a marker it could not place;
                // that is a core bug, not something to write a byte for.
                throw ShellMessageError("toggle carries an unplaced task index")
            }
            guard start < end else {
                throw ShellMessageError("toggle span \(start)..\(end) is not a range")
            }
            guard start >= 0 else {
                throw ShellMessageError("toggle span starts at \(start)")
            }
            guard let rendered = payload["rendered"] as? Bool else {
                // Absent means `shell.js` is older than this binary, which can
                // only happen if the two have drifted. Guessing `!checked`
                // would work today and silently stop working the day the
                // activation behaviour changes.
                throw ShellMessageError("toggle is missing the rendered state")
            }
            return .toggle(
                index: index,
                start: start,
                end: end,
                checked: (payload["checked"] as? Bool) ?? false,
                rendered: rendered
            )

        case "link":
            guard let href = payload["href"] as? String, !href.isEmpty else {
                throw ShellMessageError("link has no href")
            }
            return .link(href: href)

        case "scroll":
            guard let y = (payload["y"] as? NSNumber)?.doubleValue, y.isFinite else {
                throw ShellMessageError("scroll is missing a finite y")
            }
            return .scroll(y: max(0, y))

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
