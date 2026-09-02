import AppKit
import Foundation

/// How large the document text is drawn, app-wide.
///
/// Sixteen themes and no way to make the text bigger was an odd gap: theme is
/// the thing you set once, and size is the thing you change because of the
/// document in front of you, the screen you have plugged in, or the time of
/// day.
///
/// It is app-wide and persisted, like the theme and the whitespace marks and
/// for the same reason — two windows disagreeing about how big text is is not a
/// state anyone means to be in — so this is `static` state plus a notification,
/// exactly as ``Invisibles`` is. A menu item reaches only the focused window
/// through the responder chain, and every other open page and editor has to
/// hear about it some other way.
///
/// Both halves of the window zoom together: the preview through
/// `WKWebView.pageZoom`, the editor by scaling its font. They are two different
/// mechanisms because they are two different text engines, but one number, so
/// the panes cannot drift apart — which matters more here than usual, since
/// `2026-08-24-editing-pane-and-autosave`'s successor has them scroll to the
/// same *line*.
@MainActor
public enum TextZoom {

    /// Posted when the level changes. The object is the new ``scale``.
    public static let didChangeNotification = Notification.Name("dev.mark.textZoomDidChange")

    /// The scales the menu steps through.
    ///
    /// A fixed ladder rather than a multiplier, so the steps are reproducible
    /// and `⌘+` five times from two different starting points lands in the same
    /// place. The values are the ones browsers settled on, minus the extremes:
    /// nothing here is a presentation tool, and 500% of a notes file is not a
    /// use case anyone has.
    public static let steps: [Double] = [0.6, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    /// The index into ``steps`` that means "no scaling".
    static let defaultIndex = 3

    private static var index = defaultIndex {
        didSet {
            guard index != oldValue else { return }
            NotificationCenter.default.post(name: didChangeNotification, object: scale)
        }
    }

    /// The current scale. 1.0 is unscaled.
    public static var scale: Double { steps[index] }

    /// Whether the text is currently at its natural size — what
    /// `View ▸ Actual Size` is enabled by.
    public static var isDefault: Bool { index == defaultIndex }

    public static func zoomIn() {
        index = Swift.min(index + 1, steps.count - 1)
    }

    public static func zoomOut() {
        index = Swift.max(index - 1, 0)
    }

    public static func reset() {
        index = defaultIndex
    }

    /// The persisted form: the scale itself rather than the index, so a change
    /// to ``steps`` cannot silently move an existing reader's setting to a
    /// different size.
    public static var persistedScale: Double? {
        isDefault ? nil : scale
    }

    /// Adopt a persisted value at launch.
    ///
    /// Snapped to the nearest step rather than trusted, because the session
    /// file is user-editable and a scale of 40 would be a window nobody can
    /// read their way out of. Absent — a session file written before this
    /// existed — leaves the default alone.
    public static func restore(_ scale: Double?) {
        guard let scale else { return }
        var best = defaultIndex
        var distance = Double.greatestFiniteMagnitude
        for (candidate, step) in steps.enumerated() where abs(step - scale) < distance {
            distance = abs(step - scale)
            best = candidate
        }
        index = best
    }

    /// A font at the current scale, for the editor.
    ///
    /// The editor's font is a *size*, not a transform: scaling the view would
    /// scale the change ruler and the whitespace marks with it, and both are
    /// drawn in points against the text's own metrics.
    public static func scaled(_ font: NSFont) -> NSFont {
        let size = (font.pointSize * scale).rounded()
        return NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }
}
