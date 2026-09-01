#!/usr/bin/env bash
# import-skills.sh
# Bulk-imports skills from PUBLIC repos in the portal-co GitHub org.
# Private repos are never discovered by org listing; they are imported only
# via explicit repo+path entries in import-config.json `sources`, or
# `./scripts/import-skills.sh <repo> --path <subpath>`.
#
# Source of truth: each portal-co repo that owns a skill.
# This registry provides: discoverability, updatability, centralization.
#
# Each public repo may expose skills in any of these locations (all are checked):
#   1. SKILL.md at repo root             → <repo>/SKILL.md
#   2. skills/<name>/SKILL.md            → <repo>/<name>/
#   3. .agent/skills/<name>/SKILL.md     → <repo>/<name>/
#   4. .agents/skills/<name>/SKILL.md    → <repo>/<name>/
#   5. .claude/skills/<name>/SKILL.md    → <repo>/<name>/
#
# Configuration: import-config.json controls excludes, include_only,
# source_dirs, and sources (explicit repo+path, including private repos).
#
# After a full bulk run the registry index (registry.json) is regenerated
# automatically. Individual targeted imports print a reminder to sync manually.
#
# Usage:
#   ./scripts/import-skills.sh                      # bulk: public repos + sources[]
#   ./scripts/import-skills.sh <repo>               # targeted: one public repo
#   ./scripts/import-skills.sh <repo> --path <sub>  # explicit path (public or private)
#   ./scripts/import-skills.sh --list               # list repos/paths that expose skills
#   ./scripts/import-skills.sh --dry-run            # preview changes, no writes
#   ./scripts/import-skills.sh --force              # overwrite locally modified files
#   ./scripts/import-skills.sh --no-sync            # skip auto registry sync after bulk run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMPORTS_FILE="$REPO_ROOT/imports.json"
CONFIG_FILE="$REPO_ROOT/import-config.json"
ORG="portal-co"

# ── flags ────────────────────────────────────────────────────────────────────
LIST_ONLY=false
FORCE=false
DRY_RUN=false
NO_SYNC=false
TARGET_REPO=""
TARGET_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)     LIST_ONLY=true; shift ;;
    --force)    FORCE=true; shift ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --no-sync)  NO_SYNC=true; shift ;;
    --path)
      if [[ $# -lt 2 || -z "${2:-}" || "$2" == --* ]]; then
        echo "Error: --path requires a subpath argument" >&2
        exit 1
      fi
      TARGET_PATH="$2"
      shift 2
      ;;
    --*)
      echo "Error: unknown flag '$1'" >&2
      exit 1
      ;;
    *)
      if [[ -n "$TARGET_REPO" ]]; then
        echo "Error: only one repo name may be specified" >&2
        exit 1
      fi
      TARGET_REPO="$1"
      shift
      ;;
  esac
done

if [[ -n "$TARGET_PATH" && -z "$TARGET_REPO" ]]; then
  echo "Error: --path requires a repo name (e.g. ./scripts/import-skills.sh my-repo --path skills/foo)" >&2
  exit 1
fi

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
info() { echo "$*"; }
warn() { echo "  WARNING: $*" >&2; }

require_cmd() {
  command -v "$1" &>/dev/null || { echo "Error: '$1' not found. $2" >&2; exit 1; }
}

require_cmd gh      "Install the GitHub CLI: https://cli.github.com"
require_cmd jq      "Install jq: https://stedolan.github.io/jq"
require_cmd python3 "Install Python 3"

# ── config ───────────────────────────────────────────────────────────────────

