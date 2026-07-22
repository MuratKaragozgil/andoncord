import AndonKit
import AppKit
import SwiftUI

struct SettingsView: View {
    let app: AppState

    @State private var confirmingRemoval = false
    @State private var lastBackup: URL?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                integrationSection
                behaviourSection
                soundSection
                aboutSection
            }
            .padding(20)
        }
        .background(AndonTheme.void)
        .frame(minWidth: 460, minHeight: 540)
        .onAppear { app.refreshInstallStatus() }
    }

    // MARK: - Integration

    private var integrationSection: some View {
        section("Claude Code") {
            HStack(spacing: 8) {
                Circle()
                    .fill(app.isIntegrationHealthy ? AndonTheme.green : AndonTheme.amber)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(AndonTheme.body(12))
                    .foregroundStyle(AndonTheme.textPrimary)
                Spacer()
            }

            if let serverError = app.serverError {
                Text(serverError)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if app.isIntegrationHealthy {
                    Button("Reinstall hooks") { install() }
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
                    Button("Remove") { confirmingRemoval = true }
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.red))
                } else {
                    Button("Set up") { install() }
                        .buttonStyle(AndonButtonStyle(tint: AndonTheme.accent, prominent: true))
                }
                Spacer()
                Button("Reveal backups") {
                    NSWorkspace.shared.selectFile(
                        lastBackup?.path, inFileViewerRootedAtPath: Paths.backups.path)
                }
                .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
            }

            if let actionError {
                Text(actionError)
                    .font(AndonTheme.body(11))
                    .foregroundStyle(AndonTheme.red)
            }

            Text("Hooks are added alongside anything already in settings.json. "
                 + "Removing puts the file back the way it was, including any statusline "
                 + "that was there before.")
                .font(AndonTheme.body(10))
                .foregroundStyle(AndonTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("Remove Andon Cord's hooks?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("Claude Code will stop reporting to the board. Your settings.json is "
                 + "backed up first, and other tools' hooks are left untouched.")
        }
    }

    private var statusText: String {
        switch app.installStatus {
        case .installed:
            return app.serverError == nil ? "Connected" : "Hooks installed, socket not listening"
        case .notInstalled: return "Not set up"
        case .drifted(let reason): return "Needs repair — \(reason)"
        case .settingsUnreadable(let reason): return "Can't read settings.json — \(reason)"
        }
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        section("Behaviour") {
            toggle("Open automatically when a cord is pulled",
                   detail: "Expands the panel the moment a session needs you.",
                   value: Binding(get: { app.settings.autoExpandOnCord },
                                  set: { app.settings.autoExpandOnCord = $0 }))
            toggle("Hide when nothing is running",
                   detail: "Keeps the notch looking stock while you're not using Claude Code.",
                   value: Binding(get: { app.settings.hideWhenIdle },
                                  set: { app.settings.hideWhenIdle = $0 }))
            toggle("Show usage limits",
                   detail: "Reads the 5-hour and weekly windows from Claude Code's statusline.",
                   value: Binding(get: { app.settings.showUsage },
                                  set: { app.settings.showUsage = $0 }))
            toggle("Launch at login",
                   detail: nil,
                   value: Binding(get: { app.settings.launchAtLogin },
                                  set: { app.settings.launchAtLogin = $0 }))
        }
    }

    // MARK: - Sound

    private var soundSection: some View {
        section("Sound") {
            toggle("Play sounds",
                   detail: nil,
                   value: Binding(get: { app.settings.soundsEnabled },
                                  set: { app.settings.soundsEnabled = $0 }))

            HStack(spacing: 10) {
                Text("Volume")
                    .font(AndonTheme.body(12))
                    .foregroundStyle(AndonTheme.textSecondary)
                Slider(
                    value: Binding(get: { app.settings.volume },
                                   set: { app.settings.volume = $0 }),
                    in: 0...1)
                .controlSize(.small)
            }
            .disabled(!app.settings.soundsEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(AndonTheme.label(10))
                    .foregroundStyle(AndonTheme.textTertiary)
                // A wrapping row of every cue, so someone can learn the
                // vocabulary here rather than by guessing during a work session.
                FlowRow(spacing: 5) {
                    ForEach(BoardSound.allCases, id: \.self) { sound in
                        Button(Self.soundLabel(sound)) { app.previewSound(sound) }
                            .buttonStyle(AndonButtonStyle(tint: AndonTheme.textSecondary))
                    }
                }
            }

            Text("Drop a .wav or .mp3 named after any event into ~/.andoncord/sounds "
                 + "to replace it.")
                .font(AndonTheme.body(10))
                .foregroundStyle(AndonTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func soundLabel(_ sound: BoardSound) -> String {
        switch sound {
        case .sessionStart: return "Session start"
        case .cordPulled: return "Cord pulled"
        case .question: return "Question"
        case .planReview: return "Plan"
        case .cleared: return "Cleared"
        case .denied: return "Denied"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        section("About") {
            Text("Andon Cord watches Claude Code sessions and lets you answer them "
                 + "from the notch. Everything runs locally — no account, no server, "
                 + "no telemetry.")
                .font(AndonTheme.body(11))
                .foregroundStyle(AndonTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Named for the cord on a factory line that any worker can pull to stop "
                 + "production and ask for help.")
                .font(AndonTheme.body(10))
                .foregroundStyle(AndonTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Building blocks

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(AndonTheme.label(10))
                .tracking(1)
                .foregroundStyle(AndonTheme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AndonTheme.surface)
        }
    }

    private func toggle(
        _ title: String, detail: String?, value: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: value) {
                Text(title)
                    .font(AndonTheme.body(12))
                    .foregroundStyle(AndonTheme.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(AndonTheme.accent)

            if let detail {
                Text(detail)
                    .font(AndonTheme.body(10))
                    .foregroundStyle(AndonTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func install() {
        actionError = nil
        switch app.installIntegration() {
        case .success(let report): lastBackup = report.backupURL
        case .failure(let error): actionError = error.localizedDescription
        }
    }

    private func remove() {
        actionError = nil
        switch app.removeIntegration() {
        case .success(let backup): lastBackup = backup
        case .failure(let error): actionError = error.localizedDescription
        }
    }
}

/// Wrapping horizontal stack.
///
/// `LazyVGrid` needs a fixed column count, which looks wrong for chips of
/// varying width; this places them left to right and wraps on overflow.
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        Layout(spacing: spacing) { content }
    }

    private struct Layout: SwiftUI.Layout {
        var spacing: CGFloat

        func sizeThatFits(
            proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) -> CGSize {
            let maxWidth = proposal.width ?? .infinity
            var rows: CGFloat = 1
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            var total: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > 0, x + size.width > maxWidth {
                    total += rowHeight + spacing
                    rows += 1
                    x = 0
                    rowHeight = 0
                }
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: total + rowHeight)
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            var x = bounds.minX
            var y = bounds.minY
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > bounds.minX, x + size.width > bounds.maxX {
                    y += rowHeight + spacing
                    x = bounds.minX
                    rowHeight = 0
                }
                subview.place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
    }
}
