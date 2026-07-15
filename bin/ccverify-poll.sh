#!/bin/bash
# CCVerify — poll GitHub for PRs where my review is requested and run a local
# Claude Code review (/review-pr) on each new one. Designed to be run by
# launchd every couple of minutes; safe to run manually too.
#
# Usage: ccverify-poll.sh [--dry-run]
#   --dry-run  Detect and log new review requests but do not run claude.

set -u

CCV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$CCV_ROOT/config.sh"
[ -f "$CCV_ROOT/config.local.sh" ] && source "$CCV_ROOT/config.local.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

mkdir -p "$STATE_DIR" "$LOG_DIR" "$REVIEWS_DIR"
LOG_FILE="$LOG_DIR/poller.log"
SEEN_FILE="$STATE_DIR/seen.json"

# launchd runs with a minimal environment. Set a sane PATH and make sure an
# API key never leaks in — claude must bill against the subscription (OAuth).
export PATH="$(dirname "$CLAUDE_BIN"):$(dirname "$GH_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

notify() {
  [ "$NOTIFY" = true ] || return 0
  /usr/bin/osascript -e "display notification \"$2\" with title \"CCVerify\" subtitle \"$1\"" >/dev/null 2>&1
}

# Rotate the log once it grows past ~5 MB.
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  mv "$LOG_FILE" "$LOG_FILE.old"
fi

# --- Locking: a review can take much longer than the poll interval ---------
LOCK_DIR="$STATE_DIR/lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo 0)"
  if [ "$lock_pid" -gt 0 ] && kill -0 "$lock_pid" 2>/dev/null; then
    # A previous run (likely mid-review) is still going. Skip this tick.
    exit 0
  fi
  log "Removing stale lock (pid $lock_pid is gone)"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# --- Fetch open PRs where my review is requested ----------------------------
draft_flag=""
[ "$INCLUDE_DRAFTS" = false ] && draft_flag="--draft=false"

results="$("$GH_BIN" search prs --review-requested=@me --state=open $draft_flag \
  --limit 50 --json number,title,url,updatedAt 2>>"$LOG_FILE")"
if [ -z "$results" ]; then
  log "gh search failed (see stderr above); will retry next tick"
  exit 0
fi

count="$("$JQ_BIN" 'length' <<<"$results")"

# --- First run: baseline. Mark everything currently open as seen so we only
# ever react to NEW review requests (and don't burn tokens on backlog). ------
if [ ! -f "$SEEN_FILE" ]; then
  "$JQ_BIN" 'map({key: (.url | sub("https://github.com/"; "") | sub("/pull/"; "#")), value: .updatedAt}) | from_entries' \
    <<<"$results" > "$SEEN_FILE"
  log "First run: baselined $count existing review request(s); watching for new ones"
  exit 0
fi

# --- Detect new review requests ---------------------------------------------
new_items="$("$JQ_BIN" -c --slurpfile seen "$SEEN_FILE" \
  '.[] | select(($seen[0][(.url | sub("https://github.com/"; "") | sub("/pull/"; "#"))]) == null)' \
  <<<"$results")"

[ -z "$new_items" ] && exit 0

# Resolve a GitHub owner/repo to a local checkout under REPOS_DIR by matching
# the `origin` remote. Comparison is case-insensitive; `.git` suffix ignored.
resolve_local_path() {
  local want="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  local d url norm
  for d in "$REPOS_DIR"/*/; do
    [ -d "$d/.git" ] || continue
    url="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
    norm="$(tr '[:upper:]' '[:lower:]' <<<"$url")"
    norm="${norm%.git}"
    norm="${norm#git@github.com:}"
    norm="${norm#https://github.com/}"
    norm="${norm#ssh://git@github.com/}"
    if [ "$norm" = "$want" ]; then
      printf '%s' "${d%/}"
      return 0
    fi
  done
  return 1
}

run_review() {
  local repo_full="$1" number="$2" url="$3" title="$4" local_path="$5"
  local safe_name report prompt claude_pid waited rc
  safe_name="$(tr '/' '-' <<<"$repo_full")-pr${number}-$(date +%Y%m%d-%H%M%S)"
  report="$REVIEWS_DIR/$safe_name.md"

  prompt="$CLAUDE_PROMPT"
  prompt="${prompt//\{url\}/$url}"
  prompt="${prompt//\{repo\}/$repo_full}"
  prompt="${prompt//\{number\}/$number}"
  prompt="${prompt//\{title\}/$title}"

  log "Reviewing $repo_full#$number ($title) in $local_path"
  notify "Review started" "$repo_full#$number — $title"

  ( cd "$local_path" && "$CLAUDE_BIN" -p "$prompt" \
      --allowedTools "$CLAUDE_ALLOWED_TOOLS" $CLAUDE_EXTRA_ARGS \
      > "$report" 2>>"$LOG_FILE" ) &
  claude_pid=$!

  waited=0
  while kill -0 "$claude_pid" 2>/dev/null; do
    if [ "$waited" -ge "$REVIEW_TIMEOUT_SECS" ]; then
      kill "$claude_pid" 2>/dev/null
      sleep 2
      kill -9 "$claude_pid" 2>/dev/null
      log "TIMEOUT after ${REVIEW_TIMEOUT_SECS}s: $repo_full#$number (partial report: $report)"
      notify "Review timed out" "$repo_full#$number"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  wait "$claude_pid"
  rc=$?

  if [ "$rc" -eq 0 ] && [ -s "$report" ]; then
    log "DONE $repo_full#$number → $report"
    notify "Review finished" "$repo_full#$number — report ready"
  else
    log "FAILED (exit $rc) $repo_full#$number (see $report and poller.log)"
    notify "Review FAILED" "$repo_full#$number (exit $rc)"
  fi
  return "$rc"
}

while IFS= read -r item; do
  [ -z "$item" ] && continue
  url="$("$JQ_BIN" -r '.url' <<<"$item")"
  number="$("$JQ_BIN" -r '.number' <<<"$item")"
  title="$("$JQ_BIN" -r '.title' <<<"$item")"
  updated="$("$JQ_BIN" -r '.updatedAt' <<<"$item")"
  repo_full="$(sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#' <<<"$url")"
  key="$repo_full#$number"

  # Mark seen immediately: a failed review is notified + logged, never
  # retried in a loop (that would silently burn plan usage).
  "$JQ_BIN" --arg k "$key" --arg v "$updated" '.[$k] = $v' "$SEEN_FILE" \
    > "$SEEN_FILE.tmp" && mv "$SEEN_FILE.tmp" "$SEEN_FILE"

  log "NEW review request: $key ($title)"

  if [ "$DRY_RUN" = true ]; then
    log "dry-run: would review $key"
    continue
  fi

  if local_path="$(resolve_local_path "$repo_full")"; then
    run_review "$repo_full" "$number" "$url" "$title" "$local_path"
  else
    log "No local checkout found for $repo_full under $REPOS_DIR — skipping review"
    notify "Review requested (no local repo)" "$key — clone it under Repos/ to auto-review"
  fi
done <<<"$new_items"

exit 0
