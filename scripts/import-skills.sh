#!/usr/bin/env bash
# import-skills.sh
# Imports skills from repos in the portal-co GitHub org.
#
# Each repo may expose skills in one of two ways:
#   1. A top-level SKILL.md   → imported as <repo>/SKILL.md
#   2. A top-level skills/    → each subdir with a SKILL.md is imported
#      as <repo>/<skill-name>/SKILL.md (plus any sibling files)
#
# Imported skills land in a folder named after the repo at the registry root.
# The manifest (imports.json) records source SHAs so reruns only overwrite
# files that have changed upstream (unless --force is given).
#
# Usage:
#   ./scripts/import-skills.sh                 # scan all org repos
#   ./scripts/import-skills.sh <repo>          # import one repo
#   ./scripts/import-skills.sh --list          # list repos that have skills
#   ./scripts/import-skills.sh --force         # overwrite even locally modified files
#   ./scripts/import-skills.sh --dry-run       # show what would change, don't write

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMPORTS_FILE="$REPO_ROOT/imports.json"
ORG="portal-co"

# ── flags ────────────────────────────────────────────────────────────────────
LIST_ONLY=false
FORCE=false
DRY_RUN=false
TARGET_REPO=""

for arg in "$@"; do
  case "$arg" in
    --list)     LIST_ONLY=true ;;
    --force)    FORCE=true ;;
    --dry-run)  DRY_RUN=true ;;
    --*)        echo "Unknown flag: $arg" >&2; exit 1 ;;
    *)          TARGET_REPO="$arg" ;;
  esac
done

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
info() { echo "$*"; }
warn() { echo "  WARNING: $*" >&2; }

require_cmd() {
  command -v "$1" &>/dev/null || { echo "Error: '$1' not found. $2" >&2; exit 1; }
}

require_cmd gh   "Install the GitHub CLI: https://cli.github.com"
require_cmd jq   "Install jq: https://stedolan.github.io/jq"
require_cmd python3 "Install Python 3"

# Read current imports manifest
read_imports() {
  if [[ -f "$IMPORTS_FILE" ]]; then
    cat "$IMPORTS_FILE"
  else
    echo '{"org":"'"$ORG"'","imports":[]}'
  fi
}

# Check if a path exists in a GitHub repo (returns the API JSON or empty)
gh_path_json() {
  local repo="$1" path="$2"
  gh api "repos/$ORG/$repo/contents/$path" 2>/dev/null || true
}

# Download a single file by its API URL, return content (base64-decoded)
gh_file_content() {
  local download_url="$1"
  gh api "$download_url" 2>/dev/null \
    | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['content']).decode())" \
    2>/dev/null || \
  # Fallback: direct download_url fetch
  curl -fsSL "$download_url" 2>/dev/null || true
}

# Get the SHA of a file from the API JSON blob
file_sha() {
  echo "$1" | jq -r '.sha // empty'
}

# ── skill discovery ──────────────────────────────────────────────────────────

# Returns a list of repos to process
list_repos() {
  if [[ -n "$TARGET_REPO" ]]; then
    echo "$TARGET_REPO"
    return
  fi
  gh repo list "$ORG" --limit 200 --json name,isArchived \
    --jq '.[] | select(.isArchived == false) | .name'
}

