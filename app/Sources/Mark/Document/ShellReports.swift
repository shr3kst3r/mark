import Foundation

/// The numbers `shell.js` hands back, given types.
///
/// `callAsyncJavaScript` returns `Any?` — a bridged JS value, so a
/// `[String: Any]` of `NSNumber`s. Passing that around means every consumer
/// re-does the same unwrapping, and none of it is `Sendable`, so it cannot
/// cross a concurrency boundary. These structs are the one place the bridge is
/// unwrapped, and they exist mostly so `mark-bench` and `DocumentView` measure
/// the same fields by the same names.
public struct PaintReport: Sendable, Equatable {
    /// Blocks in the DOM after the prefix landed.
    public let blocks: Int
    /// `container.innerHTML = prefix`, parse only.
    public let injectMs: Double
    /// Layout forced by reading the *first* block's geometry — the measurement
    /// research §2.5 settled on, because it lets skipped subtrees legitimately
    /// stay skipped.
    public let layoutMs: Double
    /// Layout forced across the whole injected prefix. The honest "what the
    /// reader can see" number, since the prefix is sized to ~1.5 viewports.
    public let prefixLayoutMs: Double
    /// `injectMs + prefixLayoutMs`.
    public let totalMs: Double
    /// Mean laid-out block height, fed back into ``ProgressiveRenderer``.
    public let meanBlockHeight: Double
    public let viewportHeight: Double

    public init?(_ value: Any?) {
        guard let d = value as? [String: Any] else { return nil }
        blocks = Self.int(d["blocks"])
        injectMs = Self.double(d["injectMs"])
        layoutMs = Self.double(d["layoutMs"])
        prefixLayoutMs = Self.double(d["prefixLayoutMs"])
        totalMs = Self.double(d["totalMs"])
        meanBlockHeight = Self.double(d["meanBlockHeight"])
        viewportHeight = Self.double(d["viewportHeight"])
    }

    /// Unwrap one bridged JS number. `public` because `mark-bench` reads raw
    /// values straight out of the page and needs the same unwrapping.
    public static func double(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }
    public static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? -1 }
}

/// The background fill's result.
public struct FillReport: Sendable, Equatable {
    /// Detached `template.innerHTML = tail`: WebKit's HTML parse, no layout.
    public let parseMs: Double
    /// Wall-clock from the first pump tick to the last.
    public let fillMs: Double
    /// Blocks moved into the document.
    public let appended: Int
    /// Blocks in the document afterwards.
    public let blocks: Int

    public init?(_ value: Any?) {
        guard let d = value as? [String: Any] else { return nil }
        parseMs = PaintReport.double(d["parseMs"])
        fillMs = PaintReport.double(d["fillMs"])
        appended = PaintReport.int(d["appended"])
        blocks = PaintReport.int(d["blocks"])
    }
}

/// A re-render, and whether the reader's place survived it.
public struct PatchReport: Sendable, Equatable {
    public let patchMs: Double
    /// True when the anchor block was found after the patch and the correction
    /// was a `scrollBy` of the delta; false when we had to fall back to
    /// restoring the raw scroll offset.
    public let anchored: Bool
    /// True when the anchor block was only in the tail, so the tail had to be
    /// appended synchronously before the correction.
    public let synchronousTail: Bool
    /// `window.pageYOffset` after the correction. **Not**
    /// `document.body.scrollTop`, which returns 0 in `WKWebView`.
    public let scrollTop: Double
    public let blocks: Int

    /// Blocks the edit script added, removed, or swapped. `-1` for a
    /// whole-document replacement, which touched all of them.
    public let touchedBlocks: Int

    /// Checkboxes whose `data-mk-idx` / `data-mk-start` / `data-mk-end` were
    /// re-stamped from `mark_tasks_json(new_source)`.
    ///
    /// The number that says the trap is closed: a patch that keeps a block
    /// below an edit leaves that block's task attributes pointing at the wrong
    /// bytes until this has run over them. `-1` for a whole-document
    /// replacement, where every attribute is fresh by construction.
    public let tasksStamped: Int

    /// Headings whose deduplicated `id` was re-stamped from
    /// `mark_toc_json(new_source)`.
    public let headingsStamped: Int

