import AndonKit
import SwiftUI

/// Quota readout for the 5-hour and 7-day windows, plus what today has cost.
///
/// The percentages are the same ones `/usage` and the desktop app's Usage
/// panel show, because they are read from where those get them. What neither
/// says is whether the number is still true or whether it is going to hold —
/// and both of those are the reason anyone looks:
///
///   * **Is it current?** Quota comes from the Claude desktop app's own
///     five-minute record where that exists, and from Claude Code's statusline
///     otherwise — and the statusline only fires while a session is rendering
///     one, so it can sit unchanged for weeks. A five-week-old "37% used"
///     drawn as a live bar is worse than no bar at all, so a reading that has
///     gone quiet says so, and a window whose reset time has passed is not
///     drawn as a percentage at all.
///   * **Will it last?** 60% used means nothing without knowing how far into
///     the window it is. `QuotaForecast` supplies that.
///
/// Token counts come from the transcript ledger instead — Claude Code dropped
/// `cost` from the statusline payload, and the transcripts have far more in
/// them than a single running total anyway.
struct UsageStripView: View {
    let app: AppState
    /// Supplied by the panel so the tap can collapse it first — otherwise the
    /// window opens underneath a notch panel that sits at status-bar level.
    var onOpen: () -> Void

    private var board: BoardStore { app.board }

    /// Recompute countdowns and staleness without a per-view timer.
    @State private var now = Date()
    private static let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Windows with something to show. A window can be missing because Claude
    /// Code never reported it, or because its reading expired and no spend has
    /// been recorded since to estimate from.
    private var readouts: [QuotaReadout] {
        QuotaWindowKind.allCases
            .map { app.quotaReadout($0, now: now) }
            .filter { $0.usedPercentage != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                let readouts = self.readouts
                if readouts.isEmpty {
                    quotaUnavailable
                } else {
                    ForEach(readouts, id: \.kind) { readout in
                        QuotaMeterView(readout: readout)
                    }
                }

                Spacer(minLength: 0)
                todaySummary
                // A strip that silently happens to be tappable is a strip
                // nobody taps. This says what the tap does.
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AndonTheme.textTertiary)
            }

            if let note = footnote {
                Text(note)
                    .font(AndonTheme.body(9.5))
                    .foregroundStyle(noteColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, AndonTheme.Metrics.horizontalPadding)
        .padding(.vertical, 8)
        .background(AndonTheme.surface)
        .overlay(alignment: .top) { Divider().overlay(AndonTheme.hairline) }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .help("Open the token usage breakdown")
        .onReceive(Self.ticker) { now = $0 }
    }

    // MARK: - Pieces

    private var quotaUnavailable: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                .font(.system(size: 10))
                .foregroundStyle(AndonTheme.textTertiary)
            Text("QUOTA UNKNOWN")
                .font(AndonTheme.label(9))
                .tracking(0.5)
                .foregroundStyle(AndonTheme.textTertiary)
        }
    }

    private var todaySummary: some View {
        let today = app.ledger.total(since: Calendar.current.startOfDay(for: now))
        return HStack(spacing: 8) {
            if app.ledger.isIndexing {
                Text("indexing…")
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.textTertiary)
            } else if today.requests > 0 {
                Text("today \(formatTokens(today.total))")
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.textSecondary)
                    .help("Tokens moved through the model today, cache reads included")
                Text(formatCost(today.costUsd))
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .help("What today would have cost at API list prices")
            }
            if let context = board.status?.contextWindow?.usedPercentage,
               context > 0, board.status?.isStale == false {
                Text("ctx \(Int(context))%")
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .help("Context window used in the session that last reported")
            }
        }
        // The half of the row that yields when the meters will not: each part
        // stays on one line and drops its tail rather than stacking.
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// One line, and only when it changes what someone would do: a quota about
    /// to run out, or a number that is not what it appears to be.
    private var footnote: String? {
        if let binding = app.bindingQuota(now: now) {
            if binding.forecast.verdict == .exhausts || binding.forecast.verdict == .tight,
               let summary = binding.forecast.summary(windowLabel: binding.kind.longLabel) {
                return summary
            }
            if binding.isEstimate { return "Quota \(binding.provenance)." }
            return nil
        }
        guard board.status != nil else {
            return "No quota reading yet — open the Claude desktop app, or run a Claude Code session in a terminal, and one arrives within minutes."
        }
        return "The last quota reading has expired and there is no spend since to estimate from."
    }

    private var noteColor: Color {
        guard let binding = app.bindingQuota(now: now) else { return AndonTheme.textTertiary }
        switch binding.forecast.verdict {
        case .exhausts: return AndonTheme.red
        case .tight: return AndonTheme.amber
        default: return AndonTheme.textTertiary
        }
    }
}

