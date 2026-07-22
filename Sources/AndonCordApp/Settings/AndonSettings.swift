import Foundation
import Observation
import ServiceManagement

/// User preferences, backed by `UserDefaults`.
@Observable
@MainActor
final class AndonSettings {
    private enum Key {
        static let soundsEnabled = "soundsEnabled"
        static let volume = "soundVolume"
        static let autoExpand = "autoExpandOnCord"
        static let showUsage = "showUsage"
        static let followFocusedScreen = "followFocusedScreen"
        static let hideWhenIdle = "hideWhenIdle"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let quietWhileFocused = "quietWhileFocused"
        static let migratedAlwaysVisiblePill = "migratedAlwaysVisiblePill"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.soundsEnabled: true,
            Key.volume: 0.5,
            Key.autoExpand: true,
            Key.showUsage: true,
            Key.followFocusedScreen: true,
            // Off by default: a pill that vanishes when the board empties made
            // "is it broken or just idle?" unanswerable. The idle pill now
            // shows a red stopped lamp instead — visible proof of both states.
            Key.hideWhenIdle: false,
            Key.hasCompletedOnboarding: false,
            Key.quietWhileFocused: true,
        ])

        // One-time migration for installs that predate the new default. A
        // registered default only wins when no value was ever stored, so
        // without this, anyone whose toggle was written back while the old
        // default was `true` would never see the change.
        if !defaults.bool(forKey: Key.migratedAlwaysVisiblePill) {
            defaults.removeObject(forKey: Key.hideWhenIdle)
            defaults.set(true, forKey: Key.migratedAlwaysVisiblePill)
        }
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundsEnabled) }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    var volume: Double {
        get { defaults.double(forKey: Key.volume) }
        set { defaults.set(newValue, forKey: Key.volume) }
    }

    /// Whether a pulled cord opens the panel on its own.
    ///
    /// On by default: the point of the app is that you find out without
    /// looking, and an alert you have to go and open is a worse notification
    /// than the terminal bell it replaces.
    var autoExpandOnCord: Bool {
        get { defaults.bool(forKey: Key.autoExpand) }
        set { defaults.set(newValue, forKey: Key.autoExpand) }
    }

    var showUsage: Bool {
        get { defaults.bool(forKey: Key.showUsage) }
        set { defaults.set(newValue, forKey: Key.showUsage) }
    }

    var followFocusedScreen: Bool {
        get { defaults.bool(forKey: Key.followFocusedScreen) }
        set { defaults.set(newValue, forKey: Key.followFocusedScreen) }
    }

    /// Hide the pill entirely when nothing is running, so the notch looks
    /// stock while you are not using Claude Code.
    var hideWhenIdle: Bool {
        get { defaults.bool(forKey: Key.hideWhenIdle) }
        set { defaults.set(newValue, forKey: Key.hideWhenIdle) }
    }

    /// Respect macOS Focus and screen sharing by staying silent.
    var quietWhileFocused: Bool {
        get { defaults.bool(forKey: Key.quietWhileFocused) }
        set { defaults.set(newValue, forKey: Key.quietWhileFocused) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Unsigned development builds cannot register a login item.
                // Surfacing this as a thrown error would be noise; the toggle
                // simply reads back false.
                AndonLog.ui.error("Login item change failed: \(error.localizedDescription)")
            }
        }
    }
}
