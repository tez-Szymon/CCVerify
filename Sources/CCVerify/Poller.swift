import Foundation
import SwiftUI

@MainActor
final class Poller: ObservableObject {
    let store: AppStore
    @Published var isBusy = false
    private var loopTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
    }

    func start() {
        AppLog.log("Poller started (interval \(AppSettings.pollIntervalSecs)s)")
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            // Touch the repos dir once at launch so the macOS "access your
            // Documents folder" prompt appears immediately, not mid-review.
            _ = try? FileManager.default.contentsOfDirectory(atPath: AppSettings.reposDir)
            while !Task.isCancelled {
                await self?.tick()
                let interval = AppSettings.pollIntervalSecs
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    func tick(force: Bool = false) async {
        if store.isPaused && !force { return }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await poll()
    }

    private func poll() async {
        var args = [
            "search", "prs", "--review-requested=@me", "--state=open",
            "--limit", "50", "--json", "number,title,url,updatedAt",
        ]
        if !AppSettings.includeDrafts { args.append("--draft=false") }

        let result = await ProcessRunner.run(AppSettings.ghPath, args, timeout: 60)
        store.lastPollAt = Date()
        guard result.exitCode == 0, !result.timedOut else {
            let err = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            store.lastPollError = err.isEmpty ? "gh exited with code \(result.exitCode)" : String(err.prefix(300))
            AppLog.log("Poll failed: \(store.lastPollError ?? "?")")
            return
        }
        guard let items = try? JSONDecoder().decode([GHPullRequest].self, from: result.stdout) else {
            store.lastPollError = "Could not parse gh output"
            AppLog.log("Poll failed: unparseable gh output: \(String(result.stdoutText.prefix(200)))")
            return
        }
        store.lastPollError = nil

        // First successful poll: baseline the existing backlog so only PRs
        // assigned from now on trigger reviews (no token burn on old ones).
        if !store.hasBaselined {
            for item in items {
                if let key = item.key { store.seen[key] = item.updatedAt }
            }
            store.hasBaselined = true
            store.save()
            AppLog.log("First poll: baselined \(items.count) existing review request(s)")
            return
        }

        let newItems = items.filter { item in
            guard let key = item.key else { return false }
            return store.seen[key] == nil
        }
        AppLog.log("Poll OK: \(items.count) open request(s), \(newItems.count) new")
        for item in newItems {
            guard let repo = item.repoFullName, let key = item.key else { continue }
            // Mark seen immediately: failures are surfaced, never auto-retried.
            store.seen[key] = item.updatedAt
            AppLog.log("NEW review request: \(key) (\(item.title))")
            let run = ReviewRun(repo: repo, prNumber: item.number, title: item.title, url: item.url)
            store.upsert(run)
            await review(run)
        }
    }

    /// Re-run a review manually from the History window.
    func rerun(_ old: ReviewRun) {
        Task {
            guard !isBusy else { return }
            isBusy = true
            defer { isBusy = false }
            let run = ReviewRun(repo: old.repo, prNumber: old.prNumber, title: old.title, url: old.url)
            store.upsert(run)
            await review(run)
        }
    }

    private func review(_ runIn: ReviewRun) async {
        var run = runIn

        guard let localPath = Self.resolveLocalRepo(run.repo) else {
            run.status = .noLocalRepo
            run.finishedAt = Date()
            run.errorMessage = "No checkout matching \(run.repo) found under \(AppSettings.reposDir)"
            store.upsert(run)
            notify("Review requested — no local repo", run.key)
            return
        }

        run.localRepoPath = localPath
        run.status = .running
        run.startedAt = Date()
        store.currentActivity = "Reviewing \(run.key)"
        store.upsert(run)
        notify("Review started", run.key)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileName = "\(run.repo.replacingOccurrences(of: "/", with: "-"))-pr\(run.prNumber)-\(stamp).md"
        let reportURL = store.reviewsDir.appendingPathComponent(fileName)

        let prompt = AppSettings.promptTemplate
            .replacingOccurrences(of: "{url}", with: run.url)
            .replacingOccurrences(of: "{repo}", with: run.repo)
            .replacingOccurrences(of: "{number}", with: String(run.prNumber))
            .replacingOccurrences(of: "{title}", with: run.title)

        let result = await ProcessRunner.run(
            AppSettings.claudePath,
            ["-p", prompt, "--allowedTools", AppSettings.allowedTools],
            cwd: localPath,
            timeout: TimeInterval(AppSettings.reviewTimeoutSecs),
            stdoutFile: reportURL
        )

        run.finishedAt = Date()
        run.exitCode = result.exitCode
        run.reportPath = reportURL.path
        AppLog.log("Review finished: \(run.key) exit=\(result.exitCode) timedOut=\(result.timedOut) report=\(reportURL.lastPathComponent)")
        if result.timedOut {
            run.status = .timedOut
            notify("Review timed out", run.key)
        } else if result.exitCode == 0 {
            run.status = .done
            notify("Review finished", run.key)
        } else {
            run.status = .failed
            let err = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            run.errorMessage = err.isEmpty ? nil : String(err.suffix(500))
            notify("Review failed (exit \(result.exitCode))", run.key)
        }
        store.currentActivity = nil
        store.upsert(run)
    }

    // MARK: - Local repo resolution

    /// Find a local checkout of `owner/repo` by matching each folder's
    /// `origin` remote in .git/config (case-insensitive, `.git` suffix ignored).
    nonisolated static func resolveLocalRepo(_ fullName: String) -> String? {
        let want = fullName.lowercased()
        let reposDir = AppSettings.reposDir
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: reposDir) else {
            return nil
        }
        for entry in entries.sorted() {
            let dir = (reposDir as NSString).appendingPathComponent(entry)
            let configPath = dir + "/.git/config"
            guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { continue }
            if originFullName(in: text)?.lowercased() == want {
                return dir
            }
        }
        return nil
    }

    nonisolated static func originFullName(in gitConfig: String) -> String? {
        var inOrigin = false
        for rawLine in gitConfig.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
                continue
            }
            guard inOrigin, line.hasPrefix("url") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var url = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
            for prefix in ["git@github.com:", "https://github.com/", "ssh://git@github.com/", "http://github.com/"] {
                if url.lowercased().hasPrefix(prefix) {
                    return String(url.dropFirst(prefix.count))
                }
            }
            return nil
        }
        return nil
    }

    // MARK: - Notifications

    private func notify(_ title: String, _ body: String) {
        guard AppSettings.notify else { return }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(body))\" with title \"CCVerify\" subtitle \"\(esc(title))\""
        Task.detached(priority: .utility) {
            _ = await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 10)
        }
    }
}
