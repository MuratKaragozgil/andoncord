import AppKit
import Foundation

// Renders the Andon Cord app icon at every size macOS asks for.
//
// Generated rather than hand-drawn so the mark stays in lockstep with the
// palette in `AndonTheme` — the icon uses the same amber and green as the
// lamps on the board, so a session needing attention looks like the app that
// is telling you about it.
//
// Usage: swift Tools/make-icon.swift <output.iconset>

// MARK: - Palette (mirrors AndonTheme)

func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Warm charcoal rather than near-black. Dark app icons are fine — Chess is
// nearly black and reads cleanly — but leaving a little value in the tile keeps
// the shape legible against both light and dark Finder backgrounds.
let tileTop = srgb(0.204, 0.184, 0.157)
let tileBottom = srgb(0.086, 0.075, 0.063)
let amber = srgb(0.910, 0.639, 0.239)
let green = srgb(0.341, 0.780, 0.498)
let rail = srgb(0.290, 0.267, 0.227)

// MARK: - Drawing

/// Everything is expressed as a fraction of the canvas so one routine serves
/// 16pt and 1024pt alike.
func drawIcon(size: CGFloat, in context: CGContext) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.setShouldAntialias(true)

    // The icon draws its own rounded tile, on Apple's macOS icon grid.
    //
    // macOS does not mask app icons: whatever the `.icns` contains is what
    // gets drawn. A full-bleed square therefore renders as a literal square
    // with hard corners. (An earlier experiment appeared to show the system
    // rounding a square, but the probe bundle had an invalid executable, so
    // what came back was the system's generic broken-app icon — not our art.)
    //
    // Apple's grid: on a 1024 canvas the tile is 824 wide with a 185.4 corner
    // radius, i.e. inset 9.77% per side and a radius 22.5% of the tile.
    let inset = size * 0.0977
    let tile = rect.insetBy(dx: inset, dy: inset)
    let radius = tile.width * 0.225

    let tilePath = CGPath(
        roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [tileTop.cgColor, tileBottom.cgColor] as CFArray,
        locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.midX, y: tile.maxY),
            end: CGPoint(x: tile.midX, y: tile.minY),
            options: [])
    }
    context.restoreGState()

    // Light falling on the top of the enclosure.
    //
    // Deliberately a clipped gradient rather than a stroked outline. A stroke
    // is centred on its path, so half of it lands outside the tile on
    // transparent pixels with no dark fill to sink into — which reads as a
    // white frame at 16pt even at low alpha, and worse if the line width is
    // floored to a whole pixel. Clipping guarantees the highlight can only
    // ever brighten pixels that are already part of the icon.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    if let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            srgb(1, 1, 1, 0.10).cgColor,
            srgb(1, 1, 1, 0).cgColor,
        ] as CFArray,
        locations: [0, 1])
    {
        context.drawLinearGradient(
            sheen,
            start: CGPoint(x: tile.midX, y: tile.maxY),
            end: CGPoint(x: tile.midX, y: tile.maxY - tile.height * 0.22),
            options: [])
    }
    context.restoreGState()

    // The composition is centred as a whole — rail plus lamps — rather than
    // centring the lamps and letting the rail hang below them, which reads as
    // an underline instead of a base.
    let railHeight = size * 0.026
    let railY = size * 0.320
    let baseline = railY + railHeight * 0.5

    // Sub-pixel at small sizes the rail turns into a grey smear, so below the
    // point where it can resolve it is simply dropped; the two lamps carry the
    // mark on their own.
    if size >= 64 {
        let railRect = CGRect(
            x: size * 0.290, y: railY, width: size * 0.42, height: railHeight)
        context.saveGState()
        context.setFillColor(rail.cgColor)
        context.addPath(CGPath(
            roundedRect: railRect, cornerWidth: railHeight / 2,
            cornerHeight: railHeight / 2, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    // Two lamps: amber standing taller than green, because the state that
    // matters is the one asking for a human.
    let barWidth = size * 0.135
    let gap = size * 0.050
    let groupWidth = barWidth * 2 + gap
    let startX = (size - groupWidth) / 2

    func lamp(x: CGFloat, height: CGFloat, color: NSColor, glow: CGFloat) {
        let bar = CGRect(x: x, y: baseline, width: barWidth, height: height)
        let path = CGPath(
            roundedRect: bar, cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2, transform: nil)

        // Glow first, so it sits behind the bar rather than washing it out.
        context.saveGState()
        context.setShadow(
            offset: .zero, blur: size * glow, color: color.withAlphaComponent(0.7).cgColor)
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        // A gradient inside the bar, rather than a lighter cap on top of it.
        // The cap version showed a visible seam and made the shorter lamp look
        // like two stacked segments.
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color.blended(withFraction: 0.30, of: .white)?.cgColor ?? color.cgColor,
                color.cgColor,
                color.blended(withFraction: 0.18, of: .black)?.cgColor ?? color.cgColor,
            ] as CFArray,
            locations: [0, 0.55, 1])
        {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: bar.midX, y: bar.maxY),
                end: CGPoint(x: bar.midX, y: bar.minY),
                options: [])
        }
        context.restoreGState()
    }

    lamp(x: startX, height: size * 0.355, color: amber, glow: 0.075)
    lamp(x: startX + barWidth + gap, height: size * 0.245, color: green, glow: 0.050)
}

// MARK: - Output

func renderPNG(size: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "icon", code: 1) }

    drawIcon(size: CGFloat(size), in: context)

    guard let image = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try data.write(to: url)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AndonCord.iconset")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// The exact set `iconutil` expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    try renderPNG(
        size: variant.pixels,
        to: outputDir.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) sizes to \(outputDir.path)")
