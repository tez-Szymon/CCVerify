# CCVerify

A native macOS app — a regular app with a main window, top-bar menu (Runs →
Poll Now ⌘R, Scan for Updates; Settings under ⌘,) **plus** a menu bar status
item — that watches GitHub for PRs where **your review is requested** and
automatically runs a **local Claude Code review**
(`claude -p "/review-pr <url>"`) inside your checkout of that repo — with a
history of runs, per-run details, and the full review report in the app.

No server, no webhooks, no repo admin rights: it polls
`gh search prs --review-requested=@me` every 2 minutes.

## Features

- **Main window at launch** — the run history opens as a normal window; the
  Dock icon and Window menu bring it back, and the app has a real menu bar
  (Runs → Poll Now / Pause / Scan for Updates, Settings… under ⌘,).
- **Menu bar status item** — watching / reviewing / paused / poll errors, plus
  the five most recent runs at a glance.
- **History window** — every run with status (done / failed / timed out /
  no local repo), timestamps, duration, exit code, and the full review report
  rendered in-app. Open the PR, reveal the report file, or re-run a review.
- **Live progress** — reviews run with `--output-format stream-json`, so a
  running review shows its plan checkpoints (from claude's TaskCreate/TaskUpdate
  or TodoWrite), the current tool action, a recent-activity feed, and elapsed
  time with an ETA estimated from the median of your past review durations.
  Finished runs keep the final checkpoint list, turn count, and estimated cost;
  the raw event stream is saved next to each report as a `.jsonl` sidecar.
- **In-window Settings** (⌘,, or the gear in the toolbar / status item) — shown
  inside the main window, split into General / Reviews / Dependabot / Updates /
  Tickets tabs: poll interval, repos directory, prompt templates, allowed
  tools, timeout, draft filtering, notifications, launch at login.
- **macOS notifications** on review start / finish / failure.
- **Dependabot reviews** (opt-in) — watches a configured list of repos for new
  PRs authored by Dependabot and reviews each one unattended with
  `/review-dependabot-pr {number} --auto`: toolchain-aware verification in an
  isolated git worktree, risk assessment, and the review comment posted to the
  GitHub PR and its linked Jira ticket. Never approves, merges, or pushes.
- **Dependency update scans** — CCVerify's own "safe dependabot": runs
  `/update-dependencies --auto` per configured repo, on demand via the
  **Scan for updates** button (menu → Dependabot tab, or the History toolbar)
  and optionally on a schedule (opt-in, default every 24h). It finds
  outdated packages, applies only patch/minor bumps whose changelogs are clean,
  verifies them (install / lint / test / build) in a throwaway worktree, and
  only when everything is green opens a `deps/*` PR and files a Jira ticket.
  Nothing safe to bump → a report, and no PR. Majors are never applied — they
  get `dep-major` Jira backlog tickets instead, which feed the next feature.
- **Major ticket deep-dives** — closes the loop on those `dep-major` tickets:
  runs `/analyze-dep-tickets --auto` per configured repo, on demand via
  **Analyze major tickets** (menu → Dependabot tab, or Runs menu) and
  optionally on a schedule (opt-in, default every 24h). For each open ticket
  not yet labeled `dep-analyzed` it researches the major's breaking changes,
  checks the codebase against every one of them, trial-upgrades in an isolated
  worktree, and posts the full analysis as a Jira comment. Verdict
  ✅ SAFE TO UPDATE (nothing affected + verification green) additionally opens
  a `deps/major-*` PR linked from the comment and moves the ticket to
  **Dev Complete** (same for the updates ticket a dependency scan files with
  its PR — a created PR is the one status change these bots make);
  ⚠️ NEEDS MIGRATION / ⛔ BLOCKED tickets get the analysis (with a migration
  checklist) only, and their status is never touched. Never merges or
  approves.

## How it works

```
CCVerify.app (menu bar, SwiftUI)
  └─ every N seconds: gh search prs --review-requested=@me --state=open
       ├─ diff against seen set (first poll baselines the backlog);
       │    a seen PR reappearing after an absence = renewed request
       ├─ match owner/repo → local checkout under ~/Documents/Repos
       │    (by each folder's `origin` remote in .git/config)
       └─ for each NEW or RENEWED review request:
            cd <local repo> && claude -p "/review-pr <url> --publish" --allowedTools <default set>
            → verdict + comments posted to the GitHub PR (--publish)
            → report + history entry in ~/Library/Application Support/CCVerify/
            → notification
  └─ if enabled: gh search prs --author app/dependabot (configured repos)
       └─ for each NEW Dependabot PR:
            claude -p "/review-dependabot-pr <number> --auto"
            → risk-assessed review comment → GitHub PR + linked Jira ticket
  └─ if enabled: every N hours per configured repo:
            claude -p "/update-dependencies --auto"
            → safe patch/minor bumps verified in a worktree
            → PR (deps/*) + Jira ticket only when checks pass
            → skipped majors → dep-major Jira backlog tickets
  └─ if enabled: every N hours per configured repo:
            claude -p "/analyze-dep-tickets --auto"
            → JQL: open dep-major tickets without the dep-analyzed label
            → per ticket: breaking-change research + codebase impact check
              + trial upgrade in a worktree → analysis posted as Jira comment
            → SAFE verdict only: PR (deps/major-*) linked from the comment
```

