import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var poller: Poller
    @State private var tab: RunTab = .reviews

    private var tabRuns: [ReviewRun] {
        store.runs.filter { tab.matches($0) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(RunTab.allCases) { tab in
                        Text(label(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
                List(selection: $store.selectedRunID) {
                    ForEach(tabRuns) { run in
                        RunRow(run: run)
                            .tag(run.id)
                            .contextMenu {
                                if run.isStoppable {
                                    Button("Stop", role: .destructive) { poller.stop(run) }
                                }
                                Button("Delete", role: .destructive) { store.delete(run) }
                            }
                    }
                }
                .overlay {
                    if tabRuns.isEmpty {
                        emptyState
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let run = store.runs.first(where: { $0.id == store.selectedRunID }) {
                RunDetailView(run: run)
            } else {
                ContentUnavailableView("Select a run", systemImage: "sidebar.left")
            }
        }
        .navigationTitle("CCVerify History")
        .toolbar {
            if tab == .dependabot {
                DependencyScanMenu()
            }
            if poller.hasStoppableRuns {
                Button(role: .destructive) {
                    poller.stopAll()
                } label: {
                    Label("Stop All", systemImage: "stop.circle")
                }
                .help("Stop every queued and running agent (⌘.)")
            }
            Button {
                store.showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Open Settings (⌘,)")
        }
        // Keep the selection in whichever tab the user is looking at.
        .onChange(of: tab) { _, newTab in
            if let id = store.selectedRunID, let run = store.runs.first(where: { $0.id == id }),
               !newTab.matches(run) {
                store.selectedRunID = nil
            }
        }
        // A run selected from elsewhere — a clicked notification, a menu-bar
        // row — may live under another tab; follow it there. Also on appear,
        // for a click that reopened this window.
        .onChange(of: store.selectedRunID) { _, _ in showSelectedRunsTab() }
        .onAppear { showSelectedRunsTab() }
    }

    private func showSelectedRunsTab() {
        guard let id = store.selectedRunID,
              let run = store.runs.first(where: { $0.id == id })
        else { return }
        tab = RunTab.tab(for: run)
    }

    private func label(for tab: RunTab) -> String {
        let count = store.runs.lazy.filter { tab.matches($0) }.count
        return count > 0 ? "\(tab.rawValue) (\(count))" : tab.rawValue
    }

    private var emptyState: some View {
        Group {
            switch tab {
            case .reviews:
                ContentUnavailableView(
                    "No reviews yet",
                    systemImage: "checkmark.seal",
                    description: Text("When someone requests your review on a PR, it will show up here."))
            case .myPRs:
                ContentUnavailableView(
                    "No PR follow-ups yet",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Enable PR follow-ups in Settings: your own open PRs get checked for conflicts, unresolved review threads, requested changes and red CI."))
            case .dependabot:
                ContentUnavailableView(
                    "No Dependabot activity yet",
                    systemImage: "shippingbox",
                    description: Text("Enable Dependabot reviews or dependency update scans in Settings to see runs here."))
            }
        }
    }
}

private struct RunRow: View {
    let run: ReviewRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(run.key).font(.callout.weight(.semibold)).lineLimit(1)
                KindIcon(kind: run.runKind)
                Spacer()
                StatusBadge(status: run.status)
            }
            Text(run.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(run.detectedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct RunDetailView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var poller: Poller
    let run: ReviewRun
    @State private var reportText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            reportView
        }
        .task(id: taskKey) { loadReport() }
    }

    // Reload when selection changes or when this run finishes.
    private var taskKey: String { "\(run.id)-\(run.status.rawValue)" }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(run.key).font(.callout).foregroundStyle(.secondary)
                        if run.runKind != .review {
                            Text(run.runKind.label)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                Spacer()
                StatusBadge(status: run.status)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    label("Detected")
                    Text(run.detectedAt.formatted(date: .abbreviated, time: .standard))
                }
                if let trigger = run.triggerSummary {
                    GridRow {
                        label("Triggered by")
                        Text(trigger)
                    }
                }
                if let started = run.startedAt {
                    GridRow {
                        label("Started")
                        Text(started.formatted(date: .abbreviated, time: .standard))
                    }
                }
                if let duration = run.durationText {
                    GridRow {
                        label("Duration")
                        Text(duration)
                    }
                }
                if let exitCode = run.exitCode, run.status != .done {
                    GridRow {
                        label("Exit code")
                        Text(String(exitCode))
                    }
                }
                if let turns = run.numTurns {
                    GridRow {
                        label("Turns")
                        Text(String(turns))
                    }
                }
                if let cost = run.costUSD {
                    GridRow {
                        label("Est. cost")
                        Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                    }
                }
                if let localPath = run.localRepoPath {
                    GridRow {
                        label("Local repo")
                        Text(localPath).textSelection(.enabled)
                    }
                }
            }
            .font(.caption)

            if let error = run.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button(run.prNumber == 0 ? "Open Repo" : "Open PR") {
                    if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
                }
                if let reportPath = run.reportPath, FileManager.default.fileExists(atPath: reportPath) {
                    Button("Reveal Report") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reportPath)])
                    }
                }
                if run.isStoppable {
                    Button("Stop", role: .destructive) { poller.stop(run) }
                        .help(run.status == .queued
                            ? "Drop this run from the queue — it never starts."
                            : "Terminate the agent running this \(run.runKind.label.lowercased()).")
                } else {
                    Button("Re-run Review") { poller.rerun(run) }
                        .disabled(poller.isActive(key: run.key))
                }
            }
            .controlSize(.small)
        }
        .padding()
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private var reportView: some View {
        Group {
            if run.status == .running {
                ScrollView {
                    LiveProgressView(run: run)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if reportText.isEmpty {
                ContentUnavailableView(
                    "No report", systemImage: "doc.text",
                    description: Text("This run produced no report."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let todos = run.todos, !todos.isEmpty {
                            DisclosureGroup {
                                TodoListView(todos: todos).padding(.top, 4)
                            } label: {
                                let done = todos.filter { $0.status == "completed" }.count
                                Text("Checkpoints (\(done)/\(todos.count))").font(.callout.weight(.medium))
                            }
                        }
                        Text(reportText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadReport() {
        guard let reportPath = run.reportPath,
              let text = try? String(contentsOfFile: reportPath, encoding: .utf8)
        else {
            reportText = ""
            return
        }
        reportText = text
    }
}

/// Live progress for a running review: elapsed + ETA, current action,
/// the plan checkpoints claude maintains, and a recent-activity feed.
struct LiveProgressView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var poller: Poller
    let run: ReviewRun

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = context.date.timeIntervalSince(run.startedAt ?? context.date)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let estimate = store.estimatedDuration(for: run.runKind) {
                            ProgressView(value: min(elapsed / estimate, 1))
                            Text(etaText(elapsed: elapsed, estimate: estimate))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                            Text("Elapsed \(format(elapsed)) — no estimate yet (first review)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        poller.stop(run)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                    .help("Terminate this agent now. Whatever it produced so far is kept.")
                }
            }

            if let action = run.currentAction {
                Label {
                    Text(action).font(.system(.caption, design: .monospaced)).lineLimit(2)
                } icon: {
                    Image(systemName: "terminal")
                }
                .foregroundStyle(.secondary)
            }

            if let todos = run.todos, !todos.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Plan").font(.callout.weight(.medium))
                    TodoListView(todos: todos)
                }
            }

            if let actions = run.recentActions, !actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent activity").font(.callout.weight(.medium))
                    ForEach(Array(actions.suffix(12).enumerated()), id: \.offset) { _, action in
                        Text(action)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func etaText(elapsed: TimeInterval, estimate: TimeInterval) -> String {
        if elapsed < estimate {
            let remaining = estimate - elapsed
            return "Elapsed \(format(elapsed)) — ≈\(format(remaining)) remaining (median of past reviews)"
        }
        return "Elapsed \(format(elapsed)) — taking longer than usual (typical: \(format(estimate)))"
    }

    private func format(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return mins > 0 ? "\(mins)m \(String(format: "%02d", secs))s" : "\(secs)s"
    }
}

struct TodoListView: View {
    let todos: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(for: todo.status))
                        .foregroundStyle(color(for: todo.status))
                        .font(.caption)
                    Text(todo.content)
                        .font(.caption)
                        .strikethrough(todo.status == "completed", color: .secondary)
                        .foregroundStyle(todo.status == "completed" ? .secondary : .primary)
                }
            }
        }
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "arrow.triangle.2.circlepath.circle.fill"
        default: return "circle"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "in_progress": return .blue
        default: return .secondary
        }
    }
}
