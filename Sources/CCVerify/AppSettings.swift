import Foundation

/// All user-tunable settings, backed by UserDefaults (edited via SettingsView).
enum AppSettings {
    // Write + the gh pr review/comment commands exist for /review-pr --publish:
    // it writes review payload files to the scratchpad and posts the verdict.
    static let defaultAllowedTools = [
        "Read", "Grep", "Glob", "Task", "Agent", "TodoWrite", "WebFetch", "WebSearch", "Write",
        "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)",
        "Bash(gh pr review:*)", "Bash(gh pr comment:*)", "Bash(gh repo view:*)",
        "Bash(gh api:*)", "Bash(gh search:*)",
        "Bash(git log:*)", "Bash(git show:*)", "Bash(git diff:*)",
        "Bash(git fetch:*)", "Bash(git branch:*)", "Bash(git status:*)",
    ].joined(separator: ",")

    // /review-dependabot-pr --auto additionally needs: an isolated worktree for
    // FULL_CHECKS verification, package-manager runs inside it, and the
    // Atlassian MCP comment tools (available where the repo configures them).
    static let defaultDependabotAllowedTools = [
        defaultAllowedTools,
        "Bash(gh pr list:*)", "Bash(git worktree:*)", "Bash(git rev-list:*)",
        "Bash(yarn:*)", "Bash(npm:*)", "Bash(pnpm:*)", "Bash(npx:*)", "Bash(dotnet:*)",
        "mcp__atlassian__addCommentToJiraIssue", "mcp__atlassian__getJiraIssue",
    ].joined(separator: ",")

    // /update-dependencies --auto works in a throwaway worktree but must be able
    // to edit manifests, commit, push its own branch, open a PR, and file a Jira
    // ticket. It never pushes to existing branches (enforced by the command).
    // Step 8 (major backlog tickets) additionally dedupes via JQL, comments on
    // existing tickets, and clears their dep-analyzed label on version drift.
    static let defaultDepUpdateAllowedTools = [
        defaultAllowedTools,
        "Edit",
        "Bash(gh pr list:*)", "Bash(gh pr create:*)",
        "Bash(git worktree:*)", "Bash(git rev-list:*)", "Bash(git add:*)",
        "Bash(git commit:*)", "Bash(git push origin deps/:*)", "Bash(git checkout:*)",
        "Bash(yarn:*)", "Bash(npm:*)", "Bash(pnpm:*)", "Bash(npx:*)", "Bash(dotnet:*)",
        "mcp__atlassian__createJiraIssue", "mcp__atlassian__getVisibleJiraProjects",
        "mcp__atlassian__getJiraProjectIssueTypesMetadata",
        "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__addCommentToJiraIssue",
        "mcp__atlassian__editJiraIssue",
    ].joined(separator: ",")