# Load import-config.json. Falls back to safe defaults if absent.
# Exports: CFG_EXCLUDE (newline-separated), CFG_INCLUDE_ONLY (newline-separated),
#          CFG_SOURCES (lines of "repo<TAB>path"), SKILL_DIRS (array)
load_config() {
  # Default skill source directories
  SKILL_DIRS=(
    "skills"
    ".agent/skills"
    ".agents/skills"
    ".claude/skills"
  )

  CFG_EXCLUDE=""
  CFG_INCLUDE_ONLY=""
  CFG_SOURCES=""

  if [[ ! -f "$CONFIG_FILE" ]]; then return; fi

  # Always exclude this registry repo itself (safety net regardless of config)
  local self_name
  self_name=$(basename "$REPO_ROOT")

  CFG_EXCLUDE=$(python3 - "$CONFIG_FILE" "$self_name" <<'PYEOF'
import sys, json
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    cfg = {}
self_repo = sys.argv[2]
exclude = cfg.get("exclude", [])
if self_repo not in exclude:
    exclude.append(self_repo)
print("\n".join(exclude))
PYEOF
  )

  CFG_INCLUDE_ONLY=$(python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, json
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    cfg = {}
print("\n".join(cfg.get("include_only", [])))
PYEOF
  )

  CFG_SOURCES=$(python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, json
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    cfg = {}
for src in cfg.get("sources", []):
    repo = (src.get("repo") or "").strip()
    path = (src.get("path") or "").strip().strip("/")
    if repo and path:
        print(f"{repo}\t{path}")
PYEOF
  )

  # Allow config to override the default skill source directories
  local custom_dirs
  custom_dirs=$(python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, json
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    cfg = {}
dirs = cfg.get("source_dirs", [])
print("\n".join(dirs))
PYEOF
  )
  if [[ -n "$custom_dirs" ]]; then
    mapfile -t SKILL_DIRS <<< "$custom_dirs"
  fi
}

is_excluded() {
  local repo="$1"
  [[ -n "$CFG_EXCLUDE" ]] && echo "$CFG_EXCLUDE" | grep -qx "$repo"
}

is_included() {
  local repo="$1"
  # If include_only is empty, all non-excluded repos are included
  [[ -z "$CFG_INCLUDE_ONLY" ]] && return 0
  echo "$CFG_INCLUDE_ONLY" | grep -qx "$repo"
}

# ── GitHub helpers ────────────────────────────────────────────────────────────

# Check if a path exists in a GitHub repo (returns the API JSON or empty)
gh_path_json() {
  local repo="$1" path="$2"
  gh api "repos/$ORG/$repo/contents/$path" 2>/dev/null || true
}

# ── repo listing & visibility ────────────────────────────────────────────────

# Returns public, non-archived repos filtered through import-config.json
list_repos() {
  if [[ -n "$TARGET_REPO" ]]; then
    echo "$TARGET_REPO"
    return
  fi

  local all_repos
  all_repos=$(gh repo list "$ORG" --limit 200 --json name,isArchived,isPrivate \
    --jq '.[] | select(.isArchived == false and .isPrivate == false) | .name')

  while IFS= read -r repo; do
    is_excluded "$repo"  && continue
    is_included "$repo"  || continue
    echo "$repo"
  done <<< "$all_repos"
}

# Verify a single named repo is public; exit with an error if private.
# Private repos require an explicit --path (or a sources[] entry).
assert_repo_public() {
  local repo="$1"
  local is_private
  is_private=$(gh repo view "$ORG/$repo" --json isPrivate --jq '.isPrivate' 2>/dev/null || echo "true")
  if [[ "$is_private" == "true" ]]; then
    echo "Error: $ORG/$repo is private. Pass --path <subpath> to import an explicit path, or add a sources[] entry in import-config.json." >&2
    exit 1
  fi
}

# ── skill discovery ───────────────────────────────────────────────────────────

# For a given repo, discover importable skill paths.
# Outputs lines of: <type> <remote_path> <local_dest>
#   file      → single SKILL.md at repo root
#   skill_dir → a skill subdirectory (with its own SKILL.md)
discover_skills() {
  local repo="$1"
  local found=false

  # 1. Top-level SKILL.md
  local top_skill
  top_skill=$(gh_path_json "$repo" "SKILL.md")
  if [[ -n "$top_skill" ]] && echo "$top_skill" | jq -e '.type == "file"' &>/dev/null; then
    echo "file SKILL.md $repo/SKILL.md"
    found=true
  fi

  # 2. Skill subdirectories in any configured container directory
  local skills_container
  for skills_container in "${SKILL_DIRS[@]}"; do
    local dir_json
    dir_json=$(gh_path_json "$repo" "$skills_container")
    if [[ -z "$dir_json" ]] || ! echo "$dir_json" | jq -e 'type == "array"' &>/dev/null; then
      continue
    fi

    while IFS= read -r entry_json; do
      local entry_type entry_name
      entry_type=$(echo "$entry_json" | jq -r '.type')
      entry_name=$(echo "$entry_json" | jq -r '.name')
      if [[ "$entry_type" == "dir" ]]; then
        local skill_md
        skill_md=$(gh_path_json "$repo" "$skills_container/$entry_name/SKILL.md")
        if [[ -n "$skill_md" ]] && echo "$skill_md" | jq -e '.type == "file"' &>/dev/null; then
          echo "skill_dir $skills_container/$entry_name $repo/$entry_name"
          found=true
        fi
      fi
    done < <(echo "$dir_json" | jq -c '.[]')
  done

  $found || true
}

