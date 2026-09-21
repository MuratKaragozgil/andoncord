import AndonKit
import SwiftUI

/// One quota window, in full: how much is gone, when it resets, and whether it
/// is going to last.
///
/// The verdict line is the whole point of the card. A percentage on its own is
/// unreadable — 60% is comfortable four hours into a five-hour window and a
/// wall you hit before lunch twenty minutes in — so the card always states
/// which of those two it is.
struct QuotaCard: View {
    let readout: QuotaReadout

    private var used: Double? { readout.usedPercentage }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(readout.kind == .fiveHour ? "SESSION · 5H" : "WEEK · 7D")
                    .font(AndonTheme.label(9))
                    .tracking(1)
                    .foregroundStyle(AndonTheme.textTertiary)
                Spacer()
                if let countdown = readout.resetCountdown {
                    Text("resets in \(countdown)")
                        .font(AndonTheme.numeric(9))
                        .foregroundStyle(AndonTheme.textTertiary)
                }
            }

            if let used {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(readout.isEstimate ? "~" : "")\(Int(used.rounded()))%")
                        .font(AndonTheme.numeric(26, weight: .semibold))
                        .foregroundStyle(tint)
                        .monospacedDigit()
                    Text("used")
                        .font(AndonTheme.body(11))
                        .foregroundStyle(AndonTheme.textTertiary)
                    Spacer()
                    if readout.spent.requests > 0 {
                        Text("\(formatTokens(readout.spent.total)) · \(formatCost(readout.spent.costUsd))")
                            .font(AndonTheme.numeric(10))
                            .foregroundStyle(AndonTheme.textTertiary)
                            .help("What this app counted inside the same window")
                    }
                }
                AndonMeter(
                    fraction: readout.fraction, segments: 20, color: tint,
                    segmentWidth: 12, height: 8)
                    .opacity(readout.isMeasured ? 1 : 0.6)
            } else {
                Text("—")
                    .font(AndonTheme.numeric(26, weight: .semibold))
                    .foregroundStyle(AndonTheme.textTertiary)
            }

            Text(verdict)
                .font(AndonTheme.body(10.5))
                .foregroundStyle(verdictColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AndonTheme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    readout.forecast.verdict == .exhausts
                        ? AndonTheme.red.opacity(0.4) : AndonTheme.hairline,
                    lineWidth: 1)
        }
    }

    private var tint: Color {
        switch readout.severity {
        case .nominal: return AndonTheme.green
        case .caution: return AndonTheme.amber
        case .critical: return AndonTheme.red
        }
    }

    /// Says what will happen, or says plainly why it cannot — followed by
    /// where the number came from, every time. A figure this app derived and a
    /// figure Claude Code stated should never be indistinguishable.
    private var verdict: String {
        guard used != nil else {
            return "No reading yet. Quota comes from the Claude desktop app's own record, or from Claude Code's statusline when a terminal session renders one — and once either has been seen, spend measured here can carry it forward between readings."
        }
        var line: String
        switch readout.forecast.verdict {
        case .exhausts:
            line = readout.forecast.summary(windowLabel: readout.kind.longLabel)
                ?? "On pace to run out before this window resets."
            line = line.prefix(1).uppercased() + line.dropFirst()
        case .tight:
            line = "Tight — on pace for \(Int((readout.forecast.projectedAtReset ?? 0).rounded()))% by reset."
        case .holds:
            line = "Holds — on pace for \(Int((readout.forecast.projectedAtReset ?? 0).rounded()))% by reset."
        case .unknown:
            line = readout.resetsAt == nil
                ? "No reset time to project against."
                : "Too early in the window to project a pace."
        }
        if let pace = readout.forecast.burnPerHour, pace > 0,
           readout.forecast.verdict != .unknown {
            line += String(format: " %.1f%%/h%@.", pace,
                           readout.forecast.usesRecentPace
                               ? " over the last readings" : " on the window average")
        }
        return line + " Figure \(readout.provenance)."
    }

    private var verdictColor: Color {
        switch readout.forecast.verdict {
        case .exhausts: return AndonTheme.red
        case .tight: return AndonTheme.amber
        default: return AndonTheme.textSecondary
        }
    }
}

/// A labelled number in the totals strip.
struct Stat: View {
    let label: String
    let value: String
    var tint: Color = AndonTheme.textSecondary
    var help: String?

