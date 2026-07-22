import AndonKit
import SwiftUI

/// Quota readout for the 5-hour and 7-day windows.
///
/// These numbers come from Claude Code's own statusline payload, so they match
/// what `/usage` would print rather than being inferred from token counts.
/// When the statusline shim has not run yet there is nothing to show, and the
/// strip hides itself rather than displaying a misleading zero.
struct UsageStripView: View {
    let limits: RateLimits
    let status: StatusSnapshot?

    /// Recompute countdowns without a per-view timer.
    @State private var now = Date()
    private static let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 14) {
            if let five = limits.fiveHour {
                window(label: "5H", window: five)
            }
            if let seven = limits.sevenDay {
                window(label: "7D", window: seven)
            }

            Spacer(minLength: 0)

            if let cost = status?.cost?.totalCostUsd, cost > 0 {
                Text(String(format: "$%.2f", cost))
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .help("Session cost so far")
            }
            if let context = status?.contextWindow?.usedPercentage, context > 0 {
                Text("ctx \(Int(context))%")
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .help("Context window used")
            }
        }
        .padding(.horizontal, AndonTheme.Metrics.horizontalPadding)
        .padding(.vertical, 8)
        .background(AndonTheme.surface)
        .overlay(alignment: .top) { Divider().overlay(AndonTheme.hairline) }
        .onReceive(Self.ticker) { now = $0 }
    }

    private func window(label: String, window: RateLimitWindow) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(AndonTheme.label(9))
                .tracking(0.5)
                .foregroundStyle(AndonTheme.textTertiary)

            AndonMeter(
                fraction: window.fraction,
                segments: 8,
                color: color(for: window.severity))

            Text("\(Int(window.usedPercentage.rounded()))%")
                .font(AndonTheme.numeric(10, weight: .semibold))
                .foregroundStyle(color(for: window.severity))
                .monospacedDigit()

            if let countdown = window.resetCountdown {
                Text(countdown)
                    .font(AndonTheme.numeric(9))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .monospacedDigit()
            }
        }
        .help(helpText(label: label, window: window))
    }

    private func color(for severity: RateLimitWindow.Severity) -> Color {
        switch severity {
        case .nominal: return AndonTheme.green
        case .caution: return AndonTheme.amber
        case .critical: return AndonTheme.red
        }
    }

    private func helpText(label: String, window: RateLimitWindow) -> String {
        let name = label == "5H" ? "5-hour window" : "7-day window"
        guard let resetsAt = window.resetsAt else {
            return "\(name): \(Int(window.usedPercentage))% used"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(name): \(Int(window.usedPercentage))% used, resets at \(formatter.string(from: resetsAt))"
    }
}
