import Foundation

struct TodoItem: Codable, Hashable {
    var content: String
    var status: String // pending | in_progress | completed
    var taskID: String? // set when the plan comes from TaskCreate/TaskUpdate
}

struct ReviewRun: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case review
        case dependabot
        case dependencyUpdate
        case ticketAnalysis
        case prFollowup

        var label: String {
            switch self {
            case .review: return "Review"
            case .dependabot: return "Dependabot"
            case .dependencyUpdate: return "Dep update"
            case .ticketAnalysis: return "Ticket deep-dive"
            case .prFollowup: return "PR follow-up"
            }
        }
    }

    enum Status: String, Codable {
        case queued
        case running
        case done
        case failed
        case timedOut
        case noLocalRepo
        case stopped

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .running: return "Running"
            case .done: return "Done"
            case .failed: return "Failed"
            case .timedOut: return "Timed out"
            case .noLocalRepo: return "No local repo"
            case .stopped: return "Stopped"
            }
        }
    }

    var id = UUID()
    var repo: String
    var prNumber: Int
    var title: String
    var url: String
    // Optional so state saved by older app versions still decodes.
    var kind: Kind?
    var status: Status = .queued
    var detectedAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var exitCode: Int32?
    var reportPath: String?
    var localRepoPath: String?
    var errorMessage: String?
    /// Why this run was started, when the trigger isn't obvious from the kind
    /// (PR follow-ups: the signals found on the PR). Also fills {signals}.
    var triggerSummary: String?
    // Live progress (from claude's stream-json output)
    var todos: [TodoItem]?
    var currentAction: String?
    var recentActions: [String]?
    var numTurns: Int?
    var costUSD: Double?
    /// Models the agent ran on: the session's own model first (from the
    /// stream's init event), then any others the run's subagents used (from
    /// the final result event's per-model usage).
    var models: [String]?

    var runKind: Kind { kind ?? .review }

    /// Queued or executing — i.e. there is something for Stop to act on.
    var isStoppable: Bool { status == .queued || status == .running }

    var key: String { Self.key(kind: runKind, repo: repo, prNumber: prNumber) }

    /// Also built standalone (before a run exists) to check whether the same
    /// work is already queued or executing.
    static func key(kind: Kind, repo: String, prNumber: Int) -> String {
        switch kind {
        case .dependencyUpdate: return "\(repo) deps"
        case .ticketAnalysis: return "\(repo) tickets"
        // Distinct from a review of the same PR: our own PR can be both
        // reviewed by us (never) and followed up on, and the two must not
        // dedupe against each other.
        case .prFollowup: return "\(repo)#\(prNumber) follow-up"
        case .review, .dependabot: return "\(repo)#\(prNumber)"
        }
    }

    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    /// Models joined for display; nil for runs from before this was recorded.
    var modelText: String? {
        guard let models, !models.isEmpty else { return nil }
        return models.joined(separator: ", ")
    }

    var durationText: String? {
        guard let duration else { return nil }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}

struct GHPullRequest: Codable {
    var number: Int
    var title: String
    var url: String
    var updatedAt: String

    // Derive owner/repo from the PR URL: https://github.com/OWNER/REPO/pull/N
    var repoFullName: String? {
        guard let comps = URL(string: url)?.pathComponents, comps.count >= 3 else { return nil }
        return "\(comps[1])/\(comps[2])"
    }

    var key: String? { repoFullName.map { "\($0)#\(number)" } }
}

// MARK: - Own-PR follow-up polling

/// Decoded `gh api graphql` payload for the own-PR poll. One query returns
/// everything the triage needs: mergeability, the latest review per author,
/// every review thread with its last few comments, and the check rollup —
/// so the app can decide whether a PR is worth an agent run without spending
/// a single token on the ones that aren't.
struct OwnPRPoll: Codable {
    struct Root: Codable { var data: Payload }

    struct Payload: Codable {
        var viewer: Actor
        var search: Search
    }

    struct Search: Codable { var nodes: [PullRequest] }

    struct Actor: Codable { var login: String? }

    struct PullRequest: Codable {
        var number: Int?
        var title: String?
        var url: String?
        var isDraft: Bool?
        /// MERGEABLE | CONFLICTING | UNKNOWN (UNKNOWN = GitHub is still
        /// computing the merge; never treated as a conflict).
        var mergeable: String?
        var headRefOid: String?
        var baseRef: Ref?
        var repository: Repository?
        var reviewDecision: String?
        var latestReviews: ReviewConnection?
        var reviewThreads: ThreadConnection?
        var commits: CommitConnection?
    }

    struct Ref: Codable {
        var name: String?
        var target: Target?
        struct Target: Codable { var oid: String? }
    }

    struct Repository: Codable { var nameWithOwner: String? }

    struct ReviewConnection: Codable { var nodes: [Review]? }
    struct Review: Codable {
        var id: String?
        var state: String?
        var author: Actor?
    }

    struct ThreadConnection: Codable { var nodes: [Thread]? }
    struct Thread: Codable {
        var id: String?
        var isResolved: Bool?
        var isOutdated: Bool?
        var path: String?
        var comments: CommentConnection?
    }

    struct CommentConnection: Codable { var nodes: [Comment]? }
    struct Comment: Codable {
        var id: String?
        var author: Actor?
    }

    struct CommitConnection: Codable { var nodes: [CommitNode]? }
    struct CommitNode: Codable {
        var commit: Commit?
        struct Commit: Codable {
            var statusCheckRollup: Rollup?
            struct Rollup: Codable { var state: String? }
        }
    }
}

/// One PR the poll found worth acting on, with the reason(s) why.
struct OwnPRCandidate {
    var repo: String
    var number: Int
    var title: String
    var url: String
    /// Stable per-signal tokens; the fingerprint is derived from these, so a
    /// PR is re-run only when the actual feedback changes — not on every poll.
    var signalTokens: [String]
    /// Human-readable version of the same signals (history + {signals}).
    var summary: String

    var fingerprint: String { Self.fingerprint(of: signalTokens) }

    /// FNV-1a over the sorted tokens. Swift's own `hashValue` is seeded per
    /// process, so it can't be persisted across app launches.
    static func fingerprint(of tokens: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in tokens.sorted().joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
