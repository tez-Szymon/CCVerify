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
    @Published var lastPollAt: Date?
    @Published var lastPollError: String?
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: "isPaused") }
    }
    // Main window shows settings in place of the run history (not persisted).
    @Published var showingSettings = false

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
    }

    func save() {
        let state = PersistedState(
            runs: Array(runs.prefix(200)), seen: seen, hasBaselined: hasBaselined,
            dependabotBaselined: dependabotBaselined, depUpdateLastRun: depUpdateLastRun,
            ticketAnalysisLastRun: ticketAnalysisLastRun, openReviewRequests: openReviewRequests)
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

    func delete(_ run: ReviewRun) {
        runs.removeAll { $0.id == run.id }
        save()
    }
}
