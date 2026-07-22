import AndonKit
import AppKit

/// Entry point.
///
/// Hand-rolled rather than `@main struct App` because the board lives in a
/// borderless `NSPanel` positioned against the physical screen edge, which the
/// SwiftUI scene system does not model. An `NSApplicationDelegate` gives
/// direct control over window level, activation policy, and lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let notch = NotchController()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.start()

        notch.attach(to: state)

        let menuBar = MenuBarController(app: state, controller: notch)
        menuBar.install()
        self.menuBar = menuBar

        if let pid = state.duplicateInstancePID {
            presentDuplicateInstanceAlert(pid: pid)
            return
        }

        // Show setup on first run, and again if the hooks were removed from
        // under us — an app that silently does nothing is worse than one that
        // asks.
        if !state.settings.hasCompletedOnboarding {
            menuBar.showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.stop()
    }

    /// The board keeps running with no windows open, which is the point.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func presentDuplicateInstanceAlert(pid: pid_t) {
        let alert = NSAlert()
        alert.messageText = "AndonCord is already running"
        alert.informativeText =
            "Another copy (pid \(pid)) already owns the local socket. "
            + "Quit that one first, or use the copy already in your menu bar."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit This Copy")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

// Top-level code in main.swift runs on the main thread, but the compiler
// treats it as nonisolated, so the main-actor setup is made explicit here.
let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// Accessory: menu bar and panels only, no Dock icon and no app menu.
application.setActivationPolicy(.accessory)
application.run()
