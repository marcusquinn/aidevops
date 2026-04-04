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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Release Workflow

**MANDATORY**: Use this single command for ALL aidevops releases:

```bash
./.agents/scripts/version-manager.sh release [major|minor|patch] --skip-preflight
```

**Flags**: `--skip-preflight` (faster), `--force` (bypass empty changelog), `--allow-dirty` (not recommended)

Atomically: checks uncommitted changes → bumps version in all 6 files (VERSION, README.md, setup.sh, sonar-project.properties, package.json, .claude-plugin/marketplace.json) → auto-generates CHANGELOG.md → validates consistency → commits → tags → pushes → creates GitHub release.

**DO NOT** run separate bump/tag/push commands. **Prerequisites**: `gh auth login` (needs `repo` scope), all changes committed, CHANGELOG.md has unreleased content (or `--force`).

**Related**: `workflows/version-bump.md` · `workflows/changelog.md` · `workflows/postflight.md` · `.agents/scripts/validate-version-consistency.sh`

## Manual Release (Non-aidevops Repos)

```bash
./.agents/scripts/linters-local.sh
git add -A && git commit -m "chore(release): prepare v{MAJOR}.{MINOR}.{PATCH}"
./.agents/scripts/version-manager.sh tag
git push origin main && git push origin --tags
./.agents/scripts/version-manager.sh github-release
# or: gh release create v{VERSION} --title "v{VERSION}" --notes-file RELEASE_NOTES.md
# or: glab release create v{VERSION} --name "v{VERSION}" --notes-file RELEASE_NOTES.md
```

## Post-Release

**Deploy** (aidevops only): `cd ~/Git/aidevops && ./setup.sh`

**Task completion** (automatic): Release script scans commits for task IDs and auto-marks them complete in TODO.md.

```bash
.agents/scripts/version-manager.sh list-task-ids    # Preview
.agents/scripts/version-manager.sh auto-mark-tasks  # Run manually
```

**Postflight**: `./.agents/scripts/postflight-check.sh` — see `workflows/postflight.md`.

**Follow-up**: Verify artifacts/download links, update docs site, notify stakeholders, close milestone.

## Rollback

```bash
git log --oneline -10
git diff v{PREVIOUS} v{CURRENT}
git checkout -b hotfix/v{NEW_PATCH}
# Fix, then:
git commit -m "fix: resolve critical issue"
# or: git revert --no-commit <commit-hash> && git commit -m "revert: rollback v{CURRENT}"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Tag already exists | `git tag -d v{VERSION} && git push origin --delete v{VERSION}` then re-tag |
| GitHub CLI not authenticated | `gh auth login` (token needs `repo` scope) |
| Version mismatch | `./.agents/scripts/version-manager.sh validate` — see `version-bump.md` |
