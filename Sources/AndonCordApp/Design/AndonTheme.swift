import AndonKit
import SwiftUI

/// The visual language: an andon board, rendered for a Retina display.
///
/// Two constraints shape everything here. The panel hangs off the notch, so it
/// is always on a dark background and always in peripheral vision — which
/// means state has to be legible from a glance at colour alone, before any
/// text is read. And it is on screen all day, so the palette is warm and
/// desaturated rather than the saturated primaries of an actual factory
/// signal tower.
enum AndonTheme {

    // MARK: - Surfaces

    /// Matches the physical notch so the pill reads as an extension of it.
    static let void = Color(red: 0.039, green: 0.035, blue: 0.031)
    static let surface = Color(red: 0.086, green: 0.078, blue: 0.067)
    static let surfaceRaised = Color(red: 0.129, green: 0.118, blue: 0.098)
    static let hairline = Color(red: 0.20, green: 0.184, blue: 0.153)

    // MARK: - Text

    static let textPrimary = Color(red: 0.949, green: 0.929, blue: 0.890)
    static let textSecondary = Color(red: 0.651, green: 0.620, blue: 0.557)
    static let textTertiary = Color(red: 0.431, green: 0.404, blue: 0.353)

    // MARK: - Signal colours

    /// Cord pulled. The one colour that must win against everything else.
    static let amber = Color(red: 0.910, green: 0.639, blue: 0.239)
    /// Running normally.
    static let green = Color(red: 0.341, green: 0.780, blue: 0.498)
    /// Stopped in error.
    static let red = Color(red: 0.898, green: 0.329, blue: 0.294)
    /// Brand accent, used sparingly for interactive affordances.
    static let accent = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let inactive = Color(red: 0.290, green: 0.267, blue: 0.227)

    /// Per-agent tint for the identity badge.
    ///
    /// Kept away from the signal colours (green/amber/red) on purpose — the
    /// lamp already owns those, so the agent badge uses a separate hue family
    /// and never competes with "is it working / does it need me".
    static func agentTint(_ agent: AgentSource) -> Color {
        switch agent {
        case .claude: return Color(red: 0.827, green: 0.510, blue: 0.361)   // terracotta
        case .codex: return Color(red: 0.478, green: 0.686, blue: 0.937)    // sky blue
        case .gemini: return Color(red: 0.557, green: 0.749, blue: 0.518)   // google green
        case .cursor: return Color(red: 0.678, green: 0.580, blue: 0.937)   // violet
        case .unknown: return textTertiary
        }
    }

    /// Andon-board colour semantics: green only while the line is actually
    /// moving, amber when a person is needed, red whenever nothing is running —
    /// idle, finished, or stopped alike. The point is a binary you can read at
    /// a glance: green-and-moving means working, anything red means it isn't.
    static func signal(for state: StationState) -> Color {
        switch state {
        case .cordPulled: return amber
        case .running, .working: return green
        case .failed, .done, .idle, .ended: return red
        }
    }

    // MARK: - Type

