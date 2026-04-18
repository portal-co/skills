---
name: registry-formats
description: >
  Teaches the Agent Skills registry format: SKILL.md frontmatter rules, registry.json schema, directory naming conventions, and how to add, update, or validate skills in this registry. Use when creating or modifying a skill, updating registry.json, checking spec compliance, or answering questions about how this registry is structured.
license: Proprietary
metadata:
  author: portal-solutions
  version: "1.0"
---

# Registry Formats

This skill covers the canonical format for skills and the registry index in this repository.

## SKILL.md Format

Every skill is a directory whose name matches the `name` frontmatter field. The directory must contain a `SKILL.md` file with YAML frontmatter:

```markdown
---
name: my-skill
description: >
  What this skill does and when the agent should load it. Be specific —
  the description is the only thing in context until the skill is triggered.
license: MIT
---

# My Skill

Instructions go here.
```

### Required Fields

| Field         | Constraints                                                                 |
|---------------|-----------------------------------------------------------------------------|
| `name`        | 1–64 chars. Lowercase `a-z`, `0-9`, hyphens only. No leading/trailing/consecutive hyphens. Must match the parent directory name. |
| `description` | 1–1024 chars. Must state what the skill does **and** when to use it.        |

### Optional Fields

| Field           | Notes                                                                        |
|-----------------|------------------------------------------------------------------------------|
| `license`       | SPDX identifier or reference to a bundled license file.                      |
| `compatibility` | 1–500 chars. Environment requirements (OS, packages, network, target agent). |
| `metadata`      | Arbitrary `key: value` map for extra properties.                             |
| `allowed-tools` | Space-separated pre-approved tool names (experimental).                      |

### Directory Naming Rules

- Lowercase `a-z`, `0-9`, hyphens only
- 1–64 characters
- No leading, trailing, or consecutive hyphens (`--`)
- Must match the `name` field exactly

## registry.json Schema

`registry.json` is the machine-readable index. It follows `https://agentskills.io/registry-schema.json`:

```json
{
  "$schema": "https://agentskills.io/registry-schema.json",
  "registry": "Portal Solutions Agent Skills",
  "updated": "YYYY-MM-DD",
  "skills": [
    {
      "name": "my-skill",
      "description": "Short description matching SKILL.md frontmatter."
    }
  ]
}
```

Always regenerate this file by running:

```bash
./scripts/sync-registry.sh
```

Never hand-edit `registry.json` unless `sync-registry.sh` is unavailable.

## Adding a Skill

1. Create the directory: `mkdir my-skill`
2. Write `my-skill/SKILL.md` with valid frontmatter (see above)
3. Add optional `scripts/`, `references/`, or `assets/` subdirectories if needed
4. Run `./scripts/sync-registry.sh` to update `registry.json`
5. Commit both the skill directory and `registry.json`

## Validating a Skill

Use the reference validator if available:

```bash
skills-ref validate ./my-skill
```

Or check manually:
- Directory name equals the `name` field
- `name` and `description` are present and non-empty
- `description` is under 1024 characters
- No invalid characters in `name`

## Description Writing Tips

The description is loaded into the agent's context on every session. It must be precise enough to trigger the skill at the right time — and only then.

| Good | Poor |
|------|------|
| `Converts Figma frames to Tailwind components. Use when given a Figma URL.` | `Helps with Figma.` |
| `Runs the test suite and retries failures. Use before opening a PR.` | `Testing helper.` |

## Importing Skills from portal-co Repos

Skills can be sourced directly from repos in the `portal-co` GitHub org. A repo exposes skills in one of two ways:

| Convention | Location in repo | Imported to |
|---|---|---|
| Single skill | `SKILL.md` at repo root | `<repo>/SKILL.md` |
| Multiple skills | `skills/<skill-name>/SKILL.md` | `<repo>/<skill-name>/SKILL.md` |

### Running the importer

```bash
# Import all discoverable repos
./scripts/import-skills.sh

# Import one repo
./scripts/import-skills.sh <repo-name>

# List repos that have skills (no writes)
./scripts/import-skills.sh --list

# Preview changes without writing
./scripts/import-skills.sh --dry-run

# Overwrite locally modified files
./scripts/import-skills.sh --force
```

After importing, always regenerate the index:

```bash
./scripts/sync-registry.sh
```

### imports.json manifest

`imports.json` tracks what was imported and from where:

```json
{
  "org": "portal-co",
  "imports": [
    {
      "repo": "volar",
      "synced": "2026-04-18",
      "files": [
        { "local": "volar/my-skill/SKILL.md", "sha": "<git-sha>" }
      ]
    }
  ]
}
```

The importer uses stored SHAs to skip unchanged files and warn on locally modified ones. Commit `imports.json` alongside any imported skills.

### registry.json — imported skills

Entries for imported skills include a `source` field:

```json
{
  "name": "my-skill",
  "description": "...",
  "path": "volar/my-skill",
  "source": "portal-co/volar"
}
```

## Reference

Full specification: https://agentskills.io/specification
