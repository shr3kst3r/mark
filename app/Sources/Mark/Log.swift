import Foundation
import OSLog

/// Plan §4's observability, in one place.
///
/// The failure mode this exists to avoid is a GUI that feels slow with no way
/// to ask why, so the counters are a feature rather than debug scaffolding.
/// Subsystem `dev.mark`, one category per subsystem, and `OSSignposter`
/// intervals around the ADR-2 pipeline stages so Instruments shows parse →
/// render → first paint → background fill directly.
public enum Log {
    public static let subsystem = "dev.mark"

    public static let core = Logger(subsystem: subsystem, category: "core")
    public static let render = Logger(subsystem: subsystem, category: "render")
    public static let shell = Logger(subsystem: subsystem, category: "shell")
    public static let tree = Logger(subsystem: subsystem, category: "tree")
    public static let app = Logger(subsystem: subsystem, category: "app")

    /// ADR-4's tab lifecycle: open, close, reorder, and — the one that matters
    /// at 3 a.m. — every hydrate and dehydrate, with the tab's title, its
    /// restored scroll offset, and the resident count after the transition. A
    /// tab whose DOM went missing is otherwise indistinguishable from a
    /// rendering bug.
    public static let tabs = Logger(subsystem: subsystem, category: "tabs")

    /// The file watcher: what it is rooted at, every scan, every reported
    /// change, and every refusal to write. Plan §4 names this category, and it
    /// is the one that answers "did the app not notice my save, or did it
    /// notice and decide nothing changed?" — two very different bugs that look
    /// identical from the outside. Paths only, never contents.
    public static let watch = Logger(subsystem: subsystem, category: "watch")

    /// ADR-3's socket: the path and its length at bind time, every command with
    /// its name and duration, every refused peer, and every refused protocol
    /// version. Enough that someone arriving cold can tell "the CLI could not
    /// reach the app" from "the app refused what the CLI asked for" without
    /// reproducing anything. Never the *contents* of a document (plan §4) —
    /// this tool reads private notes.
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")

    /// One signposter for the render pipeline, so the intervals nest in
    /// Instruments the way ADR-2 describes the pipeline.
    public static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: subsystem, category: "render")
    )

    /// `MARK_TRACE=1` promotes per-stage timings from signposts to log lines,
    /// so a slow open can be diagnosed from Console without attaching
    /// Instruments. Read once: it is a launch-time switch.
    public static let tracing: Bool = {
        let value = ProcessInfo.processInfo.environment["MARK_TRACE"]
        return value == "1" || value == "true"
    }()

    /// Emit a stage timing. Never logs file *contents* — this tool reads
    /// private notes (plan §4).
    public static func stage(_ name: String, _ seconds: Double, detail: String = "") {
        guard tracing else { return }
        let milliseconds = seconds * 1000
        if detail.isEmpty {
            render.info("\(name, privacy: .public) \(milliseconds, privacy: .public) ms")
        } else {
            render.info(
                "\(name, privacy: .public) \(milliseconds, privacy: .public) ms \(detail, privacy: .public)"
            )
        }
    }
}

/// Wall-clock duration of `body`, in seconds, alongside its result.
@inlinable
public func timed<T>(_ body: () throws -> T) rethrows -> (value: T, seconds: Double) {
    let started = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    return (value, Double(elapsed) / 1_000_000_000)
}