# For a given repo, discover importable skill paths.
# Outputs lines of: <type> <remote_path> <local_dest>
#   type = file (single SKILL.md) or dir (skills/ subdir tree)
discover_skills() {
  local repo="$1"
  local found=false

  # 1. Check for top-level SKILL.md
  local top_skill
  top_skill=$(gh_path_json "$repo" "SKILL.md")
  if [[ -n "$top_skill" ]] && echo "$top_skill" | jq -e '.type == "file"' &>/dev/null; then
    echo "file SKILL.md $repo/SKILL.md"
    found=true
  fi

  # 2. Check for a skills/ directory
  local skills_dir
  skills_dir=$(gh_path_json "$repo" "skills")
  if [[ -n "$skills_dir" ]] && echo "$skills_dir" | jq -e 'type == "array"' &>/dev/null; then
    # Each entry in skills/ that is a directory may be a skill
    while IFS= read -r entry_json; do
      local entry_type entry_name
      entry_type=$(echo "$entry_json" | jq -r '.type')
      entry_name=$(echo "$entry_json" | jq -r '.name')
      if [[ "$entry_type" == "dir" ]]; then
        # Check that it contains a SKILL.md
        local skill_md
        skill_md=$(gh_path_json "$repo" "skills/$entry_name/SKILL.md")
        if [[ -n "$skill_md" ]] && echo "$skill_md" | jq -e '.type == "file"' &>/dev/null; then
          echo "skill_dir skills/$entry_name $repo/$entry_name"
          found=true
        fi
      fi
    done < <(echo "$skills_dir" | jq -c '.[]')
  fi

  $found || true
}

# ── file writing ─────────────────────────────────────────────────────────────

# Write a single skill file, respecting --dry-run and local-modification checks.
# Args: repo remote_api_path local_rel_path expected_sha
write_skill_file() {
  local repo="$1"
  local remote_api_path="$2"
  local local_rel="$3"
  local remote_sha="$4"

  local local_abs="$REPO_ROOT/$local_rel"

  # Check if locally modified vs last import
  if [[ -f "$local_abs" ]] && ! $FORCE; then
    local recorded_sha
    recorded_sha=$(python3 - "$IMPORTS_FILE" "$local_rel" <<'PYEOF'
import sys, json
manifest = json.load(open(sys.argv[1]))
target = sys.argv[2]
for imp in manifest.get("imports", []):
    for f in imp.get("files", []):
        if f.get("local") == target:
            print(f.get("sha", ""))
            sys.exit(0)
PYEOF
    )
    if [[ -n "$recorded_sha" && "$recorded_sha" != "$remote_sha" ]]; then
      # Check if local file differs from the version we imported
      local git_status
      git_status=$(git -C "$REPO_ROOT" status --porcelain "$local_rel" 2>/dev/null || true)
      if [[ -n "$git_status" ]]; then
        warn "Skipping locally modified file: $local_rel (use --force to overwrite)"
        return
      fi
    fi
    # If SHA unchanged, skip download
    if [[ "$recorded_sha" == "$remote_sha" ]]; then
      log "  = $local_rel (unchanged)"
      return
    fi
  fi

  if $DRY_RUN; then
    log "  + $local_rel (would write)"
    return
  fi

  mkdir -p "$(dirname "$local_abs")"
  # Fetch file content via the contents API
  local content
  content=$(gh api "repos/$ORG/$repo/contents/$remote_api_path" \
    | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['content']).decode())")
  printf '%s' "$content" > "$local_abs"
  log "  ↓ $local_rel"
}

# ── manifest update ──────────────────────────────────────────────────────────

update_manifest() {
  local repo="$1"
  shift
  # Remaining args: pairs of "local_rel:remote_sha"
  local -a file_entries=("$@")

  if $DRY_RUN; then return; fi

  python3 - "$IMPORTS_FILE" "$repo" "${file_entries[@]}" <<'PYEOF'
import sys, json
from datetime import datetime, timezone

manifest_path = sys.argv[1]
repo = sys.argv[2]
file_pairs = sys.argv[3:]

try:
    with open(manifest_path) as f:
        manifest = json.load(f)
except Exception:
    manifest = {"org": "portal-co", "imports": []}

today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

# Build file list
files = []
for pair in file_pairs:
    local, sha = pair.rsplit(":", 1)
    files.append({"local": local, "sha": sha})

# Find or create entry for this repo
found = False
for imp in manifest.get("imports", []):
    if imp.get("repo") == repo:
        imp["synced"] = today
        imp["files"] = files
        found = True
        break

if not found:
    manifest.setdefault("imports", []).append({
        "repo": repo,
        "synced": today,
        "files": files,
    })

with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PYEOF
}

# ── import a single repo ─────────────────────────────────────────────────────

