<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2230: GitHub release workflow (auto-create release on tag push)

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19743
**Parent:** t2228 / GH#19734
**Tier:** tier:simple (single workflow YAML, established pattern)

## What

Add `.github/workflows/release.yml` that triggers on `push: tags: ['v*']`, extracts the matching CHANGELOG section, and creates a GitHub Release with that content plus post-CHANGELOG commits if any.

## Why

Every `version-manager.sh release` run today requires a separate manual `gh release create` command. The tag lands on origin but the Release page stays empty until a human runs the command. Two concrete downsides:

1. The user has to remember a second command after release. v3.8.71 needed one.
2. When PRs merge between `version-manager.sh` generating CHANGELOG.md and the tag landing on origin, those PRs are missing from release notes. t2214 / PR #19715 hit this — had to manually append to the gh release body.

## How

- NEW: `.github/workflows/release.yml`

```yaml
name: Create GitHub Release
on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Extract CHANGELOG section
        id: changelog
        run: |
          VERSION="${GITHUB_REF#refs/tags/v}"
          BODY=$(awk "/^## \[$VERSION\]/,/^## \[/" CHANGELOG.md | sed '$d')
          PREV_TAG=$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || echo '')
          if [ -n "$PREV_TAG" ]; then
            EXTRA=$(git log --oneline "$PREV_TAG..v$VERSION" -- | grep -v 'chore: claim t' | head -10)
            BODY="$BODY"$'\n\n### Commits since CHANGELOG generation\n'"$EXTRA"
          fi
          {
            echo "body<<DELIM"
            echo "$BODY"
            echo "DELIM"
          } >> "$GITHUB_OUTPUT"
      - name: Create release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "$GITHUB_REF_NAME" \
            --title "$GITHUB_REF_NAME" \
            --notes "${{ steps.changelog.outputs.body }}"
```

Model on existing workflow patterns in `.github/workflows/` (most use similar permissions / GH_TOKEN conventions).

## Acceptance criteria

- [ ] `.github/workflows/release.yml` exists and is well-formed
- [ ] Triggers on `push: tags: [v*]`
- [ ] Extracts the matching `## [vN.N.N]` block from CHANGELOG.md
- [ ] Appends commits between previous tag and this one (filtering `chore: claim tNNN` noise)
- [ ] Creates GitHub Release with title = tag name, body = CHANGELOG + extras
- [ ] Next real `version-manager.sh release` produces both tag AND release page

## Verification

```bash
# Dry-run test (throwaway tag)
cd ~/Git/aidevops
git tag v0.0.0-test-release
git push origin v0.0.0-test-release
# Wait for workflow; gh release view v0.0.0-test-release should show CHANGELOG content
# Cleanup:
gh release delete v0.0.0-test-release --repo marcusquinn/aidevops --yes
git push origin --delete v0.0.0-test-release
git tag -d v0.0.0-test-release

# Real validation: next patch release
~/.aidevops/agents/scripts/version-manager.sh release patch
# After ~30s:
gh release view v$(cat VERSION) --repo marcusquinn/aidevops
```

## Context

- Session: 2026-04-18, release v3.8.71.
- `version-manager.sh` handles tag creation + push but never invokes `gh release create`.
- The CHANGELOG-lag side-benefit (regenerating notes from git log at release time) naturally closes a gap that otherwise would need its own task.

## Tier rationale

`tier:simple` — single new YAML file, ~40 lines, pattern exists elsewhere in the repo. Exact file path + verbatim file content provided above. Auto-dispatchable.