    public init?(_ value: Any?) {
        guard let d = value as? [String: Any] else { return nil }
        patchMs = PaintReport.double(d["patchMs"])
        anchored = (d["anchored"] as? Bool) ?? false
        synchronousTail = (d["synchronousTail"] as? Bool) ?? false
        scrollTop = PaintReport.double(d["scrollTop"])
        blocks = PaintReport.int(d["blocks"])
        touchedBlocks = PaintReport.int(d["touched"])
        tasksStamped = PaintReport.int(d["tasksStamped"])
        headingsStamped = PaintReport.int(d["headingsStamped"])
    }
}

/// What the page has done to the document since it loaded.
///
/// Exists for one gate: *toggling a checkbox from the GUI must not produce a
/// visible double-render* — write, watcher, patch is **one** visible change.
/// From outside the page that is unfalsifiable, since a patch followed by a
/// re-render looks identical to a patch. Here it is a subtraction.
public struct ShellStats: Sendable, Equatable {
    /// Whole documents injected with `setDocument`.
    public let documents: Int
    /// Whole documents replaced with `replaceDocument` — the fallback path.
    public let replacements: Int
    /// Block-level patches applied.
    public let patches: Int
    /// Blocks those patches touched, in total.
    public let patchedBlocks: Int
    /// Theme CSS installations. The number that must **not** move when the
    /// system appearance changes, and must move by exactly one per
    /// `mark theme`.
    public let themes: Int
    public let blocks: Int

    public init?(_ value: Any?) {
        guard let d = value as? [String: Any] else { return nil }
        documents = PaintReport.int(d["documents"])
        replacements = PaintReport.int(d["replacements"])
        patches = PaintReport.int(d["patches"])
        patchedBlocks = PaintReport.int(d["patchedBlocks"])
        themes = PaintReport.int(d["themes"])
        blocks = PaintReport.int(d["blocks"])
    }
}

/// What `ensureFullyRendered` did.
public struct EnsureReport: Sendable, Equatable {
    /// False when the document was already complete.
    public let forced: Bool
    public let forcedMs: Double
    public let blocks: Int

    public init?(_ value: Any?) {
        guard let d = value as? [String: Any] else { return nil }
        forced = (d["forced"] as? Bool) ?? false
        forcedMs = PaintReport.double(d["forcedMs"])
        blocks = PaintReport.int(d["blocks"])
    }
}

/// The three WebKit capabilities ADR-2's design depends on being absent or
/// present. `mark-bench` asserts on these so the assumptions stay checkable
/// against a future WebKit rather than becoming folklore.
public struct ShellProbe: Sendable, Equatable {
    /// Expected **false**: `requestIdleCallback` does not exist in `WKWebView`,
    /// which is why the fill pump uses `setTimeout`.
    public let requestIdleCallback: Bool
    /// Expected **false**: WebKit does not implement `overflow-anchor`, which
    /// is why scroll anchoring is manual.
    public let overflowAnchor: Bool
    /// Expected **true**, and deliberately unused: `content-visibility` is
    /// supported and is a measured 1.8× pessimization here (ADR-2).
    public let contentVisibility: Bool

    public init?(_ value: Any?) {
        guard let d = value as? [String: Any] else { return nil }
        requestIdleCallback = (d["requestIdleCallback"] as? Bool) ?? false
        overflowAnchor = (d["overflowAnchor"] as? Bool) ?? false
        contentVisibility = (d["contentVisibility"] as? Bool) ?? false
    }
}


/// What `mark.setTheme` did, and what the page resolved afterwards.
///
/// The counters are here because "applying a theme did not re-render the
/// document" is otherwise unfalsifiable from outside the page: ``documents``
/// not moving is the assertion, and ``background`` is what a reader actually
/// sees rather than what we hoped we set.
public struct ThemeReport: Sendable, Equatable {
    /// False when the CSS was already exactly this.
    public let applied: Bool
    public let themes: Int
    /// Whole-document injections *so far*. Compared across a theme change.
    public let documents: Int
    public let blocks: Int
    /// `--mk-background` and `--mk-foreground` as the page resolved them.
    public let background: String
    public let foreground: String
    /// Whether the system is currently in dark appearance, per the media query.
    public let dark: Bool

    public init?(_ value: Any?) {
        guard let d = value as? [String: Any] else { return nil }
        applied = (d["applied"] as? Bool) ?? false
        themes = PaintReport.int(d["themes"])
        documents = PaintReport.int(d["documents"])
        blocks = PaintReport.int(d["blocks"])
        background = (d["background"] as? String) ?? ""
        foreground = (d["foreground"] as? String) ?? ""
        dark = (d["dark"] as? Bool) ?? false
    }
}
