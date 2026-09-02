import AppKit
import Foundation

/// The settings that had no interface.
///
/// Most of what mark can be told is already a menu item, and stays one: the
/// theme is in **View ▸ Theme** where you can see it applied as you arrow
/// through it, and the sidebar's two "show me more" switches are beside the
/// tree they change. Those are not moved here — a Preferences window that
/// duplicates the menu bar is clutter that makes both harder to trust.
///
/// What is here is the set that could be changed *only* by editing a constant
/// or exporting an environment variable:
///
/// * **How long autosave waits.** 800 ms, from
///   `2026-08-25-flock-write-locking`'s predecessor, and a number that is
///   genuinely a matter of taste — someone on a network volume wants it longer
///   and someone who trusts their disk wants it shorter.
/// * **How many tabs keep a live web view.** `MARK_RESIDENT_TABS`, which is a
///   real control over how much memory mark uses (~52 MB each) and which
///   nobody discovers from a menu.
/// * The two editor marks, mirrored, because someone who has opened this window
///   is looking for exactly this kind of switch and should not have to be told
///   they live in View.
///
/// Stored in `UserDefaults` rather than the session file, for the reason
/// `DocumentPaneController` gives about its own tab: these are preferences —
/// the same for every project you open — and `SessionState.currentVersion`
/// does not move for a preference.
@MainActor
public enum Preferences {

    public static let autosaveDelayKey = "dev.mark.editor.autosaveDelay"
    public static let residentTabsKey = "dev.mark.tabs.residentLimit"

    /// The range autosave may be set to.
    ///
    /// Floored at 200 ms because below that every keystroke is a write, and
    /// capped at 10 s because past it "autosave" stops being a description of
    /// what happens.
    public static let autosaveRange: ClosedRange<Double> = 0.2...10.0

    /// The range the resident-view budget may be set to.
    ///
    /// At least 1, or the front document itself would be evicted. Capped at 12,
    /// which at ADR-4's measured ~52 MB per view is ~720 MB — past the point
    /// where anyone is being helped.
    public static let residentTabsRange: ClosedRange<Int> = 1...12

    /// How long the editor waits after a keystroke before writing.
    public static func autosaveDelay(_ defaults: UserDefaults = .standard) -> TimeInterval {
        // `object(forKey:)` rather than `double(forKey:)`, which cannot tell an
        // unset key from a stored 0.
        guard let stored = defaults.object(forKey: autosaveDelayKey) as? Double else {
            return Buffer.autosaveDebounce
        }
        return min(max(stored, autosaveRange.lowerBound), autosaveRange.upperBound)
    }

    public static func setAutosaveDelay(
        _ value: TimeInterval, _ defaults: UserDefaults = .standard
    ) {
        defaults.set(
            min(max(value, autosaveRange.lowerBound), autosaveRange.upperBound),
            forKey: autosaveDelayKey)
    }

    /// How many tabs may hold a web view at once, across the whole app.
    ///
    /// `MARK_RESIDENT_TABS` still wins when it is set. An environment variable
    /// is a deliberate, per-launch act — usually a measurement — and a stored
    /// preference silently overriding it would make `mark-bench` runs lie.
    public static func residentTabs(_ defaults: UserDefaults = .standard) -> Int {
        if ProcessInfo.processInfo.environment["MARK_RESIDENT_TABS"] != nil {
            return ResidencyGovernor.configuredLimit
        }
        guard let stored = defaults.object(forKey: residentTabsKey) as? Int else {
            return ResidencyGovernor.defaultLimit
        }
        return min(max(stored, residentTabsRange.lowerBound), residentTabsRange.upperBound)
    }

    public static func setResidentTabs(_ value: Int, _ defaults: UserDefaults = .standard) {
        defaults.set(
            min(max(value, residentTabsRange.lowerBound), residentTabsRange.upperBound),
            forKey: residentTabsKey)
    }

    /// Whether the environment has taken the resident-tab decision away from
    /// this window, so it can say so rather than showing a control that does
    /// nothing.
    public static var residentTabsIsOverridden: Bool {
        ProcessInfo.processInfo.environment["MARK_RESIDENT_TABS"] != nil
    }
}

