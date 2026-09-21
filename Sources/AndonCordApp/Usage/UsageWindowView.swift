import AndonKit
import AppKit
import SwiftUI

/// The token breakdown: where the quota actually went.
///
/// The notch strip answers "how much is left". This answers the two questions
/// that follow — *which project and session spent it*, and *what inside that
/// session was expensive*. Claude Code records everything needed for both in
/// its transcripts and adds up none of it.
///
/// Everything on this page is read from `~/.claude/projects`. Nothing is sent
/// anywhere.
struct UsageWindowView: View {
    let app: AppState

    @State private var scope: UsageScope = .session
    @State private var breakdown: Breakdown = .projects
    @State private var now = Date()
    @State private var expandedProject: String?

    private static let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var board: BoardStore { app.board }
    private var cutoff: Date { scope.cutoff(app: app, now: now) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AndonTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    quotaRow
                    totalsRow
                    activityChart
                    breakdownSection
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 760, height: 700)
        .background(AndonTheme.void)
        .onReceive(Self.ticker) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1.5).fill(AndonTheme.amber)
                    .frame(width: 3, height: 11)
                RoundedRectangle(cornerRadius: 1.5).fill(AndonTheme.green)
                    .frame(width: 3, height: 11)
            }
            Text("TOKEN USAGE")
                .font(AndonTheme.label(11))
                .tracking(1.4)
                .foregroundStyle(AndonTheme.textSecondary)

            Spacer()

            if app.ledger.isIndexing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("indexing transcripts…")
                        .font(AndonTheme.body(10))
                        .foregroundStyle(AndonTheme.textTertiary)
                }
            }

            Picker("", selection: $scope) {
                ForEach(UsageScope.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Quota

    private var quotaRow: some View {
        HStack(spacing: 12) {
            ForEach(QuotaWindowKind.allCases, id: \.self) { kind in
                QuotaCard(readout: app.quotaReadout(kind, now: now))
            }
        }
    }

    // MARK: - Totals

    private var totalsRow: some View {
        let total = app.ledger.total(since: cutoff)
        let sessions = app.ledger.sessions(since: cutoff)
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(
                "\(scope.label) · \(sessions.count) session\(sessions.count == 1 ? "" : "s")")
            HStack(spacing: 0) {
                Stat("tokens", formatTokens(total.total), tint: AndonTheme.textPrimary,
                     help: "Everything that moved through the model, cache reads included")
                Stat("api cost", formatCost(total.costUsd), tint: AndonTheme.accent,
                     help: "What this traffic would cost at API list prices. A subscription is not billed per token — this is the comparison, not a bill.")
                Stat("requests", "\(total.requests)")
                Stat("output", formatTokens(total.output),
                     help: "Tokens Claude generated")
                Stat("cache write", formatTokens(total.cacheWrite),
                     help: "New context written into the prompt cache")
                Stat("cache read", formatTokens(total.cacheRead),
                     help: "Context re-sent on every request. In a long session this is most of the bill.")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AndonTheme.surface)
            }
        }
    }

    // MARK: - Activity

    private var activityChart: some View {
        let buckets = app.ledger.hourlyTotals(since: cutoff)
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Activity")
            if buckets.isEmpty {
                EmptyNote("Nothing recorded in this window.")
            } else {
                ActivityChart(buckets: buckets, from: cutoff, to: now)
            }
        }
    }

    // MARK: - Breakdown

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(breakdown.title)
                Spacer()
                Picker("", selection: $breakdown) {
                    ForEach(Breakdown.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }

            Text(breakdown.explanation)
                .font(AndonTheme.body(10))
                .foregroundStyle(AndonTheme.textTertiary)
                .padding(.bottom, 2)

            switch breakdown {
            case .projects: projectList
            case .sessions: sessionList
            case .prompts: promptList
            case .context: contextList
            }
        }
    }

    private var projectList: some View {
        let projects = app.ledger.projects(since: cutoff)
        let peak = projects.first?.usage.total ?? 1
        return VStack(spacing: 0) {
            if projects.isEmpty { EmptyNote("No sessions in this window.") }
            ForEach(projects) { project in
                UsageRow(
                    title: project.name,
                    subtitle: "\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s") · \(project.path)",
                    value: formatTokens(project.usage.total),
                    detail: formatCost(project.usage.costUsd),
                    fraction: Double(project.usage.total) / Double(max(peak, 1)),
                    tint: AndonTheme.green,
                    expanded: expandedProject == project.path)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        expandedProject = expandedProject == project.path ? nil : project.path
                    }

                if expandedProject == project.path {
                    ForEach(project.sessions.prefix(8)) { session in
                        SessionSubRow(session: session)
                    }
                }
            }
        }
    }

    private var sessionList: some View {
        let sessions = app.ledger.sessions(since: cutoff)
            .sorted { $0.usage.total > $1.usage.total }
            .prefix(20)
        let peak = sessions.first?.usage.total ?? 1
        return VStack(spacing: 0) {
            if sessions.isEmpty { EmptyNote("No sessions in this window.") }
            ForEach(Array(sessions)) { session in
                UsageRow(
                    title: session.title,
                    subtitle: "\(session.projectName) · \(session.promptCount) prompt\(session.promptCount == 1 ? "" : "s") · \(session.models.map(Self.shortModel).joined(separator: ", "))",
                    value: formatTokens(session.usage.total),
                    detail: formatCost(session.usage.costUsd),
                    fraction: Double(session.usage.total) / Double(max(peak, 1)),
                    tint: AndonTheme.green)
                    .help(session.transcriptPath)
            }
        }
    }

    private var promptList: some View {
        let prompts = app.ledger.costliestPrompts(since: cutoff, limit: 15)
        let peak = prompts.first?.1.usage.total ?? 1
        return VStack(spacing: 0) {
            if prompts.isEmpty { EmptyNote("No prompts in this window.") }
            ForEach(prompts, id: \.1.id) { session, turn in
                UsageRow(
                    title: turn.prompt,
                    subtitle: "\(session.projectName) · \(turn.toolCalls) tool call\(turn.toolCalls == 1 ? "" : "s") · \(Self.time(turn.at))",
                    value: formatTokens(turn.usage.total),
                    detail: formatCost(turn.usage.costUsd),
                    fraction: Double(turn.usage.total) / Double(max(peak, 1)),
                    tint: AndonTheme.amber)
            }
        }
    }

    private var contextList: some View {
        let footprints = app.ledger.costliestFootprints(since: cutoff, limit: 15)
        let peak = footprints.first?.totalTokens ?? 1
        return VStack(spacing: 0) {
            if footprints.isEmpty { EmptyNote("No tool results in this window.") }
            ForEach(footprints) { footprint in
                UsageRow(
                    title: footprint.displayKey,
                    subtitle: "\(footprint.displayTool) · read \(footprint.occurrences)× · \(formatTokens(footprint.directTokens)) direct + \(formatTokens(footprint.carriedTokens)) re-sent",
                    value: formatTokens(footprint.totalTokens),
                    detail: "×\(footprint.occurrences)",
                    fraction: Double(footprint.totalTokens) / Double(max(peak, 1)),
                    tint: AndonTheme.accent)
                    .help(footprint.key)
            }
        }
    }

    // MARK: - Helpers

    /// `claude-opus-5` on a row is noise; `opus-5` is the part that varies.
    static func shortModel(_ id: String) -> String {
        id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Scope

enum UsageScope: String, CaseIterable, Identifiable {
    case session
    case today
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .session: return "Session"
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "30 days"
        }
    }

    /// The session and week scopes deliberately align with the quota windows
    /// rather than with the clock, so the token total on this page is the
    /// total that produced the percentage on the card above it.
    @MainActor
    func cutoff(app: AppState, now: Date) -> Date {
        switch self {
        case .session: return app.windowStart(.fiveHour, now: now)
        case .today: return Calendar.current.startOfDay(for: now)
        case .week: return app.windowStart(.sevenDay, now: now)
        case .month: return now.addingTimeInterval(-30 * 24 * 3600)
        }
    }
}

enum Breakdown: String, CaseIterable, Identifiable {
    case projects
    case sessions
    case prompts
    case context

    var id: String { rawValue }

    var label: String {
        switch self {
        case .projects: return "Projects"
        case .sessions: return "Sessions"
        case .prompts: return "Prompts"
        case .context: return "Context"
        }
    }

    var title: String {
        switch self {
        case .projects: return "Spend by project"
        case .sessions: return "Heaviest sessions"
        case .prompts: return "Most expensive prompts"
        case .context: return "Biggest context contributors"
        }
    }

    var explanation: String {
        switch self {
        case .projects:
            return "Grouped by the directory each session ran in. Click a project to see its sessions."
        case .sessions:
            return "One row per Claude Code session, largest first."
        case .prompts:
            return "Everything one prompt set in motion — its replies, its tool calls, its retries."
        case .context:
            return "Direct is the size of the result itself. Re-sent is that result travelling again as a cache read on every later request in the session, which is usually the larger half."
        }
    }
}