# Resolve an explicit repo+path into the same discovery lines as discover_skills.
# Path may be:
#   • a SKILL.md file
#   • a directory that contains SKILL.md (one skill)
#   • a container directory of skill dirs (e.g. skills/)
# Local dest is always <repo>/<skill-name>/ (or <repo>/SKILL.md for a root file).
discover_explicit_path() {
  local repo="$1"
  local path="$2"
  path="${path#/}"
  path="${path%/}"

  local json
  json=$(gh_path_json "$repo" "$path")
  if [[ -z "$json" ]]; then
    warn "path not found in $ORG/$repo: $path"
    return
  fi

  # File: must be SKILL.md
  if echo "$json" | jq -e 'type == "object" and .type == "file"' &>/dev/null; then
    local fname
    fname=$(echo "$json" | jq -r '.name')
    if [[ "$fname" != "SKILL.md" ]]; then
      warn "explicit path is not SKILL.md: $path"
      return
    fi
    if [[ "$path" == "SKILL.md" ]]; then
      echo "file SKILL.md $repo/SKILL.md"
    else
      local parent
      parent=$(basename "$(dirname "$path")")
      echo "file $path $repo/$parent/SKILL.md"
    fi
    return
  fi

  if ! echo "$json" | jq -e 'type == "array"' &>/dev/null; then
    warn "unexpected GitHub contents payload for $path"
    return
  fi

  # Directory containing SKILL.md → one skill dir
  if echo "$json" | jq -e '.[] | select(.type == "file" and .name == "SKILL.md")' &>/dev/null; then
    local skill_name
    skill_name=$(basename "$path")
    echo "skill_dir $path $repo/$skill_name"
    return
  fi

  # Container directory: import child skill dirs only
  local found=false
  while IFS= read -r entry_json; do
    local entry_type entry_name
    entry_type=$(echo "$entry_json" | jq -r '.type')
    entry_name=$(echo "$entry_json" | jq -r '.name')
    if [[ "$entry_type" == "dir" ]]; then
      local skill_md
      skill_md=$(gh_path_json "$repo" "$path/$entry_name/SKILL.md")
      if [[ -n "$skill_md" ]] && echo "$skill_md" | jq -e '.type == "file"' &>/dev/null; then
        echo "skill_dir $path/$entry_name $repo/$entry_name"
        found=true
      fi
    fi
  done < <(echo "$json" | jq -c '.[]')

  $found || true
}

# ── file writing ──────────────────────────────────────────────────────────────

# Write a single skill file, respecting --dry-run and local-modification checks.
# Args: repo remote_api_path local_rel_path expected_sha
write_skill_file() {
  local repo="$1"
  local remote_api_path="$2"
  local local_rel="$3"
  local remote_sha="$4"

  local local_abs="$REPO_ROOT/$local_rel"

  if [[ -f "$local_abs" ]] && ! $FORCE; then
    local recorded_sha
    recorded_sha=$(python3 - "$IMPORTS_FILE" "$local_rel" <<'PYEOF'
import sys, json
try:
    manifest = json.load(open(sys.argv[1]))
except Exception:
    manifest = {}
target = sys.argv[2]
for imp in manifest.get("imports", []):
    for f in imp.get("files", []):
        if f.get("local") == target:
            print(f.get("sha", ""))
            sys.exit(0)
PYEOF
    )
    if [[ -n "$recorded_sha" && "$recorded_sha" != "$remote_sha" ]]; then
      local git_status
      git_status=$(git -C "$REPO_ROOT" status --porcelain "$local_rel" 2>/dev/null || true)
      if [[ -n "$git_status" ]]; then
        warn "Skipping locally modified file: $local_rel (use --force to overwrite)"
        return
      fi
    fi
    if [[ "$recorded_sha" == "$remote_sha" ]]; then
      log "= $local_rel (unchanged)"
      return
    fi
  fi

  if $DRY_RUN; then
    log "~ $local_rel (would write)"
    return
  fi

  mkdir -p "$(dirname "$local_abs")"
  local content
  content=$(gh api "repos/$ORG/$repo/contents/$remote_api_path" \
    | python3 -c "import sys,json,base64; d=json.load(sys.stdin); print(base64.b64decode(d['content']).decode())")
  printf '%s' "$content" > "$local_abs"
  log "↓ $local_rel"
}

