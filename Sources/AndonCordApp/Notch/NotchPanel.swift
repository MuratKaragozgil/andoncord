import AndonKit
import AppKit
import SwiftUI

/// Hosting view that owns hit-testing and hover for the panel.
///
/// The window is deliberately fixed at its maximum size (see `NotchPanel`), so
/// most of it is transparent most of the time. `hitTest` returns nil outside
/// the drawn region so those clicks fall through to whatever is behind, rather
/// than the panel swallowing every click in the top-centre of the screen.
///
/// It also owns hover, rather than leaving it to SwiftUI's `onHover`, for two
/// reasons. This app is an accessory that is almost never frontmost, and
/// SwiftUI's hover tracking is not reliably delivered to a background app.
/// And hover must be judged against the *drawn* region, not the view's bounds
/// — the window is deliberately much larger than its contents, so bounds-based
/// hover would mean "the pointer is somewhere near the top of the screen",
/// which is what made the panel expand and collapse in a loop.
///
/// An explicit `.activeAlways` tracking area answers both.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// The drawn region, in this view's (flipped) coordinate space. Updated by
    /// the controller whenever the presentation changes.
    var interactiveRect: CGRect = .zero {
        didSet {
            guard interactiveRect != oldValue else { return }
            // The pointer may already be sitting inside the newly drawn area.
            recomputeHover()
        }
    }

    /// Called on the main thread whenever the pointer enters or leaves the
    /// drawn region.
    var onHoverChange: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }

        let area = NSTrackingArea(
            rect: bounds,
            // `.activeAlways` is the load-bearing option: without it the panel
            // would only respond to hover while Andon Cord is the active app,
            // which it essentially never is.
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { recomputeHover(event) }
    override func mouseMoved(with event: NSEvent) { recomputeHover(event) }

    override func mouseExited(with event: NSEvent) { setInside(false) }

    private func recomputeHover(_ event: NSEvent? = nil) {
        guard let window else { return setInside(false) }
        let windowPoint = event?.locationInWindow
            ?? window.convertPoint(fromScreen: NSEvent.mouseLocation)
        setInside(interactiveRect.contains(convert(windowPoint, from: nil)))
    }

    private func setInside(_ inside: Bool) {
        guard inside != isInside else { return }
        isInside = inside
        Log.debugFile("hover -> \(inside) rect=\(interactiveRect)")
        onHoverChange?(inside)
    }

    /// Clicks outside the drawn region fall through to whatever is behind, so
    /// the oversized transparent window does not swallow half the menu bar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

/// The borderless window the board lives in.
///
/// A panel rather than a window so it can float above everything without
/// taking over as the active application — the whole premise is that you keep
/// working while it watches. It only accepts key status once something is
/// waiting on you, so keyboard shortcuts are available exactly when they mean
/// something and never steal a keystroke from the editor otherwise.
///
/// ## Why the frame never changes
///
/// An earlier version resized the window between the collapsed pill and the
/// expanded panel. That oscillates: the window resize moves the boundary that
/// decides whether the pointer is inside it, which flips the hover state,
/// which resizes the window again. The pointer sitting anywhere near the edge
/// puts the two into a feedback loop and the panel visibly flickers.
///
/// So the window is fixed at the largest size the board can ever need, and
/// only its *contents* animate. Hover is then a property of the drawn content,
/// which does not move underneath the pointer, and the loop cannot form.
final class NotchPanel: NSPanel {
    /// Fixed window size. Wide and tall enough for the largest panel, with
    /// margin for the drop shadow.
    static let fixedSize = NSSize(
        width: AndonTheme.Metrics.panelWidth + 48,
        height: AndonTheme.Metrics.panelMaxHeight + 32)

    /// Flipped by the controller when a decision is on screen.
    var acceptsKey = false {
        didSet {
            guard acceptsKey != oldValue else { return }
            if !acceptsKey, isKeyWindow { resignKey() }
        }
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // `.nonactivatingPanel` is what stops a click here from switching
            // the frontmost app away from the user's editor.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        // Above the menu bar, so the pill can overlap the notch area. Below
        // `.popUpMenu` so open menus still draw on top of us.
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        hidesOnDeactivate = false
        // Follow the user across spaces and sit above full-screen apps, since
        // a session can need attention while they are in a full-screen editor.
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { acceptsKey }
    /// Never; becoming main would pull focus from the frontmost app.
    override var canBecomeMain: Bool { false }
}
