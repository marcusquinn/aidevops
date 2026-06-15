<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Badges — README badge template + LOC reusable workflow

aidevops ships a consistent badge block for every managed repo: a native
GitHub Actions badge when a concrete workflow file is known, static shields.io
badges for values that do not require GitHub API access, and self-hosted SVGs
for lines of code. The template deliberately avoids `img.shields.io/github/...`
endpoints because those can render upstream service text such as "Unable to
select next GitHub token from pool" in public READMEs.

Use `aidevops badges render|check|sync|install` to manage README badge blocks
and LOC badge workflows for repos listed in `repos.json`.

Subcommands:

- `render` — print the badge block that would be inserted.
- `check` — fail on README badge drift.
- `sync` — update the README badge block and managed LOC workflow caller.
- `install` — install managed badge assets for a repo.

## What you get

Three artifacts deployed by `setup.sh`:

1. **`.agents/scripts/loc-badge-helper.sh`** — runs `tokei`, emits two SVGs:
   - `.github/badges/loc-total.svg` — shields.io-style "lines of code: 482k"
   - `.github/badges/loc-languages.svg` — GitHub-style horizontal stacked
     bar of the top-N languages with a percentage legend
2. **`.agents/scripts/readme-badges-helper.sh`** — renders the badges
   markdown for a slug, injects/checks an idempotent block in a README, and
   only emits an Actions badge after resolving an actual workflow file
3. **`.agents/templates/readme/badges.md.tmpl`** — the canonical badges
   block, with conditional sections for native Actions, licence, and LOC badges

Plus the GitHub Actions wiring:

4. **`.github/workflows/loc-badge-reusable.yml`** — reusable workflow
   that downstream repos call from a tiny caller YAML
5. **`.agents/templates/workflows/loc-badge-caller.yml`** — the caller
   template (~30 lines)

## Add badges to a repo (manual flow)

This is the manual flow that works today. Phase 2 wraps it in
`aidevops badges sync`.

```bash
# 1. Drop in the LOC workflow caller
cp ~/.aidevops/agents/templates/workflows/loc-badge-caller.yml \
   .github/workflows/loc-badge.yml
git add .github/workflows/loc-badge.yml
git commit -m "chore(ci): add LOC badge workflow"
git push

# 2. Inject the README badge block
~/.aidevops/agents/scripts/readme-badges-helper.sh inject README.md owner/repo
git add README.md
git commit -m "chore(docs): add managed badges block"
git push
```

The first push of `loc-badge.yml` triggers the reusable workflow, which
generates and commits the SVGs into `.github/badges/`. The README block
references those SVGs via raw.githubusercontent.com, so they update
automatically on every push.

Do not add GitHub-backed Shields badges such as repository size, stars,
watchers, language count, release date, or issue counts to the canonical block.
Those badges depend on Shields' GitHub token pool and can intermittently render
the provider error string instead of the intended value. Prefer GitHub-native
badges for Actions, self-hosted generated SVGs for repository metrics, static
Shields badges for local/static facts, and direct Markdown links for GitHub
pages that do not need a badge.

## How the marker block works

The injected block is bounded by HTML comment markers that are invisible
in rendered Markdown:

```markdown
<!-- aidevops:badges:start -->
<!-- managed by aidevops badges; edit the template, not this block -->
[![GitHub Actions](...)](...)
[![License](...)](...)
[![Lines of code](...)](...)
...
<!-- aidevops:badges:end -->
```

`readme-badges-helper.sh inject` replaces everything between the markers
idempotently. If the markers don't exist, the block is inserted after
the first H1 (or at the top of the file when there's no H1).

`readme-badges-helper.sh check` compares the existing block to what would
be rendered and exits 3 on drift — Phase 2's CI gate uses this.

## Template authoring

The template at `.agents/templates/readme/badges.md.tmpl` supports three
substitution forms:

- `{{KEY}}` — substituted inline with the value of variable `KEY`
- `{{?KEY}}rest` — line included only when `KEY` is non-empty (prefix stripped)
- `{{!KEY}}rest` — line included only when `KEY` is empty (prefix stripped)

Available variables (computed from `repos.json` + live `gh` probes):

| Variable | Source | Notes |
|---|---|---|
| `SLUG` | argument | `owner/repo` |
| `OWNER` | derived | first segment of slug |
| `REPO` | derived | second segment of slug |
| `DEFAULT_BRANCH` | `gh api repos/{slug}` | falls back to `main` |
| `HAS_ACTIONS_WORKFLOW` | local workflow-file detection | enables the native Actions badge |
| `ACTIONS_WORKFLOW_FILE` | local workflow-file detection or `--workflow-file` | exact `.github/workflows/*.yml` basename |
| `HAS_LOC_BADGE` | `--no-loc-badge` flag | default `1`; empty if disabled |
| `HAS_RELEASES` | `gh api releases?per_page=1` | empty for `local_only` repos |
| `IS_FOSS` | `repos.json[].foss` | retained for compatibility; unused by the resilient template |
| `HAS_LICENSE` | (Phase 2: filesystem probe) | currently always `1` |

To add or remove a badge, edit the template — never edit the rendered
block in any README directly.

Public badge blocks may show third-party quality gates when the framework owns
the remediation loop. A failing public badge is treated as a dispatchable
quality blocker: the quality sweep should capture the failing gate condition,
deduplicate it, and create a worker-ready task so the underlying cause is fixed
or explicitly classified instead of hidden.

## Local development

Test the LOC helper against this repo:

```bash
brew install tokei jq    # macOS
# cargo install tokei --version 14.0.0 --locked && sudo apt install jq   # Linux

.agents/scripts/loc-badge-helper.sh --output-dir /tmp/badge-test
ls /tmp/badge-test/      # loc-total.svg + loc-languages.svg
open /tmp/badge-test/loc-languages.svg

# Print parsed summary without writing SVGs
.agents/scripts/loc-badge-helper.sh --json-only | jq .total
```

Test the README helper:

```bash
.agents/scripts/readme-badges-helper.sh render marcusquinn/aidevops
.agents/scripts/readme-badges-helper.sh check README.md marcusquinn/aidevops
```

## Related

- `reference/reusable-workflows.md` — the t2770 reusable-workflow architecture
  this feature follows
- `.agents/templates/workflows/issue-sync-caller.yml` — the canonical caller
  template that `loc-badge-caller.yml` mirrors
- Phase 2 issue (filed at end of this PR) — `aidevops badges` CLI + `init` hook
