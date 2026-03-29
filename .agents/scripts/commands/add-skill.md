---
description: Import external skills from GitHub, ClawdHub, or URLs into aidevops
agent: Build+
mode: subagent
---

Import an external skill from GitHub, ClawdHub, or a raw URL, convert it to aidevops format, and register it for update tracking.

URL/Repo: $ARGUMENTS

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

Imported skills use a `-skill` suffix to distinguish from native subagents:

| Type | Example | Managed by |
|------|---------|------------|
| Native subagent | `playwright.md` | aidevops team |
| Imported skill | `playwright-skill.md` | Upstream repo, checked for updates |

Benefits: no name clashes; `*-skill.md` glob finds all imports; `aidevops skill check` knows which to update; issues with imports → check upstream.

## Workflow

**Step 1 — Parse input** (GitHub shorthand, full URL, ClawdHub shorthand/URL, raw URL, or command).

**Step 2 — Run helper:**

```bash
~/.aidevops/agents/scripts/add-skill-helper.sh add "$ARGUMENTS"
# Other commands: list | check-updates | remove <name>
```

**Step 3 — Handle conflicts** (if file exists): Merge / Replace / Separate / Skip.

**Step 4 — Security scan:** Uses [Cisco Skill Scanner](https://github.com/cisco-ai-defense/skill-scanner) if installed. CRITICAL/HIGH findings block import. `--skip-security` bypasses (not recommended). `--force` only controls file overwrite, not security. Scan also runs on `aidevops skill update`.

**Step 5 — Post-import:** Placed in `.agents/` per conventions → registered in `.agents/configs/skill-sources.json` → run `./setup.sh` to create symlinks.

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

Tracked in `.agents/configs/skill-sources.json`. URL-sourced skills use SHA-256 content hashing instead of git commit comparison.

```json
{
  "skills": [
    {
      "name": "cloudflare",
      "upstream_url": "https://github.com/dmmulroy/cloudflare-skill",
      "upstream_commit": "abc123...",
      "local_path": ".agents/services/hosting/cloudflare-skill.md",
      "format_detected": "skill-md",
      "imported_at": "2026-01-21T00:00:00Z",
      "last_checked": "2026-01-21T00:00:00Z",
      "merge_strategy": "added"
    },
    {
      "name": "convos",
      "upstream_url": "https://convos.org/skill.md",
      "upstream_commit": "",
      "local_path": ".agents/tools/convos-skill.md",
      "format_detected": "url",
      "imported_at": "2026-03-07T00:00:00Z",
      "last_checked": "2026-03-07T00:00:00Z",
      "merge_strategy": "added",
      "notes": "Imported from URL",
      "upstream_hash": "a1b2c3d4e5f6..."
    }
  ]
}
```

Run `/add-skill check-updates` periodically to detect upstream changes.

## Related

- `tools/build-agent/add-skill.md` - Detailed conversion logic and merge strategies
- `scripts/add-skill-helper.sh` - Main import implementation
- `scripts/clawdhub-helper.sh` - ClawdHub browser-based fetcher (Playwright)
- `scripts/skill-update-helper.sh` - Automated update checking
- `scripts/generate-skills.sh` - SKILL.md stub generation for aidevops agents