import_repo() {
  local repo="$1"
  info "[$repo]"

  local discoveries
  discoveries=$(discover_skills "$repo")

  if [[ -z "$discoveries" ]]; then
    log "no skills found — skipping"
    return
  fi

  local -a manifest_pairs=()

  while IFS= read -r discovery; do
    local dtype remote_path local_dest
    dtype=$(echo "$discovery" | awk '{print $1}')
    remote_path=$(echo "$discovery" | awk '{print $2}')
    local_dest=$(echo "$discovery" | awk '{print $3}')

    if [[ "$dtype" == "file" ]]; then
      # Single SKILL.md at repo root
      local file_json sha
      file_json=$(gh api "repos/$ORG/$repo/contents/SKILL.md" 2>/dev/null || true)
      sha=$(echo "$file_json" | jq -r '.sha // empty')
      write_skill_file "$repo" "SKILL.md" "$local_dest" "$sha"
      manifest_pairs+=("$local_dest:$sha")

    elif [[ "$dtype" == "skill_dir" ]]; then
      # A skill subdirectory under skills/
      local skill_remote_dir skill_local_dir
      skill_remote_dir="$remote_path"          # e.g. skills/my-skill
      skill_local_dir="$local_dest"            # e.g. volar/my-skill

      # Fetch the directory listing and recursively import all files
      local dir_json
      dir_json=$(gh_path_json "$repo" "$skill_remote_dir")
      if [[ -z "$dir_json" ]]; then continue; fi

      # Process all files in the skill directory (non-recursive for now; skills should be flat)
      while IFS= read -r entry; do
        local etype ename
        etype=$(echo "$entry" | jq -r '.type')
        ename=$(echo "$entry" | jq -r '.name')

        if [[ "$etype" == "file" ]]; then
          local esha
          esha=$(echo "$entry" | jq -r '.sha // empty')
          local local_file="$skill_local_dir/$ename"
          write_skill_file "$repo" "$skill_remote_dir/$ename" "$local_file" "$esha"
          manifest_pairs+=("$local_file:$esha")
        elif [[ "$etype" == "dir" ]]; then
          # One level of subdirs (scripts/, references/, assets/)
          local subdir_json
          subdir_json=$(gh_path_json "$repo" "$skill_remote_dir/$ename")
          while IFS= read -r subentry; do
            local stype sname ssha
            stype=$(echo "$subentry" | jq -r '.type')
            sname=$(echo "$subentry" | jq -r '.name')
            ssha=$(echo "$subentry" | jq -r '.sha // empty')
            if [[ "$stype" == "file" ]]; then
              local local_sub="$skill_local_dir/$ename/$sname"
              write_skill_file "$repo" "$skill_remote_dir/$ename/$sname" "$local_sub" "$ssha"
              manifest_pairs+=("$local_sub:$ssha")
            fi
          done < <(echo "$subdir_json" | jq -c '.[]' 2>/dev/null || true)
        fi
      done < <(echo "$dir_json" | jq -c '.[]' 2>/dev/null || true)
    fi
  done <<< "$discoveries"

  update_manifest "$repo" "${manifest_pairs[@]+"${manifest_pairs[@]}"}"
}

# ── main ─────────────────────────────────────────────────────────────────────

info "Portal Solutions — Skill Importer"
info "Org: $ORG"
$DRY_RUN  && info "(dry run — no files will be written)"
$FORCE    && info "(force — locally modified files will be overwritten)"
info ""

repos=$(list_repos)

if $LIST_ONLY; then
  info "Repos with skills:"
  while IFS= read -r repo; do
    discoveries=$(discover_skills "$repo")
    if [[ -n "$discoveries" ]]; then
      echo "  $repo"
      while IFS= read -r d; do
        echo "    $(echo "$d" | awk '{print $3}')"
      done <<< "$discoveries"
    fi
  done <<< "$repos"
  exit 0
fi

while IFS= read -r repo; do
  import_repo "$repo"
done <<< "$repos"

info ""
if ! $DRY_RUN; then
  info "Import complete. Run ./scripts/sync-registry.sh to update registry.json."
fi
