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
    private var usageWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    init(app: AppState, controller: NotchController) {
        self.app = app
        self.controller = controller
        super.init()
    }

    func install() {
        app.openSettingsWindow = { [weak self] in self?.showSettings() }
        app.openUsageWindow = { [weak self] in self?.showUsage() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.makeIcon()
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "AndonCord"

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

        if let quota = quotaMenuTitle() {
            let item = NSMenuItem(title: quota, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let boardItem = menu.addItem(
            withTitle: "Show Board", action: #selector(showBoard), keyEquivalent: "")
        boardItem.target = self
        boardItem.isEnabled = true

        let usageItem = menu.addItem(
            withTitle: "Token Usage…", action: #selector(showUsage), keyEquivalent: "u")
        usageItem.target = self
        usageItem.isEnabled = true

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
            withTitle: "Quit AndonCord", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
    }

    /// The one quota line worth a menu row: the window that will stop you
    /// first, how much of it is left, and whether it is going to last.
    ///
    /// Nothing is shown for a window whose reset has passed — that reading
    /// describes a window which no longer exists, and a menu that reports it
    /// as current is how a stale cache becomes a wrong answer.
    private func quotaMenuTitle() -> String? {
        guard let binding = app.bindingQuota() else {
            return app.board.status == nil ? nil : "No current quota reading"
        }
        let used = Int((binding.usedPercentage ?? 0).rounded())
        var title = "\(binding.kind.shortLabel) · \(binding.isEstimate ? "~" : "")\(used)% used"
        if let countdown = binding.resetCountdown { title += ", resets in \(countdown)" }
        if binding.forecast.verdict != .holds, binding.forecast.verdict != .unknown,
           let summary = binding.forecast.summary(windowLabel: binding.kind.longLabel) {
            title += " — \(summary)"
        } else if binding.isEstimate {
            title += " (estimated)"
        }
        return title
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

    /// The token breakdown. A real window rather than a panel section: it is
    /// a page you read and scroll, and the notch panel is neither.
    @objc func showUsage() {
        if let usageWindow {
            Self.present(usageWindow)
            return
        }
        let window = Self.makePanelWindow(
            title: "Token Usage",
            content: UsageWindowView(app: app),
            size: NSSize(width: 760, height: 700))
        window.isReleasedWhenClosed = false
        usageWindow = window
        Self.present(window)
    }

    /// Bring a window forward and keep it there.
    ///
    /// `makeKeyAndOrderFront` alone is not enough for an accessory app.
    /// Activation is cooperative on recent macOS — a request from an app that
    /// is not already frontmost can simply be declined, which is exactly what
    /// happens when a window is opened at launch rather than by a click. The
    /// window is then created and ordered in, but never displayed.
    /// `orderFrontRegardless` is the one call that does not ask permission.
    private static func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func showSettings() {
        if let settingsWindow {
            Self.present(settingsWindow)
            return
        }
        let window = Self.makePanelWindow(
            title: "AndonCord Settings",
            content: SettingsView(app: app),
            // Must match SettingsView's fixed frame exactly: the hosting view
            // does not drive window sizing, so a mismatch leaves either a
            // clipped panel or a bare margin around it.
            size: NSSize(width: 480, height: 640))
        window.isReleasedWhenClosed = false
        settingsWindow = window
        Self.present(window)
    }

    func showOnboarding() {
        if let onboardingWindow {
            Self.present(onboardingWindow)
            return
        }
        let window = Self.makePanelWindow(
            title: "Welcome to AndonCord",
            content: OnboardingView(app: app) { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            },
            size: NSSize(width: 520, height: 560))
        window.isReleasedWhenClosed = false
        onboardingWindow = window
        window.center()
        Self.present(window)
    }

    private static func makePanelWindow(
        title: String, content: some View, size: NSSize
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title
        // The SwiftUI header owns the title-bar strip, so hide the system
        // title and let the content draw all the way to the top edge — that is
        // what removes the empty black band a plain titled window leaves.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(AndonTheme.void)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.center()
        return window
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
