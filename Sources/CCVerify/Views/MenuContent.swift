import SwiftUI

/// The two run categories the UI splits into: requested reviews vs everything
/// Dependabot-related (Dependabot PR reviews + dependency update scans).
enum RunTab: String, CaseIterable, Identifiable {
    case reviews = "Reviews"
    case dependabot = "Dependabot"

    var id: String { rawValue }

    func matches(_ run: ReviewRun) -> Bool {
        switch self {
        case .reviews: return run.runKind == .review
        case .dependabot: return run.runKind != .review
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var poller: Poller
    @Environment(\.openWindow) private var openWindow
    @State private var tab: RunTab = .reviews

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
            Divider()
            recentRuns
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 340)
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.headline)
            }
            if let running = store.runs.first(where: { $0.status == .running }) {
                liveProgress(for: running)
            }
            if let lastPoll = store.lastPollAt {
                Text("Last poll: \(lastPoll.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Waiting for first poll…").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.lastPollError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private func liveProgress(for run: ReviewRun) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(run.startedAt ?? context.date)
            VStack(alignment: .leading, spacing: 3) {
                if let estimate = store.estimatedDuration(for: run.runKind) {
                    ProgressView(value: min(elapsed / estimate, 1))
                        .controlSize(.small)
                    Text("\(formatDuration(elapsed)) elapsed — ≈\(formatDuration(max(0, estimate - elapsed))) left")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("\(formatDuration(elapsed)) elapsed")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let todos = run.todos, !todos.isEmpty {
                    let done = todos.filter { $0.status == "completed" }.count
                    Text("Checkpoints: \(done)/\(todos.count)"
                        + (todos.first(where: { $0.status == "in_progress" }).map { " — \($0.content)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let action = run.currentAction {
                    Text(action)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return mins > 0 ? "\(mins)m \(String(format: "%02d", secs))s" : "\(secs)s"
    }

    private var statusColor: Color {
        if store.isPaused { return .orange }
        if store.currentActivity != nil { return .blue }
        if store.lastPollError != nil { return .red }
        return .green
    }

    private var statusText: String {
        if let activity = store.currentActivity { return activity }
        if store.isPaused { return "Paused" }
        if store.lastPollError != nil { return "Poll error" }
        return "Watching for review requests"
    }

    private var tabRuns: [ReviewRun] {
        store.runs.filter { tab.matches($0) }
    }

    private var recentRuns: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $tab) {
                ForEach(RunTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            if tab == .dependabot {
                DependencyScanMenu()
                    .controlSize(.small)
                TicketAnalysisMenu()
                    .controlSize(.small)
            }
            if tabRuns.isEmpty {
                Text(tab == .reviews
                    ? "No reviews yet — you'll see them here when someone requests your review."
                    : "No Dependabot activity yet — enable Dependabot reviews or dependency update scans in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tabRuns.prefix(5)) { run in
                    Button {
                        openHistory()
                    } label: {
                        HStack(spacing: 6) {
                            StatusBadge(status: run.status, compact: true)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(run.key).font(.callout).lineLimit(1)
                                    KindIcon(kind: run.runKind)
                                }
                                Text(run.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(run.detectedAt.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("History") { openHistory() }
            Button(store.isPaused ? "Resume" : "Pause") { store.isPaused.toggle() }
            Button("Poll now") { Task { await poller.tick(force: true) } }
                .disabled(poller.isBusy)
            Spacer()
            Button {
                store.showingSettings = true
                openHistory()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings (⌘, in the app)")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit CCVerify")
        }
        .controlSize(.small)
    }

    private func openHistory() {
        openWindow(id: "history")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// On-demand trigger for the dependency update scan (/update-dependencies):
/// one configured repo → a plain button, several → a menu, none → a hint.
/// Works regardless of the automatic schedule toggle.
struct DependencyScanMenu: View {
    @EnvironmentObject var poller: Poller
    // @AppStorage (not a static AppSettings read) so the button updates the
    // moment repos are picked in Settings.
    @AppStorage(AppSettings.Keys.depUpdateRepos) private var depUpdateReposRaw = ""

    var body: some View {
        let repos = AppSettings.repoList(depUpdateReposRaw)
        if repos.isEmpty {
            Text("Add repos under Settings → Updates to scan for safe upgrades.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if repos.count == 1 {
            Button {
                poller.scanDependencies(repos[0])
            } label: {
                Label("Scan \(repos[0]) for updates", systemImage: "arrow.up.square")
            }
            .disabled(poller.isBusy)
            .help("Run /update-dependencies --auto now: find outdated packages and vulnerabilities, verify safe bumps, open a PR + Jira ticket if everything passes.")
        } else {
            Menu {
                ForEach(repos, id: \.self) { repo in
                    Button(repo) { poller.scanDependencies(repo) }
                }
            } label: {
                Label("Scan for updates", systemImage: "arrow.up.square")
            }
            .disabled(poller.isBusy)
            .help("Run /update-dependencies --auto for a repo now: find outdated packages and vulnerabilities, verify safe bumps, open a PR + Jira ticket if everything passes.")
        }
    }
}

/// On-demand trigger for the dep-major ticket deep-dive (/analyze-dep-tickets):
/// one configured repo → a plain button, several → a menu, none → nothing
/// (the Settings tab explains the feature; no second hint needed here).
/// Works regardless of the automatic schedule toggle.
struct TicketAnalysisMenu: View {
    @EnvironmentObject var poller: Poller
    // @AppStorage (not a static AppSettings read) so the button updates the
    // moment repos are picked in Settings.
    @AppStorage(AppSettings.Keys.ticketAnalysisRepos) private var ticketAnalysisReposRaw = ""

    var body: some View {
        let repos = AppSettings.repoList(ticketAnalysisReposRaw)
        if repos.count == 1 {
            Button {
                poller.analyzeTickets(repos[0])
            } label: {
                Label("Analyze \(repos[0]) major tickets", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(poller.isBusy)
            .help("Run /analyze-dep-tickets --auto now: deep-dive open dep-major Jira tickets, post the analysis as a comment, open a PR when the upgrade proves safe.")
        } else if repos.count > 1 {
            Menu {
                ForEach(repos, id: \.self) { repo in
                    Button(repo) { poller.analyzeTickets(repo) }
                }
            } label: {
                Label("Analyze major tickets", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(poller.isBusy)
            .help("Run /analyze-dep-tickets --auto for a repo now: deep-dive open dep-major Jira tickets, post the analysis as a comment, open a PR when the upgrade proves safe.")
        }
    }
}

/// Small marker distinguishing dependabot reviews and dependency scans from
/// ordinary requested reviews (which get no icon — they're the common case).
struct KindIcon: View {
    let kind: ReviewRun.Kind

    var body: some View {
        switch kind {
        case .review:
            EmptyView()
        case .dependabot:
            Image(systemName: "shippingbox")
                .font(.caption2).foregroundStyle(.secondary)
                .help("Dependabot PR review")
        case .dependencyUpdate:
            Image(systemName: "arrow.up.square")
                .font(.caption2).foregroundStyle(.secondary)
                .help("Dependency update scan")
        case .ticketAnalysis:
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption2).foregroundStyle(.secondary)
                .help("Major ticket deep-dive")
        }
    }
}

struct StatusBadge: View {
    let status: ReviewRun.Status
    var compact = false

    var color: Color {
        switch status {
        case .done: return .green
        case .running, .queued: return .blue
        case .failed, .timedOut: return .red
        case .noLocalRepo: return .orange
        }
    }

    var body: some View {
        if compact {
            Circle().fill(color).frame(width: 8, height: 8)
        } else {
            Text(status.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
    }
}
