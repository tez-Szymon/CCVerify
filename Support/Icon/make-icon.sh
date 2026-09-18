#!/bin/bash
# Regenerate Support/AppIcon.icns from Support/Icon/GenerateIcon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/Support/Icon/GenerateIcon.swift" "$WORK"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Support/AppIcon.icns"
cp "$WORK/AppIcon-preview.png" "$ROOT/Support/Icon/AppIcon-preview.png"

echo "Wrote $ROOT/Support/AppIcon.icns"
