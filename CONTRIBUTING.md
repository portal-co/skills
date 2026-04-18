# Contributing a Skill

Thanks for adding to the Portal Solutions skills registry. Follow this checklist to make sure your skill loads correctly in any Agent Skills-compatible harness.

---

## Checklist

- [ ] Directory name is lowercase, hyphens only (e.g. `my-skill`)
- [ ] Directory name matches the `name` field in `SKILL.md`
- [ ] `SKILL.md` has valid frontmatter (`name` + `description` are required)
- [ ] Description clearly states what the skill does **and when to use it**
- [ ] All paths inside `SKILL.md` are relative to the skill directory
- [ ] `./scripts/sync-registry.sh` has been run and `registry.json` is committed
- [ ] PR description includes a one-line summary of the skill

---

## Step-by-Step

### 1. Create the skill directory

```bash
mkdir my-skill
```

Name rules (from the [Agent Skills spec](https://agentskills.io/specification)):
- 1–64 characters
- Lowercase `a-z`, `0-9`, hyphens only
- No leading, trailing, or consecutive hyphens

### 2. Create `SKILL.md`

```markdown
---
name: my-skill
description: >
  What this skill does and when the agent should load it. Be specific —
  the description is the only thing in context until the skill is triggered.
license: MIT
compatibility: >
  Requires Node.js >= 18. Run scripts/setup.sh before first use.
---

# My Skill

## Setup

```bash
cd /path/to/my-skill && npm install
```

## Usage

Describe what the agent should do step by step.

```bash
./scripts/run.sh <input>
```

See [reference/DETAILS.md](reference/DETAILS.md) for advanced options.
```

### 3. Add supporting files (optional)

```
my-skill/
├── SKILL.md
├── scripts/
│   ├── setup.sh
│   └── run.sh
└── reference/
    └── DETAILS.md
```

Use relative paths from the skill directory everywhere in `SKILL.md`.

### 4. Update the registry

```bash
./scripts/sync-registry.sh
```

Commit the updated `registry.json` alongside your skill.

### 5. Open a PR

Title format: `skill: add <name>` or `skill: update <name>`

---

## Description Writing Tips

The description is loaded into the agent's system prompt on every session. It must be good enough to trigger the skill at the right time — and only then.

| ✅ Good | ❌ Poor |
|--------|--------|
| `Converts Figma frames to production-ready Tailwind components. Use when given a Figma URL or design file.` | `Helps with Figma.` |
| `Runs the full test suite, captures failures, and opens a retry loop. Use when tests are failing or before opening a PR.` | `Testing helper.` |

Keep descriptions under 1024 characters (hard limit per spec).

---

## Validation

Pi will warn (but still load) skills with:
- Name/directory mismatch
- Names with invalid characters
- Descriptions over 1024 characters

Pi will **refuse to load** skills with:
- Missing `description` field

Run `pi --validate-skills` to check your skill before submitting.
