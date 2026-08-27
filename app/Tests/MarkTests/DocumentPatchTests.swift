import AppKit
import Foundation
import Testing
import WebKit

@testable import MarkKit

/// A throwaway directory to put documents in.
@MainActor
final class PatchFixture {
    let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func write(_ source: String, to name: String = "doc.md") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// A ``DocumentView`` with a document painted, off screen but real.
///
/// A real `WKWebView` running the shipped `shell.js`, because the thing under
/// test *is* `shell.js`: a Swift-side model of what the patch does to the DOM
/// would agree with itself and prove nothing. Geometry is meaningless here —
/// `window.innerHeight` is 0 for a view with no window — so nothing in this
/// file asserts on scroll. That belongs to `mark-bench`, which has a window.
@MainActor
final class PatchHarness {
    let fixture: PatchFixture
    let view: DocumentView
    let url: URL

    init(_ source: String) async throws {
        fixture = try PatchFixture()
        url = try fixture.write(source)
        view = DocumentView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.open(url)
        await view.awaitReady()
        await view.ensureFullyRendered()
    }

    /// What a `<div class="mk-blk">`'s own byte span should count for in a
    /// comparison.
    ///
    /// A patch cannot fix those two attributes, and this is not an oversight —
    /// see ``DocumentPatchTests/blockByteSpansStayStaleOnKeptBlocks()``, which
    /// pins the gap rather than papering over it.
    enum BlockSpans {
        /// Compare them. Only valid for an edit that moved no offsets.
        case exact
        /// Blank them before comparing, the way `core/tests/diff_apply.rs`'s
        /// `without_positions` does.
        case ignored
    }

    /// The document as the DOM has it, serialized by WebKit.
    ///
    /// Comparisons against a fresh render go through ``freshHTML(of:blockSpans:)``,
    /// never against the core's output directly: WebKit normalizes on the way
    /// in (`checked` becomes `checked=""`), so the only honest comparison is
    /// serializer-to-serializer.
    func documentHTML(blockSpans: BlockSpans = .exact) async throws -> String {
        let script: String
        switch blockSpans {
        case .exact:
            script = "return document.getElementById('mk-doc').innerHTML;"
        case .ignored:
            // On a clone, so looking at the document does not change it.
            script = """
                var clone = document.getElementById('mk-doc').cloneNode(true);
                var blocks = clone.querySelectorAll('.mk-blk');
                for (var i = 0; i < blocks.length; i++) {
                  blocks[i].setAttribute('data-mk-start', '*');
                  blocks[i].setAttribute('data-mk-end', '*');
                }
                return clone.innerHTML;
                """
        }
        let value = try await view.call(script)
        return (value as? String) ?? ""
    }

    /// What the DOM would hold if `source` had been rendered from scratch.
    ///
    /// Injected into the *same* page, so the same serializer sees both sides.
    /// Called last in a test, since it replaces the document.
    func freshHTML(of source: String, blockSpans: BlockSpans = .exact) async throws -> String {
        let html = try MarkCore.renderHTML(source: source, prefixBlocks: 0)
        _ = try await view.call(
            "return window.mark.setDocument(html, {});", arguments: ["html": html])
        return try await documentHTML(blockSpans: blockSpans)
    }

    /// Write `source` to the file and hand it to the view the way the watcher
    /// would. The watcher itself is tested in `FileWatcherTests`; this is the
    /// patch, isolated from the timing.
    @discardableResult
    func patch(to source: String) async throws -> PatchReport? {
        try source.write(to: url, atomically: true, encoding: .utf8)
        return await view.apply(source: source)
    }

    func js(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await view.call(body, arguments: arguments)
    }

    /// Every checkbox in the DOM, as `idx:start:end:state`.
    ///
    /// `data-mk-state` rather than the `checked` attribute: the core's
    /// `checked` means "the state is terminal", so it is true for a cancelled
    /// marker the page draws unticked (`2026-08-27-five-task-states`), and a
    /// comparison built on it would both report false disagreements and hide
    /// real ones.
    func domTasks() async throws -> [String] {
        let value = try await view.call(
            """
            var out = [];
            var boxes = document.querySelectorAll('#mk-doc input.mk-task');
            for (var i = 0; i < boxes.length; i++) {
              out.push([boxes[i].getAttribute('data-mk-idx'),
                        boxes[i].getAttribute('data-mk-start'),
                        boxes[i].getAttribute('data-mk-end'),
                        boxes[i].getAttribute('data-mk-state')].join(':'));
            }
            return out;
            """)
        return (value as? [String]) ?? []
    }

