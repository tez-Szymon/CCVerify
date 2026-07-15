# CCVerify

Local, webhook-free automation: when someone requests **your** review on a
GitHub PR, CCVerify notices within ~2 minutes and runs a **local Claude Code
review** (`claude -p "/review-pr <url>"`) inside your checkout of that repo.
The finished report lands in `reviews/` and you get a macOS notification.

No server, no webhooks, no repo admin rights needed — just a `launchd` job
polling `gh search prs --review-requested=@me` every 120 seconds.

## How it works

```
launchd (every 120s)
  └─ bin/ccverify-poll.sh
       ├─ gh search prs --review-requested=@me --state=open
       ├─ diff against state/seen.json  (first run only baselines the backlog)
       ├─ match owner/repo → local checkout under ~/Documents/Repos
       │    (by each folder's `origin` remote)
       └─ for each NEW review request:
            cd <local repo> && claude -p "/review-pr <url>"
            → reviews/<owner>-<repo>-pr<N>-<timestamp>.md
            → macOS notification (started / finished / failed)
```

## Install

```bash
./install.sh      # generates + loads ~/Library/LaunchAgents/com.ccverify.poller.plist
./uninstall.sh    # stops and removes the agent
```

Requirements: `gh` (authenticated), `jq`, `claude` (logged in with your
subscription via `/login`).

## Billing / auth notes

- Runs on your **normal Claude subscription** (OAuth login), drawing from plan
  usage limits — the poller explicitly `unset`s `ANTHROPIC_API_KEY` /
  `ANTHROPIC_AUTH_TOKEN` so a stray key can never switch it to per-token API
  billing.
- Deliberately **not** `--bare` mode: we want CLAUDE.md, skills (`/review-pr`)
  and agents from the target repo loaded.

## Configuration

Defaults live in `config.sh`; put machine-specific overrides in
`config.local.sh` (git-ignored). Notable knobs:

| Variable | Default | Meaning |
|---|---|---|
| `REPOS_DIR` | `~/Documents/Repos` | Where local checkouts are matched |
| `CLAUDE_PROMPT` | `/review-pr {url}` | Prompt template (`{url}`, `{repo}`, `{number}`, `{title}`) |
| `CLAUDE_ALLOWED_TOOLS` | read-only + `gh`/`git` reads | The review **cannot** post PR comments or edit files by default |
| `REVIEW_TIMEOUT_SECS` | `2400` | Kill runaway reviews |
| `INCLUDE_DRAFTS` | `false` | Ignore draft PRs |
| `NOTIFY` | `true` | macOS notifications |

To let reviews **post to the PR**, add to `config.local.sh`:

```bash
CLAUDE_ALLOWED_TOOLS="$CLAUDE_ALLOWED_TOOLS,Bash(gh pr comment:*),Bash(gh pr review:*)"
```

Poll interval: `StartInterval` in `launchd/com.ccverify.poller.plist.template`
(re-run `./install.sh` after changing it).

## Behavior details & known limits

- **First run baselines**: everything already awaiting your review when the
  poller first runs is marked seen — only *new* requests trigger reviews.
- **Seen = once per PR**: a PR is reviewed once (keyed `owner/repo#number`).
  A re-request after new commits does **not** re-trigger. To force a re-review,
  delete the PR's key from `state/seen.json`.
- **Failures are never retried automatically** (no silent token burn): you get
  a failure notification and a log entry instead.
- **No local checkout → no review**: you're notified, and the PR is skipped.
  Clone the repo under `REPOS_DIR` to include it.
- **One review at a time**: a lock prevents overlapping poller runs; reviews
  for multiple new PRs run sequentially.
- `gh search` hits the GitHub *search* API, which can lag a few seconds behind
  real-time and only sees repos your token can access.

## One-time macOS permission (required)

macOS TCC blocks launchd-spawned processes from touching `~/Documents`, and
both this repo and your checkouts live there — without the grant the agent
exits 126 with `Operation not permitted` and does nothing.

1. System Settings → **Privacy & Security → Full Disk Access**
2. Click **+**, press **⌘⇧G**, enter `/bin/bash`, add it, toggle it **on**
3. Kick the agent: `launchctl kickstart -k gui/$(id -u)/com.ccverify.poller`
4. Verify: `logs/poller.log` should show the baseline line

## Debugging

```bash
bash bin/ccverify-poll.sh --dry-run   # detect + log, don't run claude
tail -f logs/poller.log               # poller activity
launchctl print gui/$(id -u)/com.ccverify.poller   # agent status
```
