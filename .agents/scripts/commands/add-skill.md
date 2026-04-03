---
description: Import external skills from GitHub, ClawdHub, or URLs into aidevops
agent: Build+
mode: subagent
---

Import an external skill, convert to aidevops format, and register for update tracking. URL/Repo: `$ARGUMENTS`

## Quick Reference

```bash
# GitHub shorthand (saved as *-skill.md)
/add-skill dmmulroy/cloudflare-skill        # → .agents/services/hosting/cloudflare-skill.md
/add-skill anthropics/skills/pdf            # → .agents/tools/pdf-skill.md
/add-skill vercel-labs/agent-skills --name vercel-deploy

# ClawdHub
/add-skill clawdhub:caldav-calendar         # → .agents/tools/productivity/caldav-calendar-skill.md
/add-skill https://clawdhub.com/mSarheed/proxmox-full

# Raw URL
/add-skill https://convos.org/skill.md --name convos   # category auto-detected

# Flags
/add-skill dmmulroy/cloudflare-skill --force    # overwrite existing
/add-skill dmmulroy/cloudflare-skill --dry-run  # simulate

# Management
/add-skill list
/add-skill check-updates
/add-skill remove <name>
```

## Naming Convention

`-skill` suffix marks imported skills: `playwright-skill.md` (imported, upstream-tracked) vs `playwright.md` (native). No name clashes; `*-skill.md` glob finds all imports; `aidevops skill check` knows which to update.

## Workflow

1. **Parse input** — GitHub shorthand, full URL, ClawdHub shorthand/URL, raw URL, or management command.
2. **Run helper:** `~/.aidevops/agents/scripts/add-skill-helper.sh add "$ARGUMENTS"` (other commands: `list | check-updates | remove <name>`)
3. **Handle conflicts** (if file exists): Merge / Replace / Separate / Skip.
4. **Security scan:** [Cisco Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner) if installed — CRITICAL/HIGH blocks import. `--skip-security` bypasses; `--force` only controls file overwrite. Scan also runs on `aidevops skill update`.
5. **Post-import:** Placed in `.agents/` per conventions → registered in `.agents/configs/skill-sources.json` → run `./setup.sh` to create symlinks.

## Supported Sources & Formats

| Source | Detection | Fetch Method |
|--------|-----------|--------------|
| GitHub | `owner/repo` or github.com URL | `git clone --depth 1` |
| ClawdHub | `clawdhub:slug` or clawdhub.com URL | Playwright browser extraction |
| Raw URL | Any `https://` (not GitHub/ClawdHub) | `curl` with SHA-256 content hash |

| Format | Detection | Conversion |
|--------|-----------|------------|
| SKILL.md | OpenSkills/Claude Code/ClawdHub | Frontmatter preserved, content adapted |
| AGENTS.md | aidevops/Windsurf | Direct copy with mode: subagent |
| .cursorrules | Cursor | Wrapped in markdown with frontmatter |
| README.md | Generic | Copied as-is |

## Update Tracking

Tracked in `.agents/configs/skill-sources.json`: `name`, `upstream_url`, `upstream_commit`/`upstream_hash`, `local_path`, `format_detected`, `imported_at`, `last_checked`, `merge_strategy`. URL sources use SHA-256 content hashing instead of git commit comparison. Run `/add-skill check-updates` periodically.

## Related

- `tools/build-agent/add-skill.md` — Detailed conversion logic and merge strategies
- `scripts/add-skill-helper.sh` — Main import implementation
- `scripts/clawdhub-helper.sh` — ClawdHub browser-based fetcher (Playwright)
- `scripts/skill-update-helper.sh` — Automated update checking
- `scripts/generate-skills.sh` — SKILL.md stub generation for aidevops agents
