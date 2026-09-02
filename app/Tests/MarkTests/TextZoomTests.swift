import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// Making the text bigger.
///
/// Sixteen themes and no ⌘+ was the gap. These pin the two things that make it
/// a *setting* rather than a per-window control: it is one number that every
/// open page and editor hears about, and it survives a relaunch.
@Suite("Text zoom", .serialized)
@MainActor
struct TextZoomTests {

    /// `WKWebView.pageZoom` does not round-trip bit-identically — setting 1.1
    /// and reading it back gives a value that prints as 1.1 and is not `==` to
    /// it, because WebKit stores the factor at lower precision. Comparing
    /// exactly here would be asserting on WebKit's storage rather than on
    /// whether the page is scaled.
    private func isZoom(_ actual: CGFloat, _ expected: Double) -> Bool {
        abs(Double(actual) - expected) < 0.0001
    }

    /// `TextZoom` is process-wide state, so every test here has to hand it back
    /// the way it found it — otherwise the suite's own order decides what the
    /// next assertion sees, and so does every other suite that opens a window.
    private func withDefaultZoom(_ body: () throws -> Void) rethrows {
        TextZoom.reset()
        defer { TextZoom.reset() }
        try body()
    }

    @Test("it starts at actual size")
    func startsAtOne() {
        withDefaultZoom {
            #expect(TextZoom.scale == 1.0)
            #expect(TextZoom.isDefault)
        }
    }

    @Test("in and out walk a fixed ladder and stop at the ends")
    func theLadderHasEnds() {
        withDefaultZoom {
            for _ in 0..<50 { TextZoom.zoomIn() }
            #expect(TextZoom.scale == TextZoom.steps.last)
            // The property that makes a ladder worth having over a multiplier:
            // it cannot run away, and it cannot land between steps.
            for _ in 0..<50 { TextZoom.zoomOut() }
            #expect(TextZoom.scale == TextZoom.steps.first)
        }
    }

    @Test("the same number of steps from the same place lands in the same size")
    func stepsAreReproducible() {
        withDefaultZoom {
            TextZoom.zoomIn()
            TextZoom.zoomIn()
            let twice = TextZoom.scale
            TextZoom.reset()
            TextZoom.zoomIn()
            TextZoom.zoomIn()
            #expect(TextZoom.scale == twice)
        }
    }

    @Test("actual size goes back to 1.0 from either direction")
    func resetWorksBothWays() {
        withDefaultZoom {
            TextZoom.zoomIn()
            TextZoom.reset()
            #expect(TextZoom.scale == 1.0)
            TextZoom.zoomOut()
            TextZoom.reset()
            #expect(TextZoom.scale == 1.0)
        }
    }

    @Test("a change is announced, because a menu item only reaches one window")
    func changesAreAnnounced() async {
        TextZoom.reset()
        defer { TextZoom.reset() }

        var announced: Double?
        let token = NotificationCenter.default.addObserver(
            forName: TextZoom.didChangeNotification, object: nil, queue: .main
        ) { note in
            announced = note.object as? Double
        }
        defer { NotificationCenter.default.removeObserver(token) }

        TextZoom.zoomIn()
        #expect(announced == TextZoom.scale)

        // No notification for a step that changes nothing, or every ⌘− at the
        // floor would repaint every editor in the app.
        announced = nil
        TextZoom.reset()
        announced = nil
        for _ in 0..<20 { TextZoom.zoomOut() }
        announced = nil
        TextZoom.zoomOut()
        #expect(announced == nil, "a no-op step must not repaint anything")
    }

    // ---- persistence -----------------------------------------------------

    @Test("actual size persists as nothing at all")
    func defaultWritesNothing() {
        withDefaultZoom {
            #expect(TextZoom.persistedScale == nil)
            TextZoom.zoomIn()
            #expect(TextZoom.persistedScale == TextZoom.scale)
        }
    }

    @Test("a persisted scale comes back")
    func restoreRoundTrips() {
        withDefaultZoom {
            TextZoom.zoomIn()
            TextZoom.zoomIn()
            let saved = TextZoom.persistedScale
            TextZoom.reset()
            TextZoom.restore(saved)
            #expect(TextZoom.scale == saved)
        }
    }

    @Test("a session file written before this existed leaves the default alone")
    func absentIsTheDefault() {
        withDefaultZoom {
            TextZoom.restore(nil)
            #expect(TextZoom.scale == 1.0)
        }
    }

    @Test("a hand-edited session file cannot produce a window nobody can read")
    func restoreSnapsToTheLadder() {
        withDefaultZoom {
            // The session file is a user-editable JSON file.
            TextZoom.restore(40)
            #expect(TextZoom.scale == TextZoom.steps.last)
            TextZoom.restore(-3)
            #expect(TextZoom.scale == TextZoom.steps.first)
            TextZoom.restore(0.94)
            #expect(TextZoom.scale == 0.9, "snapped to the nearest step")
        }
    }

    @Test("the scale survives a session round trip through JSON")
    func survivesTheSessionFile() throws {
        try withDefaultZoom {
            TextZoom.zoomIn()
            var state = SessionState()
            state.textZoom = TextZoom.persistedScale

            let encoded = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(SessionState.self, from: encoded)

            TextZoom.reset()
            TextZoom.restore(decoded.textZoom)
            #expect(TextZoom.scale == TextZoom.steps[TextZoom.defaultIndex + 1])
        }
    }

    // ---- the two panes ---------------------------------------------------

    @Test("the editor's type scales, headings with it")
    func theEditorScales() {
        withDefaultZoom {
            let natural = EditorPane.bodyFont.pointSize
            TextZoom.zoomIn()
            #expect(
                EditorPane.bodyFont.pointSize > natural,
                "the editor's body font ignored the zoom")
        }
    }

    @Test("a new web view opens at the current zoom rather than jumping to it")
    func aNewWebViewStartsScaled() async throws {
        TextZoom.reset()
        defer { TextZoom.reset() }
        TextZoom.zoomIn()

        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        defer { view.tearDown() }
        let webView = try #require(view.webView)
        #expect(isZoom(webView.pageZoom, TextZoom.scale))
    }

    @Test("an open preview follows a change made from another window")
    func anOpenPreviewFollows() async throws {
        TextZoom.reset()
        defer { TextZoom.reset() }

        let view = DocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        defer { view.tearDown() }
        let webView = try #require(view.webView)
        #expect(isZoom(webView.pageZoom, 1.0))

        TextZoom.zoomIn()
        #expect(
            isZoom(webView.pageZoom, TextZoom.scale),
            "the page did not hear the app-wide change")
    }
}
