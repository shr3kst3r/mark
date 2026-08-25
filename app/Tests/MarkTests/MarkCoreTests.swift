import CMarkCore
import Darwin
import Foundation
import Testing

@testable import MarkKit

/// ADR-1's ABI contract, from the Swift side.
@Suite("MarkCore — the C ABI wrapper")
struct MarkCoreTests {

    @Test("version round-trips through the ABI")
    func version() throws {
        let version = try MarkCore.version()
        #expect(!version.isEmpty)
        #expect(version.first?.isNumber == true)
    }

    @Test("render emits block ids and task spans")
    func render() throws {
        let html = try MarkCore.renderHTML(source: "# Title\n\n- [x] done\n")
        #expect(html.contains("data-blk="))
        #expect(html.contains("class=\"mk-task\""))
        #expect(html.contains("data-mk-start="))
    }

    @Test("prefixBlocks is honoured, and 0 means the whole document")
    func prefix() throws {
        let source = "a\n\nb\n\nc\n\nd\n"
        let two = try MarkCore.renderHTML(source: source, prefixBlocks: 2)
        let all = try MarkCore.renderHTML(source: source, prefixBlocks: 0)
        #expect(two.components(separatedBy: "mk-blk").count - 1 == 2)
        #expect(all.components(separatedBy: "mk-blk").count - 1 == 4)
    }

    @Test("tasks decode with their byte spans")
    func tasks() throws {
        let tasks = try MarkCore.tasks(source: "- [ ] one\n- [x] two\n")
        #expect(tasks.count == 2)
        #expect(tasks[0].checked == false)
        #expect(tasks[1].checked == true)
        #expect(tasks[0].end - tasks[0].start == 3)
    }

    @Test("a literal bracket in prose is not a task")
    func proseBracket() throws {
        #expect(try MarkCore.tasks(source: "A literal [ ] in prose.\n").isEmpty)
    }

    @Test("toc decodes with anchors")
    func toc() throws {
        let headings = try MarkCore.toc(source: "# Hello World\n\n## Sub\n")
        #expect(headings.map(\.anchor) == ["hello-world", "sub"])
        #expect(headings.map(\.level) == [1, 2])
    }

    @Test("tree lists one level and decodes is_dir")
    func tree() throws {
        let entries = try MarkCore.tree(directory: FileManager.default.currentDirectoryPath)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.depth >= 1 })
    }

    /// ADR-1: the core cannot unwind, so failure is a sentinel plus
    /// `mark_last_error()`. The wrapper's job is to turn that pair into a typed
    /// error rather than an unexplained `nil`.
    @Test("a failing call throws a CoreError carrying the core's message")
    func failureCarriesTheMessage() {
        #expect(throws: CoreError.self) {
            try MarkCore.toggle(path: "/definitely/not/here.md", index: 0, action: .toggle)
        }
        do {
            try MarkCore.toggle(path: "/definitely/not/here.md", index: 0, action: .toggle)
            Issue.record("expected a throw")
        } catch let error as CoreError {
            #expect(error.function == "mark_toggle")
            #expect(error.detail?.contains("/definitely/not/here.md") == true)
            #expect(error.description.contains("mark_toggle failed"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("an unknown toggle action is refused rather than guessed at")
    func unknownAction() throws {
        // Not reachable through `ToggleAction`, so it goes through the raw ABI.
        let path = "/tmp/does-not-matter.md"
        let result = path.withCString { mark_toggle($0, 0, 9) }
        #expect(result == -1)
        #expect(MarkCore.lastError()?.contains("unknown toggle action 9") == true)
    }

    @Test("CoreString of a null pointer is nil, not a crash")
    func nullCoreString() {
        #expect(CoreString(nil) == nil)
    }

    /// Plan §5: *"`MarkCore` wrapper leaks nothing: allocate/free 10k strings,
    /// assert flat RSS."*
    ///
    /// This is the test ADR-1's "every pointer the core returns is freed with
    /// `mark_free`" rule actually rests on. It goes through the raw ABI as well
    /// as the wrapper, because the rule is about the pointer, not about the
    /// Swift type that happens to hold it.
    ///
    /// **Run this serially.** RSS is a property of the whole process, so a
    /// concurrently-running suite that allocates a `WKWebView` shows up here as
    /// a leak. `just swift-test` passes `--no-parallel` for exactly this
    /// reason; running `swift test` in parallel mode makes this flaky and the
    /// flake is not about the core.
    ///
    /// It is measured as *two* batches rather than one: a leak is linear, so
    /// what it looks like is the second batch growing as much as the first. A
    /// one-batch measurement cannot tell a leak from one-time warm-up.
    @Test("allocating and freeing 10k core strings leaves RSS flat")
    func noLeaks() throws {
        // A document with no code blocks, so the core's highlight memo cache
        // (which is *supposed* to grow) cannot be mistaken for a leak.
        let source = String(repeating: "A paragraph of prose about blocks.\n\n", count: 20)

        func batch(_ count: Int) throws {
            for _ in 0..<count {
                _ = try MarkCore.renderHTML(source: source)
                _ = try MarkCore.version()
                _ = autoreleasepool { CoreString(mark_version())?.value }
            }
        }

        // Warm up: first-touch page-ins, syntect asset load, and malloc arena
        // growth are all one-time and would otherwise read as a leak.
        try batch(1_000)

        let start = residentBytes()
        try batch(10_000)
        let middle = residentBytes()
        try batch(10_000)
        let end = residentBytes()

        let first = Int(middle) - Int(start)
        let second = Int(end) - Int(middle)

        // Each iteration allocates ~1.5 KB across three strings, so a missing
        // `mark_free` costs ~15 MB per batch and both numbers would be large.
        #expect(
            second < 2 * 1024 * 1024,
            """
            RSS grew by \(second) bytes during the second batch of 30k core \
            allocations (first batch: \(first)) — a pointer is not being freed
            """
        )
        #expect(first < 8 * 1024 * 1024, "first batch grew by \(first) bytes")
    }

    /// Resident size of this process, in bytes.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
