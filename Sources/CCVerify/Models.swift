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

        var label: String {
            switch self {
            case .review: return "Review"
            case .dependabot: return "Dependabot"
            case .dependencyUpdate: return "Dep update"
            case .ticketAnalysis: return "Ticket deep-dive"
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

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .running: return "Running"
            case .done: return "Done"
            case .failed: return "Failed"
            case .timedOut: return "Timed out"
            case .noLocalRepo: return "No local repo"
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
    // Live progress (from claude's stream-json output)
    var todos: [TodoItem]?
    var currentAction: String?
    var recentActions: [String]?
    var numTurns: Int?
    var costUSD: Double?

    var runKind: Kind { kind ?? .review }

    var key: String {
        switch runKind {
        case .dependencyUpdate: return "\(repo) deps"
        case .ticketAnalysis: return "\(repo) tickets"
        case .review, .dependabot: return "\(repo)#\(prNumber)"
        }
    }

    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
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
