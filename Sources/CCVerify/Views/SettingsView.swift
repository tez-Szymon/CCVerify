import ServiceManagement
import SwiftUI

/// In-window settings shown in place of the run history (no separate modal).
/// Split into tabs so no single form outgrows the screen; each tab is a
/// grouped Form, which scrolls on its own when the window is short.
struct SettingsScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case reviews = "Reviews"
        case myPRs = "My PRs"
        case dependabot = "Dependabot"
        case updates = "Updates"
        case tickets = "Tickets"

        var id: String { rawValue }
    }

    @EnvironmentObject var store: AppStore
    @State private var tab: Tab = .general

    @AppStorage(AppSettings.Keys.pollIntervalSecs) private var pollInterval = 120
    @AppStorage(AppSettings.Keys.maxConcurrentRuns) private var maxConcurrentRuns = 3
    @AppStorage(AppSettings.Keys.reposDir) private var reposDir = ""
    @AppStorage(AppSettings.Keys.ghPath) private var ghPath = ""
    @AppStorage(AppSettings.Keys.claudePath) private var claudePath = ""
    @AppStorage(AppSettings.Keys.promptTemplate) private var promptTemplate = ""
    @AppStorage(AppSettings.Keys.allowedTools) private var allowedTools = ""
    @AppStorage(AppSettings.Keys.reviewTimeoutSecs) private var reviewTimeout = 2400
    @AppStorage(AppSettings.Keys.includeDrafts) private var includeDrafts = false
    @AppStorage(AppSettings.Keys.notify) private var notify = true

    @AppStorage(AppSettings.Keys.prFollowupEnabled) private var prFollowupEnabled = false
    @AppStorage(AppSettings.Keys.prFollowupRepos) private var prFollowupRepos = ""
    @AppStorage(AppSettings.Keys.prFollowupCooldownMins) private var prFollowupCooldownMins = 30
    @AppStorage(AppSettings.Keys.prFollowupPromptTemplate) private var prFollowupPromptTemplate = ""
    @AppStorage(AppSettings.Keys.prFollowupAllowedTools) private var prFollowupAllowedTools = ""

    @AppStorage(AppSettings.Keys.dependabotEnabled) private var dependabotEnabled = false
    @AppStorage(AppSettings.Keys.dependabotRepos) private var dependabotRepos = ""
    @AppStorage(AppSettings.Keys.dependabotPromptTemplate) private var dependabotPromptTemplate = ""
    @AppStorage(AppSettings.Keys.dependabotAllowedTools) private var dependabotAllowedTools = ""

    @AppStorage(AppSettings.Keys.depUpdateEnabled) private var depUpdateEnabled = false
    @AppStorage(AppSettings.Keys.depUpdateRepos) private var depUpdateRepos = ""
    @AppStorage(AppSettings.Keys.depUpdateIntervalHours) private var depUpdateIntervalHours = 24
    @AppStorage(AppSettings.Keys.depUpdatePromptTemplate) private var depUpdatePromptTemplate = ""
    @AppStorage(AppSettings.Keys.depUpdateAllowedTools) private var depUpdateAllowedTools = ""

    @AppStorage(AppSettings.Keys.ticketAnalysisEnabled) private var ticketAnalysisEnabled = false
    @AppStorage(AppSettings.Keys.ticketAnalysisRepos) private var ticketAnalysisRepos = ""
    @AppStorage(AppSettings.Keys.ticketAnalysisIntervalHours) private var ticketAnalysisIntervalHours = 24
    @AppStorage(AppSettings.Keys.ticketAnalysisPromptTemplate) private var ticketAnalysisPromptTemplate = ""
    @AppStorage(AppSettings.Keys.ticketAnalysisAllowedTools) private var ticketAnalysisAllowedTools = ""

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notificationsBlocked = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 720)
            Divider()
            form
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.showingSettings = false
                } label: {
                    Label("History", systemImage: "chevron.left")
                }
                .help("Back to run history")
            }
        }
        .onExitCommand { store.showingSettings = false }
        .navigationTitle("CCVerify Settings")
    }

    @ViewBuilder private var form: some View {
        switch tab {
        case .general: generalForm
        case .reviews: reviewsForm
        case .myPRs: myPRsForm
        case .dependabot: dependabotForm
        case .updates: updatesForm
        case .tickets: ticketsForm
        }
    }

    private var generalForm: some View {
        Form {
            Section("Polling") {
                TextField("Poll interval (seconds)", value: $pollInterval, format: .number)
                TextField("Max parallel agents", value: $maxConcurrentRuns, format: .number)
                    .help("How many claude runs may execute at once; further runs wait in a queue")
                Toggle("Include draft PRs", isOn: $includeDrafts)
                TextField("Repos directory", text: $reposDir)
                    .help("Local checkouts are matched to GitHub repos by their origin remote")
            }

            Section("Binaries") {
                TextField("gh path", text: $ghPath)
                TextField("claude path", text: $claudePath)
            }

            Section("App") {
                Toggle("Notifications", isOn: $notify)
                if notificationsBlocked {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("macOS is blocking them. Allow CCVerify under Notifications.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open System Settings") {
                            Notifier.openSystemNotificationSettings()
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
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
            }
        }
        .formStyle(.grouped)
        // Re-checked on every visit: the permission can be flipped in System
        // Settings while the app is running.
        .task { notificationsBlocked = await Notifier.shared.blockedBySystem() }
    }

    private var reviewsForm: some View {
        Form {
            Section("Requested reviews") {
                TextField("Prompt template", text: $promptTemplate)
                    .help("Placeholders: {url} {repo} {number} {title}")
                TextField("Allowed tools", text: $allowedTools, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.caption)
                    .help("Passed to claude --allowedTools. The defaults cover /review-pr --publish (posting the verdict and comments to the PR).")
                TextField("Review timeout (seconds)", value: $reviewTimeout, format: .number)
                    .help("Applies to all run kinds: reviews, Dependabot reviews, and dependency scans.")
                Button("Reset allowed tools to default") {
                    allowedTools = AppSettings.defaultAllowedTools
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private var myPRsForm: some View {
        Form {
            Section("Follow-ups on your own PRs") {
                Text("Every poll checks your open PRs in the selected repos for things worth acting on: a conflict with the target branch, unresolved review threads (CodeRabbit and humans), a review that requested changes, and failing CI. When something is found — and only then — an agent runs /resolve-pr-feedback: it fixes what's valid in an isolated worktree, pushes to the PR branch, and answers every thread (including \"this doesn't apply, because…\").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Follow up automatically", isOn: $prFollowupEnabled)
            }
            RepoMultiPicker(title: "Watched repos", rawSelection: $prFollowupRepos)
            Section("Pacing") {
                TextField("Min minutes between runs on the same PR", value: $prFollowupCooldownMins, format: .number)
                    .help("A push of ours usually triggers a fresh bot review; the cooldown keeps that from becoming a loop. Unchanged feedback never starts a run at all.")
                Text("At most 3 PRs are picked up per poll — the rest follow on the next ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Advanced") {
                TextField("Prompt template", text: $prFollowupPromptTemplate)
                    .help("Placeholders: {url} {repo} {number} {title} {signals}. --auto = unattended: fixes, pushes and thread replies need no approval.")
                TextField("Allowed tools", text: $prFollowupAllowedTools, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.caption)
                    .help("Adds Edit, worktree + package-manager commands, and push to the PR's own head branch (git push origin HEAD:… only — never force, never another branch).")
                Button("Reset allowed tools to default") {
                    prFollowupAllowedTools = AppSettings.defaultPRFollowupAllowedTools
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private var dependabotForm: some View {
        Form {
            Section("Dependabot PR reviews") {
                Toggle("Review new Dependabot PRs", isOn: $dependabotEnabled)
                    .help("Watches the checked repos for new PRs authored by Dependabot and reviews each one unattended (verdict posted to the PR and its Jira ticket). Existing PRs are baselined, not reviewed.")
            }
            RepoMultiPicker(title: "Watched repos", rawSelection: $dependabotRepos)
            Section("Advanced") {
                TextField("Prompt template", text: $dependabotPromptTemplate)
                    .help("Placeholders: {url} {repo} {number} {title}. --auto = unattended: comments are posted without approval gates.")
                TextField("Allowed tools", text: $dependabotAllowedTools, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.caption)
                    .help("Adds worktree + package-manager commands and the Atlassian Jira comment tools on top of the review defaults.")
                Button("Reset allowed tools to default") {
                    dependabotAllowedTools = AppSettings.defaultDependabotAllowedTools
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private var updatesForm: some View {
        Form {
            RepoMultiPicker(title: "Repos to scan", rawSelection: $depUpdateRepos)
            Section("Schedule") {
                Toggle("Scan automatically", isOn: $depUpdateEnabled)
                    .help("Runs the scan for each checked repo on the interval below. The manual Scan for updates button works even when this is off.")
                if depUpdateEnabled {
                    TextField("Scan interval (hours)", value: $depUpdateIntervalHours, format: .number)
                }
            }
            Section("Advanced") {
                TextField("Prompt template", text: $depUpdatePromptTemplate)
                    .help("Placeholders: {url} {repo} {number} {title}")
                TextField("Allowed tools", text: $depUpdateAllowedTools, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.caption)
                    .help("Adds Edit, commit/push of deps/* branches, gh pr create, and the Atlassian Jira issue-creation tools.")
                Button("Reset allowed tools to default") {
                    depUpdateAllowedTools = AppSettings.defaultDepUpdateAllowedTools
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private var ticketsForm: some View {
        Form {
            Section("Major ticket deep-dives") {
                Text("The dependency scan files Jira backlog tickets (label dep-major) for every major it won't apply. This feature picks those tickets up: it researches the breaking changes, checks the codebase against each one, trial-upgrades in an isolated worktree, posts the analysis as a ticket comment — and opens a PR when the upgrade proves safe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            RepoMultiPicker(title: "Repos whose tickets to analyze", rawSelection: $ticketAnalysisRepos)
            Section("Schedule") {
                Toggle("Analyze automatically", isOn: $ticketAnalysisEnabled)
                    .help("Runs the deep-dive for each checked repo on the interval below (a few tickets per run, oldest first). The manual Analyze tickets button works even when this is off.")
                if ticketAnalysisEnabled {
                    TextField("Analysis interval (hours)", value: $ticketAnalysisIntervalHours, format: .number)
                }
            }
            Section("Advanced") {
                TextField("Prompt template", text: $ticketAnalysisPromptTemplate)
                    .help("Placeholders: {url} {repo} {number} {title}. --auto = unattended: comments, labels, and SAFE-verdict PRs need no approval.")
                TextField("Allowed tools", text: $ticketAnalysisAllowedTools, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.caption)
                    .help("Adds worktree + package-manager commands, deps/* push + gh pr create, and the Atlassian Jira search/read/comment/label tools.")
                Button("Reset allowed tools to default") {
                    ticketAnalysisAllowedTools = AppSettings.defaultTicketAnalysisAllowedTools
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }
}

/// Checkbox list of GitHub repos, fed from the local checkouts under the
/// repos directory (their origin remotes — so entries always have the right
/// owner/repo form). Backing storage stays the comma-separated string, so
/// everything downstream (AppSettings.repoList) is unchanged.
struct RepoMultiPicker: View {
    let title: String
    @Binding var rawSelection: String
    @State private var localRepos: [String] = []

    var body: some View {
        Section(title) {
            let all = allRepos
            if all.isEmpty {
                Text("No GitHub checkouts found under \(AppSettings.reposDir). Clone a repo there, then hit Refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(all, id: \.self) { repo in
                Toggle(repo, isOn: isOn(repo))
            }
            HStack {
                Text("\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { localRepos = Poller.localGitHubRepos() }
                    .controlSize(.small)
                    .help("Re-scan the repos directory for checkouts")
            }
            .onAppear {
                localRepos = Poller.localGitHubRepos()
                migrateBareNames()
            }
        }
    }

    private var selected: [String] { AppSettings.repoList(rawSelection) }

    /// Local checkouts plus anything already selected that isn't cloned here
    /// (so a selection never silently disappears from view).
    private var allRepos: [String] {
        var all = localRepos
        for repo in selected
        where !all.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) {
            all.append(repo)
        }
        return all
    }

    private func isOn(_ repo: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains { $0.caseInsensitiveCompare(repo) == .orderedSame } },
            set: { on in
                var list = selected.filter { $0.caseInsensitiveCompare(repo) != .orderedSame }
                if on { list.append(repo) }
                rawSelection = list.joined(separator: ", ")
            })
    }

    /// Fix up entries saved without an owner (e.g. "text2park.web") by
    /// matching them against a unique local checkout's repo name — earlier
    /// versions accepted the bare form in a text field and silently ignored it.
    private func migrateBareNames() {
        let tokens = rawSelection
            .split(whereSeparator: { ", \n\t".contains($0) })
            .map(String.init)
        guard tokens.contains(where: { !$0.contains("/") }) else { return }
        let fixed = tokens.compactMap { token -> String? in
            if token.contains("/") { return token }
            let matches = localRepos.filter { $0.lowercased().hasSuffix("/" + token.lowercased()) }
            return matches.count == 1 ? matches[0] : nil
        }
        rawSelection = fixed.joined(separator: ", ")
    }
}
