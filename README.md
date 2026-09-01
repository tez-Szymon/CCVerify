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
  inside the main window, split into General / Reviews / Dependabot / Updates
  tabs: poll interval, repos directory, prompt templates, allowed tools,
  timeout, draft filtering, notifications, launch at login.
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
  Nothing safe to bump → a report, and no PR.

## How it works

```
CCVerify.app (menu bar, SwiftUI)
  └─ every N seconds: gh search prs --review-requested=@me --state=open
       ├─ diff against seen set (first poll baselines the backlog)
       ├─ match owner/repo → local checkout under ~/Documents/Repos
       │    (by each folder's `origin` remote in .git/config)
       └─ for each NEW review request:
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
an unattended `--auto` mode), and `/update-dependencies` (safe update scan).

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
- **One review per PR** (keyed `owner/repo#number`); a re-request after new
  commits does not re-trigger. Use **Re-run Review** in the History window.
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
- Reviews run sequentially; a timeout (default 40 min) kills runaways.
- **Dependabot & update scans are opt-in** (off by default) and scoped to an
  explicit repo list. Both features baseline first: pre-existing Dependabot
  PRs are marked seen without being reviewed, and update scans run at most one
  repo per poll tick. Each run kind has its own allowlist: dependabot reviews
  add worktree + package-manager commands and Jira commenting; update scans
  additionally allow `Edit`, commits, pushes restricted to `deps/*` branches,
  `gh pr create`, and Jira issue creation. Neither can approve or merge.
- **Update scans never touch your working copy** — verification happens in a
  throwaway `git worktree`, and a scan that finds nothing provably safe ends
  with a report, not a PR.

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
