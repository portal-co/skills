# Portal Solutions Agent Skills Registry

This repository is a shared registry of [Agent Skills](https://agentskills.io/specification). Each subdirectory containing a `SKILL.md` file is an installable skill.

## What You Can Do Here

- **Discover skills**: Browse subdirectories or check `registry.json` for the full index
- **Load a skill**: Read the `SKILL.md` in the relevant subdirectory — it contains full instructions
- **Invoke a skill**: Use `/skill:<name>` if your harness supports slash commands
- **Add a skill**: Follow `CONTRIBUTING.md` — create a directory, add `SKILL.md`, run `scripts/sync-registry.sh`

## Skill Index

See `registry.json` for a machine-readable list of all skills with names and descriptions.

## Structure

```
skills/
├── README.md              # Human-readable docs
├── AGENTS.md              # This file — agent project context
├── CONTRIBUTING.md        # How to add a new skill
├── registry.json          # Machine-readable skill index
├── scripts/
│   ├── install.sh         # Symlinks skills into ~/.agents/skills/
│   └── sync-registry.sh   # Regenerates registry.json from SKILL.md frontmatter
└── <skill-name>/
    └── SKILL.md           # Each skill follows the Agent Skills standard
```

## Installation

Run `./scripts/install.sh` to symlink this registry into your agent harness skills directory.

Or add this directory to your harness settings manually:
```json
{ "skills": ["/path/to/portal-hot/skills"] }
```
