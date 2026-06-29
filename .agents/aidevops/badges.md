<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Badges — README badge template + local repository metrics

aidevops ships a consistent badge block for every managed repo: a native
GitHub Actions badge when a concrete workflow file is known, static shields.io
badges for values that do not require GitHub API access, and committed local
SVGs for lines of code, language mix, and dependency counts. The template
deliberately avoids `img.shields.io/github/...`
endpoints because those can render upstream service text such as "Unable to
select next GitHub token from pool" in public READMEs.

Use `aidevops metrics generate` for the current repo, or `aidevops badges
render|check|sync|install` to manage README badge blocks and refresh workflows
for repos listed in `repos.json`.

Subcommands:

- `render` — print the badge block that would be inserted.
- `check` — fail on README badge drift.
- `sync` — update the README badge block, generate local metrics, and install the managed refresh workflow caller.
- `install` — install the managed repo metrics refresh workflow for a repo.

## What you get

Three artifacts deployed by `setup.sh`:

1. **`.agents/scripts/repo-metrics-helper.sh`** — runs a dependency-light local scanner and emits:
   - `docs/metrics/repo-metrics.json` — machine-readable app/about-page data
   - `docs/metrics/repo-metrics.md` — human-readable summary tables
   - `docs/metrics/badges/loc.svg` — lines-of-code badge
   - `docs/metrics/badges/languages.svg` — top-N language breakdown badge
   - `docs/metrics/badges/dependencies.svg` — dependency count badge
   - `.github/badges/loc-total.svg` and `.github/badges/loc-languages.svg` for legacy README compatibility
2. **`.agents/scripts/readme-badges-helper.sh`** — renders the badges
   markdown for a slug, injects/checks an idempotent block in a README, and
   only emits an Actions badge after resolving an actual workflow file
3. **`.agents/templates/readme/badges.md.tmpl`** — the canonical badges
   block, with conditional sections for native Actions, licence, and local metrics badges

Plus the GitHub Actions wiring:

4. **`.github/workflows/loc-badge-reusable.yml`** — reusable workflow
   that downstream repos call from a tiny caller YAML; it runs weekly and on
   default-branch pushes, skips outputs fresher than 24h by default, and never
   runs on pull_request events
5. **`.agents/templates/workflows/loc-badge-caller.yml`** — the caller template

## Add badges to a repo (manual flow)

This is the manual flow that works today. Phase 2 wraps it in
`aidevops badges sync`.

```bash
# 1. Generate local metrics immediately
~/.aidevops/agents/scripts/repo-metrics-helper.sh generate \
   --legacy-badge-dir .github/badges

# 2. Drop in the repo metrics refresh workflow caller
cp ~/.aidevops/agents/templates/workflows/loc-badge-caller.yml \
   .github/workflows/loc-badge.yml
git add docs/metrics .github/badges .github/workflows/loc-badge.yml
git commit -m "chore(metrics): add repository metrics"
git push

# 3. Inject the README badge block
~/.aidevops/agents/scripts/readme-badges-helper.sh inject README.md owner/repo
git add README.md
git commit -m "chore(docs): add managed badges block"
git push
```

The README block references relative `docs/metrics/badges/*.svg` assets, so it
renders as soon as the files are committed. The workflow refreshes the metrics
periodically without delaying PR checks.

Do not add GitHub-backed Shields badges such as repository size, stars,
watchers, language count, release date, or issue counts to the canonical block.
Those badges depend on Shields' GitHub token pool and can intermittently render
the provider error string instead of the intended value. Prefer GitHub-native
badges for Actions, local generated SVGs for repository metrics, static Shields
badges for local/static facts, and direct Markdown links for GitHub pages that
do not need a badge.

## How the marker block works

The injected block is bounded by HTML comment markers that are invisible
in rendered Markdown:

```markdown
<!-- aidevops:badges:start -->
<!-- managed by aidevops badges; edit the template, not this block -->
[![GitHub Actions](...)](...)
[![License](...)](...)
[![Lines of code](docs/metrics/badges/loc.svg)](docs/metrics/repo-metrics.md)
[![Languages by lines of code](docs/metrics/badges/languages.svg)](docs/metrics/repo-metrics.md)
[![Dependencies](docs/metrics/badges/dependencies.svg)](docs/metrics/repo-metrics.md)
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
| `HAS_REPO_METRICS` | `--no-repo-metrics` flag | default `1`; empty if disabled |
| `HAS_LOC_BADGE` | compatibility alias | mirrors `HAS_REPO_METRICS` |
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

Test the repo metrics helper against this repo:

```bash
.agents/scripts/repo-metrics-helper.sh generate \
  --output-dir /tmp/aidevops-metrics \
  --badge-dir /tmp/aidevops-metrics/badges
ls /tmp/aidevops-metrics/      # repo-metrics.json + repo-metrics.md + badges/
open /tmp/aidevops-metrics/badges/languages.svg

# Print parsed summary without writing SVGs
.agents/scripts/repo-metrics-helper.sh json | jq .summary
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
