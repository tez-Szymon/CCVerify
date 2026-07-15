#!/bin/bash
# Remove the CCVerify launchd agent (repo, state and reviews are left intact).
set -euo pipefail

PLIST_LABEL="com.ccverify.poller"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
rm -f "$PLIST_DST"
echo "Uninstalled $PLIST_LABEL"
