import Foundation

/// Whether a document gets the whole window, or a column in the middle of it.
///
/// The default is the column — `shell.css`'s `--mk-measure`, which holds a line
/// of prose to a comfortable length however wide the window is, and which a
/// table that is a block of its own is already allowed past. This is the switch
/// for the reader who does not want the measure at all: a wide screen, a
/// document that is mostly tables and diagrams, or simply a preference. Turning
/// it on drops the cap on every block.
///
/// It is app-wide and persisted, like the theme and the whitespace marks and
/// for the same reason — two windows disagreeing about how wide a document is
/// is not a state anyone means to be in — so this is `static` state plus a
/// notification, exactly as ``TextZoom`` is. A menu item reaches only the
/// focused window through the responder chain, and every other open page has to
/// hear about it some other way.
///
/// Applying it costs one `classList` call per hydrated page and nothing else:
/// the class is on `<body>`, the rules that read it are in `shell.css`, and the
/// document's HTML does not mention width at all. Nothing is re-rendered, no
/// core call is made, and a dehydrated tab needs nothing — it reads ``isFull``
/// when it rehydrates. That is the same argument the theme makes for being a
/// `<style>` swap.
///
/// **Printing is not affected, and deliberately.** `@media print` already
/// drops the measure, because paper has margins of its own and a 43rem column
/// inside them leaves a third of the sheet empty. So a printout looks the same
/// either way, and this setting stays a thing about the window.
@MainActor
public enum DocumentWidth {

    /// Posted when ``isFull`` changes. The object is the new value.
    public static let didChangeNotification = Notification.Name(
        "dev.mark.documentWidthDidChange")

    /// Whether blocks use the whole window rather than the measure.
    ///
    /// **Off by default.** The measure is the reading decision the stylesheet
    /// makes on the reader's behalf, and a first launch that ignored it would
    /// hand someone on a 32-inch display a 2000-pixel line of prose.
    public static var isFull: Bool = false {
        didSet {
            guard isFull != oldValue else { return }
            NotificationCenter.default.post(name: didChangeNotification, object: isFull)
        }
    }

    /// The persisted form. `nil` at the default, so a session file does not
    /// pin a setting nobody chose — the same shape as
    /// ``TextZoom/persistedScale``.
    public static var persisted: Bool? {
        isFull ? true : nil
    }

    /// Adopt a persisted value at launch. Absent — a session file written
    /// before this existed, or one written with the setting off — leaves the
    /// default alone.
    public static func restore(_ full: Bool?) {
        guard let full else { return }
        isFull = full
    }
}
