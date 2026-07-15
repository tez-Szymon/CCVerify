#!/bin/bash
# Build CCVerify.app into dist/. Pass --run to launch it afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/dist/CCVerify.app"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CCVerify "$APP/Contents/MacOS/CCVerify"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force -s - "$APP"

echo "Built: $APP"
if [ "${1:-}" = "--run" ]; then
  # Relaunch cleanly if already running.
  pkill -x CCVerify 2>/dev/null && sleep 1 || true
  open "$APP"
  echo "Launched."
fi