    init(_ label: String, _ value: String, tint: Color = AndonTheme.textSecondary, help: String? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(AndonTheme.label(8.5))
                .tracking(0.7)
                .foregroundStyle(AndonTheme.textTertiary)
            Text(value)
                .font(AndonTheme.numeric(15, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(AndonTheme.label(9.5))
            .tracking(1)
            .foregroundStyle(AndonTheme.textTertiary)
    }
}

struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(AndonTheme.body(11))
            .foregroundStyle(AndonTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
    }
}

/// One line of a breakdown: a bar you can compare at a glance, a name, and the
/// number itself.
///
/// The bar is proportional to the largest row rather than to the total. What
/// these lists are for is "is anything here disproportionate", and a bar
/// scaled to the total flattens twenty rows into twenty invisible slivers.
struct UsageRow: View {
    let title: String
    let subtitle: String
    let value: String
    let detail: String
    let fraction: Double
    var tint: Color = AndonTheme.green
    var expanded: Bool = false

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AndonTheme.body(12, weight: .medium))
                        .foregroundStyle(AndonTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(AndonTheme.body(10))
                        .foregroundStyle(AndonTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value)
                        .font(AndonTheme.numeric(12, weight: .semibold))
                        .foregroundStyle(AndonTheme.textPrimary)
                        .monospacedDigit()
                    Text(detail)
                        .font(AndonTheme.numeric(10))
                        .foregroundStyle(AndonTheme.textTertiary)
                        .monospacedDigit()
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(AndonTheme.inactive.opacity(0.4))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(tint.opacity(expanded ? 1 : 0.75))
                        .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(expanded ? AndonTheme.surfaceRaised : Color.clear)
        }
    }
}

/// A session nested under its project.
struct SessionSubRow: View {
    let session: SessionUsage

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AndonTheme.hairline)
                .frame(width: 1, height: 22)
                .padding(.leading, 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.textSecondary)
                    .lineLimit(1)
                Text("\(session.shortId) · \(session.promptCount) prompts · \(UsageWindowView.time(session.lastActivityAt))")
                    .font(AndonTheme.body(9.5))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(formatTokens(session.usage.total))
                .font(AndonTheme.numeric(11))
                .foregroundStyle(AndonTheme.textSecondary)
                .monospacedDigit()
            Text(formatCost(session.usage.costUsd))
                .font(AndonTheme.numeric(10))
                .foregroundStyle(AndonTheme.textTertiary)
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.trailing, 10)
        .padding(.bottom, 2)
    }
}

/// Hour-by-hour token throughput across the selected window.
///
/// Deliberately unlabelled beyond the ends: this is a shape, not a table. What
/// it is for is spotting the hour that cost three times the rest, which is
/// visible without a single gridline.
struct ActivityChart: View {
    let buckets: [HourBucket]
    let from: Date
    let to: Date

    /// Every slot in the window, including the empty ones — a chart that packs
    /// only the active hours together makes a quiet afternoon look busy.
    ///
    /// Buckets are binned by index in one pass rather than by rescanning them
    /// per slot: a week at hourly resolution is 168 slots, and the quadratic
    /// version re-walked every bucket for each of them on every redraw.
    private var slots: [(date: Date, usage: TokenUsage)] {
        let start = floorToHour(from)
        let end = floorToHour(to)
        guard end >= start else { return [] }
        // A 30-day window is 720 bars, more than the width can carry, so past
        // a few days the chart rolls up to days.
        let step: TimeInterval = end.timeIntervalSince(start) > 4 * 24 * 3_600 ? 86_400 : 3_600
        let count = min(800, Int(end.timeIntervalSince(start) / step) + 1)
        guard count > 0 else { return [] }

        var totals = [TokenUsage](repeating: TokenUsage(), count: count)
        for bucket in buckets {
            let offset = Int(bucket.hour.timeIntervalSince(start) / step)
            guard offset >= 0, offset < count else { continue }
            totals[offset] += bucket.usage
        }
        return (0..<count).map {
            (start.addingTimeInterval(Double($0) * step), totals[$0])
        }
    }

    var body: some View {
        let slots = self.slots
        let peak = max(slots.map(\.usage.total).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                let spacing: CGFloat = slots.count > 120 ? 0.5 : 2
                let width = max(1, (geometry.size.width - spacing * CGFloat(max(slots.count - 1, 0)))
                    / CGFloat(max(slots.count, 1)))
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                        let ratio = Double(slot.usage.total) / Double(peak)
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(slot.usage.total > 0
                                  ? AndonTheme.green.opacity(0.35 + 0.65 * ratio)
                                  : AndonTheme.inactive.opacity(0.3))
                            .frame(width: width, height: max(1.5, 56 * ratio))
                            .help("\(UsageWindowView.time(slot.date)) · \(formatTokens(slot.usage.total)) · \(formatCost(slot.usage.costUsd))")
                    }
                }
                .frame(height: 56, alignment: .bottom)
            }
            .frame(height: 56)

            HStack {
                Text(UsageWindowView.time(from))
                Spacer()
                Text("peak \(formatTokens(peak))")
                Spacer()
                Text("now")
            }
            .font(AndonTheme.numeric(9))
            .foregroundStyle(AndonTheme.textTertiary)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AndonTheme.surface)
        }
    }

    private func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / 3600).rounded(.down) * 3600)
    }
}
