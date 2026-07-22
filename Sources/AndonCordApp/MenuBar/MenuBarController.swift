import AndonKit
import AppKit
import SwiftUI

/// Menu bar presence.
///
/// The notch panel hides itself when nothing is running, so this is the only
/// permanent handle on the app — it has to be able to explain a broken
/// integration and get to Settings even when the board is empty.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let app: AppState
    private let controller: NotchController
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    init(app: AppState, controller: NotchController) {
        self.app = app
        self.controller = controller
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.makeIcon()
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Andon Cord"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Two bars of unequal height — a signal tower reduced to a menu bar glyph.
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let bar = { (x: CGFloat, height: CGFloat) in
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: (rect.height - height) / 2,
                                        width: 3, height: height),
                    xRadius: 1.5, yRadius: 1.5
                ).fill()
            }
            NSColor.black.setFill()
            bar(3.5, 11)
            bar(8.5, 7)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // We enable items explicitly; the informational rows at the top are
        // meant to stay dimmed.
        menu.autoenablesItems = false

        let board = app.board
        let waiting = board.sessionsNeedingHuman.count
        let summary: String
        if waiting > 0 {
            summary = "\(waiting) waiting on you"
        } else if board.activeSessionCount > 0 {
            summary = "\(board.activeSessionCount) running"
        } else if board.sessions.isEmpty {
            summary = "No sessions"
        } else {
            summary = "\(board.sessions.count) idle"
        }
        menu.addItem(withTitle: summary, action: nil, keyEquivalent: "")
        menu.items.last?.isEnabled = false

        if let limits = board.rateLimits, let binding = limits.binding {
            let item = NSMenuItem(
                title: "\(binding.label) · \(Int(binding.window.usedPercentage))% used"
                    + (binding.window.resetCountdown.map { ", resets in \($0)" } ?? ""),
                action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let boardItem = menu.addItem(
            withTitle: "Show Board", action: #selector(showBoard), keyEquivalent: "")
        boardItem.target = self
        boardItem.isEnabled = true

        // Surface a broken integration here rather than only in the panel,
        // which the user may never open if it never appears.
        if !app.isIntegrationHealthy {
            menu.addItem(.separator())
            let title: String
            switch app.installStatus {
            case .notInstalled: title = "Set Up Claude Code…"
            case .drifted: title = "Repair Hooks"
            case .settingsUnreadable: title = "Can't Read settings.json"
            case .installed: title = app.serverError ?? "Not Connected"
            }
            let item = menu.addItem(
                withTitle: title, action: #selector(repairIntegration), keyEquivalent: "")
            item.target = self
            if case .settingsUnreadable = app.installStatus {
                item.isEnabled = false
            } else {
                item.isEnabled = true
            }
        }

        menu.addItem(.separator())
        let settingsItem = menu.addItem(
            withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true

        menu.addItem(.separator())

        let quitItem = menu.addItem(
            withTitle: "Quit Andon Cord", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
    }

    @objc private func showBoard() {
        controller.toggleExpanded()
    }

    @objc private func repairIntegration() {
        if case .notInstalled = app.installStatus {
            showOnboarding()
        } else {
            app.installIntegration()
        }
    }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = Self.makePanelWindow(
            title: "Andon Cord Settings",
            content: SettingsView(app: app),
            size: NSSize(width: 460, height: 540))
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = Self.makePanelWindow(
            title: "Welcome to Andon Cord",
            content: OnboardingView(app: app) { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            },
            size: NSSize(width: 520, height: 560))
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makePanelWindow(
        title: String, content: some View, size: NSSize
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(AndonTheme.void)
        window.contentView = NSHostingView(rootView: content)
        window.center()
        return window
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
