import CoreGraphics
import Foundation

/// The agent marks, as vector paths.
///
/// Path data comes from the Simple Icons project (CC0-licensed path data; the
/// marks themselves remain trademarks of their owners and appear here purely
/// to say "this session belongs to that tool"). Each glyph is authored on a
/// 24×24 grid and parsed once, lazily, by the small path-data interpreter
/// below — four monochrome glyphs as strings beat vendored binary assets.
///
/// Deliberately Foundation + CoreGraphics only (no AppKit, no other AndonKit
/// types): `Tools/make-demo-gif.sh` compiles this same file into the offline
/// GIF renderer, which has no module to import. The hook shim links this file
/// too but never touches it, and static lets are lazy, so it costs the shim
/// nothing.
public enum AgentGlyph {
    /// Side length of the square the paths are drawn in.
    public static let viewBox: CGFloat = 24

    /// Anthropic's starburst.
    public static let claude: CGPath = parse("m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z")

    /// The OpenAI knot — Codex sessions wear the company mark.
    public static let openai: CGPath = parse("M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z")

    /// Gemini's four-point spark.
    public static let gemini: CGPath = parse("M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81")

    /// Cursor's cube.
    public static let cursor: CGPath = parse("M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23")

    // MARK: - Path-data interpreter

    /// Parses SVG path data — just enough grammar for the icons above:
    /// M L H V C S Q T A Z in both cases, implicit command repetition, packed
    /// numbers (".84.84", "1-3.81"), and single-character arc flags.
    ///
    /// Malformed data stops the parse and returns whatever was built so far;
    /// these strings are compile-time constants guarded by unit tests, so a
    /// hard crash would punish the wrong person.
    public static func parse(_ data: String) -> CGPath {
        var scanner = PathScanner(data)
        let path = CGMutablePath()
        var pen = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character = "M"

        while !scanner.atEnd() {
            if let letter = scanner.command() { command = letter }
            // No letter → the previous command repeats with fresh arguments
            // (and a repeated moveto becomes lineto, per spec — see "m").
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: pen.x + x, y: pen.y + y) : CGPoint(x: x, y: y)
            }
            var newCubicControl: CGPoint?
            var newQuadControl: CGPoint?

