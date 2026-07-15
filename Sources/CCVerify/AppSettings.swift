import Foundation

/// All user-tunable settings, backed by UserDefaults (edited via SettingsView).
enum AppSettings {
    static let defaultAllowedTools = [
        "Read", "Grep", "Glob", "Task", "Agent", "TodoWrite", "WebFetch", "WebSearch",
        "Bash(gh pr view:*)", "Bash(gh pr diff:*)", "Bash(gh pr checks:*)",
        "Bash(gh api:*)", "Bash(gh search:*)",
        "Bash(git log:*)", "Bash(git show:*)", "Bash(git diff:*)",
        "Bash(git fetch:*)", "Bash(git branch:*)", "Bash(git status:*)",
    ].joined(separator: ",")

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.pollIntervalSecs: 120,
            Keys.reposDir: ("~/Documents/Repos" as NSString).expandingTildeInPath,
            Keys.ghPath: "/opt/homebrew/bin/gh",
            Keys.claudePath: ("~/.local/bin/claude" as NSString).expandingTildeInPath,
            Keys.promptTemplate: "/review-pr {url}",
            Keys.allowedTools: defaultAllowedTools,
            Keys.reviewTimeoutSecs: 2400,
            Keys.includeDrafts: false,
            Keys.notify: true,
        ])
    }

    enum Keys {
        static let pollIntervalSecs = "pollIntervalSecs"
        static let reposDir = "reposDir"
        static let ghPath = "ghPath"
        static let claudePath = "claudePath"
        static let promptTemplate = "promptTemplate"
        static let allowedTools = "allowedTools"
        static let reviewTimeoutSecs = "reviewTimeoutSecs"
        static let includeDrafts = "includeDrafts"
        static let notify = "notify"
    }

    private static var d: UserDefaults { .standard }

    static var pollIntervalSecs: Int { max(30, d.integer(forKey: Keys.pollIntervalSecs)) }
    static var reposDir: String { d.string(forKey: Keys.reposDir) ?? "" }
    static var ghPath: String { d.string(forKey: Keys.ghPath) ?? "/opt/homebrew/bin/gh" }
    static var claudePath: String { d.string(forKey: Keys.claudePath) ?? "" }
    static var promptTemplate: String { d.string(forKey: Keys.promptTemplate) ?? "/review-pr {url}" }
    static var allowedTools: String { d.string(forKey: Keys.allowedTools) ?? defaultAllowedTools }
    static var reviewTimeoutSecs: Int { max(60, d.integer(forKey: Keys.reviewTimeoutSecs)) }
    static var includeDrafts: Bool { d.bool(forKey: Keys.includeDrafts) }
    static var notify: Bool { d.bool(forKey: Keys.notify) }
}