/// **mark ▸ Settings…** (⌘,).
@MainActor
public final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    public private(set) static var shared: PreferencesWindowController?

    @discardableResult
    public static func show(defaults: UserDefaults = .standard) -> PreferencesWindowController {
        if let existing = shared, !existing.isTornDown {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = PreferencesWindowController(defaults: defaults)
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    public private(set) var isTornDown = false
    private let defaults: UserDefaults

    let invisiblesButton = NSButton()
    let lineNumbersButton = NSButton()
    let autosaveSlider = NSSlider()
    let autosaveLabel = NSTextField(labelWithString: "")
    let residentStepper = NSStepper()
    let residentLabel = NSTextField(labelWithString: "")
    private let residentNote = NSTextField(labelWithString: "")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("dev.mark.PreferencesWindow")

        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreferencesWindowController is created in code, not from a nib")
    }

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 280))

        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            return label
        }

        invisiblesButton.setButtonType(.switch)
        invisiblesButton.title = "Show invisibles in the editor"
        invisiblesButton.state = Invisibles.isShowing ? .on : .off
        invisiblesButton.target = self
        invisiblesButton.action = #selector(invisiblesChanged)

        lineNumbersButton.setButtonType(.switch)
        lineNumbersButton.title = "Show line numbers in the editor"
        lineNumbersButton.state = LineNumbers.isShowing ? .on : .off
        lineNumbersButton.target = self
        lineNumbersButton.action = #selector(lineNumbersChanged)

        autosaveSlider.minValue = Preferences.autosaveRange.lowerBound
        autosaveSlider.maxValue = Preferences.autosaveRange.upperBound
        autosaveSlider.doubleValue = Preferences.autosaveDelay(defaults)
        autosaveSlider.target = self
        autosaveSlider.action = #selector(autosaveChanged)
        autosaveSlider.isContinuous = true

        residentStepper.minValue = Double(Preferences.residentTabsRange.lowerBound)
        residentStepper.maxValue = Double(Preferences.residentTabsRange.upperBound)
        residentStepper.increment = 1
        residentStepper.integerValue = Preferences.residentTabs(defaults)
        residentStepper.target = self
        residentStepper.action = #selector(residentChanged)
        residentStepper.isEnabled = !Preferences.residentTabsIsOverridden

        residentNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        residentNote.textColor = .secondaryLabelColor
        residentNote.maximumNumberOfLines = 3
        residentNote.lineBreakMode = .byWordWrapping
        residentNote.preferredMaxLayoutWidth = 420

        let rows = NSStackView(views: [
            heading("Editor"),
            invisiblesButton,
            lineNumbersButton,
            labelled("Autosave after", autosaveSlider, autosaveLabel),
            heading("Memory"),
            labelled("Tabs kept in memory", residentStepper, residentLabel),
            residentNote,
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])

        window?.contentView = content
        updateLabels()
    }

    private func labelled(_ title: String, _ control: NSView, _ value: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        value.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular)
        value.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, control, value])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func updateLabels() {
        autosaveLabel.stringValue = String(format: "%.1f s", autosaveSlider.doubleValue)
        residentLabel.stringValue = "\(residentStepper.integerValue)"
        residentNote.stringValue =
            Preferences.residentTabsIsOverridden
            ? "MARK_RESIDENT_TABS is set, so it decides this. Unset it to change it here."
            : """
            Each one holds a live web view, about 52 MB. The rest are restored \
            in a few milliseconds when you switch back to them.
            """
    }

    // MARK: - Actions

    @objc private func invisiblesChanged() {
        Invisibles.isShowing = invisiblesButton.state == .on
    }

    @objc private func lineNumbersChanged() {
        LineNumbers.isShowing = lineNumbersButton.state == .on
    }

    @objc private func autosaveChanged() {
        Preferences.setAutosaveDelay(autosaveSlider.doubleValue, defaults)
        updateLabels()
    }

    @objc private func residentChanged() {
        Preferences.setResidentTabs(residentStepper.integerValue, defaults)
        // Applied at once rather than at the next launch: a memory setting that
        // does nothing until you quit is one nobody can tell is working.
        ResidencyGovernor.shared.limit = residentStepper.integerValue
        updateLabels()
    }

    // MARK: - Lifetime

    public func windowWillClose(_ notification: Notification) {
        tearDown()
    }

    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        window?.delegate = nil
        if Self.shared === self { Self.shared = nil }
    }
}