    // /analyze-dep-tickets --auto deep-dives dep-major Jira tickets: JQL
    // discovery, ticket read/comment/label, trial upgrade in a throwaway
    // worktree, and — on a SAFE verdict — a deps/major-* branch + PR.
    static let defaultTicketAnalysisAllowedTools = [
        defaultAllowedTools,
        "Edit",
        "Bash(gh pr list:*)", "Bash(gh pr create:*)",
        "Bash(git worktree:*)", "Bash(git rev-list:*)", "Bash(git add:*)",
        "Bash(git commit:*)", "Bash(git push origin deps/:*)", "Bash(git checkout:*)",
        "Bash(yarn:*)", "Bash(npm:*)", "Bash(pnpm:*)", "Bash(npx:*)", "Bash(dotnet:*)",
        "mcp__atlassian__searchJiraIssuesUsingJql", "mcp__atlassian__getJiraIssue",
        "mcp__atlassian__addCommentToJiraIssue", "mcp__atlassian__editJiraIssue",
    ].joined(separator: ",")

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.pollIntervalSecs: 120,
            Keys.maxConcurrentRuns: 3,
            Keys.reposDir: ("~/Documents/Repos" as NSString).expandingTildeInPath,
            Keys.ghPath: "/opt/homebrew/bin/gh",
            Keys.claudePath: ("~/.local/bin/claude" as NSString).expandingTildeInPath,
            Keys.promptTemplate: "/review-pr {url} --publish",
            Keys.allowedTools: defaultAllowedTools,
            Keys.reviewTimeoutSecs: 2400,
            Keys.includeDrafts: false,
            Keys.notify: true,
            Keys.dependabotEnabled: false,
            Keys.dependabotRepos: "",
            Keys.dependabotPromptTemplate: "/review-dependabot-pr {number} --auto",
            Keys.dependabotAllowedTools: defaultDependabotAllowedTools,
            Keys.depUpdateEnabled: false,
            Keys.depUpdateRepos: "",
            Keys.depUpdateIntervalHours: 24,
            Keys.depUpdatePromptTemplate: "/update-dependencies --auto",
            Keys.depUpdateAllowedTools: defaultDepUpdateAllowedTools,
            Keys.ticketAnalysisEnabled: false,
            Keys.ticketAnalysisRepos: "",
            Keys.ticketAnalysisIntervalHours: 24,
            Keys.ticketAnalysisPromptTemplate: "/analyze-dep-tickets --auto",
            Keys.ticketAnalysisAllowedTools: defaultTicketAnalysisAllowedTools,
        ])
    }

    enum Keys {
        static let pollIntervalSecs = "pollIntervalSecs"
        static let maxConcurrentRuns = "maxConcurrentRuns"
        static let reposDir = "reposDir"
        static let ghPath = "ghPath"
        static let claudePath = "claudePath"
        static let promptTemplate = "promptTemplate"
        static let allowedTools = "allowedTools"
        static let reviewTimeoutSecs = "reviewTimeoutSecs"
        static let includeDrafts = "includeDrafts"
        static let notify = "notify"
        static let dependabotEnabled = "dependabotEnabled"
        static let dependabotRepos = "dependabotRepos"
        static let dependabotPromptTemplate = "dependabotPromptTemplate"
        static let dependabotAllowedTools = "dependabotAllowedTools"
        static let depUpdateEnabled = "depUpdateEnabled"
        static let depUpdateRepos = "depUpdateRepos"
        static let depUpdateIntervalHours = "depUpdateIntervalHours"
        static let depUpdatePromptTemplate = "depUpdatePromptTemplate"
        static let depUpdateAllowedTools = "depUpdateAllowedTools"
        static let ticketAnalysisEnabled = "ticketAnalysisEnabled"
        static let ticketAnalysisRepos = "ticketAnalysisRepos"
        static let ticketAnalysisIntervalHours = "ticketAnalysisIntervalHours"
        static let ticketAnalysisPromptTemplate = "ticketAnalysisPromptTemplate"
        static let ticketAnalysisAllowedTools = "ticketAnalysisAllowedTools"
    }

    private static var d: UserDefaults { .standard }

    static var pollIntervalSecs: Int { max(30, d.integer(forKey: Keys.pollIntervalSecs)) }
    static var maxConcurrentRuns: Int { max(1, d.integer(forKey: Keys.maxConcurrentRuns)) }
    static var reposDir: String { d.string(forKey: Keys.reposDir) ?? "" }
    static var ghPath: String { d.string(forKey: Keys.ghPath) ?? "/opt/homebrew/bin/gh" }
    static var claudePath: String { d.string(forKey: Keys.claudePath) ?? "" }
    static var promptTemplate: String { d.string(forKey: Keys.promptTemplate) ?? "/review-pr {url} --publish" }
    static var allowedTools: String { d.string(forKey: Keys.allowedTools) ?? defaultAllowedTools }
    static var reviewTimeoutSecs: Int { max(60, d.integer(forKey: Keys.reviewTimeoutSecs)) }
    static var includeDrafts: Bool { d.bool(forKey: Keys.includeDrafts) }
    static var notify: Bool { d.bool(forKey: Keys.notify) }

    static var dependabotEnabled: Bool { d.bool(forKey: Keys.dependabotEnabled) }
    static var dependabotRepos: [String] { repoList(d.string(forKey: Keys.dependabotRepos) ?? "") }
    static var dependabotPromptTemplate: String {
        d.string(forKey: Keys.dependabotPromptTemplate) ?? "/review-dependabot-pr {number} --auto"
    }
    static var dependabotAllowedTools: String {
        d.string(forKey: Keys.dependabotAllowedTools) ?? defaultDependabotAllowedTools
    }

    static var depUpdateEnabled: Bool { d.bool(forKey: Keys.depUpdateEnabled) }
    static var depUpdateRepos: [String] { repoList(d.string(forKey: Keys.depUpdateRepos) ?? "") }
    static var depUpdateIntervalHours: Int { max(1, d.integer(forKey: Keys.depUpdateIntervalHours)) }
    static var depUpdatePromptTemplate: String {
        d.string(forKey: Keys.depUpdatePromptTemplate) ?? "/update-dependencies --auto"
    }
    static var depUpdateAllowedTools: String {
        d.string(forKey: Keys.depUpdateAllowedTools) ?? defaultDepUpdateAllowedTools
    }

    static var ticketAnalysisEnabled: Bool { d.bool(forKey: Keys.ticketAnalysisEnabled) }
    static var ticketAnalysisRepos: [String] { repoList(d.string(forKey: Keys.ticketAnalysisRepos) ?? "") }
    static var ticketAnalysisIntervalHours: Int { max(1, d.integer(forKey: Keys.ticketAnalysisIntervalHours)) }
    static var ticketAnalysisPromptTemplate: String {
        d.string(forKey: Keys.ticketAnalysisPromptTemplate) ?? "/analyze-dep-tickets --auto"
    }
    static var ticketAnalysisAllowedTools: String {
        d.string(forKey: Keys.ticketAnalysisAllowedTools) ?? defaultTicketAnalysisAllowedTools
    }

    /// Parse a user-entered repo list ("owner/repo, owner/repo2" or one per line).
    static func repoList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { ", \n\t".contains($0) })
            .map { String($0) }
            .filter { $0.contains("/") }
    }
}
