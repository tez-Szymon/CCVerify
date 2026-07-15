# CCVerify

A native macOS **menu bar app** that watches GitHub for PRs where **your review
is requested** and automatically runs a **local Claude Code review**
(`claude -p "/review-pr <url>"`) inside your checkout of that repo — with a
history of runs, per-run details, and the full review report in the app.

No server, no webhooks, no repo admin rights: it polls
`gh search prs --review-requested=@me` every 2 minutes.

## Features

- **Menu bar status** — watching / reviewing / paused / poll errors, plus the
  five most recent runs at a glance.
- **History window** — every run with status (done / failed / timed out /
  no local repo), timestamps, duration, exit code, and the full review report
  rendered in-app. Open the PR, reveal the report file, or re-run a review.
- **Settings window** (⌘,) — poll interval, repos directory, prompt template,
  allowed tools, timeout, draft filtering, notifications, launch at login.
- **macOS notifications** on review start / finish / failure.

## How it works

```
CCVerify.app (menu bar, SwiftUI)
  └─ every N seconds: gh search prs --review-requested=@me --state=open
       ├─ diff against seen set (first poll baselines the backlog)
       ├─ match owner/repo → local checkout under ~/Documents/Repos
       │    (by each folder's `origin` remote in .git/config)
       └─ for each NEW review request:
            cd <local repo> && claude -p "/review-pr <url>" --allowedTools <read-only set>
            → report + history entry in ~/Library/Application Support/CCVerify/
            → notification
```

## Build & run

```bash
./build.sh          # builds dist/CCVerify.app (Swift 5.9+, macOS 14+)
./build.sh --run    # build + (re)launch
```

Requirements: Xcode (or CLT with Swift), `gh` (authenticated), `claude`
(logged in with your subscription via `/login`).

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
- **Read-only tool allowlist**: the review cannot edit files or post PR
  comments. To let it post, add `Bash(gh pr comment:*),Bash(gh pr review:*)`
  to *Allowed tools* in Settings.
- Reviews run sequentially; a timeout (default 40 min) kills runaways.

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