    /// Board labels. Uppercase with wide tracking reads as instrumentation
    /// rather than prose, which is the point.
    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    /// Numerals are monospaced so percentages and timers do not jitter as
    /// they tick — a proportional font makes a countdown visibly wobble.
    static func numeric(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func body(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func code(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    // MARK: - Metrics

    enum Metrics {
        /// Standard menu bar height, which the collapsed pill matches so it
        /// looks like part of the hardware.
        static let pillHeight: CGFloat = 38
        /// How far the pill extends past each side of the physical notch.
        static let pillShoulder: CGFloat = 132
        static let panelWidth: CGFloat = 520
        static let panelMinHeight: CGFloat = 132
        static let panelMaxHeight: CGFloat = 620
        /// Bottom corners of the pill, tuned to sit flush with the notch radius.
        static let notchCornerRadius: CGFloat = 12
        static let panelCornerRadius: CGFloat = 22
        static let rowHeight: CGFloat = 46
        static let horizontalPadding: CGFloat = 14
    }

    enum Motion {
        /// Expansion should feel like a physical panel dropping, so it settles
        /// rather than eases — a little overshoot, no bounce.
        static let expand = Animation.spring(response: 0.34, dampingFraction: 0.82)
        static let collapse = Animation.spring(response: 0.28, dampingFraction: 0.9)
        static let state = Animation.easeOut(duration: 0.18)
    }
}

// MARK: - Components

/// The andon lamp: a status light whose motion tells you what the session is
/// doing at a glance, before any text is read.
///
/// Three modes, deliberately distinct so they are never confused peripherally:
///   * **working** (running / a tool executing) — a live equalizer whose bars
///     bounce continuously. Real, ever-changing motion, not a two-state pulse:
///     a still lamp and a dead session must never look the same, and the only
///     way to be sure of that is genuine frame-by-frame movement.
///   * **alert** (cord pulled) — a hard amber blink; something needs you now.
///   * **stopped** (idle / done / failed / ended) — a steady red dot. On an
///     andon board a line that is not moving is red, whatever the reason.
struct AndonLamp: View {
    let state: StationState
    var size: CGFloat = 8

    private var color: Color { AndonTheme.signal(for: state) }

    var body: some View {
        if state.isActive {
            WorkingIndicator(color: color, size: size)
                .accessibilityLabel(state.label)
        } else {
            DotLamp(color: color, size: size, alerting: state.needsHuman)
                .accessibilityLabel(state.label)
        }
    }
}

/// The "working" animation: three bars driven by a continuous clock.
///
/// `TimelineView(.animation)` re-evaluates every display frame while the view
/// is on screen, so the heights are recomputed from a sine of the current time
/// — the bars are actually different every frame rather than easing between two
/// fixed states. That continuous change is the whole point: it reads as live
/// activity, and it stops dead the instant the session stops working because
/// the lamp switches to `DotLamp`.
struct WorkingIndicator: View {
    let color: Color
    var size: CGFloat = 8

    private let barCount = 3
    /// Each bar is offset in the wave so they never move in unison, which is
    /// what separates "activity" from "a blinking group".
    private let phases: [Double] = [0, 1.1, 2.2]

    var body: some View {
        let barWidth = size * 0.22
        let spacing = size * 0.17

        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let wave = 0.5 + 0.5 * sin(t * 7 + phases[index])
                    let height = size * (0.32 + 0.68 * wave)
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(width: size, height: size, alignment: .center)
            .shadow(color: color.opacity(0.5), radius: 2)
        }
        .frame(width: size, height: size)
    }
}

/// The static states: a solid dot, blinking only when it needs a human.
struct DotLamp: View {
    let color: Color
    var size: CGFloat = 8
    var alerting: Bool = false

    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(alerting ? 0.9 : 0.45),
                    radius: alerting ? 6 : 3)
            .opacity(alerting && dim ? 0.4 : 1)
            .animation(
                alerting ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                value: dim)
            .onAppear { dim = alerting }
            .onChange(of: alerting) { _, new in dim = new }
    }
}

/// Which agent a session belongs to — a tinted two-letter tag.
///
/// Small and quiet by default so a board of same-agent sessions is not noisy,
/// but tinted distinctly enough that a mixed board (Claude + Codex at once)
/// reads apart instantly.
struct AgentBadge: View {
    let agent: AgentSource
    var size: CGFloat = 9

    var body: some View {
        let tint = AndonTheme.agentTint(agent)
        Text(agent.badge)
            .font(AndonTheme.numeric(size, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.16))
            }
            .fixedSize()
            .help(agent.displayName)
    }
}

/// Small uppercase status chip.
struct AndonChip: View {
    let text: String
    var color: Color = AndonTheme.textSecondary
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(AndonTheme.label(9))
            .tracking(0.6)
            .foregroundStyle(filled ? AndonTheme.void : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(filled ? color : color.opacity(0.14))
            }
            .fixedSize()
    }
}

/// Segmented quota bar.
///
/// Segments rather than a smooth fill because the andon board it is imitating
/// is a row of discrete lamps, and because discrete blocks are easier to read
/// at a glance than a continuous bar at small sizes.
struct AndonMeter: View {
    let fraction: Double
    var segments: Int = 10
    var color: Color
    var segmentWidth: CGFloat = 5
    var height: CGFloat = 7

    var body: some View {
        let lit = Int((Double(segments) * fraction).rounded(.up))
        HStack(spacing: 1.5) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < lit ? color : AndonTheme.inactive.opacity(0.5))
                    .frame(width: segmentWidth, height: height)
            }
        }
        .animation(AndonTheme.Motion.state, value: lit)
    }
}

/// Button styled for the panel. Primary is filled, secondary is outlined.
struct AndonButtonStyle: ButtonStyle {
    var tint: Color = AndonTheme.accent
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AndonTheme.body(12, weight: .semibold))
            .foregroundStyle(prominent ? AndonTheme.void : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? tint : tint.opacity(0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(prominent ? .clear : tint.opacity(0.35), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// Keyboard-shortcut hint rendered as a trailing key cap.
    func keyCap(_ text: String) -> some View {
        HStack(spacing: 5) {
            self
            Text(text)
                .font(AndonTheme.numeric(9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Relative elapsed time, e.g. `27m`, `1h4m`.
func formatElapsed(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h\(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(total)s"
}