## Build & run

```bash
./build.sh          # builds dist/CCVerify.app (Swift 5.9+, macOS 14+)
./build.sh --run    # build + (re)launch
```

Requirements: Xcode (or CLT with Swift), `gh` (authenticated), `claude`
(logged in with your subscription via `/login`).

### Install the review agent

The prompts invoke slash commands that must exist in your `~/.claude`. Copies
ship in this repo (`claude/`): `/review-pr` (dispatcher + three stack-specific
reviewer agents), `/review-dependabot-pr` (multi-stack Dependabot review with
an unattended `--auto` mode), `/update-dependencies` (safe update scan), and
`/analyze-dep-tickets` (deep-dive of the `dep-major` Jira tickets the scan
files). Also bundled: the `dependabot-review` skill
(`claude/skills/dependabot-review/`), the interactive text2park.web-specific
review workflow — not required by the app (the bundled command is
self-contained), but version-controlled here so a machine that uses it can be
reproduced. Like every mutating run, it verifies in a throwaway `git worktree`
and never checks out branches in the main working copy.

```bash
./install-review-agent.sh           # copies into ~/.claude (never overwrites)
./install-review-agent.sh --force   # overwrite existing files
```

If you already have your own `/review-dependabot-pr` (e.g. the text2park.web
one), the installer will skip it — rerun with `--force` to replace it with the
generalized version (the old one has no `--auto` mode, so unattended runs from
CCVerify would stall waiting for approval).

If you already have your own review command, skip this and point the prompt
template in Settings at it instead.

Enable **Launch at login** in Settings to make it permanent. If you move the
app (e.g. to /Applications), re-toggle launch-at-login so the registration
points at the new path.

## Billing / auth

- Reviews run on your **normal Claude subscription** (OAuth login), drawing
  from plan usage limits. The app strips `ANTHROPIC_API_KEY` /
  `ANTHROPIC_AUTH_TOKEN` from the claude environment so a stray key can never
  switch it to per-token API billing.
- Deliberately **not** `--bare` mode: CLAUDE.md, skills (`/review-pr`) and
  agents from the target repo are loaded — that's the point.

## Safety defaults

- **First poll baselines**: PRs already awaiting your review when the app
  first runs are marked seen — only *new* requests trigger reviews.
- **One review per request** (keyed `owner/repo#number`): pushes and comments
  on a PR whose request is still open never re-trigger. Re-requesting your
  review after you've submitted one *does* trigger a fresh review (the PR
  reappears in the `--review-requested=@me` search after being absent).
  **Re-run Review** in the History window re-runs one manually at any time.
- **Failures are never auto-retried** (no silent token burn) — you get a
  notification and a failed history entry instead.
- **Publishes by default**: the prompt is `/review-pr {url} --publish`, so the
  verdict (approve / request changes) and grouped findings are posted to the
  GitHub PR. For local-only reports, remove `--publish` from the prompt
  template in Settings.
- **Scoped tool allowlist**: beyond read-only tools, only the `gh` commands
  publishing needs (`gh pr review`, `gh pr comment`, `gh api`) plus `Write`
  (for review payload files) are allowed — the review cannot run arbitrary
  shell commands.
- Runs execute in parallel up to a configurable agent cap (default 3, Settings
  → General); further runs queue. The same PR/scan is never started twice
  concurrently, and a timeout (default 40 min) kills runaways.
- **Dependabot, update scans & ticket deep-dives are opt-in** (off by
  default) and scoped to an explicit repo list. Pre-existing Dependabot PRs
  are baselined (seen, not reviewed); due scans and deep-dives queue behind
  the agent cap. Each run kind has its own allowlist: dependabot reviews
  add worktree + package-manager commands and Jira commenting; update scans
  additionally allow `Edit`, commits, pushes restricted to `deps/*` branches,
  `gh pr create`, and Jira issue creation; ticket deep-dives get Jira
  search/read/comment/label instead of issue creation. None can approve or
  merge.
- **Update scans and ticket deep-dives never touch your working copy** —
  verification happens in a throwaway `git worktree`, and a run that proves
  nothing safe ends with a report (or an analysis comment), not a PR. A
  deep-dive PR requires *both* halves: every breaking change shown to not
  affect the codebase, and a fully green verification against a green base.

## Files

| Path | Purpose |
|---|---|
| `~/Library/Application Support/CCVerify/state.json` | run history + seen set |
| `~/Library/Application Support/CCVerify/reviews/*.md` | review reports |
| `~/Library/Application Support/CCVerify/ccverify.log` | poller log |

## Troubleshooting

- **No local checkout found** — the PR's repo must be cloned directly under
  the repos directory (default `~/Documents/Repos`) with an `origin` remote
  pointing at github.com.
- **Documents access** — if macOS asks that CCVerify may access your
  Documents folder, allow it (repos live there). If it was denied, re-enable
  in System Settings → Privacy & Security → Files and Folders.
- **Poll errors in the menu** — usually `gh` auth; run `gh auth status`.
- `tail -f ~/Library/Application\ Support/CCVerify/ccverify.log` shows every
  poll and review.
