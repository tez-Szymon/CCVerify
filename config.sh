# CCVerify configuration (sourced by bin/ccverify-poll.sh).
# Machine-specific overrides go in config.local.sh (git-ignored), which is
# sourced after this file and wins.

# Where your local git checkouts live (immediate subdirectories are scanned
# and matched to GitHub repos by their `origin` remote URL).
REPOS_DIR="$HOME/Documents/Repos"

# Binaries (launchd runs with a minimal PATH, so absolute paths matter).
CLAUDE_BIN="$HOME/.local/bin/claude"
GH_BIN="/opt/homebrew/bin/gh"
JQ_BIN="/usr/bin/jq"

# Skip draft PRs (review usually starts when the PR is marked ready).
INCLUDE_DRAFTS=false

# Prompt passed to `claude -p`. {url} / {repo} / {number} / {title} are replaced.
CLAUDE_PROMPT='/review-pr {url}'

# Extra arguments for the claude invocation. The default allowlist is
# read-only + gh/git reads: the review CANNOT post PR comments or edit files.
# To let it post the review to the PR, add: 'Bash(gh pr comment:*),Bash(gh pr review:*)'
CLAUDE_ALLOWED_TOOLS='Read,Grep,Glob,Task,Agent,TodoWrite,WebFetch,WebSearch,Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh pr checks:*),Bash(gh api:*),Bash(gh search:*),Bash(git log:*),Bash(git show:*),Bash(git diff:*),Bash(git fetch:*),Bash(git branch:*),Bash(git status:*)'
CLAUDE_EXTRA_ARGS=""

# Kill a review that runs longer than this many seconds.
REVIEW_TIMEOUT_SECS=2400

# macOS notifications on review start / finish / failure.
NOTIFY=true

# Where state, logs and finished review reports are kept (all git-ignored).
CCV_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$CCV_HOME/state"
LOG_DIR="$CCV_HOME/logs"
REVIEWS_DIR="$CCV_HOME/reviews"
