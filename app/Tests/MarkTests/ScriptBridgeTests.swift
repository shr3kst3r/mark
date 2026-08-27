import Foundation
import Testing

@testable import MarkKit

/// The page → app wire format.
///
/// Decoding is tested without a `WKWebView` on purpose: this is the seam M5's
/// checkbox write-back hangs off, and it should be possible to break it in a
/// test rather than by clicking.
@Suite("ScriptBridge — the page's message channel")
struct ScriptBridgeTests {

    @Test("ready decodes")
    func ready() throws {
        #expect(try ScriptBridge.decode(["kind": "ready"]) == .ready)
    }

    @Test("a checkbox click carries its index, byte span, and both states by name")
    func toggle() throws {
        let message = try ScriptBridge.decode([
            "kind": "toggle", "index": 3, "start": 140, "end": 143,
            "state": "done", "renderedState": "open",
        ])
        #expect(
            message == .toggle(index: 3, start: 140, end: 143, state: .done, renderedState: .open))
    }

    /// The four states a plain click cannot reach are reachable through the
    /// same message — ⌥-click sends `cancelled`, and the context menu sends
    /// whichever item was picked — so every one of the five has to decode.
    @Test("every one of the five states decodes, in both positions")
    func everyState() throws {
        for state in TaskState.allCases {
            let message = try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": 2, "end": 5,
                "state": state.rawValue, "renderedState": state.rawValue,
            ])
            #expect(
                message == .toggle(index: 0, start: 2, end: 5, state: state, renderedState: state))
        }
    }

    @Test("JS numbers arriving as doubles still decode as byte offsets")
    func doubleNumbers() throws {
        let message = try ScriptBridge.decode([
            "kind": "toggle", "index": 0.0, "start": 14.0, "end": 17.0,
            "state": "open", "renderedState": "done",
        ])
        #expect(
            message == .toggle(index: 0, start: 14, end: 17, state: .open, renderedState: .done))
    }

    /// M5 carries the *rendered* state alongside the requested one, because
    /// they answer different questions: what the user wants, and what the page
    /// believed the file said. Inferring the second from the first would work
    /// for a plain click and quietly turn an ⌥-click into a tick.
    @Test("a toggle without the rendered state is refused rather than guessed")
    func missingRenderedState() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": 14, "end": 17, "state": "done",
            ])
        }
    }

    /// A state name this binary does not know means `shell.js` is newer than
    /// the app. Rounding it to done would write a byte for a state nobody
    /// asked for, which is the one thing the write path never does.
    @Test("an unknown state name is refused, in either position")
    func unknownStateName() {
        let payloads: [[String: Any]] = [
            ["kind": "toggle", "index": 0, "start": 2, "end": 5,
             "state": "deferred", "renderedState": "open"],
            ["kind": "toggle", "index": 0, "start": 2, "end": 5,
             "state": "done", "renderedState": "deferred"],
            // Not the JSON spelling: the aria one, which is a different string
            // on purpose and must not decode.
            ["kind": "toggle", "index": 0, "start": 2, "end": 5,
             "state": "in progress", "renderedState": "open"],
        ]
        for payload in payloads {
            #expect(throws: ShellMessageError.self) { try ScriptBridge.decode(payload) }
        }
    }

    /// The right-click menu's message: the same marker reference, plus where
    /// to put the menu. It carries no requested state — the user has not picked
    /// one yet, which is the whole reason a menu is being shown.
    @Test("a right-click on a checkbox decodes with its position")
    func taskMenu() throws {
        let message = try ScriptBridge.decode([
            "kind": "taskMenu", "index": 2, "start": 40, "end": 43,
            "renderedState": "in-progress", "x": 120.0, "y": 64.5,
        ])
        #expect(
            message
                == .taskMenu(
                    index: 2, start: 40, end: 43, renderedState: .inProgress, x: 120, y: 64.5))
    }

    @Test("a right-click without a position is refused")
    func taskMenuWithoutPosition() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "taskMenu", "index": 2, "start": 40, "end": 43,
                "renderedState": "open",
            ])
        }
    }

    @Test("a negative byte offset is refused")
    func negativeOffset() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": -1, "end": 17,
                "state": "done", "renderedState": "open",
            ])
        }
    }

    /// The write path is the one place to be conservative (plan §3): a
    /// non-integral offset must not be truncated into a byte to write.
    @Test("a non-integral byte offset is refused, not truncated")
    func fractionalOffset() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": 14.5, "end": 17, "state": "done",
                "renderedState": "open",
            ])
        }
    }

    @Test("an unplaced task index is refused")
    func unplacedIndex() {
        // The core writes a sentinel when it cannot place a marker. Writing a
        // byte for that would be writing a guessed byte.
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": -1, "start": 14, "end": 17, "state": "done",
                "renderedState": "open",
            ])
        }
    }

    @Test("an inverted span is refused")
    func invertedSpan() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": 17, "end": 14, "state": "done",
                "renderedState": "open",
            ])
        }
    }

    @Test("a scroll report carries the source position the editor follows")
    func scrollWithSource() throws {
        let message = try ScriptBridge.decode(["kind": "scroll", "y": 480.0, "src": 1_204])
        #expect(message == .scroll(y: 480, source: 1_204))
    }

    /// A page with nothing to map — an error page, a document with no blocks —
    /// reports where it is and says nothing about the source. That has to stay
    /// distinguishable from byte 0, which is a real position the editor would
    /// scroll to.
    @Test("a scroll report with no source position is not a report of byte 0")
    func scrollWithoutSource() throws {
        #expect(try ScriptBridge.decode(["kind": "scroll", "y": 12.0]) == .scroll(y: 12, source: nil))
        #expect(try ScriptBridge.decode(["kind": "scroll", "y": 12.0, "src": 0]) == .scroll(y: 12, source: 0))
    }

    @Test("an unusable source position is refused rather than rounded")
    func unusableSource() {
        for src in [-1, 3.5] as [Any] {
            #expect(throws: ShellMessageError.self) {
                try ScriptBridge.decode(["kind": "scroll", "y": 12.0, "src": src])
            }
        }
    }

    @Test("links decode")
    func link() throws {
        #expect(try ScriptBridge.decode(["kind": "link", "href": "./other.md"]) == .link(href: "./other.md"))
    }

    @Test("metrics decode")
    func metrics() throws {
        #expect(
            try ScriptBridge.decode(["kind": "metrics", "name": "fill", "ms": 12.5])
                == .metrics(name: "fill", milliseconds: 12.5))
    }

    @Test("malformed bodies are named errors, not silent no-ops")
    func malformed() {
        let bodies: [Any] = [
            "just a string",
            42,
            [String: Any](),
            ["kind": "nope"],
            ["kind": "link"],
            ["kind": "link", "href": ""],
            ["kind": "toggle", "index": 1],
            ["kind": "metrics", "name": "x"],
        ]
        for body in bodies {
            #expect(throws: ShellMessageError.self) { try ScriptBridge.decode(body) }
        }
    }
}
