#!/usr/bin/env bash
# open-sync-pr.sh
# Commit staged import changes and open or update the canonical sync PR.
#
# Called by .github/workflows/sync-skills.yml after import-skills.sh when
# the index is dirty. Reuses an open PR on branch `sync/skills` by appending
# a commit (no force-push onto an open PR). If no open PR exists, starts a
# fresh PR from current main.
#
# Environment (optional):
#   SYNC_SCOPE     Human-readable source description for the PR title/body
#   SYNC_EVENT     Triggering GitHub event name
#   SYNC_RUN_URL   Actions run URL to link from the PR
#   GH_TOKEN       Token with contents:write and pull-requests:write
#
# Usage:
#   git add -A
#   ./scripts/open-sync-pr.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BRANCH="sync/skills"
BASE="main"
DATE="$(date -u +%Y-%m-%d)"
SCOPE="${SYNC_SCOPE:-all public portal-co repos}"
EVENT="${SYNC_EVENT:-manual}"
RUN_URL="${SYNC_RUN_URL:-}"

require_cmd() {
  command -v "$1" &>/dev/null || { echo "Error: '$1' not found. $2" >&2; exit 1; }
}

require_cmd git "Install git"
require_cmd gh  "Install the GitHub CLI: https://cli.github.com"

if git diff --staged --quiet; then
  echo "No staged changes — nothing to open a PR for."
  exit 0
fi

git config user.name  "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git config user.email "${GIT_AUTHOR_EMAIL:-github-actions[bot]@users.noreply.github.com}"

COMMIT_MSG="sync: import skills from portal-co repos (${DATE})"

write_pr_body() {
  local body_file="$1"
  local changed_files="$2"
  {
    echo "## Automated skill sync"
    echo ""
    echo "**Source:** ${SCOPE}"
    echo "**Triggered by:** ${EVENT}"
    echo "**Date:** ${DATE}"
    echo ""
    if [[ -n "$RUN_URL" ]]; then
      echo "This PR was opened automatically by the [Sync skills workflow](${RUN_URL})."
      echo ""
    fi
    echo "### Changed files"
    echo ""
    echo '```'
    echo "${changed_files}"
    echo '```'
    echo ""
    echo "### Review checklist"
    echo ""
    echo "- [ ] Skill content looks correct and isn't malicious"
    echo "- [ ] No private or sensitive data was included"
    echo "- [ ] \`imports.json\` and \`registry.json\` are consistent"
    echo ""
    echo "_Merge when satisfied. The source repos remain the authoritative copy — edits here will be overwritten on the next sync unless the repo is added to \`import-config.json\` exclude list._"
  } > "$body_file"
}

EXISTING_PR="$(gh pr list --base "$BASE" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"

if [[ -n "$EXISTING_PR" ]]; then
  echo "Reusing open PR #${EXISTING_PR} on ${BRANCH}"

  # Snapshot the import without moving the current branch (usually main).
  IMPORT_COMMIT="$(git commit-tree "$(git write-tree)" -p HEAD -m "$COMMIT_MSG")"
  git reset --hard HEAD
  git clean -fd

  git fetch origin "$BRANCH" "$BASE"
  git checkout -B "$BRANCH" "origin/$BRANCH"
  git merge "origin/$BASE" --no-edit

  git checkout "$IMPORT_COMMIT" -- .
  git add -A

  if git diff --cached --quiet && git diff --quiet; then
    echo "Open PR already contains this import — nothing to append."
    CHANGED_FILES="$(git diff "origin/${BASE}...HEAD" --name-only | head -50)"
  else
    git commit -m "$COMMIT_MSG"
    git push origin "$BRANCH"
    CHANGED_FILES="$(git diff "origin/${BASE}...HEAD" --name-only | head -50)"
  fi

  COMMENT_FILE="$(mktemp)"
  {
    echo "Sync appended ${DATE}."
    echo ""
    echo "**Triggered by:** ${EVENT}"
    if [[ -n "$RUN_URL" ]]; then
      echo "**Run:** ${RUN_URL}"
    fi
    echo ""
    echo "### Changed files"
    echo ""
    echo '```'
    echo "${CHANGED_FILES}"
    echo '```'
  } > "$COMMENT_FILE"
  gh pr comment "$EXISTING_PR" --body-file "$COMMENT_FILE"
  rm -f "$COMMENT_FILE"
  echo "Updated PR #${EXISTING_PR}"
else
  echo "No open sync PR — creating ${BRANCH}"

  git checkout -B "$BRANCH"
  git commit -m "$COMMIT_MSG"

  # Replace a leftover closed-PR branch so the new PR starts from main.
  # Never force-push when an open PR is tracking this branch (handled above).
  git push --force-with-lease origin "$BRANCH"

  CHANGED_FILES="$(git diff "origin/${BASE}...HEAD" --name-only | head -50)"
  BODY_FILE="$(mktemp)"
  write_pr_body "$BODY_FILE" "$CHANGED_FILES"

  gh pr create \
    --base "$BASE" \
    --head "$BRANCH" \
    --title "sync: skill import from ${SCOPE} (${DATE})" \
    --body-file "$BODY_FILE"
  rm -f "$BODY_FILE"
  echo "Opened new sync PR on ${BRANCH}"
fi