# ── manifest update ───────────────────────────────────────────────────────────

update_manifest() {
  local repo="$1"
  local mode="${2:-replace}"
  shift 2
  local -a file_entries=("$@")

  if $DRY_RUN; then return; fi

  python3 - "$IMPORTS_FILE" "$repo" "$mode" "${file_entries[@]}" <<'PYEOF'
import sys, json
from datetime import datetime, timezone

manifest_path = sys.argv[1]
repo = sys.argv[2]
mode = sys.argv[3]
file_pairs = sys.argv[4:]

try:
    with open(manifest_path) as f:
        manifest = json.load(f)
except Exception:
    manifest = {"org": "portal-co", "imports": []}

today = datetime.now(timezone.utc).strftime("%Y-%m-%d")

files = []
for pair in file_pairs:
    local, sha = pair.rsplit(":", 1)
    files.append({"local": local, "sha": sha})

found = False
for imp in manifest.get("imports", []):
    if imp.get("repo") == repo:
        imp["synced"] = today
        if mode == "merge":
            existing = {f.get("local"): f for f in imp.get("files", [])}
            for f in files:
                existing[f["local"]] = f
            imp["files"] = list(existing.values())
        else:
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

# Apply discovery lines: download files into MANIFEST_PAIRS.
import_discoveries() {
  local repo="$1"
  local discoveries="$2"
  MANIFEST_PAIRS=()

  while IFS= read -r discovery; do
    [[ -z "$discovery" ]] && continue
    local dtype remote_path local_dest
    dtype=$(echo "$discovery" | awk '{print $1}')
    remote_path=$(echo "$discovery" | awk '{print $2}')
    local_dest=$(echo "$discovery" | awk '{print $3}')

    if [[ "$dtype" == "file" ]]; then
      local file_json sha
      file_json=$(gh api "repos/$ORG/$repo/contents/$remote_path" 2>/dev/null || true)
      sha=$(echo "$file_json" | jq -r '.sha // empty')
      write_skill_file "$repo" "$remote_path" "$local_dest" "$sha"
      MANIFEST_PAIRS+=("$local_dest:$sha")

    elif [[ "$dtype" == "skill_dir" ]]; then
      local skill_remote_dir="$remote_path"
      local skill_local_dir="$local_dest"

      local dir_json
      dir_json=$(gh_path_json "$repo" "$skill_remote_dir")
      if [[ -z "$dir_json" ]]; then continue; fi

      while IFS= read -r entry; do
        local etype ename
        etype=$(echo "$entry" | jq -r '.type')
        ename=$(echo "$entry" | jq -r '.name')

        if [[ "$etype" == "file" ]]; then
          local esha
          esha=$(echo "$entry" | jq -r '.sha // empty')
          local local_file="$skill_local_dir/$ename"
          write_skill_file "$repo" "$skill_remote_dir/$ename" "$local_file" "$esha"
          MANIFEST_PAIRS+=("$local_file:$esha")

        elif [[ "$etype" == "dir" ]]; then
          # One level of subdirs: scripts/, references/, assets/
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
              MANIFEST_PAIRS+=("$local_sub:$ssha")
            fi
          done < <(echo "$subdir_json" | jq -c '.[]' 2>/dev/null || true)
        fi
      done < <(echo "$dir_json" | jq -c '.[]' 2>/dev/null || true)
    fi
  done <<< "$discoveries"
}

# ── single-repo import ────────────────────────────────────────────────────────

import_repo() {
  local repo="$1"
  info "[$repo]"

  local discoveries
  discoveries=$(discover_skills "$repo")

  if [[ -z "$discoveries" ]]; then
    log "no skills found — skipping"
    return
  fi

  import_discoveries "$repo" "$discoveries"
  update_manifest "$repo" replace "${MANIFEST_PAIRS[@]+"${MANIFEST_PAIRS[@]}"}"
}

# Import one explicit repo+path. Merges into the repo's manifest so a bulk
# discovery of the same public repo is not wiped by a later sources[] pass.
import_explicit_path() {
  local repo="$1"
  local path="$2"
  info "[$repo] path=$path"

  local discoveries
  discoveries=$(discover_explicit_path "$repo" "$path")

  if [[ -z "$discoveries" ]]; then
    log "no skills found at $path — skipping"
    return
  fi

  import_discoveries "$repo" "$discoveries"
  update_manifest "$repo" merge "${MANIFEST_PAIRS[@]+"${MANIFEST_PAIRS[@]}"}"
}

import_config_sources() {
  [[ -z "$CFG_SOURCES" ]] && return
  while IFS=$'\t' read -r src_repo src_path; do
    [[ -z "$src_repo" || -z "$src_path" ]] && continue
    if is_excluded "$src_repo"; then
      warn "skipping sources[] entry for excluded repo: $src_repo"
      continue
    fi
    if [[ -n "$TARGET_REPO" && "$src_repo" != "$TARGET_REPO" ]]; then
      continue
    fi
    import_explicit_path "$src_repo" "$src_path"
  done <<< "$CFG_SOURCES"
}

# ── main ─────────────────────────────────────────────────────────────────────

load_config

info "Portal Solutions — Skill Importer"
info "Org: $ORG"
if [[ -n "$TARGET_REPO" && -n "$TARGET_PATH" ]]; then
  info "Target: $TARGET_REPO path=$TARGET_PATH (explicit; public or private)"
elif [[ -n "$TARGET_REPO" ]]; then
  info "Target: $TARGET_REPO"
else
  info "Mode: bulk (public repos + explicit sources)"
fi
$DRY_RUN && info "(dry run — no files will be written)"
$FORCE   && info "(force — locally modified files will be overwritten)"
info ""

# Bare targeted import (no --path) must be a public, non-excluded repo.
# --path is the consent gate for private repos and skips full-repo discovery.
if [[ -n "$TARGET_REPO" && -z "$TARGET_PATH" ]]; then
  assert_repo_public "$TARGET_REPO"
fi
if [[ -n "$TARGET_REPO" ]] && is_excluded "$TARGET_REPO"; then
  echo "Error: '$TARGET_REPO' is listed in import-config.json exclude list." >&2
  exit 1
fi

list_discoveries() {
  local label="$1"
  local discoveries="$2"
  [[ -z "$discoveries" ]] && return
  echo "  $label"
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    echo "    → $(echo "$d" | awk '{print $3}')"
  done <<< "$discoveries"
}

if $LIST_ONLY; then
  if [[ -n "$TARGET_PATH" ]]; then
    info "Explicit path $ORG/$TARGET_REPO/$TARGET_PATH:"
    list_discoveries "$TARGET_REPO ($TARGET_PATH)" "$(discover_explicit_path "$TARGET_REPO" "$TARGET_PATH")"
    exit 0
  fi

  info "Repos with skills (public, non-archived, non-excluded):"
  repos=$(list_repos)
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    list_discoveries "$repo" "$(discover_skills "$repo")"
  done <<< "$repos"

  if [[ -n "$CFG_SOURCES" ]]; then
    info "Explicit sources (import-config.json):"
    while IFS=$'\t' read -r src_repo src_path; do
      [[ -z "$src_repo" || -z "$src_path" ]] && continue
      is_excluded "$src_repo" && continue
      if [[ -n "$TARGET_REPO" && "$src_repo" != "$TARGET_REPO" ]]; then
        continue
      fi
      list_discoveries "$src_repo ($src_path)" "$(discover_explicit_path "$src_repo" "$src_path")"
    done <<< "$CFG_SOURCES"
  fi
  exit 0
fi

if [[ -n "$TARGET_PATH" ]]; then
  import_explicit_path "$TARGET_REPO" "$TARGET_PATH"
else
  repos=$(list_repos)
  imported_count=0
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    import_repo "$repo"
    ((imported_count++)) || true
  done <<< "$repos"
  import_config_sources
fi

info ""

if $DRY_RUN; then
  info "Dry run complete — no files written."
  exit 0
fi

# ── auto-sync registry after a bulk run ──────────────────────────────────────
# For targeted single-repo imports, print a reminder instead of auto-syncing
# so the user stays in control of when registry.json is updated.

if [[ -n "$TARGET_REPO" ]]; then
  info "Import complete. Run ./scripts/sync-registry.sh to update registry.json."
elif ! $NO_SYNC; then
  info "Regenerating registry.json..."
  bash "$SCRIPT_DIR/sync-registry.sh"
  info ""
  info "Bulk import complete. Commit imports.json, registry.json, and any new skill directories."
else
  info "Bulk import complete (--no-sync). Run ./scripts/sync-registry.sh when ready."
fi
