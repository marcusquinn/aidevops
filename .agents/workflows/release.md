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
- **CRITICAL**: Always use the script above — it updates all 6 version files atomically
- **NEVER** manually edit VERSION, bump versions yourself, or use separate commands

**Before releasing**: Commit all changes first:

```bash
git status --short
git add -A && git commit -m "feat: description of changes"
```

- **Auto-changelog**: Release script auto-generates CHANGELOG.md from conventional commits
- **Create tag**: `.agents/scripts/version-manager.sh tag`
- **GitHub release**: `.agents/scripts/version-manager.sh github-release`
- **Postflight**: `.agents/scripts/postflight-check.sh`
- **Deploy locally**: `./setup.sh` (aidevops repo only)
- **Validator**: `.agents/scripts/validate-version-consistency.sh`
- **Version bump only**: See `workflows/version-bump.md`
- **Changelog format**: See `workflows/changelog.md`

<!-- AI-CONTEXT-END -->

For version number management only, see `workflows/version-bump.md`. For changelog format, see `workflows/changelog.md`. For merging branches, see `workflows/git-workflow.md` and `workflows/pr.md`.

## Pre-Release Checklist

- [ ] All working changes committed — release script **refuses** if uncommitted changes exist
- [ ] Tests passing
- [ ] CHANGELOG.md has unreleased content (or use `--force`)

## Quick Release (aidevops)

**MANDATORY**: Use this single command for ALL releases:

```bash
./.agents/scripts/version-manager.sh release [major|minor|patch] --skip-preflight
```

**Flags**: `--skip-preflight` (faster), `--force` (bypass empty changelog), `--allow-dirty` (not recommended)

This atomically: checks uncommitted changes → bumps version in all 6 files (VERSION, README.md, setup.sh, sonar-project.properties, package.json, .claude-plugin/marketplace.json) → auto-generates CHANGELOG.md → validates consistency → commits → creates git tag → pushes → creates GitHub release.

**DO NOT** run separate bump/tag/push commands.

## Auto-Changelog Generation

| Commit Type | Changelog Section |
|-------------|-------------------|
| `feat:` | Added |
| `fix:` | Fixed |
| `docs:`, `refactor:`, `perf:` | Changed |
| `security:` | Security |
| `BREAKING CHANGE:` | Removed (BREAKING) |
| `deprecate:` | Deprecated |
| `chore:` | (excluded) |

See `workflows/changelog.md` for full format rules and examples.

## Manual Release Steps (Non-aidevops Repos)

```bash
# 1. Quality checks
./.agents/scripts/linters-local.sh   # or: npm run lint && npm test

# 2. Changelog preview (optional)
./.agents/scripts/version-manager.sh changelog-preview

# 3. Commit version changes
git add -A && git commit -m "chore(release): prepare v{MAJOR}.{MINOR}.{PATCH}"

# 4. Tag
./.agents/scripts/version-manager.sh tag
# or: git tag -a v{VERSION} -m "Release v{VERSION}"

# 5. Push
git push origin main && git push origin --tags

# 6. GitHub/GitLab release
./.agents/scripts/version-manager.sh github-release
# or: gh release create v{VERSION} --title "v{VERSION}" --notes-file RELEASE_NOTES.md ./dist/*
# or: glab release create v{VERSION} --name "v{VERSION}" --notes-file RELEASE_NOTES.md
```

## Post-Release Tasks

**GitHub auth** (prerequisite): `brew install gh && gh auth login` (preferred) or `export GITHUB_TOKEN=your_personal_access_token` (fallback, needs `repo` scope).

**Deploy** (aidevops only): `cd ~/Git/aidevops && ./setup.sh`

**Task completion** (automatic): The release script scans commits since last release for task IDs (t001, t001.1, etc.) and auto-marks them complete in TODO.md.

```bash
.agents/scripts/version-manager.sh list-task-ids    # Preview
.agents/scripts/version-manager.sh auto-mark-tasks  # Run manually
```

**Postflight**: `./.agents/scripts/postflight-check.sh` or `gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status`. See `workflows/postflight.md` for verification and rollback.

**Follow-up**: Verify artifacts/download links, update docs site, notify stakeholders, update dependent projects, close milestone.

## Rollback Procedures

```bash
# Identify the issue
git log --oneline -10
git diff v{PREVIOUS} v{CURRENT}

# Create hotfix
git checkout -b hotfix/v{NEW_PATCH}
git commit -m "fix: resolve critical issue"

# Or revert
git revert <commit-hash>
git commit -m "revert: rollback v{CURRENT}"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Tag already exists | `git tag -d v{VERSION} && git push origin --delete v{VERSION}` then re-tag |
| GitHub CLI not authenticated | `gh auth login` (token needs `repo` scope) |
| Version mismatch | `./.agents/scripts/version-manager.sh validate` — see `version-bump.md` for fixing |

See `workflows/version-bump.md` for semantic versioning rules (major/minor/patch).
