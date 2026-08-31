import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The editor's whitespace marks.
///
/// Three halves, and they fail differently:
///
/// * **which character gets which mark**, a pure function, and the only place a
///   code point can be filed under the wrong shape;
/// * **where the mark goes**, which needs a laid-out text container — so those
///   tests build one and draw the overlay into a bitmap, rather than asserting
///   on a view with no window that would report a zero viewport;
/// * **the switch**, which is app-wide, persisted, and reaches every open editor
///   through a notification rather than through the window that was clicked.
@Suite("The editor's whitespace marks")
@MainActor
struct InvisiblesTests {

    // MARK: - Which character gets which mark

    @Test("a space and a tab are told apart, and letters are left alone")
    func theTwoOrdinaryBlanks() {
        #expect(Invisibles.mark(forUTF16: 0x0020) == .space)
        #expect(Invisibles.mark(forUTF16: 0x0009) == .tab)
        for unit in "abcXYZ0189-_*#`".utf16 {
            #expect(Invisibles.mark(forUTF16: unit) == nil, "\(unit) is ink, not a blank")
        }
    }

    /// The grouping is by consequence rather than by code point, and this is
    /// the assertion that says so: `U+202F` is drawn like `U+00A0` because the
    /// thing worth knowing about both is that they do not break.
    @Test("the three kinds of stranger are grouped by what they do, not by block")
    func theStrangers() {
        for unit: UTF16.CodeUnit in [0x00A0, 0x2007, 0x202F] {
            #expect(Invisibles.mark(forUTF16: unit) == .noBreakSpace, "U+\(String(unit, radix: 16))")
        }
        for unit: UTF16.CodeUnit in [0x1680, 0x2000, 0x2003, 0x2009, 0x200A, 0x205F, 0x3000] {
            #expect(Invisibles.mark(forUTF16: unit) == .exoticSpace, "U+\(String(unit, radix: 16))")
        }
        for unit: UTF16.CodeUnit in [0x180E, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF] {
            #expect(Invisibles.mark(forUTF16: unit) == .zeroWidth, "U+\(String(unit, radix: 16))")
        }
        // A space and a tab are worth counting; the other three are worth
        // noticing, which is the whole of what the tint means.
        #expect(InvisibleMark.allCases.filter(\.isUnexpected).count == 3)
        #expect(!InvisibleMark.space.isUnexpected)
        #expect(!InvisibleMark.tab.isUnexpected)
    }

    /// Deliberate, and the thing that keeps this feature non-invasive: a
    /// pilcrow at the end of every line of a markdown document is noise, and
    /// markdown's own significant whitespace — the two trailing spaces — is
    /// already shown by the spaces themselves.
    @Test("line endings get no mark")
    func lineEndingsAreNotMarked() {
        #expect(Invisibles.mark(forUTF16: 0x000A) == nil)
        #expect(Invisibles.mark(forUTF16: 0x000D) == nil)
        #expect(Invisibles.marks(in: "a\nb\r\nc").isEmpty)
    }

    /// UTF-16 offsets, because that is what `NSTextLineFragment` positions
    /// characters by. An emoji is two units, so every offset after one is two
    /// higher than a `Character` count would say — and getting that wrong would
    /// put every mark on a line one cell left of where it belongs.
    @Test("offsets are UTF-16, so a mark after an emoji is not two cells off")
    func offsetsAreUTF16() {
        let marks = Invisibles.marks(in: "🙂 a\u{00A0}b\tc")
        #expect(marks.map(\.offset) == [2, 4, 6])
        #expect(marks.map(\.mark) == [.space, .noBreakSpace, .tab])
    }

    @Test("trailing spaces — markdown's hard line break — are marked")
    func trailingSpacesAreMarked() {
        let marks = Invisibles.marks(in: "a line  \nnext")
        #expect(marks.map(\.offset) == [1, 6, 7])
        #expect(marks.allSatisfy { $0.mark == .space })
    }

    // MARK: - Where the mark goes

