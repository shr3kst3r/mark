import AppKit
import Foundation
import Testing

@testable import MarkKit

/// The settings that had no interface.
///
/// Most of what mark can be told is already a menu item and stays one — a
/// Settings window that duplicates the menu bar is clutter. These are the two
/// that could be changed only by editing a constant or exporting an environment
/// variable, plus the guards that keep a stored value from becoming absurd.
@Suite("Settings", .serialized)
@MainActor
struct PreferencesTests {

    private func defaults() -> UserDefaults {
        VolatileDefaults().defaults
    }

    // ---- autosave ----------------------------------------------------------

    @Test("unset means the constant the ADR names")
    func autosaveDefault() {
        #expect(Preferences.autosaveDelay(defaults()) == Buffer.autosaveDebounce)
    }

    @Test("a stored delay is used")
    func autosaveStored() {
        let store = defaults()
        Preferences.setAutosaveDelay(2.5, store)
        #expect(Preferences.autosaveDelay(store) == 2.5)
    }

    @Test("a stored zero is a value, not an unset key")
    func autosaveZeroIsAValue() {
        // `double(forKey:)` cannot tell those apart, which is why the read uses
        // `object(forKey:)`. Zero is clamped up, so this checks the clamp fired
        // rather than the default being returned.
        let store = defaults()
        Preferences.setAutosaveDelay(0, store)
        #expect(Preferences.autosaveDelay(store) == Preferences.autosaveRange.lowerBound)
    }

    @Test("an absurd delay is clamped rather than honoured")
    func autosaveClamped() {
        let store = defaults()
        Preferences.setAutosaveDelay(9999, store)
        #expect(Preferences.autosaveDelay(store) == Preferences.autosaveRange.upperBound)
        Preferences.setAutosaveDelay(-5, store)
        #expect(Preferences.autosaveDelay(store) == Preferences.autosaveRange.lowerBound)
    }

    @Test("a new buffer picks up the preference without a relaunch")
    func buffersFollowThePreference() throws {
        // `Buffer.open`'s default argument is the preference, not the constant.
        let store = UserDefaults.standard
        let original = store.object(forKey: Preferences.autosaveDelayKey)
        defer {
            if let original {
                store.set(original, forKey: Preferences.autosaveDelayKey)
            } else {
                store.removeObject(forKey: Preferences.autosaveDelayKey)
            }
        }
        Preferences.setAutosaveDelay(3.0, store)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mark-prefs-\(UUID().uuidString).md")
        try "# x\n".write(to: url, atomically: true, encoding: .utf8)
        let buffer = try Buffer.open(url: url)
        #expect(buffer.autosaveDelay == 3.0)
    }

    // ---- resident tabs -----------------------------------------------------

    @Test("unset means the limit the ADR set")
    func residentDefault() {
        // Only meaningful when the environment has not taken the decision away.
        try? #require(!Preferences.residentTabsIsOverridden)
        if !Preferences.residentTabsIsOverridden {
            #expect(Preferences.residentTabs(defaults()) == ResidencyGovernor.defaultLimit)
        }
    }

    @Test("a stored limit is used and is clamped to something survivable")
    func residentStored() {
        guard !Preferences.residentTabsIsOverridden else { return }
        let store = defaults()
        Preferences.setResidentTabs(6, store)
        #expect(Preferences.residentTabs(store) == 6)

        // Below 1 the front document itself would be evicted; the cap is where
        // ADR-4's ~52 MB each stops helping anyone.
        Preferences.setResidentTabs(0, store)
        #expect(Preferences.residentTabs(store) == Preferences.residentTabsRange.lowerBound)
        Preferences.setResidentTabs(500, store)
        #expect(Preferences.residentTabs(store) == Preferences.residentTabsRange.upperBound)
    }

    // ---- the window --------------------------------------------------------

    @Test("the window opens showing what is currently set")
    func theWindowReflectsState() {
        let store = defaults()
        Preferences.setAutosaveDelay(1.5, store)
        Invisibles.isShowing = false
        LineNumbers.isShowing = true
        DocumentWidth.isFull = true
        defer {
            Invisibles.isShowing = true
            LineNumbers.isShowing = false
            DocumentWidth.isFull = false
        }

        let controller = PreferencesWindowController(defaults: store)
        defer { controller.tearDown() }
        _ = controller.window

        #expect(controller.autosaveSlider.doubleValue == 1.5)
        #expect(controller.invisiblesButton.state == .off)
        #expect(controller.lineNumbersButton.state == .on)
        #expect(controller.fullWidthButton.state == .on)
    }

    @Test("the width switch drives the same app-wide setting the View menu does")
    func fullWidthSwitch() {
        DocumentWidth.isFull = false
        defer { DocumentWidth.isFull = false }

        let controller = PreferencesWindowController(defaults: defaults())
        defer { controller.tearDown() }
        _ = controller.window

        controller.fullWidthButton.state = .on
        _ = controller.fullWidthButton.target?.perform(
            controller.fullWidthButton.action, with: controller.fullWidthButton)
        #expect(DocumentWidth.isFull, "the switch did not reach the app-wide setting")
    }

    @Test("the two mirrored switches drive the same app-wide state the menu does")
    func mirroredSwitches() {
        Invisibles.isShowing = true
        defer { Invisibles.isShowing = true }

        let controller = PreferencesWindowController(defaults: defaults())
        defer { controller.tearDown() }
        _ = controller.window

        controller.invisiblesButton.state = .off
        _ = controller.invisiblesButton.target?.perform(
            controller.invisiblesButton.action, with: controller.invisiblesButton)
        #expect(!Invisibles.isShowing, "the switch did not reach the app-wide setting")
    }

    @Test("the resident-tab control says when the environment has taken the decision")
    func environmentWins() {
        let controller = PreferencesWindowController(defaults: defaults())
        defer { controller.tearDown() }
        _ = controller.window
        // Disabled rather than present-but-ignored: a control that does nothing
        // is worse than one that explains why it is off.
        #expect(controller.residentStepper.isEnabled == !Preferences.residentTabsIsOverridden)
    }
}
