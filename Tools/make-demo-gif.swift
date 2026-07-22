import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders a faithful demo of the AndonCord notch panel, frame by frame, into an
// animated GIF. Not a screen capture (this environment has no screen-recording
// permission) — every pixel is drawn from the same palette, geometry, and
// equalizer math the real app uses, so it mirrors what the app renders.

// MARK: - Palette (mirrors AndonTheme exactly)

func C(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let void = C(0.039, 0.035, 0.031)
let surface = C(0.086, 0.078, 0.067)
let surfaceRaised = C(0.129, 0.118, 0.098)
let hairline = C(0.20, 0.184, 0.153)
let textPrimary = C(0.949, 0.929, 0.890)
let textSecondary = C(0.651, 0.620, 0.557)
let textTertiary = C(0.431, 0.404, 0.353)
let amber = C(0.910, 0.639, 0.239)
let green = C(0.341, 0.780, 0.498)
let red = C(0.898, 0.329, 0.294)
let accent = C(0.851, 0.467, 0.341)
let inactive = C(0.290, 0.267, 0.227)

func nscolor(_ c: CGColor) -> NSColor { NSColor(cgColor: c) ?? .white }

// MARK: - Canvas

let W = 760, H = 460
let scale = 2
let pxW = W * scale, pxH = H * scale

/// Top-left rect helper (CoreGraphics origin is bottom-left).
func rTL(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: CGFloat(H) - top - h, width: w, height: h)
}

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The notch shape: square top corners (flush with the screen edge), rounded
/// bottom — exactly `NotchShape` in the app.
func notchPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius))
    p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.minY),
                   control: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + radius),
                   control: CGPoint(x: r.minX, y: r.minY))
    p.closeSubpath()
    return p
}

func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ top: CGFloat,
          size: CGFloat, color: CGColor, weight: NSFont.Weight = .regular,
          mono: Bool = false, tracking: CGFloat = 0) {
    let font = mono
        ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: nscolor(color), .kern: tracking,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    str.draw(at: NSPoint(x: x, y: CGFloat(H) - top - size * 1.15))
    NSGraphicsContext.restoreGraphicsState()
}

func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> CGFloat {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : NSFont.systemFont(ofSize: size, weight: weight)
    return NSAttributedString(string: s, attributes: [.font: font]).size().width
}

// MARK: - Components

func lampColor(_ state: String) -> CGColor {
    switch state {
    case "working": return green
    case "cord": return amber
    default: return red
    }
}

/// Equalizer bars — identical math to WorkingIndicator.
func equalizer(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, t: Double, color: CGColor) {
    let barW = size * 0.22, sp = size * 0.17
    let phases = [0.0, 1.1, 2.2]
    let total = barW * 3 + sp * 2
    var x = cx - total / 2
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 4, color: color.copy(alpha: 0.5))
    for ph in phases {
        let wave = 0.5 + 0.5 * sin(t * 7 + ph)
        let h = size * (0.32 + 0.68 * wave)
        ctx.setFillColor(color)
        let rect = CGRect(x: x, y: cy - h / 2, width: barW, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2,
                           cornerHeight: min(barW / 2, h / 2), transform: nil))
        ctx.fillPath()
        x += barW + sp
    }
    ctx.restoreGState()
}

func dot(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, size: CGFloat, color: CGColor, glow: CGFloat = 0.5) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 4, color: color.copy(alpha: glow))
    ctx.setFillColor(color)
    let r = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.3, cornerHeight: size * 0.3, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

func meter(_ ctx: CGContext, x: CGFloat, cy: CGFloat, fraction: Double, color: CGColor) {
    let segs = 5, segW: CGFloat = 5, gap: CGFloat = 1.5, hgt: CGFloat = 7
    let lit = Int((Double(segs) * fraction).rounded(.up))
    var cx = x
    for i in 0..<segs {
        ctx.setFillColor(i < lit ? color : inactive.copy(alpha: 0.5)!)
        let r = CGRect(x: cx, y: cy - hgt / 2, width: segW, height: hgt)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1, cornerHeight: 1, transform: nil))
        ctx.fillPath()
        cx += segW + gap
    }
}

