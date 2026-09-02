import AppKit
import Foundation

/// Whether the editor's margin draws line numbers.
///
/// A twin of ``Invisibles``, and deliberately the same shape: app-wide static
/// state plus a notification, because a menu item reaches only the focused
/// window through the responder chain and a second editor still unnumbered
/// would read as the toggle half-working.
///
/// **Off by default.** A gutter full of numbers is the invasive version of that
/// margin — the same argument `Invisibles` makes for drawing nothing on line
/// endings — and someone who wants them is someone who went looking.
@MainActor
public enum LineNumbers {

    public static let didChangeNotification = Notification.Name("dev.mark.lineNumbersDidChange")

    public static var isShowing: Bool = false {
        didSet {
            guard isShowing != oldValue else { return }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Adopt a persisted value at launch. Absent — a session file written
    /// before this existed — leaves the default alone.
    public static func restore(_ showing: Bool?) {
        guard let showing else { return }
        isShowing = showing
    }
}
