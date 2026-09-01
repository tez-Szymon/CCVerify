#!/bin/bash
# Install the /review-pr command and pr-reviewer agents into ~/.claude so
# CCVerify's default prompt (/review-pr {url} --publish) works on this machine.
# Existing files are never overwritten unless you pass --force.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

install_file() {
  local src="$1" dst="$2"
  if [ -f "$dst" ] && [ "$FORCE" = false ]; then
    if cmp -s "$src" "$dst"; then
      echo "up to date:  ~${dst#"$HOME"}"
    else
      echo "SKIPPED (exists, differs — rerun with --force to overwrite): ~${dst#"$HOME"}"
    fi
    return
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "installed:   ~${dst#"$HOME"}"
}

for cmd in "$ROOT"/claude/commands/*.md; do
  install_file "$cmd" "$HOME/.claude/commands/$(basename "$cmd")"
done
for agent in "$ROOT"/claude/agents/pr-reviewer-*.md; do
  install_file "$agent" "$HOME/.claude/agents/$(basename "$agent")"
done
for skill in "$ROOT"/claude/skills/*/SKILL.md; do
  install_file "$skill" "$HOME/.claude/skills/$(basename "$(dirname "$skill")")/SKILL.md"
done

echo
echo "Done. CCVerify's prompts now resolve:"
echo "  /review-pr {url} --publish            (review requests)"
echo "  /review-dependabot-pr {number} --auto (Dependabot PRs)"
echo "  /update-dependencies --auto           (dependency update scans)"
echo "  /analyze-dep-tickets --auto           (dep-major ticket deep-dives)"
