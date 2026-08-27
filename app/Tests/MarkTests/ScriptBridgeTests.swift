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

    @Test("a checkbox click carries its index and byte span")
    func toggle() throws {
        let message = try ScriptBridge.decode([
            "kind": "toggle", "index": 3, "start": 140, "end": 143,
            "checked": true, "rendered": false,
        ])
        #expect(message == .toggle(index: 3, start: 140, end: 143, checked: true, rendered: false))
    }

    @Test("JS numbers arriving as doubles still decode as byte offsets")
    func doubleNumbers() throws {
        let message = try ScriptBridge.decode([
            "kind": "toggle", "index": 0.0, "start": 14.0, "end": 17.0,
            "checked": false, "rendered": true,
        ])
        #expect(message == .toggle(index: 0, start: 14, end: 17, checked: false, rendered: true))
    }

    /// M5 carries the *rendered* state alongside the requested one, because
    /// they answer different questions: what the user wants, and what the page
    /// believed the file said. Inferring the second from the first would work
    /// today and break silently the day the click activation behaviour changes.
    @Test("a toggle without the rendered state is refused rather than guessed")
    func missingRenderedState() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": 14, "end": 17, "checked": true,
            ])
        }
    }

    @Test("a negative byte offset is refused")
    func negativeOffset() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": -1, "end": 17,
                "checked": true, "rendered": false,
            ])
        }
    }

    /// The write path is the one place to be conservative (plan §3): a
    /// non-integral offset must not be truncated into a byte to write.
    @Test("a non-integral byte offset is refused, not truncated")
    func fractionalOffset() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": 14.5, "end": 17, "checked": false,
            ])
        }
    }

    @Test("an unplaced task index is refused")
    func unplacedIndex() {
        // The core writes a sentinel when it cannot place a marker. Writing a
        // byte for that would be writing a guessed byte.
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": -1, "start": 14, "end": 17, "checked": false,
            ])
        }
    }

    @Test("an inverted span is refused")
    func invertedSpan() {
        #expect(throws: ShellMessageError.self) {
            try ScriptBridge.decode([
                "kind": "toggle", "index": 0, "start": 17, "end": 14, "checked": false,
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