    /// Every `<div class="mk-blk">`'s `data-mk-start`, in document order.
    func blockStarts() async throws -> [Int] {
        let value = try await view.call(
            """
            var out = [];
            var blocks = document.querySelectorAll('#mk-doc .mk-blk');
            for (var i = 0; i < blocks.length; i++) {
              out.push(Number(blocks[i].getAttribute('data-mk-start')));
            }
            return out;
            """)
        return (value as? [Any])?.map { ($0 as? NSNumber)?.intValue ?? -1 } ?? []
    }

    /// The same, from the core — the authority.
    func coreTasks(of source: String) throws -> [String] {
        try MarkCore.tasks(source: source).map {
            "\($0.index):\($0.start):\($0.end):\($0.state.rawValue)"
        }
    }
}

@Suite("Incremental patching — stale position attributes")
@MainActor
struct DocumentPatchTests {

    // MARK: - The trap

    /// The gate this milestone exists for.
    ///
    /// A task is inserted **above** an existing one. The lower task's block is
    /// content-identical, so ADR-2 requires its `data-blk` to be unchanged and
    /// the diff to *keep* it — the node is never re-rendered. But in the new
    /// document that task is `data-mk-idx="1"` at a byte span 20-odd bytes
    /// further down, while the kept DOM node still says `data-mk-idx="0"` at
    /// the old span.
    ///
    /// `shell.js` reads exactly those attributes when the box is clicked. So
    /// without the re-stamp, clicking the checkbox in the untouched block
    /// writes the *other* task. This is the same pair the core pins in
    /// `core/tests/diff_apply.rs::
    /// stale_position_attributes_are_the_one_thing_a_patch_cannot_fix`.
    @Test("a kept block's task attributes are re-stamped after an insert above it")
    func theTrap() async throws {
        // Two task items separated by a blank line would be one loose list, so
        // the thematic break is load-bearing: it keeps them as two blocks, and
        // therefore gives the diff something to keep.
        let old = "- [ ] second\n\ntrailing\n"
        let new = "- [ ] first\n\n***\n\n- [ ] second\n\ntrailing\n"

        let harness = try await PatchHarness(old)
        let before = try await harness.domTasks()
        #expect(before == ["0:2:5:open"], "the starting render: one task, index 0")

        // Mark the block that must survive, with a JS property rather than an
        // attribute so the tagging cannot itself change the serialized HTML.
        _ = try await harness.js(
            "document.querySelector('#mk-doc [data-blk]').__witness = 7; return true;")
        let keptID =
            try await harness.js("return document.querySelector('#mk-doc [data-blk]').dataset.blk;")
            as? String

        let report = try await harness.patch(to: new)
        #expect(report?.tasksStamped == 2, "both checkboxes are re-stamped from the new source")

        // The kept node is the same node — ADR-2's "leaves every other DOM node
        // untouched" — and it is the *last* block now.
        let witness = try await harness.js(
            "var blocks = document.querySelectorAll('#mk-doc [data-blk]');"
                + "return blocks[blocks.length - 2].__witness;")
        #expect(
            (witness as? NSNumber)?.intValue == 7,
            "the block below the edit was re-rendered instead of kept")
        #expect(keptID != nil)

        // And the attributes on that untouched node now describe the new file.
        let after = try await harness.domTasks()
        let authority = try harness.coreTasks(of: new)
        #expect(after == authority, "the DOM's task attributes disagree with mark_tasks_json")
        #expect(after.count == 2)
        #expect(after[1].hasPrefix("1:"), "the kept task is index 1 now, not 0")
        #expect(after[1] != before[0], "its byte span moved")
    }

