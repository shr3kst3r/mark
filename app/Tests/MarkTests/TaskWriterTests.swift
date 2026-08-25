import Foundation
import Testing

@testable import MarkKit

/// The only place the GUI writes a user's file.
///
/// Plan §8 lists "checkbox write corrupts a file" as a risk and plan §3 answers
/// it: *"Re-parse immediately before writing, verify the target span still
/// holds a task marker, and write via a temp-file-plus-rename … Refusing to
/// write is always better than writing the wrong byte."* Each test below is one
/// clause of that.
@Suite("FileTaskWriter — the write path")
@MainActor
struct TaskWriterTests {

    private func fixture() throws -> (PatchFixture, URL, String) {
        let fixture = try PatchFixture()
        let source = """
            # Tasks

            Some prose with a literal [ ] bracket in it.

            - [ ] first
            - [x] second

            1. [ ] an ordered task
            """
        let url = try fixture.write(source)
        return (fixture, url, source)
    }

    private func span(of index: Int, in source: String) throws -> Range<Int> {
        let task = try MarkCore.tasks(source: source)[index]
        return task.start..<task.end
    }

    // MARK: - The happy path

    @Test("a toggle changes exactly one byte, and the file is otherwise identical")
    func exactlyOneByte() throws {
        let (fixture, url, source) = try fixture()
        _ = fixture
        let before = try Data(contentsOf: url)

        let result = try FileTaskWriter.shared.apply(
            TaskToggle(index: 0, span: try span(of: 0, in: source), rendered: false, desired: true),
            to: url
        )
        #expect(result.checked)

        let after = try Data(contentsOf: url)
        #expect(after.count == before.count, "the document changed length")
        let differing = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
        #expect(differing.count == 1)
        #expect(differing.first?.offset == result.byteOffset)
        #expect(after[result.byteOffset] == UInt8(ascii: "x"))

        // ...and back again, byte for byte.
        _ = try FileTaskWriter.shared.apply(
            TaskToggle(index: 0, span: try span(of: 0, in: source), rendered: true, desired: false),
            to: url
        )
        #expect(try Data(contentsOf: url) == before)
    }

