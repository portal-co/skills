#!/usr/bin/env bash
# install.sh
# Symlinks this skills registry into the standard locations for pi and Claude Code.
# Safe to run multiple times — existing symlinks are updated, not duplicated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY_NAME="portal"

echo "Portal Solutions Agent Skills — Install"
echo "Source: $REPO_ROOT"
echo ""

link_skill_dir() {
  local target_dir="$1"
  local link_path="$target_dir/$REGISTRY_NAME"

  mkdir -p "$target_dir"

  if [[ -L "$link_path" ]]; then
    existing=$(readlink "$link_path")
    if [[ "$existing" == "$REPO_ROOT" ]]; then
      echo "  ✓ $link_path → already linked"
      return
    else
      echo "  ~ $link_path → updating (was: $existing)"
      rm "$link_path"
    fi
  elif [[ -e "$link_path" ]]; then
    echo "  ! $link_path exists and is not a symlink — skipping (remove manually to re-link)"
    return
  fi

  ln -s "$REPO_ROOT" "$link_path"
  echo "  ✓ $link_path → $REPO_ROOT"
}

# Pi: ~/.agents/skills/portal
link_skill_dir "$HOME/.agents/skills"

# Claude Code: ~/.claude/skills/portal
link_skill_dir "$HOME/.claude/skills"

echo ""
echo "Done. Skills will be discovered automatically on next agent start."
echo ""
echo "Manual setup (if auto-discovery is disabled):"
echo "  pi settings.json:     { \"skills\": [\"$REPO_ROOT\"] }"
echo "  Claude settings.json: { \"skills\": [\"$REPO_ROOT\"] }"
