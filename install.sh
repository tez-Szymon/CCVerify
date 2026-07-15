#!/bin/bash
# Install the CCVerify launchd agent for the current user.
set -euo pipefail

CCV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_LABEL="com.ccverify.poller"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents" "$CCV_ROOT/logs" "$CCV_ROOT/state" "$CCV_ROOT/reviews"
chmod +x "$CCV_ROOT/bin/ccverify-poll.sh"

sed "s#__CCV_ROOT__#$CCV_ROOT#g" \
  "$CCV_ROOT/launchd/$PLIST_LABEL.plist.template" > "$PLIST_DST"

# Reload if already installed.
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

echo "Installed: $PLIST_DST"
echo "Poller runs every 120s. Logs: $CCV_ROOT/logs/poller.log"
echo "First run baselines currently-open review requests (no reviews fired for backlog)."
