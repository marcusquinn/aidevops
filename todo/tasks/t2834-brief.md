<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2834: loc badges + readme badges template (reusable workflow + helpers)

## Pre-flight

- [x] Memory recall: `loc badges readme template` → 0 hits — no prior lessons stored
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in last 48h (clean slate)
- [x] File refs verified: all NEW files; parent dirs `.agents/scripts/`, `.agents/templates/`, `.github/workflows/` exist
- [x] Tier: `tier:standard` — multi-file feature with new helpers, template, and reusable workflow; not transcription

## Origin

- **Created:** 2026-04-25
- **Session:** opencode:interactive
- **Created by:** marcusquinn (human) via interactive conversation
- **Conversation context:** User asked whether aidevops can add a lines-of-code badge across all repos. After discussing shields.io / codetabs / self-hosted options, user chose self-hosted SVG via reusable workflow with language breakdowns. User then expanded scope to "aidevops should have a badges template that we can apply to the readme of all repos we aidevops init and manage with repos.json". This task ships Phase 1 (the framework artifacts); Phase 2 (CLI + init hook + check/sync) is filed separately.

## What

Phase 1 deliverables — the reusable framework artifacts other repos consume:

1. **`loc-badge-helper.sh`** — runs `tokei`, parses JSON, generates two SVGs:
   - `.github/badges/loc-total.svg` — total lines of code with shields.io-style format
   - `.github/badges/loc-languages.svg` — GitHub-style horizontal stacked bar with top-N languages and a legend
2. **`loc-badge-reusable.yml`** — reusable GitHub Actions workflow (`workflow_call:`). Installs tokei, runs the helper, commits SVGs back via SYNC_PAT||GITHUB_TOKEN, with `[skip ci]` and bot-author guard for loop prevention. Triggers: push to default + weekly schedule + workflow_dispatch.
3. **`loc-badge-caller.yml`** — ~30-line caller template downstream repos copy into `.github/workflows/loc-badge.yml`.
4. **`badges.md.tmpl`** — README badges template with `{{SLUG}}` / `{{DEFAULT_BRANCH}}` / `{{HAS_RELEASES}}` placeholders. Logical badge groups: Build/Quality, License, GitHub Stats (LOC, languages, last commit, contributors, commit activity, code size), Release, Community, Framework-specific (optional). Bounded by `<!-- aidevops:badges:start -->` / `<!-- aidevops:badges:end -->` markers for idempotent updates.
5. **`readme-badges-helper.sh`** — three subcommands: `render <slug>` (prints rendered template), `inject <readme-path>` (idempotently updates the marker block in a README.md), `check <readme-path>` (drift detection — exit 1 if rendered != current).
6. **`badges.md`** — feature documentation under `.agents/aidevops/`.

What the user experiences: any repo can drop in the caller workflow, point its README at the helper-rendered template, and get auto-updating LOC SVGs + a polished standard badge set across all managed repos.

## Why

- Consistency across 30+ managed repos — currently each README has bespoke badges (or none).
- The aidevops README has a great badge block but it's hand-maintained; replicating that quality across every repo by hand doesn't scale.
- LOC is the only missing badge that needs custom infra (shields.io's tokei service is flaky); everything else uses shields.io GitHub endpoints which are reliable.
- Establishes the artifacts that Phase 2 (`aidevops badges check|sync|render` + `aidevops init` hook) will operate on. Phase 1 must ship first so Phase 2 has something to apply.

## How

### Files Scope

- `.agents/scripts/loc-badge-helper.sh`
- `.agents/scripts/readme-badges-helper.sh`
- `.agents/templates/readme/badges.md.tmpl`
- `.agents/templates/workflows/loc-badge-caller.yml`
- `.agents/aidevops/badges.md`
- `.github/workflows/loc-badge-reusable.yml`
- `todo/tasks/t2834-brief.md`

### Implementation notes

- **`loc-badge-helper.sh`**: depend on `tokei` + `jq` (both Ubuntu-installable in a single apt-get). Output dir defaults to `.github/badges/`. Top-N defaults to 6. Inline SVG generation (no external SVG libraries) — language colors map from a small table mirroring GitHub's language colors for the most common ones, with a fallback grey. Exclude common dirs by default (`__aidevops/`, `node_modules/`, `vendor/`, `.git/`, `dist/`, `build/`).
- **`readme-badges-helper.sh`**: read repo metadata from `~/.config/aidevops/repos.json` for the given slug. Compute `HAS_LICENSE` (file exists), `HAS_RELEASES` (gh api call, fail-soft to false), `IS_FOSS` (repos.json `foss` key). Use `awk` for marker-block replacement to keep dependency surface small.
- **`loc-badge-reusable.yml`**: model on `issue-sync-reusable.yml` exactly — same pattern for `actions/checkout` of aidevops scripts at runtime, same `SYNC_PAT||GITHUB_TOKEN` token logic, same bot-author guard for loop prevention. The reusable workflow checks out aidevops at `${{ inputs.aidevops_ref || 'main' }}`.
- **Caller template**: model on `issue-sync-caller.yml` — minimal, declares triggers, `uses: marcusquinn/aidevops/.github/workflows/loc-badge-reusable.yml@main`, `secrets: inherit`.
- **README block markers**: use HTML comments so they're invisible in rendered markdown. `<!-- aidevops:badges:start -->` / `<!-- aidevops:badges:end -->`. The injector writes a notice line inside: `<!-- managed by aidevops badges; edit template not block -->`.

### Verification

```bash
# Local test on this repo
.agents/scripts/loc-badge-helper.sh --output-dir /tmp/badge-test
ls -la /tmp/badge-test/  # expect loc-total.svg + loc-languages.svg
.agents/scripts/readme-badges-helper.sh render marcusquinn/aidevops > /tmp/badges.md
shellcheck .agents/scripts/loc-badge-helper.sh .agents/scripts/readme-badges-helper.sh
yq -P . .github/workflows/loc-badge-reusable.yml > /dev/null
yq -P . .agents/templates/workflows/loc-badge-caller.yml > /dev/null
```

## Acceptance

1. `loc-badge-helper.sh` produces two valid SVG files when run in this repo (verifiable by `file /tmp/badge-test/*.svg` showing SVG type).
2. `readme-badges-helper.sh render marcusquinn/aidevops` outputs a markdown block bounded by the start/end markers, with all `{{SLUG}}` placeholders substituted.
3. `loc-badge-reusable.yml` passes `actionlint` (the framework's existing workflow lint).
4. `loc-badge-caller.yml` is ≤45 lines (matching the issue-sync caller's shape).
5. ShellCheck zero violations on both helpers.
6. `.agents/aidevops/badges.md` documents installation, the marker convention, the SVG output paths, and forward-references the Phase 2 CLI work.

## PR Conventions

Leaf task — PR will use `Resolves #20879`.

## Phase 2 (separate issue, filed at end of this PR)

Add `aidevops badges check|sync|render|install` subcommand mirroring `aidevops check-workflows`/`sync-workflows`. Hook `aidevops init` to offer badge-block injection on first repo setup. Cross-repo drift detection via the helper's `check` subcommand iterating `~/.config/aidevops/repos.json`.
