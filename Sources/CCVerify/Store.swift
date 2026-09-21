import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var runs: [ReviewRun] = []
    @Published var seen: [String: String] = [:]
    @Published var hasBaselined = false
    // Keys present in the last successful review-request poll. A seen PR that
    // reappears here after being absent means its review was re-requested.
    // nil = never recorded (state from an older app version): the next poll
    // records the set without treating anything as renewed.
    @Published var openReviewRequests: Set<String>?
    // Repos whose pre-existing Dependabot PR backlog has been marked seen
    // (baselined per repo, so repos added to the watch list later get their
    // own baseline instead of a review storm).
    @Published var dependabotBaselined: Set<String> = []
    // Last dependency-update scan per repo (owner/repo → date).
    @Published var depUpdateLastRun: [String: Date] = [:]
    // Last dep-major ticket deep-dive per repo (owner/repo → date).
    @Published var ticketAnalysisLastRun: [String: Date] = [:]
    // Own-PR follow-up: the signal fingerprint last acted on per PR
    // (run key → fingerprint). A PR is only re-run when this changes, so
    // sitting on the same unresolved thread costs nothing.
    @Published var prFollowupHandled: [String: String] = [:]
    // Last follow-up run per PR (run key → date), for the cooldown.
    @Published var prFollowupLastRun: [String: Date] = [:]
    @Published var lastPollAt: Date?
    @Published var lastPollError: String?
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: "isPaused") }
    }
    // Main window shows settings in place of the run history (not persisted).
    @Published var showingSettings = false
    /// Run selected in the history window. Lives here rather than in the view
    /// so a notification click (or a menu-bar row) can point the window at a
    /// particular run.
    @Published var selectedRunID: ReviewRun.ID?

    var reviewsDir: URL { AppPaths.reviews }
    private var stateFile: URL { AppPaths.stateFile }

    private struct PersistedState: Codable {
        var runs: [ReviewRun]
        var seen: [String: String]
        var hasBaselined: Bool
        // Optional so state saved by older app versions still decodes.
        var dependabotBaselined: Set<String>?
        var depUpdateLastRun: [String: Date]?
        var ticketAnalysisLastRun: [String: Date]?
        var openReviewRequests: Set<String>?
        var prFollowupHandled: [String: String]?
        var prFollowupLastRun: [String: Date]?
    }

    init() {
        isPaused = UserDefaults.standard.bool(forKey: "isPaused")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        // Anything persisted as mid-flight was interrupted by an app quit.
        runs = state.runs.map { run in
            var r = run
            if r.status == .running || r.status == .queued {
                r.status = .failed
                r.errorMessage = "Interrupted (app quit while the review was in progress)"
                r.finishedAt = r.finishedAt ?? Date()
            }
            return r
        }
        seen = state.seen
        hasBaselined = state.hasBaselined
        dependabotBaselined = state.dependabotBaselined ?? []
        depUpdateLastRun = state.depUpdateLastRun ?? [:]
        ticketAnalysisLastRun = state.ticketAnalysisLastRun ?? [:]
        openReviewRequests = state.openReviewRequests
        prFollowupHandled = state.prFollowupHandled ?? [:]
        prFollowupLastRun = state.prFollowupLastRun ?? [:]
    }

    func save() {
        let state = PersistedState(
            runs: Array(runs.prefix(200)), seen: seen, hasBaselined: hasBaselined,
            dependabotBaselined: dependabotBaselined, depUpdateLastRun: depUpdateLastRun,
            ticketAnalysisLastRun: ticketAnalysisLastRun, openReviewRequests: openReviewRequests,
            prFollowupHandled: prFollowupHandled, prFollowupLastRun: prFollowupLastRun)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.appSupport, withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }

    func upsert(_ run: ReviewRun) {
        if let i = runs.firstIndex(where: { $0.id == run.id }) {
            runs[i] = run
        } else {
            runs.insert(run, at: 0)
        }
        save()
    }

    /// In-memory update for high-frequency streaming progress — no disk write.
    func updateLive(_ run: ReviewRun) {
        if let i = runs.firstIndex(where: { $0.id == run.id }) {
            runs[i] = run
        }
    }

    /// Median duration of recent successful runs of the same kind; nil until
    /// one has finished (reviews and dependency scans pace very differently).
    func estimatedDuration(for kind: ReviewRun.Kind) -> TimeInterval? {
        let durations = runs.lazy
            .filter { $0.status == .done && $0.runKind == kind }
            .compactMap(\.duration)
            .prefix(10)
            .sorted()
        guard !durations.isEmpty else { return nil }
        return max(120, durations[durations.count / 2])
    }

    /// Point the history window at a run, replacing the settings screen if
    /// it is up. Raising the window itself is the caller's job.
    func reveal(_ runID: ReviewRun.ID) {
        showingSettings = false
        selectedRunID = runID
    }

    func delete(_ run: ReviewRun) {
        runs.removeAll { $0.id == run.id }
        if selectedRunID == run.id { selectedRunID = nil }
        save()
    }
}