    /// A text view with real layout, and the overlay over it.
    ///
    /// Not `EditorHarness`: what is under test is the draw, and a draw needs
    /// nothing but a laid-out text container. Building one here keeps these
    /// tests free of a `WKWebView`, a file watcher, and a window.
    private func laidOut(_ text: String) throws -> (NSTextView, InvisiblesOverlay) {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        textView.font = EditorPane.bodyFont
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.textContainer?.size = NSSize(
            width: 464, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        let overlay = InvisiblesOverlay(textView: textView)
        overlay.frame = textView.bounds
        textView.addSubview(overlay)

        let layoutManager = try #require(textView.textLayoutManager)
        let contentManager = try #require(layoutManager.textContentManager)
        layoutManager.ensureLayout(for: contentManager.documentRange)
        return (textView, overlay)
    }

    /// Draw, the way AppKit does: into a bitmap, through `cacheDisplay`, so the
    /// context the marks are filled into is a real one.
    private func draw(_ overlay: InvisiblesOverlay) throws -> Int {
        let rep = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        return overlay.lastDrawnCount
    }

    @Test("every blank on screen gets exactly one mark")
    func everyBlankIsMarkedOnce() throws {
        let source = "# One two\n\n\tindented\u{00A0}line  \nand\u{3000}wide\u{200B}zero\n"
        let (_, overlay) = try laidOut(source)
        let expected = Invisibles.marks(in: source).count
        #expect(expected == 8, "the fixture itself changed")
        #expect(try draw(overlay) == expected)
    }

    /// The switch, as the draw sees it. The count is the cheap way to assert it
    /// does something: an overlay that drew anyway would be a toggle that only
    /// looked like one.
    @Test("with the marks off, nothing is drawn")
    func theSwitchStopsTheDraw() throws {
        let (_, overlay) = try laidOut("a b\tc")
        #expect(try draw(overlay) > 0)

        let previous = Invisibles.isShowing
        defer { Invisibles.isShowing = previous }
        Invisibles.isShowing = false
        #expect(try draw(overlay) == 0)
    }

    /// A document taller than the pane. The draw must be bounded by what is on
    /// screen — this is the property every recurring draw in the app is held
    /// to, and the one a "walk the document and mark its spaces" implementation
    /// would quietly break.
    @Test("the draw is bounded by the viewport, not by the document")
    func theDrawIsBoundedByTheViewport() throws {
        let line = "one two three four five six seven eight nine ten\n"
        let source = String(repeating: line, count: 400)
        let (_, overlay) = try laidOut(source)
        let all = Invisibles.marks(in: source).count
        #expect(all > 3_000, "the fixture itself changed")

        // The overlay is the size of one pane, and `cacheDisplay` draws that
        // rectangle — the same rectangle AppKit would hand it inside a scroll
        // view.
        let drawn = try draw(overlay)
        #expect(drawn > 0, "nothing was marked at all")
        #expect(drawn < all / 4, "the draw walked the document (\(drawn) of \(all))")
    }

    // MARK: - The switch

    @Test("changing the setting tells every open editor, once")
    func theSettingPosts() async {
        let previous = Invisibles.isShowing
        defer { Invisibles.isShowing = previous }

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: Invisibles.didChangeNotification, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        Invisibles.isShowing = true
        Invisibles.isShowing = false
        #expect(posts == 1, "only the change is worth a repaint")
        Invisibles.isShowing = false
        #expect(posts == 1, "setting it to what it already is is not a change")
        Invisibles.isShowing = true
        #expect(posts == 2)
    }

    /// A session file written before the marks existed has no key for them, and
    /// what it must not do is turn the feature off — an absent key means "this
    /// build had nothing to say", not "the user said no".
    @Test("a session with no opinion leaves the default alone")
    func restoringNothingChangesNothing() {
        let previous = Invisibles.isShowing
        defer { Invisibles.isShowing = previous }

        Invisibles.isShowing = true
        Invisibles.restore(nil)
        #expect(Invisibles.isShowing)
        Invisibles.restore(false)
        #expect(!Invisibles.isShowing)
        Invisibles.restore(true)
        #expect(Invisibles.isShowing)
    }

    @Test("the setting survives a session round trip, and an old file decodes")
    func theSessionCarriesIt() throws {
        var state = SessionState(tabs: [SessionTab(path: "/tmp/a.md")])
        state.editorInvisibles = false
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SessionState.self, from: encoded)
        #expect(decoded.editorInvisibles == false)

        // The shape every session file written before this feature has.
        let old = Data(
            #"{"version":1,"tabs":[{"path":"/tmp/a.md","scrollOffset":0,"preview":false}]}"#.utf8)
        let older = try JSONDecoder().decode(SessionState.self, from: old)
        #expect(older.editorInvisibles == nil)
    }

    // MARK: - The menu item

    @Test("View ▸ Show Invisibles is ⌥⌘I, and its checkmark follows the setting")
    func theMenuItem() throws {
        let delegate = AppDelegate()
        let menu = try #require(delegate.buildMainMenu())
        var found: NSMenuItem?
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.title == "Show Invisibles" { found = item }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        let item = try #require(found, "the item is not in the menu bar")
        #expect(item.keyEquivalent == "i")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
        #expect(item.action == #selector(MainWindowController.toggleInvisibles(_:)))

        let previous = Invisibles.isShowing
        defer { Invisibles.isShowing = previous }
        let controller = MainWindowController(root: URL(fileURLWithPath: "/tmp"))

        Invisibles.isShowing = true
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .on)

        // Through the action, not through the property: the item is what a
        // person clicks.
        controller.toggleInvisibles(item)
        #expect(!Invisibles.isShowing)
        _ = controller.validateMenuItem(item)
        #expect(item.state == .off)
    }
}
