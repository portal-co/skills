#!/usr/bin/env bash
# sync-registry.sh
# Scans all skill directories for SKILL.md files and regenerates registry.json.
# Run this after adding, removing, or renaming skills.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$REPO_ROOT/registry.json"

echo "Scanning skills in: $REPO_ROOT"

# Build JSON array from SKILL.md frontmatter
skills_json="[]"

while IFS= read -r -d '' skill_file; do
  skill_dir="$(dirname "$skill_file")"
  dir_name="$(basename "$skill_dir")"

  # Extract name from frontmatter
  name=$(awk '/^---/{p++} p==1 && /^name:/{gsub(/^name:[[:space:]]*/,""); print; exit}' "$skill_file" | tr -d '"'"'" | xargs)
  # Extract description (single-line or folded block — collapse to one line)
  description=$(awk '
    /^---/{p++; next}
    p==1 && /^description:/{
      gsub(/^description:[[:space:]]*/,"")
      if ($0 ~ /^>/) { desc=""; in_block=1; next }
      desc=$0; in_block=0
    }
    p==1 && in_block && /^[[:space:]]/{
      gsub(/^[[:space:]]*/,"")
      desc = (desc=="" ? $0 : desc " " $0)
      next
    }
    p==1 && in_block && /^[^[:space:]]/{in_block=0}
    p==2{exit}
    END{print desc}
  ' "$skill_file" | tr -d '"' | xargs)

  if [[ -z "$name" ]]; then
    echo "  WARNING: no name found in $skill_file, skipping"
    continue
  fi

  if [[ -z "$description" ]]; then
    echo "  WARNING: no description found in $skill_file ($name), skipping"
    continue
  fi

  rel_path="${skill_dir#$REPO_ROOT/}"

  # Detect whether this skill lives under a repo-import namespace.
  # Imported skills have a path like <repo>/<skill-name>/SKILL.md (depth >= 3
  # from repo root), while local skills are <skill-name>/SKILL.md (depth 2).
  source_repo=""
  path_depth=$(echo "$rel_path" | tr -cd '/' | wc -c)
  if [[ "$path_depth" -ge 2 ]]; then
    source_repo=$(echo "$rel_path" | cut -d'/' -f1)
  fi

  echo "  + $name — $rel_path${source_repo:+ (from $source_repo)}"

  entry=$(python3 -c "
import json, sys
e = {
    'name': sys.argv[1],
    'description': sys.argv[2],
    'path': sys.argv[3],
}
if sys.argv[4]:
    e['source'] = 'portal-co/' + sys.argv[4]
print(json.dumps(e))
" "$name" "$description" "$rel_path" "$source_repo")

  skills_json=$(echo "$skills_json" | python3 -c "
import sys, json
arr = json.load(sys.stdin)
arr.append(json.loads(sys.argv[1]))
print(json.dumps(arr, indent=2))
" "$entry")

done < <(find "$REPO_ROOT" -mindepth 2 -name "SKILL.md" -not -path "*/.git/*" -print0 | sort -z)

today=$(date -u +%Y-%m-%d)

python3 - "$REGISTRY" "$skills_json" "$today" <<'PYEOF'
import sys, json

registry_path = sys.argv[1]
skills = json.loads(sys.argv[2])
today = sys.argv[3]

try:
    with open(registry_path) as f:
        data = json.load(f)
except Exception:
    data = {}

data["updated"] = today
data["skills"] = skills

with open(registry_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

PYEOF

echo ""
echo "registry.json updated — $(echo "$skills_json" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))') skill(s) indexed."