            switch Character(command.lowercased()) {
            case "m":
                guard let p = point() else { return path }
                path.move(to: p)
                pen = p
                subpathStart = p
                command = relative ? "l" : "L"
            case "l":
                guard let p = point() else { return path }
                path.addLine(to: p)
                pen = p
            case "h":
                guard let x = scanner.number() else { return path }
                pen.x = relative ? pen.x + x : x
                path.addLine(to: pen)
            case "v":
                guard let y = scanner.number() else { return path }
                pen.y = relative ? pen.y + y : y
                path.addLine(to: pen)
            case "c":
                guard let c1 = point(), let c2 = point(), let end = point() else { return path }
                path.addCurve(to: end, control1: c1, control2: c2)
                pen = end
                newCubicControl = c2
            case "s":
                // First control point mirrors the previous curve's second one.
                let c1 = lastCubicControl.map { CGPoint(x: 2 * pen.x - $0.x, y: 2 * pen.y - $0.y) } ?? pen
                guard let c2 = point(), let end = point() else { return path }
                path.addCurve(to: end, control1: c1, control2: c2)
                pen = end
                newCubicControl = c2
            case "q":
                guard let control = point(), let end = point() else { return path }
                path.addQuadCurve(to: end, control: control)
                pen = end
                newQuadControl = control
            case "t":
                let control = lastQuadControl.map { CGPoint(x: 2 * pen.x - $0.x, y: 2 * pen.y - $0.y) } ?? pen
                guard let end = point() else { return path }
                path.addQuadCurve(to: end, control: control)
                pen = end
                newQuadControl = control
            case "a":
                guard let rx = scanner.number(), let ry = scanner.number(),
                      let rotation = scanner.number(),
                      let largeArc = scanner.flag(), let sweep = scanner.flag(),
                      let end = point() else { return path }
                addArc(to: path, from: pen, rx: rx, ry: ry, rotationDegrees: rotation,
                       largeArc: largeArc, sweep: sweep, end: end)
                pen = end
            case "z":
                path.closeSubpath()
                pen = subpathStart
            default:
                return path
            }
            lastCubicControl = newCubicControl
            lastQuadControl = newQuadControl
        }
        return path
    }

    /// Converts an SVG elliptical-arc segment into cubic Béziers (the
    /// endpoint-to-center conversion from SVG spec appendix F.6.5), splitting
    /// the sweep into ≤90° slices so the standard k = 4/3·tan(Δθ/4)
    /// approximation stays accurate.
    private static func addArc(to path: CGMutablePath, from start: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
                               largeArc: Bool, sweep: Bool, end: CGPoint) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, start != end else {
            path.addLine(to: end)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Scale radii up if the endpoints cannot be joined at the given size.
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let grow = lambda.squareRoot()
            rx *= grow
            ry *= grow
        }

        let rx2 = rx * rx, ry2 = ry * ry
        let numerator = max(0, rx2 * ry2 - rx2 * y1 * y1 - ry2 * x1 * x1)
        let denominator = rx2 * y1 * y1 + ry2 * x1 * x1
        var scale = (numerator / denominator).squareRoot()
        if largeArc == sweep { scale = -scale }
        let cx1 = scale * rx * y1 / ry
        let cy1 = -scale * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
                             y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)

        func angle(from u: CGPoint, to v: CGPoint) -> CGFloat {
            let dot = u.x * v.x + u.y * v.y
            let magnitudes = ((u.x * u.x + u.y * u.y) * (v.x * v.x + v.y * v.y)).squareRoot()
            var value = acos(min(1, max(-1, dot / magnitudes)))
            if u.x * v.y - u.y * v.x < 0 { value = -value }
            return value
        }
        let u = CGPoint(x: (x1 - cx1) / rx, y: (y1 - cy1) / ry)
        let v = CGPoint(x: (-x1 - cx1) / rx, y: (-y1 - cy1) / ry)
        let theta1 = angle(from: CGPoint(x: 1, y: 0), to: u)
        var deltaTheta = angle(from: u, to: v)
        if !sweep, deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweep, deltaTheta < 0 { deltaTheta += 2 * .pi }

        func pointAt(_ theta: CGFloat) -> CGPoint {
            CGPoint(x: center.x + rx * cosPhi * cos(theta) - ry * sinPhi * sin(theta),
                    y: center.y + rx * sinPhi * cos(theta) + ry * cosPhi * sin(theta))
        }
        func derivativeAt(_ theta: CGFloat) -> CGPoint {
            CGPoint(x: -rx * cosPhi * sin(theta) - ry * sinPhi * cos(theta),
                    y: -rx * sinPhi * sin(theta) + ry * cosPhi * cos(theta))
        }

        let segments = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let step = deltaTheta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        var theta = theta1
        var from = start
        for _ in 0..<segments {
            let next = theta + step
            let to = pointAt(next)
            let d1 = derivativeAt(theta), d2 = derivativeAt(next)
            path.addCurve(to: to,
                          control1: CGPoint(x: from.x + k * d1.x, y: from.y + k * d1.y),
                          control2: CGPoint(x: to.x - k * d2.x, y: to.y - k * d2.y))
            theta = next
            from = to
        }
    }
}

/// Tokenizer for SVG path data. The grammar's traps are all lexical: numbers
/// pack together without separators (".84.84" is two numbers, "1-3.81" too),
/// and arc flags are single characters, so "01" is two flags — never eleven.
private struct PathScanner {
    private let chars: [Character]
    private var index = 0

    init(_ data: String) {
        chars = Array(data)
    }

    private mutating func skipSeparators() {
        while index < chars.count {
            let c = chars[index]
            guard c == " " || c == "," || c == "\n" || c == "\r" || c == "\t" else { break }
            index += 1
        }
    }

    mutating func atEnd() -> Bool {
        skipSeparators()
        return index >= chars.count
    }

    /// A command letter, or nil when a number follows (implicit repetition).
    mutating func command() -> Character? {
        skipSeparators()
        guard index < chars.count, chars[index].isLetter else { return nil }
        defer { index += 1 }
        return chars[index]
    }

    /// One coordinate. A second "." or a sign ends the number and starts the
    /// next one. (Exponent notation never occurs in this icon set, so a stray
    /// "e" simply fails the parse instead of being half-supported.)
    mutating func number() -> CGFloat? {
        skipSeparators()
        var text = ""
        if index < chars.count, chars[index] == "-" || chars[index] == "+" {
            text.append(chars[index])
            index += 1
        }
        var sawDigit = false, sawDot = false
        while index < chars.count {
            let c = chars[index]
            if c.isNumber {
                sawDigit = true
            } else if c == ".", !sawDot {
                sawDot = true
            } else {
                break
            }
            text.append(c)
            index += 1
        }
        guard sawDigit, let value = Double(text) else { return nil }
        return CGFloat(value)
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < chars.count else { return nil }
        if chars[index] == "0" { index += 1; return false }
        if chars[index] == "1" { index += 1; return true }
        return nil
    }
}
