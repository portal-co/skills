# Portal Solutions — Agent Skills Registry

A shared registry of [Agent Skills](https://agentskills.io/specification) for use with **pi** and **Claude Code** (and any other Agent Skills-compatible harness).

Skills are self-contained capability packages. Each skill lives in its own directory with a `SKILL.md` file containing frontmatter (name, description) and instructions the agent follows when the skill is activated.

---

## Table of Contents

- [Quick Start](#quick-start)
- [Using with Pi](#using-with-pi)
- [Using with Claude Code](#using-with-claude-code)
- [Available Skills](#available-skills)
- [Adding a Skill](#adding-a-skill)
- [Maintenance](#maintenance)

---

## Quick Start

Clone the repo and run the install script:

```bash
git clone <repo-url> ~/Code/portal-hot/skills
cd ~/Code/portal-hot/skills
./scripts/install.sh
```

The install script symlinks this directory into the right locations for pi and Claude Code automatically.

---

## Using with Pi

### Option A — Project-level (recommended)

Add to `.pi/settings.json` in any project that should have access to these skills:

```json
{
  "skills": ["/Users/<you>/Code/portal-hot/skills"]
}
```

### Option B — Global

Add to `~/.pi/settings.json`:

```json
{
  "skills": ["/Users/<you>/Code/portal-hot/skills"]
}
```

### Option C — Symlink

Run the install script (`./scripts/install.sh`) — it creates a symlink at `~/.agents/skills/portal` pointing here. Pi discovers `~/.agents/skills/` automatically.

Pi will pick up all subdirectories containing a `SKILL.md` file.

---

## Using with Claude Code

### Option A — Global (via install script)

Run `./scripts/install.sh`. It creates a symlink at `~/.claude/skills/portal` pointing here. Claude Code discovers `~/.claude/skills/` automatically.

### Option B — Manual settings

Add to your Claude Code settings:

```json
{
  "skills": ["/Users/<you>/Code/portal-hot/skills"]
}
```

### Option C — Project-level

From within a project repo, reference the skills directory in `.claude/settings.json`:

```json
{
  "skills": ["../../portal-hot/skills"]
}
```

---

## Available Skills

See [registry.json](./registry.json) for the machine-readable index.

| Name | Description |
|------|-------------|
| *(no skills yet — add the first one!)* | |

---

## Adding a Skill

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the full guide.

Short version:

1. Create a directory with a slug name: `my-skill/`
2. Add `my-skill/SKILL.md` with valid frontmatter (see spec below)
3. Add any supporting scripts or reference files
4. Run `./scripts/sync-registry.sh` to update `registry.json`
5. Open a PR

### SKILL.md frontmatter

```yaml
---
name: my-skill            # must match directory name; lowercase, hyphens only
description: >            # 1–1024 chars; what it does and when to use it
  One or two sentences describing the skill's capability and trigger conditions.
license: MIT              # optional
compatibility: >          # optional; environment requirements
  Requires Node.js >= 18. Run setup.sh before first use.
---
```

---

## Maintenance

### Sync the registry index

After adding or removing skills, regenerate `registry.json`:

```bash
./scripts/sync-registry.sh
```

### Keep skills up to date

```bash
git pull
```

No reinstallation needed — symlinks point here, so updates are live immediately.
