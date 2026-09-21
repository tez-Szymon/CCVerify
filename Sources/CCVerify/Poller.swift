import Foundation
import SwiftUI

@MainActor
final class Poller: ObservableObject {
    let store: AppStore
    /// True while a tick's gh polls / schedule checks run. Reviews themselves
    /// execute detached from the tick, so a long agent run never blocks polling.
    @Published var isPolling = false
    /// Keys of runs currently queued or executing — the same work is never
    /// started twice concurrently, and per-repo trigger buttons disable off it.
    @Published private(set) var activeKeys: Set<String> = []
    // Runs admitted but waiting for a free agent slot (maxConcurrentRuns).
    private var pendingRuns: [ReviewRun] = []
    private var executingCount = 0
    private var loopTask: Task<Void, Never>?
    // Per-run report text captured from the stream's final `result` event,
    // with concatenated assistant text as fallback if that event never comes.
    private var resultText: [UUID: String] = [:]
    private var assistantText: [UUID: String] = [:]
    // TaskCreate assigns sequential ids ("Task #1 created"); mirror that here.
    private var taskCounter: [UUID: Int] = [:]
    // Stop handles for the agent processes currently executing, by run id.
    private var cancellations: [UUID: ProcessCancellation] = [:]
    // Runs the user stopped. Needed as well as `cancellations` because a run
    // can be stopped in the gap between leaving the queue and its process
    // being launched — review() checks this before and after it starts one.
    private var stopRequested: Set<UUID> = []

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
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        await pollReviewRequests()
        await pollDependabot()
        await pollOwnPullRequests()
        enqueueDueDependencyUpdates()
        enqueueDueTicketAnalyses()
    }

    // MARK: - Run queue

    /// Whether the given work is already queued or executing.
    func isActive(_ kind: ReviewRun.Kind, repo: String, prNumber: Int = 0) -> Bool {
        activeKeys.contains(ReviewRun.key(kind: kind, repo: repo, prNumber: prNumber))
    }

    func isActive(key: String) -> Bool { activeKeys.contains(key) }

    /// Admit a run: duplicates of an already queued/executing key are dropped,
    /// everything else starts as soon as an agent slot is free.
    private func enqueue(_ run: ReviewRun) {
        guard !activeKeys.contains(run.key) else {
            AppLog.log("Skipped \(run.key): the same run is already queued or executing")
            return
        }
        activeKeys.insert(run.key)
        store.upsert(run)
        pendingRuns.append(run)
        pump()
    }

    /// Start queued runs while there are free agent slots.
    private func pump() {
        while executingCount < AppSettings.maxConcurrentRuns, !pendingRuns.isEmpty {
            let run = pendingRuns.removeFirst()
            executingCount += 1
            Task { [weak self] in
                await self?.review(run)
                guard let self else { return }
                self.executingCount -= 1
                self.activeKeys.remove(run.key)
                self.pump()
            }
        }
    }

    /// Stop a run the user no longer wants: a queued one never starts, an
    /// executing one gets its agent process terminated. Either way the run
    /// ends up in history as "Stopped" — nothing is retried automatically.
    func stop(_ run: ReviewRun) {
        guard run.isStoppable else { return }
        stopRequested.insert(run.id)

        if let i = pendingRuns.firstIndex(where: { $0.id == run.id }) {
            // Still waiting for a slot: drop it before it ever runs.
            pendingRuns.remove(at: i)
            activeKeys.remove(run.key)
            stopRequested.remove(run.id)
            var stopped = run
            finishStopped(&stopped)
            return
        }

        AppLog.log("Stopping run: \(run.key)")
        cancellations[run.id]?.cancel()
    }

    /// Stop everything queued or executing.
    func stopAll() {
        for run in store.runs where run.isStoppable {
            stop(run)
        }
    }

    /// Whether there is anything to stop (drives the Stop All command).
    var hasStoppableRuns: Bool {
        store.runs.contains(where: \.isStoppable)
    }

    private func pollReviewRequests() async {
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
        let currentKeys = Set(items.compactMap(\.key))

        // First successful poll: baseline the existing backlog so only PRs
        // assigned from now on trigger reviews (no token burn on old ones).
        if !store.hasBaselined {
            for item in items {
                if let key = item.key { store.seen[key] = item.updatedAt }
            }
            store.hasBaselined = true
            store.openReviewRequests = currentKeys
            store.save()
            AppLog.log("First poll: baselined \(items.count) existing review request(s)")
            return
        }

        // GitHub drops a PR from --review-requested=@me once the review is
        // submitted (or the request is removed); it reappears when someone
        // re-requests the review. So a seen PR that is back after being absent
        // last poll is a renewed request and gets reviewed again. A nil set
        // (state from an older app version) just records without triggering.
        let previouslyOpen = store.openReviewRequests
        store.openReviewRequests = currentKeys
        if previouslyOpen != currentKeys { store.save() }

        let newItems = items.filter { item in
            guard let key = item.key else { return false }
            return store.seen[key] == nil
        }
        let renewedItems = items.filter { item in
            guard let previouslyOpen, let key = item.key else { return false }
            return store.seen[key] != nil && !previouslyOpen.contains(key)
        }
        AppLog.log("Poll OK: \(items.count) open request(s), \(newItems.count) new, \(renewedItems.count) renewed")
        for item in newItems + renewedItems {
            guard let repo = item.repoFullName, let key = item.key else { continue }
            let renewed = store.seen[key] != nil
            // Mark seen immediately: failures are surfaced, never auto-retried.
            store.seen[key] = item.updatedAt
            AppLog.log("\(renewed ? "RENEWED" : "NEW") review request: \(key) (\(item.title))")
            let run = ReviewRun(repo: repo, prNumber: item.number, title: item.title, url: item.url, kind: .review)
            enqueue(run)
        }
    }

    /// Watch the configured repos for new Dependabot PRs and review each one
    /// with the dependabot prompt (unattended: the review comment is posted
    /// straight to the PR/Jira — see /review-dependabot-pr --auto).
    private func pollDependabot() async {
        guard AppSettings.dependabotEnabled else { return }
        let repos = AppSettings.dependabotRepos
        guard !repos.isEmpty else { return }

        var args = [
            "search", "prs", "--author", "app/dependabot", "--state=open",
            "--limit", "50", "--json", "number,title,url,updatedAt",
        ]
        for repo in repos { args += ["--repo", repo] }
        if !AppSettings.includeDrafts { args.append("--draft=false") }

        let result = await ProcessRunner.run(AppSettings.ghPath, args, timeout: 60)
        guard result.exitCode == 0, !result.timedOut,
              let items = try? JSONDecoder().decode([GHPullRequest].self, from: result.stdout)
        else {
            let err = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.log("Dependabot poll failed: \(String(err.prefix(300)))")
            return
        }

        // Baseline per repo: a repo's pre-existing backlog is marked seen the
        // first time it appears in the watch list — only PRs opened after that
        // trigger reviews (same no-token-burn rule as review requests).
        let newRepos = Set(repos).subtracting(store.dependabotBaselined)
        if !newRepos.isEmpty {
            var baselined = 0
            for item in items {
                guard let repo = item.repoFullName, let key = item.key,
                      newRepos.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame })
                else { continue }
                if store.seen[key] == nil {
                    store.seen[key] = item.updatedAt
                    baselined += 1
                }
            }
            store.dependabotBaselined.formUnion(newRepos)
            store.save()
            AppLog.log("Dependabot: baselined \(baselined) existing PR(s) in \(newRepos.sorted().joined(separator: ", "))")
            return
        }

        let newItems = items.filter { item in
            guard let key = item.key else { return false }
            return store.seen[key] == nil
        }
        if !newItems.isEmpty {
            AppLog.log("Dependabot poll: \(items.count) open PR(s), \(newItems.count) new")
        }
        for item in newItems {
            guard let repo = item.repoFullName, let key = item.key else { continue }
            store.seen[key] = item.updatedAt
            AppLog.log("NEW dependabot PR: \(key) (\(item.title))")
            let run = ReviewRun(repo: repo, prNumber: item.number, title: item.title, url: item.url, kind: .dependabot)
            enqueue(run)
        }
    }

    // MARK: - Own PRs

    /// At most this many follow-up runs are started per poll. The queue caps
    /// concurrency anyway; this keeps a first enable (or a busy morning) from
    /// stacking a dozen agents at once — the rest come on the next ticks.
    private static let maxFollowupsPerTick = 3

    /// One query answers everything the triage needs about our open PRs:
    /// mergeability, the latest review per author, every review thread with
    /// its last few comments, and the check rollup of the head commit.
    private static let ownPRQuery = """
    query($q: String!) {
      viewer { login }
      search(query: $q, type: ISSUE, first: 40) {
        nodes {
          ... on PullRequest {
            number
            title
            url
            isDraft
            mergeable
            headRefOid
            baseRef { name target { oid } }
            repository { nameWithOwner }
            reviewDecision
            latestReviews(first: 20) { nodes { id state author { login } } }
            reviewThreads(first: 50) {
              nodes {
                id
                isResolved
                isOutdated
                path
                comments(last: 5) { nodes { id author { login } } }
              }
            }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    /// Watch our own open PRs in the configured repos and hand the ones that
    /// need attention to the follow-up agent: merge conflicts, unresolved
    /// review threads (CodeRabbit and humans alike), reviews that requested
    /// changes, and red CI. Nothing actionable → no agent run, no tokens.
    private func pollOwnPullRequests() async {
        guard AppSettings.prFollowupEnabled else { return }
        let repos = AppSettings.prFollowupRepos
        guard !repos.isEmpty else { return }

        var search = "is:pr is:open author:@me " + repos.map { "repo:\($0)" }.joined(separator: " ")
        if !AppSettings.includeDrafts { search += " -is:draft" }

        let result = await ProcessRunner.run(
            AppSettings.ghPath,
            ["api", "graphql", "-f", "query=\(Self.ownPRQuery)", "-f", "q=\(search)"],
            timeout: 90)
        guard result.exitCode == 0, !result.timedOut,
              let root = try? JSONDecoder().decode(OwnPRPoll.Root.self, from: result.stdout)
        else {
            let err = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            // GraphQL errors come back on stdout with exit 0 → show whichever we got.
            let detail = err.isEmpty ? result.stdoutText : err
            AppLog.log("Own-PR poll failed: \(String(detail.prefix(300)))")
            return
        }

        let viewer = root.data.viewer.login ?? ""
        let candidates = root.data.search.nodes.compactMap { Self.triage($0, viewer: viewer) }
        guard !candidates.isEmpty else { return }

        var started = 0
        var deferred = 0
        for candidate in candidates {
            let key = ReviewRun.key(kind: .prFollowup, repo: candidate.repo, prNumber: candidate.number)
            // Same feedback as the last run acted on → nothing new to do.
            if store.prFollowupHandled[key] == candidate.fingerprint { continue }
            // Cooldown: a fix of ours often triggers a fresh bot review, and
            // that must not become a tight loop. The fingerprint is left
            // unrecorded so the PR comes back once the cooldown expires.
            if let last = store.prFollowupLastRun[key],
               Date().timeIntervalSince(last) < TimeInterval(AppSettings.prFollowupCooldownMins) * 60 {
                continue
            }
            guard started < Self.maxFollowupsPerTick else {
                deferred += 1
                continue
            }
            started += 1
            store.prFollowupHandled[key] = candidate.fingerprint
            store.prFollowupLastRun[key] = Date()
            store.save()
            AppLog.log("PR follow-up: \(key) — \(candidate.summary)")
            let run = ReviewRun(
                repo: candidate.repo, prNumber: candidate.number, title: candidate.title,
                url: candidate.url, kind: .prFollowup, triggerSummary: candidate.summary)
            enqueue(run)
        }
        if deferred > 0 {
            AppLog.log("PR follow-up: \(deferred) more PR(s) actionable, deferred to the next poll")
        }
    }

    /// Decide whether one of our PRs needs the agent, and why. Returns nil
    /// when nothing is pending — including threads where our own reply is the
    /// last word, which means the ball is in the reviewer's court.
    nonisolated static func triage(_ pr: OwnPRPoll.PullRequest, viewer: String) -> OwnPRCandidate? {
        func isViewer(_ login: String?) -> Bool {
            guard let login, !viewer.isEmpty else { return false }
            return login.caseInsensitiveCompare(viewer) == .orderedSame
        }

        guard let number = pr.number, let repo = pr.repository?.nameWithOwner, let url = pr.url
        else { return nil }

        var tokens: [String] = []
        var reasons: [String] = []
        let head = pr.headRefOid ?? "?"

        // UNKNOWN means GitHub is still computing the merge — not a conflict.
        if pr.mergeable?.uppercased() == "CONFLICTING" {
            let base = pr.baseRef?.target?.oid ?? "?"
            // Both oids: a conflict we could not resolve is retried only once
            // one of the two sides has actually moved.
            tokens.append("conflict:\(base):\(head)")
            reasons.append("conflicts with \(pr.baseRef?.name ?? "the base branch")")
        }

        let latestReviews: [OwnPRPoll.Review] = pr.latestReviews?.nodes ?? []
        let changesRequested = latestReviews.filter { review in
            guard review.state?.uppercased() == "CHANGES_REQUESTED" else { return false }
            return !isViewer(review.author?.login)
        }
        for review in changesRequested { tokens.append("changes:\(review.id ?? "?")") }
        if !changesRequested.isEmpty {
            let who = changesRequested.compactMap { $0.author?.login }.joined(separator: ", ")
            reasons.append("changes requested by \(who.isEmpty ? "a reviewer" : who)")
        }

        var openThreads = 0
        for thread in pr.reviewThreads?.nodes ?? [] {
            guard thread.isResolved != true, let id = thread.id else { continue }
            // comments(last: 5) → the newest is last. Our own reply sitting at
            // the end means the ball is in the reviewer's court, not ours.
            let comments = thread.comments?.nodes ?? []
            guard let last = comments.last, !isViewer(last.author?.login) else { continue }
            tokens.append("thread:\(id):\(last.id ?? "?")")
            openThreads += 1
        }
        if openThreads > 0 {
            reasons.append("\(openThreads) unresolved review thread\(openThreads == 1 ? "" : "s")")
        }

        if let rollup = pr.commits?.nodes?.first?.commit?.statusCheckRollup?.state?.uppercased(),
           rollup == "FAILURE" || rollup == "ERROR" {
            tokens.append("checks:\(rollup):\(head)")
            reasons.append("failing CI checks")
        }

        guard !tokens.isEmpty else { return nil }
        return OwnPRCandidate(
            repo: repo, number: number, title: pr.title ?? "PR #\(number)", url: url,
            signalTokens: tokens, summary: reasons.joined(separator: "; "))
    }

    /// Enqueue a dependency-update scan for every configured repo whose last
    /// scan is older than the configured interval; the agent-slot cap paces them.
    private func enqueueDueDependencyUpdates() {
        guard AppSettings.depUpdateEnabled else { return }
        let interval = TimeInterval(AppSettings.depUpdateIntervalHours) * 3600
        for repo in AppSettings.depUpdateRepos {
            if let last = store.depUpdateLastRun[repo],
               Date().timeIntervalSince(last) < interval { continue }
            startDependencyScan(repo)
        }
    }

    /// Manually trigger a dependency update scan from the UI, regardless of
    /// the automatic schedule (and even when it is disabled).
    func scanDependencies(_ repo: String) {
        AppLog.log("Manual dependency update scan: \(repo)")
        startDependencyScan(repo)
    }

    private func startDependencyScan(_ repo: String) {
        // Stamp before running: a failed scan is surfaced in history, never
        // silently retried every tick.
        store.depUpdateLastRun[repo] = Date()
        store.save()
        AppLog.log("Dependency update scan: \(repo)")
        let run = ReviewRun(
            repo: repo, prNumber: 0, title: "Dependency update scan",
            url: "https://github.com/\(repo)", kind: .dependencyUpdate)
        enqueue(run)
    }

    /// Enqueue a dep-major ticket deep-dive for every configured repo whose
    /// last analysis is older than the interval.
    /// Discovery of the actual tickets (JQL for open dep-major tickets
    /// without the dep-analyzed label) happens inside the command — the app
    /// itself never talks to Jira.
    private func enqueueDueTicketAnalyses() {
        guard AppSettings.ticketAnalysisEnabled else { return }
        let interval = TimeInterval(AppSettings.ticketAnalysisIntervalHours) * 3600
        for repo in AppSettings.ticketAnalysisRepos {
            if let last = store.ticketAnalysisLastRun[repo],
               Date().timeIntervalSince(last) < interval { continue }
            startTicketAnalysis(repo)
        }
    }

    /// Manually trigger a ticket deep-dive from the UI, regardless of the
    /// automatic schedule (and even when it is disabled).
    func analyzeTickets(_ repo: String) {
        AppLog.log("Manual ticket deep-dive: \(repo)")
        startTicketAnalysis(repo)
    }

    private func startTicketAnalysis(_ repo: String) {
        // Same stamp-before-run rule as dependency scans.
        store.ticketAnalysisLastRun[repo] = Date()
        store.save()
        AppLog.log("Ticket deep-dive: \(repo)")
        let run = ReviewRun(
            repo: repo, prNumber: 0, title: "Major ticket deep-dive",
            url: "https://github.com/\(repo)", kind: .ticketAnalysis)
        enqueue(run)
    }

    /// Re-run a review manually from the History window.
    func rerun(_ old: ReviewRun) {
        let run = ReviewRun(
            repo: old.repo, prNumber: old.prNumber, title: old.title, url: old.url,
            kind: old.runKind)
        enqueue(run)
    }

    private func review(_ runIn: ReviewRun) async {
        var run = runIn

        // Stopped while it sat in the queue, after pump() had already picked
        // it up: never start the agent.
        if stopRequested.remove(run.id) != nil {
            finishStopped(&run)
            return
        }

        guard let localPath = Self.resolveLocalRepo(run.repo) else {
            run.status = .noLocalRepo
            run.finishedAt = Date()
            run.errorMessage = "No checkout matching \(run.repo) found under \(AppSettings.reposDir)"
            store.upsert(run)
            notify("No local repo", run)
            return
        }

        let kindNoun: String
        let promptTemplate: String
        let allowedTools: String
        switch run.runKind {
        case .review:
            kindNoun = "Review"
            promptTemplate = AppSettings.promptTemplate
            allowedTools = AppSettings.allowedTools
        case .dependabot:
            kindNoun = "Dependabot review"
            promptTemplate = AppSettings.dependabotPromptTemplate
            allowedTools = AppSettings.dependabotAllowedTools
        case .dependencyUpdate:
            kindNoun = "Dependency scan"
            promptTemplate = AppSettings.depUpdatePromptTemplate
            allowedTools = AppSettings.depUpdateAllowedTools
        case .ticketAnalysis:
            kindNoun = "Ticket deep-dive"
            promptTemplate = AppSettings.ticketAnalysisPromptTemplate
            allowedTools = AppSettings.ticketAnalysisAllowedTools
        case .prFollowup:
            kindNoun = "PR follow-up"
            promptTemplate = AppSettings.prFollowupPromptTemplate
            allowedTools = AppSettings.prFollowupAllowedTools
        }

        run.localRepoPath = localPath
        run.status = .running
        run.startedAt = Date()
        store.upsert(run)
        notify("\(kindNoun) started", run)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let slug: String
        switch run.runKind {
        case .dependencyUpdate: slug = "deps"
        case .ticketAnalysis: slug = "tickets"
        case .prFollowup: slug = "pr\(run.prNumber)-followup"
        case .review, .dependabot: slug = "pr\(run.prNumber)"
        }
        let fileName = "\(run.repo.replacingOccurrences(of: "/", with: "-"))-\(slug)-\(stamp).md"
        let reportURL = store.reviewsDir.appendingPathComponent(fileName)

        let prompt = promptTemplate
            .replacingOccurrences(of: "{url}", with: run.url)
            .replacingOccurrences(of: "{repo}", with: run.repo)
            .replacingOccurrences(of: "{number}", with: String(run.prNumber))
            .replacingOccurrences(of: "{title}", with: run.title)
            .replacingOccurrences(of: "{signals}", with: run.triggerSummary ?? "")

        // Raw event stream is kept as a sidecar for debugging.
        let streamURL = reportURL.deletingPathExtension().appendingPathExtension("jsonl")
        try? FileManager.default.createDirectory(at: store.reviewsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: streamURL.path, contents: nil)
        let streamHandle = try? FileHandle(forWritingTo: streamURL)

        let runID = run.id
        let cancellation = ProcessCancellation()
        cancellations[runID] = cancellation
        // Stop pressed between the status flipping to running and here.
        if stopRequested.contains(runID) { cancellation.cancel() }
        let result = await ProcessRunner.run(
            AppSettings.claudePath,
            [
                "-p", prompt, "--allowedTools", allowedTools,
                "--output-format", "stream-json", "--verbose",
            ],
            cwd: localPath,
            timeout: TimeInterval(AppSettings.reviewTimeoutSecs),
            cancellation: cancellation,
            onStdoutLine: { line in
                streamHandle?.write(Data((line + "\n").utf8))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.handleStreamLine(line, runID: runID) }
                }
            }
        )
        try? streamHandle?.close()
        cancellations.removeValue(forKey: runID)
        stopRequested.remove(runID)

        // Pick up progress fields the stream handler wrote while we awaited.
        if let live = store.runs.first(where: { $0.id == runID }) { run = live }
        run.currentAction = nil

        let reportText = resultText.removeValue(forKey: runID)
            ?? assistantText[runID]
            ?? ""
        assistantText.removeValue(forKey: runID)
        taskCounter.removeValue(forKey: runID)
        try? Data(reportText.utf8).write(to: reportURL, options: .atomic)

        run.finishedAt = Date()
        run.exitCode = result.exitCode
        run.reportPath = reportURL.path
        AppLog.log("Review finished: \(run.key) exit=\(result.exitCode) timedOut=\(result.timedOut) cancelled=\(result.cancelled) report=\(reportURL.lastPathComponent)")
        if result.cancelled {
            // Whatever the agent produced before the signal is kept in the
            // report, so a partial review isn't lost.
            run.status = .stopped
            run.errorMessage = "Stopped by you"
            notify("\(kindNoun) stopped", run)
        } else if result.timedOut {
            run.status = .timedOut
            notify("\(kindNoun) timed out", run)
        } else if result.exitCode == 0 {
            run.status = .done
            notify("\(kindNoun) finished", run)
        } else {
            run.status = .failed
            let err = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            run.errorMessage = err.isEmpty ? nil : String(err.suffix(500))
            notify("\(kindNoun) failed (exit \(result.exitCode))", run)
        }
        store.upsert(run)
    }

    /// Mark a run the user stopped before its agent ever started.
    private func finishStopped(_ run: inout ReviewRun) {
        run.status = .stopped
        run.finishedAt = Date()
        run.errorMessage = "Stopped before it started"
        store.upsert(run)
        AppLog.log("Stopped run before start: \(run.key)")
    }

    // MARK: - Stream-json progress parsing

    private func handleStreamLine(_ line: String, runID: UUID) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }
        guard var run = store.runs.first(where: { $0.id == runID }) else { return }

        switch type {
        case "system":
            // The init event names the model the session runs on — the only
            // place it appears, since we never pass --model ourselves.
            guard event["subtype"] as? String == "init",
                  let model = event["model"] as? String, !model.isEmpty
            else { return }
            run.models = [model]
            store.updateLive(run)
        case "assistant":
            guard let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return }
            let nested = event["parent_tool_use_id"] as? String != nil
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if !nested, let text = block["text"] as? String, !text.isEmpty {
                        assistantText[runID, default: ""] += text
                    }
                case "tool_use":
                    guard let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    // The plan/checkpoint list claude maintains for the task:
                    // current Claude Code uses TaskCreate/TaskUpdate; TodoWrite is
                    // the older equivalent. Subagents keep their own lists — only
                    // track the top-level one.
                    if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                        if !nested {
                            run.todos = todos.compactMap { todo in
                                guard let content = todo["content"] as? String,
                                      let status = todo["status"] as? String
                                else { return nil }
                                return TodoItem(content: content, status: status)
                            }
                        }
                    } else if name == "TaskCreate" {
                        if !nested {
                            let nextID = (taskCounter[runID] ?? 0) + 1
                            taskCounter[runID] = nextID
                            let subject = input["subject"] as? String
                                ?? input["description"] as? String ?? "task"
                            var todos = run.todos ?? []
                            todos.append(TodoItem(content: subject, status: "pending", taskID: String(nextID)))
                            run.todos = todos
                        }
                    } else if name == "TaskUpdate" {
                        if !nested, var todos = run.todos {
                            let taskID = input["taskId"] as? String
                                ?? (input["taskId"] as? Int).map(String.init)
                            if let taskID, let i = todos.firstIndex(where: { $0.taskID == taskID }) {
                                if let status = input["status"] as? String {
                                    if status == "deleted" {
                                        todos.remove(at: i)
                                    } else {
                                        todos[i].status = status
                                    }
                                }
                                if let subject = input["subject"] as? String, todos.indices.contains(i) {
                                    todos[i].content = subject
                                }
                                run.todos = todos
                            }
                        }
                    } else {
                        let summary = (nested ? "↳ " : "") + Self.summarizeTool(name, input)
                        run.currentAction = summary
                        var actions = run.recentActions ?? []
                        if actions.last != summary { actions.append(summary) }
                        if actions.count > 30 { actions.removeFirst(actions.count - 30) }
                        run.recentActions = actions
                    }
                default:
                    continue
                }
            }
            store.updateLive(run)
        case "result":
            run.numTurns = event["num_turns"] as? Int
            // Subagents can run on other models; modelUsage lists every one
            // that billed, so add whatever init didn't already name.
            if let usage = event["modelUsage"] as? [String: Any] {
                var models = run.models ?? []
                models.append(contentsOf: usage.keys.sorted().filter { !models.contains($0) })
                run.models = models
            }
            if let cost = event["total_cost_usd"] as? Double, cost > 0 {
                run.costUSD = cost
            }
            if let text = event["result"] as? String, !text.isEmpty {
                resultText[runID] = text
            }
            store.updateLive(run)
        default:
            break
        }
    }

    nonisolated static func summarizeTool(_ name: String, _ input: [String: Any]) -> String {
        func clip(_ s: String, _ max: Int = 80) -> String {
            let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            return oneLine.count > max ? String(oneLine.prefix(max)) + "…" : oneLine
        }
        switch name {
        case "Bash":
            if let cmd = input["command"] as? String { return clip(cmd) }
        case "Read", "Write", "Edit":
            if let path = input["file_path"] as? String {
                return "\(name) \((path as NSString).lastPathComponent)"
            }
        case "Grep":
            if let pattern = input["pattern"] as? String { return "Grep \(clip(pattern, 50))" }
        case "Glob":
            if let pattern = input["pattern"] as? String { return "Glob \(clip(pattern, 50))" }
        case "Task", "Agent":
            let agent = input["subagent_type"] as? String
            let desc = input["description"] as? String ?? input["prompt"] as? String
            return "Agent\(agent.map { " (\($0))" } ?? ""): \(clip(desc ?? "subtask", 60))"
        case "WebFetch":
            if let url = input["url"] as? String { return "Fetch \(clip(url, 60))" }
        case "WebSearch":
            if let query = input["query"] as? String { return "Search \(clip(query, 60))" }
        default:
            break
        }
        return name
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

    /// All local checkouts under reposDir with a GitHub origin, as owner/repo
    /// (deduplicated case-insensitively, sorted). Feeds the repo pickers in
    /// Settings so users select repos instead of typing them.
    nonisolated static func localGitHubRepos() -> [String] {
        let reposDir = AppSettings.reposDir
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: reposDir) else {
            return []
        }
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries.sorted() {
            let configPath = (reposDir as NSString).appendingPathComponent(entry) + "/.git/config"
            guard let text = try? String(contentsOfFile: configPath, encoding: .utf8),
                  let name = originFullName(in: text),
                  seen.insert(name.lowercased()).inserted
            else { continue }
            result.append(name)
        }
        return result.sorted { $0.lowercased() < $1.lowercased() }
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

    /// Body is the run key; clicking the banner opens the app on that run.
    private func notify(_ title: String, _ run: ReviewRun) {
        guard AppSettings.notify else { return }
        Notifier.shared.post(title: title, body: run.key, runID: run.id)
    }
}
