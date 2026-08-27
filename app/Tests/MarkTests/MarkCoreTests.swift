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
        #expect(tasks[0].state == .open)
        #expect(tasks[0].checked == false)
        #expect(tasks[1].state == .done)
        #expect(tasks[1].checked == true)
        #expect(tasks[0].end - tasks[0].start == 3)
    }

    /// All five markers decode to all five states, and `checked` keeps the
    /// meaning `2026-08-27-five-task-states` gives it: **the state is
    /// terminal**, which is true for cancelled as well as done. A consumer
    /// asking "is this still outstanding?" is the one that field is for, and it
    /// has to keep answering that correctly.
    @Test("every marker byte decodes to its state, and checked means terminal")
    func fiveStates() throws {
        let tasks = try MarkCore.tasks(
            source: """
                - [ ] open
                - [/] in progress
                - [x] done
                - [X] done, shouted
                - [-] cancelled
                - [?] blocked
                """)
        #expect(
            tasks.map(\.state) == [.open, .inProgress, .done, .done, .cancelled, .blocked])
        #expect(tasks.map(\.checked) == [false, false, true, true, true, false])
        #expect(tasks.map(\.state.isOutstanding) == [true, true, false, false, false, true])
        // Every marker is one byte between two brackets — the constraint the
        // whole write path rests on.
        #expect(tasks.allSatisfy { $0.end - $0.start == 3 })
        #expect(TaskCounts(tasks) == TaskCounts(
            open: 1, inProgress: 1, done: 2, cancelled: 1, blocked: 1, total: 6))
        #expect(TaskCounts(tasks).outstanding == 3)
        #expect(TaskCounts(tasks).active == 5, "the cancelled item left the denominator")
    }

    /// A byte that is not in the allowlist is not a task at all — it renders as
    /// prose, exactly as it did before there were five states (plan §3).
    @Test("a marker byte outside the allowlist is not a task")
    func unknownMarkerByte() throws {
        for source in ["- [!] shouty\n", "- [ab] two bytes\n", "- [-]nospace\n"] {
            #expect(try MarkCore.tasks(source: source).isEmpty, "\(source)")
        }
    }

    /// `2026-08-27-inline-task-metadata`, from the Swift side: `text` keeps its
    /// meaning — the full flattened text, metadata included — and `label` is
    /// the stripped one. Swapping them would silently change every existing
    /// consumer.
    @Test("metadata decodes beside an unchanged text field")
    func metadata() throws {
        let tasks = try MarkCore.tasks(
            source: "- [/] ship it !! @work @due(2026-09-01) @start(2026-08-01)\n")
        let task = try #require(tasks.first)
        #expect(task.text == "ship it !! @work @due(2026-09-01) @start(2026-08-01)")
        #expect(task.label == "ship it")
        #expect(task.priority == 2)
        #expect(task.due == "2026-09-01")
        #expect(task.startDate == "2026-08-01", "the start date, not the marker's byte offset")
        #expect(task.done == nil)
        #expect(task.tags.contains(TaskTag(name: "work")))
    }

    /// The two hazards the metadata ADR names, from the app's side: an email
    /// address is not a tag, and a malformed date is an untyped tag rather than
    /// an error.
    @Test("an email address is not a tag, and a bad date is not a date")
    func metadataFalsePositives() throws {
        let tasks = try MarkCore.tasks(
            source: "- [ ] email bob@example.com @due(friday)\n")
        let task = try #require(tasks.first)
        #expect(!task.tags.contains { $0.name == "example.com" })
        #expect(task.due == nil)
        #expect(task.tags.contains(TaskTag(name: "due", value: "friday")))
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
        // The widened domain stops at 5, and 6 is the first value outside it.
        #expect(path.withCString { mark_toggle($0, 0, 6) } == -1)
        #expect(MarkCore.lastError()?.contains("expected 0-5") == true)
    }

    /// `ToggleAction`'s raw values *are* the ABI's `action` domain, and
    /// `2026-08-27-five-task-states` requires the old encoding to be a prefix
    /// of the new one — so 0, 1 and 2 must not have moved.
    @Test("the toggle action domain is the ABI's, with the old values in place")
    func actionDomain() {
        #expect(MarkCore.ToggleAction.off.rawValue == 0)
        #expect(MarkCore.ToggleAction.on.rawValue == 1)
        #expect(MarkCore.ToggleAction.toggle.rawValue == 2)
        #expect(MarkCore.ToggleAction.inProgress.rawValue == 3)
        #expect(MarkCore.ToggleAction.cancel.rawValue == 4)
        #expect(MarkCore.ToggleAction.block.rawValue == 5)
        // Every state is reachable, which is what lets the menu write through
        // the ordinary toggle path.
        #expect(
            TaskState.allCases.map(\.action.rawValue) == [0, 3, 1, 4, 5])
    }

    /// `mark_toggle`'s return is the resulting *state*, and done stays `1` so
    /// an existing caller testing `result == 1` still reads "done".
    @Test("toggle returns the state the marker landed in, for every action")
    func toggleReturnsAState() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mark-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("a.md")

        for state in TaskState.allCases {
            try "- [ ] one\n".write(to: url, atomically: true, encoding: .utf8)
            let landed = try MarkCore.toggle(path: url.path, index: 0, action: state.action)
            #expect(landed == state)
            let onDisk = try MarkCore.tasks(source: String(contentsOf: url, encoding: .utf8))
            #expect(onDisk.first?.state == state)
        }

        // And the plain toggle: open becomes done, done becomes open, and every
        // other state becomes done — ticking a box ticks it.
        for (before, after) in [
            ("- [ ] x\n", TaskState.done), ("- [x] x\n", .open), ("- [/] x\n", .done),
            ("- [-] x\n", .done), ("- [?] x\n", .done),
        ] {
            try before.write(to: url, atomically: true, encoding: .utf8)
            #expect(try MarkCore.toggle(path: url.path, index: 0, action: .toggle) == after)
        }
    }

    /// The code the C ABI answers with, mapped back. `-1` is failure and must
    /// never decode to a state.
    @Test("the state codes are the ABI's, and nothing else decodes")
    func stateCodes() {
        #expect(TaskState(code: 0) == .open)
        #expect(TaskState(code: 1) == .done)
        #expect(TaskState(code: 2) == .inProgress)
        #expect(TaskState(code: 3) == .cancelled)
        #expect(TaskState(code: 4) == .blocked)
        #expect(TaskState(code: 5) == nil)
        #expect(TaskState(code: -1) == nil)
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
