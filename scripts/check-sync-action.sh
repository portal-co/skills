#!/usr/bin/env bash
# check-sync-action.sh
# Preflight for .github/workflows/sync-skills.yml.
# Catches the class of failure that previously aborted GitHub runs in 0s
# with zero jobs (invalid workflow YAML from a dedented PR-body heredoc).
#
# Usage:
#   ./scripts/check-sync-action.sh           # offline + GitHub API probes
#   ./scripts/check-sync-action.sh --offline # YAML, scripts, and tools only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/sync-skills.yml"
CONFIG_FILE="$REPO_ROOT/import-config.json"
ORG="portal-co"
OFFLINE=false

for arg in "$@"; do
  case "$arg" in
    --offline) OFFLINE=true ;;
    --*)
      echo "Error: unknown flag '$arg'" >&2
      exit 1
      ;;
    *)
      echo "Error: unexpected argument '$arg'" >&2
      exit 1
      ;;
  esac
done

fail=0
pass() { echo "  ok  $*"; }
warn() { echo "  warn $*"; }
err()  { echo "  FAIL $*" >&2; fail=1; }

echo "Sync action checker"
echo "Root: $REPO_ROOT"
echo ""

echo "== Offline =="

for cmd in git jq python3 gh; do
  if command -v "$cmd" &>/dev/null; then
    pass "command: $cmd"
  else
    err "command not on PATH: $cmd"
  fi
done

for script in import-skills.sh open-sync-pr.sh check-sync-action.sh; do
  path="$SCRIPT_DIR/$script"
  if [[ ! -f "$path" ]]; then
    err "missing script: scripts/$script"
  elif [[ ! -x "$path" ]]; then
    err "not executable: scripts/$script"
  else
    pass "script: scripts/$script"
  fi
done

if [[ ! -f "$WORKFLOW" ]]; then
  err "missing workflow: .github/workflows/sync-skills.yml"
else
  set +e
  yaml_out="$(python3 - "$WORKFLOW" 2>&1 <<'PYEOF'
import sys, subprocess

path = sys.argv[1]

def load_yaml():
    try:
        import yaml
        return yaml
    except ImportError:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "--quiet", "pyyaml"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        import yaml
        return yaml

try:
    yaml = load_yaml()
except Exception as e:
    print(f"cannot import PyYAML: {e}")
    sys.exit(2)

try:
    with open(path) as f:
        yaml.safe_load(f)
except yaml.YAMLError as e:
    mark = getattr(e, "problem_mark", None)
    if mark is not None:
        print(f"{path}:{mark.line + 1}:{mark.column + 1}: {e}")
    else:
        print(f"{path}: {e}")
    sys.exit(1)
except Exception as e:
    print(f"{path}: {e}")
    sys.exit(1)
PYEOF
)"
  yaml_rc=$?
  set -e
  if [[ $yaml_rc -eq 0 ]]; then
    pass "workflow YAML parses: .github/workflows/sync-skills.yml"
  else
    err "workflow YAML invalid"
    echo "$yaml_out" >&2
  fi
fi

if [[ "$OFFLINE" == true ]]; then
  echo ""
  if [[ $fail -ne 0 ]]; then
    echo "Checker failed (offline)."
    exit 1
  fi
  echo "Checker passed (offline)."
  exit 0
fi

echo ""
echo "== Online =="

if ! command -v gh &>/dev/null; then
  err "gh missing; skip online probes"
else
  if gh auth status &>/dev/null; then
    pass "gh auth status"
  else
    err "gh is not authenticated (gh auth status failed)"
  fi

  if gh api "orgs/$ORG" --jq '.login' &>/dev/null; then
    pass "org probe: $ORG"
  else
    err "cannot read org $ORG via gh api (token may lack access)"
  fi

  if gh pr list --repo "${GITHUB_REPOSITORY:-$ORG/skills}" --head sync/skills --base main --state open --limit 1 >/dev/null; then
    open_pr="$(gh pr list --repo "${GITHUB_REPOSITORY:-$ORG/skills}" --head sync/skills --base main --state open --json number --jq '.[0].number // empty')"
    if [[ -n "$open_pr" ]]; then
      pass "PR reuse API: open PR #$open_pr on sync/skills"
    else
      pass "PR reuse API: no open sync/skills PR (next sync will create one)"
    fi
  else
    err "cannot list PRs (needed to reuse sync/skills)"
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    while IFS=$'\t' read -r src_repo src_path; do
      [[ -z "$src_repo" || -z "$src_path" ]] && continue
      if gh api "repos/$ORG/$src_repo/contents/$src_path" --jq 'if type=="array" then length else .type end' >/dev/null; then
        pass "sources path: $ORG/$src_repo/$src_path"
      else
        err "sources path unreadable: $ORG/$src_repo/$src_path (private path? set SKILLS_IMPORT_TOKEN with contents:read)"
      fi
    done < <(python3 - "$CONFIG_FILE" <<'PYEOF'
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
  fi
fi

echo ""
if [[ $fail -ne 0 ]]; then
  echo "Checker failed."
  exit 1
fi
echo "Checker passed."