func pillButton(_ ctx: CGContext, _ label: String, x: CGFloat, top: CGFloat,
                tint: CGColor, prominent: Bool, highlight: Bool = false) -> CGFloat {
    let padH: CGFloat = 12, fontSize: CGFloat = 12
    let tw = textWidth(label, size: fontSize, weight: .semibold)
    let w = tw + padH * 2, h: CGFloat = 28
    let r = rTL(x, top, w, h)
    ctx.saveGState()
    let fill = prominent ? tint : tint.copy(alpha: highlight ? 0.30 : 0.16)!
    ctx.setFillColor(fill)
    ctx.addPath(roundedPath(r, 7)); ctx.fillPath()
    if !prominent {
        ctx.setStrokeColor(tint.copy(alpha: 0.35)!); ctx.setLineWidth(1)
        ctx.addPath(roundedPath(r.insetBy(dx: 0.5, dy: 0.5), 7)); ctx.strokePath()
    }
    ctx.restoreGState()
    let tcolor = prominent ? void : tint
    text(ctx, label, x + padH, top + (h - fontSize) / 2 - 1, size: fontSize, color: tcolor, weight: .semibold)
    return w
}

// MARK: - Frame

/// Eased 0→1 over [a,b].
func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
    if t <= a { return 0 }; if t >= b { return 1 }
    let x = (t - a) / (b - a)
    return x * x * (3 - 2 * x) // smoothstep
}

