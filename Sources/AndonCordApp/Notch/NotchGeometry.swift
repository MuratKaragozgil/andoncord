import AppKit

/// Where the notch is, and what to do when there isn't one.
///
/// Only some Macs have a notch, people dock laptops to external displays, and
/// the panel has to look deliberate in every case. On notched hardware the
/// pill grows out of the physical cutout; everywhere else it becomes a
/// floating bar pinned below the menu bar.
struct NotchGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    /// Width of the physical cutout. Zero when there isn't one.
    let notchWidth: CGFloat
    /// Height of the cutout, which is also the menu bar height on those Macs.
    let notchHeight: CGFloat

    /// The screen the panel should live on.
    ///
    /// Prefers the built-in display when it has a notch, because that is where
    /// the affordance makes sense; otherwise follows the screen with the
    /// mouse, so the board appears on whichever display is being used.
    static func preferredScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func current() -> NotchGeometry? {
        guard let screen = preferredScreen() else { return nil }
        return NotchGeometry(screen: screen)
    }

    init(screen: NSScreen) {
        self.screen = screen

        let inset = screen.safeAreaInsets.top
        // A non-zero top safe-area inset on macOS means a camera housing.
        // External displays report zero even when the built-in one is notched.
        self.hasNotch = inset > 0
        self.notchHeight = inset > 0 ? inset : screen.frame.height - screen.visibleFrame.height

        if inset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The two auxiliary areas are the usable menu bar strips either
            // side of the cutout; whatever is left over is the notch itself.
            self.notchWidth = max(0, screen.frame.width - left.width - right.width)
        } else {
            self.notchWidth = 0
        }
    }

    /// Width of the collapsed pill, including the shoulders either side.
    func pillWidth(shoulder: CGFloat) -> CGFloat {
        hasNotch ? notchWidth + shoulder * 2 : shoulder * 2
    }

    /// Frame for a panel of the given size, centred at the top of the screen.
    ///
    /// The panel hangs from the very top edge, overlapping the menu bar, which
    /// is what makes it read as an extension of the notch rather than a
    /// floating window that happens to be near it.
    func frame(width: CGFloat, height: CGFloat) -> NSRect {
        let frame = screen.frame
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height)
    }
}
