import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var poller: Poller
    @Environment(\.openWindow) private var openWindow

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

    private var recentRuns: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent reviews").font(.caption).foregroundStyle(.secondary)
            if store.runs.isEmpty {
                Text("No reviews yet — you'll see them here when someone requests your review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.runs.prefix(5)) { run in
                    Button {
                        openHistory()
                    } label: {
                        HStack(spacing: 6) {
                            StatusBadge(status: run.status, compact: true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(run.key).font(.callout).lineLimit(1)
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
            SettingsLink { Image(systemName: "gearshape") }
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
