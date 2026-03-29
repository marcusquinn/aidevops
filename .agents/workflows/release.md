---
description: Full release workflow with version bump, tag, and GitHub release
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

# Release Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Full release**: `.agents/scripts/version-manager.sh release [major|minor|patch] --skip-preflight`
- **CRITICAL**: Always use the script — it updates all 6 version files atomically
- **NEVER** manually edit VERSION, bump versions, or use separate commands
- **Version bump only**: `workflows/version-bump.md`
- **Changelog format**: `workflows/changelog.md`
- **Postflight**: `workflows/postflight.md`
- **Validator**: `.agents/scripts/validate-version-consistency.sh`

<!-- AI-CONTEXT-END -->

## Quick Release (aidevops)

**MANDATORY**: Use this single command for ALL releases:

```bash
./.agents/scripts/version-manager.sh release [major|minor|patch] --skip-preflight
```

**Flags**: `--skip-preflight` (faster), `--force` (bypass empty changelog), `--allow-dirty` (not recommended)

This atomically: checks uncommitted changes → bumps version in all 6 files (VERSION, README.md, setup.sh, sonar-project.properties, package.json, .claude-plugin/marketplace.json) → auto-generates CHANGELOG.md → validates consistency → commits → creates git tag → pushes → creates GitHub release.

**DO NOT** run separate bump/tag/push commands.

**Prerequisites**: GitHub auth configured (`gh auth login` or `export GITHUB_TOKEN=...` with `repo` scope), all changes committed (script refuses otherwise), tests passing, CHANGELOG.md has unreleased content (or use `--force`).

## Manual Release Steps (Non-aidevops Repos)

```bash
# 1. Quality checks
./.agents/scripts/linters-local.sh

# 2. Commit version changes
git add -A && git commit -m "chore(release): prepare v{MAJOR}.{MINOR}.{PATCH}"

# 3. Tag and push
./.agents/scripts/version-manager.sh tag
git push origin main && git push origin --tags

# 4. GitHub/GitLab release
./.agents/scripts/version-manager.sh github-release
# or: gh release create v{VERSION} --title "v{VERSION}" --notes-file RELEASE_NOTES.md
# or: glab release create v{VERSION} --name "v{VERSION}" --notes-file RELEASE_NOTES.md
```

## Post-Release

**Deploy** (aidevops only): `cd ~/Git/aidevops && ./setup.sh`

**Task completion** (automatic): Release script scans commits since last release for task IDs (t001, t001.1, etc.) and auto-marks them complete in TODO.md.

```bash
.agents/scripts/version-manager.sh list-task-ids    # Preview
.agents/scripts/version-manager.sh auto-mark-tasks  # Run manually
```

**Postflight**: `./.agents/scripts/postflight-check.sh` — see `workflows/postflight.md` for verification and rollback.

**Follow-up**: Verify artifacts/download links, update docs site, notify stakeholders, update dependent projects, close milestone.

## Rollback

```bash
# Identify the issue
git log --oneline -10
git diff v{PREVIOUS} v{CURRENT}

# Hotfix or revert
git checkout -b hotfix/v{NEW_PATCH}
git commit -m "fix: resolve critical issue"
# or: git revert --no-commit <commit-hash> && git commit -m "revert: rollback v{CURRENT}"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Tag already exists | `git tag -d v{VERSION} && git push origin --delete v{VERSION}` then re-tag |
| GitHub CLI not authenticated | `gh auth login` (token needs `repo` scope) |
| Version mismatch | `./.agents/scripts/version-manager.sh validate` — see `version-bump.md` |

See `workflows/version-bump.md` for semantic versioning rules.