    /// The prose-bracket regression from research §2.4, on the GUI's path: a
    /// literal `[ ]` in a paragraph is not a task, so the indices the page sends
    /// must not count it.
    @Test("a literal bracket in prose is not a task and is never written")
    func proseBracketIsUntouched() throws {
        let (fixture, url, source) = try fixture()
        _ = fixture
        #expect(try MarkCore.tasks(source: source).count == 3, "the prose bracket was counted")

        for index in 0..<3 {
            _ = try FileTaskWriter.shared.apply(
                TaskToggle(
                    index: index, span: try span(of: index, in: source),
                    rendered: try MarkCore.tasks(source: source)[index].checked, desired: true),
                to: url)
        }
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains("literal [ ] bracket"))
    }

    // MARK: - Symlinks

    /// The M1 review's finding, on the path the GUI now uses on every click:
    /// `fs::rename` over a symlink replaces the **link** with a regular file,
    /// silently detaching the user's note from wherever it really lives. The
    /// core canonicalizes first; this asserts that the app gets the benefit.
    @Test("toggling through a symlink edits the real file and leaves the link a link")
    func symlinkIsPreserved() throws {
        let fixture = try PatchFixture()
        let source = "# Real\n\n- [ ] a task\n"
        let real = try fixture.write(source, to: "real.md")
        let link = fixture.directory.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let realInode = try inode(of: real)

        let result = try FileTaskWriter.shared.apply(
            TaskToggle(index: 0, span: try span(of: 0, in: source), rendered: false, desired: true),
            to: link
        )
        #expect(result.checked)

        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path,
            "the symlink was replaced by a regular file")
        #expect(try String(contentsOf: real, encoding: .utf8) == "# Real\n\n- [x] a task\n")
        #expect(
            try inode(of: real) != realInode,
            "an atomic rename replaces the inode; if this is equal the write was not atomic")
    }

    // MARK: - Refusals

    /// If the page's span no longer matches the file, the index the page is
    /// holding is not the identity ADR-1 guarantees, and writing it could flip
    /// a neighbouring task. So it is refused, and the caller re-renders.
    @Test("a span that has moved refuses the write rather than flipping a neighbour")
    func staleSpanIsRefused() throws {
        let fixture = try PatchFixture()
        let old = "- [ ] only\n"
        let new = "intro\n\n- [ ] only\n"
        let url = try fixture.write(old)
        let staleSpan = try span(of: 0, in: old)
        try new.write(to: url, atomically: true, encoding: .utf8)
        #expect(staleSpan != (try span(of: 0, in: new)), "this fixture no longer moves the span")
        let before = try Data(contentsOf: url)

        #expect(throws: TaskWriteRefusal.self) {
            // What a click would send from a page that has not been patched.
            try FileTaskWriter.shared.apply(
                TaskToggle(index: 0, span: staleSpan, rendered: false, desired: true), to: url)
        }
        #expect(try Data(contentsOf: url) == before, "the file was written despite the refusal")
    }

    /// **The span check is not what closes the trap, and pretending otherwise
    /// would be the most dangerous kind of comfort.**
    ///
    /// In the exact case M5 exists for — a task inserted *above* one the diff
    /// kept — the stale `(index 0, span 2..5)` the page is holding collides
    /// byte for byte with the *new* task 0, because both are the first task in
    /// their document and both sit two bytes into a list item. Nothing the
    /// write path can inspect distinguishes them: the file is internally
    /// consistent, the span holds a task marker, and the index is in range.
    ///
    /// So the writer writes — the wrong task — and the only thing that prevents
    /// it is that the page never held a stale index in the first place, because
    /// the patch re-stamped it. That is asserted in `DocumentPatchTests` and in
    /// the end-to-end gate; this test exists so that nobody reads the span
    /// check above and concludes the re-stamp is belt and braces.
    @Test("the span check alone cannot catch a stale index whose span coincides")
    func spanCheckAloneIsNotEnough() throws {
        let fixture = try PatchFixture()
        let old = "- [ ] second\n\ntrailing\n"
        let new = "- [ ] first\n\n***\n\n- [ ] second\n\ntrailing\n"
        let url = try fixture.write(old)
        let staleSpan = try span(of: 0, in: old)
        try new.write(to: url, atomically: true, encoding: .utf8)
        #expect(
            staleSpan == (try span(of: 0, in: new)),
            "the collision this test is about no longer happens; the test is stale, not the code")

        let result = try FileTaskWriter.shared.apply(
            TaskToggle(index: 0, span: staleSpan, rendered: false, desired: true), to: url)
        #expect(result.index == 0)
        // The *wrong* task was written, from a stale index the write path had
        // no way to reject. Read this as the specification for the re-stamp.
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("- [x] first"))
    }

    @Test("an index past the end of the document is refused")
    func indexOutOfRange() throws {
        let (fixture, url, _) = try fixture()
        _ = fixture
        let before = try Data(contentsOf: url)
        #expect(throws: TaskWriteRefusal.self) {
            try FileTaskWriter.shared.apply(
                TaskToggle(index: 99, span: 0..<3, rendered: false, desired: true), to: url)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("a missing file is refused with a message naming it")
    func missingFile() throws {
        let fixture = try PatchFixture()
        let url = fixture.directory.appendingPathComponent("nothing-here.md")
        var refusal: TaskWriteRefusal?
        do {
            _ = try FileTaskWriter.shared.apply(
                TaskToggle(index: 0, span: 0..<3, rendered: false, desired: true), to: url)
        } catch let error as TaskWriteRefusal {
            refusal = error
        }
        let description = refusal?.description ?? ""
        #expect(description.contains("nothing-here.md"), "unhelpful refusal: \(description)")
    }

    // MARK: - Staleness that is not a refusal

    /// A span that still matches but a *state* that does not means the page is
    /// showing bytes the file no longer has. The write is still correct — the
    /// span was verified — and the user's intent is honoured, but the caller is
    /// told to re-render, because a file that already held the requested state
    /// changes no byte and therefore produces no watcher event to fix the
    /// display.
    @Test("a stale rendered state still writes the state the user asked for, and says so")
    func staleRenderedStateIsReported() throws {
        let fixture = try PatchFixture()
        let source = "- [x] already done\n"
        let url = try fixture.write(source)

        let result = try FileTaskWriter.shared.apply(
            // The page thinks it is unchecked, so the click asks for checked.
            TaskToggle(
                index: 0, span: try span(of: 0, in: source), rendered: false, desired: true),
            to: url
        )
        #expect(result.checked)
        #expect(result.renderWasStale)
        #expect(try String(contentsOf: url, encoding: .utf8) == source)
    }

    /// The click sends the state it wants, not "flip whatever is there", so a
    /// click delivered twice cannot land in the opposite state from the one the
    /// user asked for.
    @Test("a toggle is idempotent")
    func idempotent() throws {
        let fixture = try PatchFixture()
        let source = "- [ ] a task\n"
        let url = try fixture.write(source)
        let span = try span(of: 0, in: source)

        for _ in 0..<3 {
            let result = try FileTaskWriter.shared.apply(
                TaskToggle(index: 0, span: span, rendered: false, desired: true), to: url)
            #expect(result.checked)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "- [x] a task\n")
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
