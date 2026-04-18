# TODO: Registry Formats

Tracked improvements and open questions for the `registry-formats` skill and the registry infrastructure.

---

## Skill

- [ ] Validate that `sync-registry.sh` correctly reads SKILL.md frontmatter and emits the right `registry.json` shape — write a test or dry-run mode
- [ ] Add `references/REFERENCE.md` with extended field documentation (full `allowed-tools` syntax, metadata key conventions)
- [ ] Document the `install.sh` symlink targets and how harnesses discover the skills directory
- [ ] Add examples of `compatibility` field usage for common environments (Node, Python, Docker)
- [ ] Confirm whether `registry-schema.json` is publicly versioned and pin the `$schema` URL if so

## Registry Infrastructure

- [ ] `sync-registry.sh` — verify it handles skills with multi-line `description` YAML blocks correctly
- [ ] Add a pre-commit hook or CI step that runs `sync-registry.sh` and fails if `registry.json` is stale
- [ ] Consider adding a `version` field to `registry.json` for cache-busting on harness updates
- [ ] Evaluate whether to publish this registry to a public index (e.g. agentskills.io discovery)
- [ ] `install.sh` currently targets `~/.agents/skills/` — document or extend for additional harness paths as they emerge

## CONTRIBUTING.md

- [ ] Update `CONTRIBUTING.md` to reference `AGENTS.md` instead of `CLAUDE.md` now that the file has been renamed
- [ ] Add a note about the `registry-formats` skill so contributors know they can load it for format help
