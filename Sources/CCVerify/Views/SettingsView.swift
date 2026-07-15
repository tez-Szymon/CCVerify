import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.Keys.pollIntervalSecs) private var pollInterval = 120
    @AppStorage(AppSettings.Keys.reposDir) private var reposDir = ""
    @AppStorage(AppSettings.Keys.ghPath) private var ghPath = ""
    @AppStorage(AppSettings.Keys.claudePath) private var claudePath = ""
    @AppStorage(AppSettings.Keys.promptTemplate) private var promptTemplate = ""
    @AppStorage(AppSettings.Keys.allowedTools) private var allowedTools = ""
    @AppStorage(AppSettings.Keys.reviewTimeoutSecs) private var reviewTimeout = 2400
    @AppStorage(AppSettings.Keys.includeDrafts) private var includeDrafts = false
    @AppStorage(AppSettings.Keys.notify) private var notify = true

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Polling") {
                TextField("Poll interval (seconds)", value: $pollInterval, format: .number)
                Toggle("Include draft PRs", isOn: $includeDrafts)
                TextField("Repos directory", text: $reposDir)
                    .help("Local checkouts are matched to GitHub repos by their origin remote")
            }

            Section("Review") {
                TextField("Prompt template", text: $promptTemplate)
                    .help("Placeholders: {url} {repo} {number} {title}")
                TextField("Allowed tools", text: $allowedTools, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.caption)
                    .help("Passed to claude --allowedTools. Add Bash(gh pr comment:*) to let reviews post to the PR.")
                TextField("Review timeout (seconds)", value: $reviewTimeout, format: .number)
            }

            Section("Binaries") {
                TextField("gh path", text: $ghPath)
                TextField("claude path", text: $claudePath)
            }

            Section("App") {
                Toggle("Notifications", isOn: $notify)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Button("Reset allowed tools to default") {
                    allowedTools = AppSettings.defaultAllowedTools
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