/// One window: label, meter, percentage, countdown, and where it is heading.
///
/// An estimated figure is marked `~` and drawn dimmer than a reported one.
/// The distinction is not cosmetic — a number Claude Code stated and a number
/// this app derived deserve different amounts of trust, and a readout that
/// blurs the two is how people stop believing any of it.
struct QuotaMeterView: View {
    let readout: QuotaReadout

    var body: some View {
        HStack(spacing: 6) {
            Text(readout.kind.shortLabel)
                .font(AndonTheme.label(9))
                .tracking(0.5)
                .foregroundStyle(AndonTheme.textTertiary)

            AndonMeter(fraction: readout.fraction, segments: 8, color: meterColor)

            Text("\(readout.isEstimate ? "~" : "")\(Int((readout.usedPercentage ?? 0).rounded()))%")
                .font(AndonTheme.numeric(10, weight: .semibold))
                .foregroundStyle(meterColor)
                .monospacedDigit()

            if let glyph = forecastGlyph {
                Image(systemName: glyph)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(forecastColor)
            }

            if let countdown = readout.resetCountdown {
                Text(countdown)
                    .font(AndonTheme.numeric(9))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .monospacedDigit()
            }
        }
        // Nothing in a meter may wrap or be clipped. The strip is a fixed-width
        // row with a spacer in it, so under pressure SwiftUI compresses
        // whichever child will yield — and a meter that gives is a meter that
        // grows a second line and makes the whole strip jump. Let the summary
        // on the right shorten instead; it is the one part of this row that
        // reads fine truncated.
        .fixedSize(horizontal: true, vertical: false)
        .opacity(readout.isMeasured ? 1 : 0.68)
        .help(helpText)
    }

    private var meterColor: Color {
        switch readout.severity {
        case .nominal: return AndonTheme.green
        case .caution: return AndonTheme.amber
        case .critical: return AndonTheme.red
        }
    }

    private var forecastColor: Color {
        switch readout.forecast.verdict {
        case .exhausts: return AndonTheme.red
        case .tight: return AndonTheme.amber
        default: return AndonTheme.green
        }
    }

    /// Only drawn when the projection disagrees with the bar. A meter at 20%
    /// that is on pace to blow through the cap is exactly the case the colour
    /// alone gets wrong.
    private var forecastGlyph: String? {
        switch readout.forecast.verdict {
        case .exhausts: return "exclamationmark.triangle.fill"
        case .tight: return "arrow.up.right"
        case .holds, .unknown: return nil
        }
    }

    private var helpText: String {
        var parts = [
            "\(readout.kind.longLabel) window: \(Int((readout.usedPercentage ?? 0)))% used",
            readout.provenance,
        ]
        if let resetsAt = readout.resetsAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            parts.append("resets at \(formatter.string(from: resetsAt))")
        }
        if readout.spent.requests > 0 {
            parts.append("\(formatTokens(readout.spent.total)) counted in this window")
        }
        if let summary = readout.forecast.summary(windowLabel: readout.kind.longLabel) {
            parts.append(summary)
        }
        return parts.joined(separator: " · ")
    }
}