func drawFrame(_ ctx: CGContext, t: Double) {
    // Backdrop: a soft dark "desktop" so the panel reads as hanging from the top.
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [C(0.10, 0.10, 0.12), C(0.04, 0.04, 0.05)] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(H)),
                               end: CGPoint(x: 0, y: 0), options: [])
    }

    // ── Scene timeline (seconds) ──
    // 0.0-1.0 idle | 1.0-3.0 working | 3.0-3.4 cord pulled | 3.4-3.8 expand
    // 3.8-5.6 permission card | 5.6-6.0 approve→working
    let expand = ramp(t, 3.4, 3.8) - ramp(t, 5.6, 5.9)  // 0→1→0

    // Panel geometry, centered at top.
    let collapsedW: CGFloat = 330
    let expandedW: CGFloat = 460
    let w = collapsedW + (expandedW - collapsedW) * expand
    let pillH: CGFloat = 40
    let panelH = pillH + (250 - pillH) * expand
    let x = (CGFloat(W) - w) / 2
    let radius = 12 + 10 * expand
    let panelRect = rTL(x, 0, w, panelH)

    // Shape + border + shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22 * (0.4 + 0.6 * expand),
                  color: C(0, 0, 0, 0.55))
    ctx.setFillColor(void)
    ctx.addPath(notchPath(panelRect, radius)); ctx.fillPath()
    ctx.restoreGState()
    if expand > 0.02 {
        ctx.setStrokeColor(hairline.copy(alpha: expand)!); ctx.setLineWidth(1)
        ctx.addPath(notchPath(panelRect.insetBy(dx: 0.5, dy: 0.5), radius)); ctx.strokePath()
    }

    // ── Pill row (always drawn, at the top) ──
    let rowCy = CGFloat(H) - pillH / 2
    let padL = x + 16

    // State for the pill.
    let working = t >= 1.0 && t < 3.0 || t >= 5.85
    let cord = t >= 3.0
    let idle = t < 1.0

    // Lamp / equalizer.
    if working {
        equalizer(ctx, cx: padL + 5, cy: rowCy, size: 12, t: t, color: green)
    } else if cord {
        // amber, blinking
        let blink = 0.55 + 0.45 * (sin(t * 7) > 0 ? 1.0 : 0.0)
        dot(ctx, cx: padL + 4, cy: rowCy, size: 9, color: amber, glow: 0.9 * blink)
    } else {
        dot(ctx, cx: padL + 4, cy: rowCy, size: 8, color: red)
    }

    // Title.
    let title = idle ? "Idle" : "fix auth in middleware.ts"
    let titleColor = idle ? textTertiary : textPrimary
    text(ctx, title, padL + 18, pillH / 2 - 6, size: 12, color: titleColor, weight: .medium)

    // Trailing: cord badge / timer + meter.
    var trailX = x + w - 16
    // usage meter
    let meterW: CGFloat = 5 * 5 + 4 * 1.5
    trailX -= meterW
    meter(ctx, x: trailX, cy: rowCy, fraction: 0.42, color: green)
    trailX -= 12

    if cord {
        let label = "CORD"
        let bw = textWidth(label, size: 9, weight: .semibold) + 12
        trailX -= bw
        let br = rTL(trailX, pillH / 2 - 8, bw, 16)
        ctx.setFillColor(amber); ctx.addPath(roundedPath(br, 4)); ctx.fillPath()
        text(ctx, label, trailX + 6, pillH / 2 - 6, size: 9, color: void, weight: .semibold, tracking: 0.6)
    } else if working {
        let secs = Int(t - 1.0)
        let label = "\(secs)s"
        let tw = textWidth(label, size: 10, mono: true)
        trailX -= tw
        text(ctx, label, trailX, pillH / 2 - 5, size: 10, color: green, weight: .medium, mono: true)
    }

    // ── Expanded permission card ──
    if expand > 0.3 {
        let a = ramp(t, 3.6, 4.0)
        ctx.saveGState()
        ctx.setAlpha(a * (1 - ramp(t, 5.55, 5.85)))

        var y = pillH + 6
        // Amber left rule.
        ctx.setFillColor(amber.copy(alpha: 0.9)!)
        ctx.fill(rTL(x, y, 2, panelH - y - 8))

        // header
        dot(ctx, cx: x + 20, cy: CGFloat(H) - y - 10, size: 7, color: amber, glow: 0.9)
        text(ctx, "CORD PULLED · PERMISSION", x + 30, y + 5, size: 10, color: amber, weight: .semibold, tracking: 0.8)
        let sess = "fix auth in middleware.ts"
        text(ctx, sess, x + w - 16 - textWidth(sess, size: 10), y + 6, size: 10, color: textTertiary)
        y += 26

        // tool + subtitle
        text(ctx, "Edit", x + 16, y, size: 13, color: textPrimary, weight: .semibold)
        text(ctx, "auth/middleware.ts", x + 16 + textWidth("Edit ", size: 13, weight: .semibold), y + 1,
             size: 11, color: textSecondary, mono: true)
        y += 22

        // diff box
        let diffRect = rTL(x + 16, y, w - 32, 66)
        ctx.setFillColor(surface); ctx.addPath(roundedPath(diffRect, 6)); ctx.fillPath()
        let diffLines: [(String, String, CGColor)] = [
            ("−", "  jwt.verify(token);", red),
            ("+", "  if (!token) throw new AuthError('missing');", green),
            ("+", "  return jwt.verify(token, SECRET);", green),
        ]
        var dy = y + 8
        for (sign, code, col) in diffLines {
            ctx.setFillColor(col.copy(alpha: 0.10)!)
            ctx.fill(rTL(x + 20, dy, w - 40, 18))
            text(ctx, sign, x + 26, dy + 2, size: 10, color: col, mono: true)
            text(ctx, code, x + 40, dy + 2, size: 10, color: textPrimary.copy(alpha: 0.9)!, mono: true)
            dy += 19
        }
        y += 66 + 12

        // buttons
        let allowHi = t >= 5.2 && t < 5.6
        let dw = pillButton(ctx, "Deny", x: x + 16, top: y, tint: red, prominent: false)
        _ = pillButton(ctx, "Allow", x: x + 16 + dw + 8, top: y, tint: green, prominent: true, highlight: allowHi)
        text(ctx, "⌘Y / ⌘N", x + w - 16 - textWidth("⌘Y / ⌘N", size: 9, mono: true), y + 8,
             size: 9, color: textTertiary, mono: true)

        ctx.restoreGState()
    }
}

// MARK: - Render GIF

let fps = 18
let duration = 6.4
let frameCount = Int(duration * Double(fps))
let delay = 1.0 / Double(fps)

let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/andon-demo.gif")
guard let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
    fatalError("cannot create gif")
}
let gifProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]]

let cs = CGColorSpaceCreateDeviceRGB()
for i in 0..<frameCount {
    let t = Double(i) / Double(fps)
    guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(true)
    drawFrame(ctx, t: t)
    if let img = ctx.makeImage() {
        CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
    }
}
if CGImageDestinationFinalize(dest) {
    print("wrote \(outURL.path) (\(frameCount) frames)")
} else {
    print("finalize failed")
}
