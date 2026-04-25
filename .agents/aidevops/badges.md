<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Badges — README badge template + LOC reusable workflow

aidevops ships a consistent badge block for every managed repo: shields.io
badges for stats GitHub already exposes, plus a self-hosted SVG for lines
of code (the only badge that needs custom infrastructure because shields.io's
tokei endpoint is too unreliable to depend on).

This is **Phase 1** — the framework artifacts. **Phase 2** (filed as a
follow-up issue) adds the `aidevops badges check|sync|render|install`
CLI subcommand and an `aidevops init` hook to apply badges automatically
to every managed repo from `repos.json`.

## What you get

Three artifacts deployed by `setup.sh`:

1. **`.agents/scripts/loc-badge-helper.sh`** — runs `tokei`, emits two SVGs:
   - `.github/badges/loc-total.svg` — shields.io-style "lines of code: 482k"
   - `.github/badges/loc-languages.svg` — GitHub-style horizontal stacked
     bar of the top-N languages with a percentage legend
2. **`.agents/scripts/readme-badges-helper.sh`** — renders the badges
   markdown for a slug, injects/checks an idempotent block in a README
3. **`.agents/templates/readme/badges.md.tmpl`** — the canonical badges
   block, with conditional sections for licence, releases, and FOSS-only
   community badges

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

## How the marker block works

The injected block is bounded by HTML comment markers that are invisible
in rendered Markdown:

```markdown
<!-- aidevops:badges:start -->
<!-- managed by aidevops badges; edit the template, not this block -->
[![Lines of code](...)](...)
[![Last commit](...)](...)
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
| `HAS_LOC_BADGE` | `--no-loc-badge` flag | default `1`; empty if disabled |
| `HAS_RELEASES` | `gh api releases?per_page=1` | empty for `local_only` repos |
| `IS_FOSS` | `repos.json[].foss` | enables Stars/Forks/Open lines |
| `HAS_LICENSE` | (Phase 2: filesystem probe) | currently always `1` |

To add or remove a badge, edit the template — never edit the rendered
block in any README directly.

## Local development

Test the LOC helper against this repo:

```bash
brew install tokei jq    # macOS
# apt install tokei jq   # Ubuntu

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
