import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var runs: [ReviewRun] = []
    @Published var seen: [String: String] = [:]
    @Published var hasBaselined = false
    @Published var lastPollAt: Date?
    @Published var lastPollError: String?
    @Published var currentActivity: String?
    @Published var isPaused: Bool {
        didSet { UserDefaults.standard.set(isPaused, forKey: "isPaused") }
    }

    var reviewsDir: URL { AppPaths.reviews }
    private var stateFile: URL { AppPaths.stateFile }

    private struct PersistedState: Codable {
        var runs: [ReviewRun]
        var seen: [String: String]
        var hasBaselined: Bool
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
    }

    func save() {
        let state = PersistedState(runs: Array(runs.prefix(200)), seen: seen, hasBaselined: hasBaselined)
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

    func delete(_ run: ReviewRun) {
        runs.removeAll { $0.id == run.id }
        save()
    }
}