    /// The quiet variant, and the reason a no-op edit script is still applied.
    ///
    /// Inserting a blank line changes no block's identity — the core hashes the
    /// *trimmed* slice, deliberately, so that trailing blank lines belong to
    /// the document's layout rather than to a block's identity. The diff is
    /// therefore a single `keep` and `isNoop` is true, while every byte offset
    /// below the insertion has moved by one. A patch that skipped "empty"
    /// scripts would leave the task span stale, which is the same corruption
    /// arriving by a quieter route.
    @Test("an edit that changes no block still re-stamps moved byte offsets")
    func noOpScriptStillRestamps() async throws {
        let old = "para\n\n- [ ] a task\n"
        let new = "para\n\n\n- [ ] a task\n"

        let script = try MarkCore.diff(old: old, new: new)
        #expect(script.isNoop, "this edit is expected to keep every block: \(script)")

        let harness = try await PatchHarness(old)
        let before = try await harness.domTasks()
        try await harness.patch(to: new)
        let after = try await harness.domTasks()

        #expect(after != before, "the offsets moved and the DOM did not follow")
        #expect(after == (try harness.coreTasks(of: new)))
    }

    // MARK: - Due dates, coloured in the app and nowhere else

    /// `2026-08-27-inline-task-metadata` splits this deliberately: the core
    /// emits a neutral chip carrying its own date, because a renderer that read
    /// a clock would stop being a pure function of its source, and the *app*
    /// compares that date against today in the shell script. So the class is
    /// absent from the core's HTML and present in the DOM.
    ///
    /// Asserted through a real page rather than by reading `shell.js`, because
    /// what matters is that the comparison happens on injection — including for
    /// blocks that arrive later, which is where a whole-document walk would
    /// have broken ADR-2's "nothing may assume the document is all in the DOM".
    @Test("an overdue chip is classed in the page, and never by the renderer")
    func overdueChipsAreClassedInThePage() async throws {
        // The *local* date, which is what the page compares against: a UTC
        // formatter would put this test's "today" on the wrong side of
        // midnight for anyone west of Greenwich.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let source = """
            - [ ] long overdue @due(2020-01-01)

            ***

            - [ ] due today @due(\(today))

            ***

            - [ ] miles off @due(2999-12-31)

            ***

            - [ ] no date at all @work
            """
        // The renderer's own output carries the dates and no verdict about them.
        let html = try MarkCore.renderHTML(source: source)
        #expect(html.contains("data-mk-due=\"2020-01-01\""))
        #expect(!html.contains("mk-overdue"))
        #expect(!html.contains("mk-due-today"))

        let harness = try await PatchHarness(source)
        let classes = try await harness.js(
            """
            var out = [];
            var chips = document.querySelectorAll('#mk-doc .mk-tag[data-mk-due]');
            for (var i = 0; i < chips.length; i++) out.push(chips[i].className);
            return out;
            """) as? [String] ?? []
        #expect(classes.count == 3, "three dated chips, got \(classes)")
        #expect(classes.first?.contains("mk-overdue") == true)
        #expect(classes.dropFirst().first?.contains("mk-due-today") == true)
        #expect(classes.last == "mk-tag", "a future date is neither overdue nor due today")

        // And a chip that arrives in a *patch* is painted too — a document is
        // injected in two halves and patched afterwards, so painting only the
        // first injection would leave later blocks uncoloured.
        try await harness.patch(to: source + "\n\n***\n\n- [ ] also late @due(2019-05-05)\n")
        let afterPatch = try await harness.js(
            "return document.querySelectorAll('#mk-doc .mk-tag.mk-overdue').length;")
        #expect((afterPatch as? NSNumber)?.intValue == 2, "the patched-in chip was not painted")

        // Re-running it over the whole document changes nothing: the class is
        // added, never toggled, so a second pass is idempotent. This is also
        // the hook a diagnostic reaches for when a chip looks wrong.
        let repainted = try await harness.js("return window.mark.paintDue();")
        #expect((repainted as? NSNumber)?.intValue == 4, "four dated chips after the patch")
        let stillTwo = try await harness.js(
            "return document.querySelectorAll('#mk-doc .mk-tag.mk-overdue').length;")
        #expect((stillTwo as? NSNumber)?.intValue == 2)
    }

    // MARK: - Patched equals fresh

    /// ADR-2's Consequences: *"This needs tests that assert the patched DOM
    /// equals a freshly rendered one."*
    ///
    /// The core's proptest asserts that **modulo four attributes** —
    /// `data-mk-start`, `data-mk-end`, `data-mk-idx`, and a heading's
    /// deduplicated `id` — because a node-preserving patch structurally cannot
    /// fix them. Closing that gap is M5's job, and after the re-stamp three of
    /// the four are exact here: every attribute on a task input, and every
    /// heading id.
    ///
    /// What is still normalized is narrower: `data-mk-start` / `data-mk-end` on
    /// the `<div class="mk-blk">` wrappers themselves. Nothing reads those
    /// today, and re-stamping them is not possible over the current C ABI —
    /// there is no function that reports block byte ranges, and adding one
    /// would be an eleventh function against ADR-1's ceiling. That is recorded
    /// as a finding rather than fixed here; see
    /// ``blockByteSpansStayStaleOnKeptBlocks()``.
    @Test(
        "the patched DOM equals a freshly rendered one, byte for byte",
        arguments: [
            // a checkbox toggled: the M5 round trip's own shape
            (
                "# Tasks\n\n- [ ] first\n\nnote\n\n- [ ] second\n",
                "# Tasks\n\n- [x] first\n\nnote\n\n- [ ] second\n"
            ),
            // a task inserted above an existing one: the trap
            ("- [ ] second\n\ntrailing\n", "- [ ] first\n\n***\n\n- [ ] second\n\ntrailing\n"),
            // a block deleted from the middle
            ("a\n\nb\n\n- [ ] t\n\nc\n", "a\n\n- [ ] t\n\nc\n"),
            // a block appended
            ("# H\n\n- [ ] t\n", "# H\n\n- [ ] t\n\nappended\n"),
            // a block prepended, moving every offset below it
            ("# H\n\n- [ ] t\n\ntail\n", "intro\n\n# H\n\n- [ ] t\n\ntail\n"),
            // duplicated headings, where the deduplicated id is positional
            ("## Notes\n\nbody\n", "## Notes\n\n## Notes\n\nbody\n"),
            // everything changed at once
            ("alpha\n\nbravo\n\ncharlie\n", "one\n\ntwo\n\nthree\n"),
            // emptied
            ("# H\n\n- [ ] t\n", ""),
            // and filled again from nothing
            ("", "# H\n\n- [x] t\n\n- [ ] u\n"),
        ])
    func patchedEqualsFresh(pair: (old: String, new: String)) async throws {
        let harness = try await PatchHarness(pair.old)
        try await harness.patch(to: pair.new)
        let patched = try await harness.documentHTML(blockSpans: .ignored)
        let fresh = try await harness.freshHTML(of: pair.new, blockSpans: .ignored)
        #expect(patched == fresh)
    }

    /// The complement, and the stricter half: when the edit disturbs no other
    /// block's position, "patched equals fresh" holds with **no** normalization
    /// at all — every `data-mk-*` on every element, and every heading id.
    ///
    /// "Confined to the tail" is not enough for that, which is worth knowing:
    /// appending a paragraph changes the *previous* block's `data-mk-end`,
    /// because a block's span runs to the start of the next one. A same-length
    /// replacement of the last block moves nothing. (The core makes the same
    /// point in `an_edit_that_moves_no_byte_offsets_patches_byte_for_byte`.)
    @Test("an edit that moves no byte offsets patches byte for byte, with nothing ignored")
    func anEditThatMovesNothingIsExact() async throws {
        let old = "# Title\n\nintro\n\n- [ ] alpha\n"
        let new = "# Title\n\nintro\n\n- [x] alpha\n"
        let harness = try await PatchHarness(old)
        try await harness.patch(to: new)
        let patched = try await harness.documentHTML(blockSpans: .exact)
        let fresh = try await harness.freshHTML(of: new, blockSpans: .exact)
        #expect(patched == fresh)
    }

    /// **A finding, pinned rather than fixed.**
    ///
    /// The re-stamp fixes every attribute anything reads: the three on a task
    /// input, which the click handler uses to decide which byte to write, and a
    /// heading's `id`, which `mark goto` resolves. It does **not** fix
    /// `data-mk-start` / `data-mk-end` on the `<div class="mk-blk">` wrapper of
    /// a block the diff kept, and it cannot: the C ABI exposes no function
    /// reporting block byte ranges, and `mark_diff_json` names kept blocks by
    /// id and count only. Reconstructing them would mean a full
    /// `mark_render_html` of the new source — which is the whole-document
    /// re-render the patch exists to avoid — or an eleventh ABI function,
    /// against ADR-1's *"roughly a dozen"* ceiling.
    ///
    /// This test exists so the gap is a known, asserted number rather than a
    /// surprise the first time something reads those attributes. The plan's M5
    /// section says "re-stamp task attributes"; this is the part of the same
    /// staleness that sentence does not cover.
    @Test("block byte spans on kept blocks stay stale, and nothing reads them")
    func blockByteSpansStayStaleOnKeptBlocks() async throws {
        let old = "# H\n\n- [ ] t\n\ntail\n"
        let new = "intro\n\n# H\n\n- [ ] t\n\ntail\n"
        let harness = try await PatchHarness(old)
        try await harness.patch(to: new)

        // The task attributes — the ones the click handler reads — are right.
        #expect((try await harness.domTasks()) == (try harness.coreTasks(of: new)))

        // The block wrappers below the insertion are not.
        let patchedStarts = try await harness.blockStarts()
        _ = try await harness.freshHTML(of: new)
        let freshStarts = try await harness.blockStarts()

        #expect(patchedStarts.first == freshStarts.first, "the inserted block is freshly rendered")
        #expect(
            patchedStarts != freshStarts,
            """
            block byte spans now match a fresh render. If they are being re-stamped, \
            delete this test and drop the `.ignored` normalization from \
            patchedEqualsFresh; if this fixture stopped moving any offsets, change \
            the fixture.
            """)
    }

    /// The heading half of the re-stamp. `mark goto` resolves an anchor by
    /// `id`, and a heading's id is deduplicated across the document, so
    /// inserting a second "Notes" above one the diff kept leaves the kept
    /// heading answering to an id that now belongs to its new neighbour.
    @Test("a kept heading's deduplicated id is re-stamped")
    func headingAnchorsAreRestamped() async throws {
        let harness = try await PatchHarness("## Notes\n\nbody\n")
        let report = try await harness.patch(to: "## Notes\n\n## Notes\n\nbody\n")
        #expect(report?.headingsStamped == 2)

        let ids = try await harness.js(
            "var out = []; var hs = document.querySelectorAll('#mk-doc .mk-h');"
                + "for (var i = 0; i < hs.length; i++) out.push(hs[i].id); return out;")
        #expect((ids as? [String]) == ["notes", "notes-1"])
    }

    // MARK: - Refusing rather than corrupting

    /// A block-diff bug shows up as a stale or duplicated document rather than
    /// a crash (ADR-2), so the shell refuses the moment the script stops
    /// describing the DOM — and the app re-renders wholesale rather than
    /// leaving the reader with a plausible-looking wrong document.
    @Test("a patch that does not describe the DOM is refused, and the document is re-rendered")
    func aPatchThatDoesNotFitIsRefused() async throws {
        let old = "a\n\nb\n\n- [ ] t\n\nc\n"
        let new = "a\n\nb\n\n- [x] t\n\nc\n"
        let harness = try await PatchHarness(old)

        // Corrupt the DOM behind the view's back — the stand-in for a diff bug,
        // since the real one cannot be produced on demand.
        _ = try await harness.js(
            "var doc = document.getElementById('mk-doc');"
                + "doc.removeChild(doc.firstElementChild); return true;")

        let script = try MarkCore.diff(old: old, new: new)
        let refusal = try await harness.js(
            "return window.mark.applyEditScript(script, null);",
            ["script": script.json])
        #expect(((refusal as? [String: Any])?["ok"] as? Bool) == false)
        let reason = (refusal as? [String: Any])?["reason"] as? String ?? ""
        #expect(reason.contains("the DOM holds 3 blocks"), "unhelpful refusal: \(reason)")

        // And the app's own path recovers rather than propagating the damage.
        try await harness.patch(to: new)
        let recovered = try await harness.documentHTML()
        let fresh = try await harness.freshHTML(of: new)
        #expect(recovered == fresh)
    }

    /// The re-stamp is refused too, for the same reason: if the patched
    /// document holds a different number of checkboxes than the new source
    /// does, then the patch did not produce the new document, and stamping it
    /// would only make the damage harder to see.
    @Test("a task count that does not line up refuses the patch rather than stamping over it")
    func mismatchedTaskCountIsRefused() async throws {
        let source = "- [ ] one\n\nbody\n"
        let harness = try await PatchHarness(source)
        let script = try MarkCore.diff(old: source, new: source)
        let stamps = "{\"tasks\":[],\"headings\":[]}"
        let result = try await harness.js(
            "return window.mark.applyEditScript(script, stamps);",
            ["script": script.json, "stamps": stamps])
        #expect(((result as? [String: Any])?["ok"] as? Bool) == false)
        let reason = (result as? [String: Any])?["reason"] as? String ?? ""
        #expect(reason.contains("checkboxes"), "unhelpful refusal: \(reason)")
    }

    // MARK: - Node preservation

    /// ADR-2's reason for block-level patching in the first place: *"Node-
    /// preserving patches mean already-rendered MathML and pre-rendered diagram
    /// SVGs are never re-laid-out or re-decoded."* A patch that replaced the
    /// whole document would pass every equality assertion above and lose this.
    @Test("blocks the script keeps are the same DOM nodes afterwards")
    func keptBlocksAreTheSameNodes() async throws {
        let old = "# H\n\none\n\ntwo\n\nthree\n\nfour\n"
        let new = "# H\n\none\n\nTWO\n\nthree\n\nfour\n"
        let harness = try await PatchHarness(old)

        _ = try await harness.js(
            """
            var blocks = document.querySelectorAll('#mk-doc [data-blk]');
            for (var i = 0; i < blocks.length; i++) blocks[i].__witness = i;
            return blocks.length;
            """)
        let report = try await harness.patch(to: new)
        #expect(report?.touchedBlocks == 2, "one block out, one in")

        let witnesses = try await harness.js(
            """
            var blocks = document.querySelectorAll('#mk-doc [data-blk]');
            var out = [];
            for (var i = 0; i < blocks.length; i++) {
              out.push(blocks[i].__witness === undefined ? -1 : blocks[i].__witness);
            }
            return out;
            """)
        // Index 2 is the replaced paragraph: a new node, so no witness.
        #expect((witnesses as? [Any])?.map { ($0 as? NSNumber)?.intValue ?? -2 } == [0, 1, -1, 3, 4])
    }

    /// Nothing may depend on the whole document being in the DOM (ADR-2), and
    /// the edit script names blocks the pump may not have appended yet.
    @Test("a patch arriving mid-fill is not applied to a half-populated document")
    func aPatchDuringTheFillIsRefused() async throws {
        let harness = try await PatchHarness("# H\n\nbody\n")
        let tail = (0..<400).map { "<div class=\"mk-blk\" data-blk=\"x-\($0)\"><p>\($0)</p></div>" }
            .joined()
        let script = try MarkCore.diff(old: "# H\n\nbody\n", new: "# H\n\nother\n")

        // Hand the pump a tail and attempt the patch in the *same* turn of the
        // event loop. Two separate round trips would let `setTimeout(0)` fire
        // in between and drain the whole tail, so the state under test would
        // never exist — which is exactly what the first draft of this test
        // measured.
        let result = try await harness.js(
            """
            window.mark.appendTail(tail);
            if (!window.mark.isFilling()) return { ok: true, reason: "the pump was not filling" };
            return window.mark._patchNow(script, null);
            """,
            ["tail": tail, "script": script.json])
        let payload = result as? [String: Any]
        #expect((payload?["ok"] as? Bool) == false)
        let reason = (payload?["reason"] as? String) ?? ""
        #expect(reason.contains("background fill"), "unhelpful refusal: \(reason)")
    }
}
