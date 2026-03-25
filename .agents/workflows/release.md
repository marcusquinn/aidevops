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

This workflow covers tagging, pushing, and creating GitHub/GitLab releases. For version number management only, see `workflows/version-bump.md`. For changelog format, see `workflows/changelog.md`. For PR-based merges, see `workflows/pr.md`.

## Pre-Release Checklist

- [ ] All working changes committed (no uncommitted files)
- [ ] Tests passing
- [ ] CHANGELOG.md has unreleased content (or use `--force`)

The release script **refuses to release** if there are uncommitted changes.

## Merging Work Branch to Main

### Direct Merge (Solo Work)

```bash
git checkout {your-branch} && git fetch origin && git rebase origin/main
git checkout main && git pull origin main
git merge --no-ff {your-branch} -m "Merge {your-branch} into main"
git push origin main
git branch -d {your-branch} && git push origin --delete {your-branch}
```

### PR/MR Workflow (Collaborative)

```bash
git push -u origin {your-branch}
gh pr create --fill --base main   # GitHub
glab mr create --fill --target-branch main  # GitLab
# After approval and merge:
git checkout main && git pull origin main
```

| Situation | Action |
|-----------|--------|
| Solo work, simple changes | Direct merge to main |
| Team collaboration | Create PR/MR for review |
| Hotfix on production | Use `hotfix/` branch, merge to main + release |

## Quick Release (aidevops)

**MANDATORY**: Use this single command for ALL releases:

```bash
./.agents/scripts/version-manager.sh release [major|minor|patch] --skip-preflight
```

**Flags**: `--skip-preflight` (faster), `--force` (bypass empty changelog), `--allow-dirty` (not recommended)

This command atomically: checks for uncommitted changes → bumps version in all 6 files (VERSION, README.md, setup.sh, sonar-project.properties, package.json, .claude-plugin/marketplace.json) → auto-generates CHANGELOG.md → validates consistency → commits → creates git tag → pushes → creates GitHub release.

**DO NOT** run separate bump/tag/push commands.

## Auto-Changelog Generation

| Commit Type | Changelog Section |
|-------------|-------------------|
| `feat:` | Added |
| `fix:` | Fixed |
| `docs:` | Changed (Documentation) |
| `refactor:` | Changed (Refactor) |
| `perf:` | Changed (Performance) |
| `security:` | Security |
| `BREAKING CHANGE:` | Removed (BREAKING) |
| `deprecate:` | Deprecated |
| `chore:` | (excluded) |

```bash
git commit -m "feat: add DataForSEO MCP integration"
git commit -m "fix: resolve Serper API authentication"
```

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

## GitHub Integration

```bash
# GitHub CLI (preferred)
brew install gh && gh auth login

# GitHub API (fallback)
export GITHUB_TOKEN=your_personal_access_token
```

### GitHub Actions Automation

```yaml
name: Release
on:
  push:
    tags: ['v*']
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm run build
      - uses: softprops/action-gh-release@v1
        with:
          files: dist/*
          generate_release_notes: true
```

## Post-Release Tasks

### Deploy Updated Agents (aidevops repo only)

```bash
cd ~/Git/aidevops && ./setup.sh
```

### Task Completion (Automatic)

The release script scans commits since last release for task IDs (t001, t001.1, etc.) and auto-marks them complete in TODO.md.

```bash
.agents/scripts/version-manager.sh list-task-ids    # Preview
.agents/scripts/version-manager.sh auto-mark-tasks  # Run manually
```

### Postflight Verification

```bash
./.agents/scripts/postflight-check.sh
# or quick check:
gh run watch $(gh run list --limit=1 --json databaseId -q '.[0].databaseId') --exit-status
```

See `workflows/postflight.md` for detailed verification and rollback guidance.

### Follow-up

1. Verify release artifacts and download links
2. Update documentation site and notify stakeholders
3. Update dependent projects and close release milestone
4. Start next version planning

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
| GitHub CLI not authenticated | `gh auth login` |
| GitHub token issues | `curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user` (needs `repo` scope) |
| Version mismatch | `./.agents/scripts/version-manager.sh validate` — see `version-bump.md` for fixing |

## Release Communication Template

```markdown
# [Project Name] v{X.Y.Z} Released

## Highlights
- Feature 1: Description
- Feature 2: Description

## Breaking Changes
- Description of any breaking changes

## Upgrade Guide
1. Step to upgrade
2. Migration notes

## Full Changelog
See [CHANGELOG.md](link) for complete details.
```

See `workflows/version-bump.md` for semantic versioning rules (major/minor/patch).
