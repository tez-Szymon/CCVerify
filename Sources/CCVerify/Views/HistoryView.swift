import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var poller: Poller
    @State private var selectedID: ReviewRun.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(store.runs) { run in
                    RunRow(run: run)
                        .tag(run.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.delete(run) }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .overlay {
                if store.runs.isEmpty {
                    ContentUnavailableView(
                        "No reviews yet",
                        systemImage: "checkmark.seal",
                        description: Text("When someone requests your review on a PR, it will show up here."))
                }
            }
        } detail: {
            if let run = store.runs.first(where: { $0.id == selectedID }) {
                RunDetailView(run: run)
            } else {
                ContentUnavailableView("Select a review", systemImage: "sidebar.left")
            }
        }
        .navigationTitle("CCVerify History")
    }
}

private struct RunRow: View {
    let run: ReviewRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(run.key).font(.callout.weight(.semibold)).lineLimit(1)
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
                    Text(run.key).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: run.status)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    label("Detected")
                    Text(run.detectedAt.formatted(date: .abbreviated, time: .standard))
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
                Button("Open PR") {
                    if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
                }
                if let reportPath = run.reportPath, FileManager.default.fileExists(atPath: reportPath) {
                    Button("Reveal Report") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reportPath)])
                    }
                }
                Button("Re-run Review") { poller.rerun(run) }
                    .disabled(poller.isBusy)
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
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Claude is reviewing this PR…")
                }
            } else if reportText.isEmpty {
                ContentUnavailableView(
                    "No report", systemImage: "doc.text",
                    description: Text("This run produced no report."))
            } else {
                ScrollView {
                    Text(reportText)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
