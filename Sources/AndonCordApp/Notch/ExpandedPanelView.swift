import AndonKit
import SwiftUI

/// The full board.
///
/// Layout priority top to bottom: whatever is blocking a human, then quota,
/// then everything that is merely running. A pulled cord always occupies the
/// top of the panel — if you opened this, that is almost certainly why.
struct ExpandedPanelView: View {
    let controller: NotchController
    let app: AppState

    @State private var showingSettings = false

    private var board: BoardStore { app.board }
    private var waiting: [Session] { board.sessionsNeedingHuman }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !app.isIntegrationHealthy {
                IntegrationWarningView(app: app)
            }

            // The active request, if any. Only one is presented at a time;
            // the rest queue behind it in the session list below.
            if let session = waiting.first, let request = session.pending {
                RequestCardView(session: session, request: request, app: app)
                    .transition(.asymmetric(
                        insertion: .push(from: .top).combined(with: .opacity),
                        removal: .opacity))
            }

            if app.settings.showUsage, let limits = board.rateLimits, !limits.isEmpty {
                UsageStripView(limits: limits, status: board.status)
            }

            if !board.sessions.isEmpty {
                sessionList
            } else {
                emptyState
            }
        }
        // Shape, border and shadow belong to the animated container in
        // `NotchRootView`, which is the thing that actually grows.
        .animation(AndonTheme.Motion.expand, value: waiting.first?.pending?.id)
        .sheet(isPresented: $showingSettings) {
            SettingsView(app: app)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // Wordmark: two lamps and the name, echoing a signal tower.
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1.5).fill(AndonTheme.amber)
                    .frame(width: 3, height: 11)
                RoundedRectangle(cornerRadius: 1.5).fill(AndonTheme.green)
                    .frame(width: 3, height: 11)
            }
            Text("ANDON CORD")
                .font(AndonTheme.label(10))
                .tracking(1.4)
                .foregroundStyle(AndonTheme.textSecondary)

            Spacer()

            if board.activeSessionCount > 0 {
                Text("\(board.activeSessionCount) running")
                    .font(AndonTheme.numeric(10))
                    .foregroundStyle(AndonTheme.textTertiary)
            }

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AndonTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button {
                controller.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AndonTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Collapse")
        }
        .padding(.horizontal, AndonTheme.Metrics.horizontalPadding)
        .frame(height: AndonTheme.Metrics.pillHeight)
    }

    // MARK: - Sessions

    private var sessionList: some View {
        VStack(spacing: 0) {
            Divider().overlay(AndonTheme.hairline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(board.orderedSessions) { session in
                        SessionRowView(session: session, app: app)
                        if session.id != board.orderedSessions.last?.id {
                            Divider()
                                .overlay(AndonTheme.hairline.opacity(0.5))
                                .padding(.leading, AndonTheme.Metrics.horizontalPadding + 16)
                        }
                    }
                }
            }
            // Cap the list so a dozen sessions cannot push the panel off the
            // bottom of the screen; the scroll view takes over past this.
            .frame(maxHeight: 320)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No sessions")
                .font(AndonTheme.body(12, weight: .medium))
                .foregroundStyle(AndonTheme.textSecondary)
            Text("Start Claude Code in any terminal and it will appear here.")
                .font(AndonTheme.body(11))
                .foregroundStyle(AndonTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
    }
}

/// Shown when hooks are missing or the socket did not come up, because the
/// failure mode otherwise is a board that silently stays empty forever.
struct IntegrationWarningView: View {
    let app: AppState

    private var message: String {
        if let error = app.serverError { return error }
        switch app.installStatus {
        case .notInstalled:
            return "Claude Code isn't wired up yet."
        case .drifted(let reason):
            return "Hooks need repair — \(reason)."
        case .settingsUnreadable(let reason):
            return "Can't read settings.json — \(reason)"
        case .installed:
            return ""
        }
    }

    private var canRepair: Bool {
        switch app.installStatus {
        case .notInstalled, .drifted: return true
        case .installed, .settingsUnreadable: return false
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(AndonTheme.amber)

            Text(message)
                .font(AndonTheme.body(11))
                .foregroundStyle(AndonTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if canRepair {
                Button("Repair") { app.installIntegration() }
                    .buttonStyle(AndonButtonStyle(tint: AndonTheme.amber, prominent: true))
            }
        }
        .padding(.horizontal, AndonTheme.Metrics.horizontalPadding)
        .padding(.vertical, 9)
        .background(AndonTheme.amber.opacity(0.09))
        .overlay(alignment: .top) { Divider().overlay(AndonTheme.hairline) }
    }
}
