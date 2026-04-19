<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2259: Biome CI fails on all PRs against pre-existing JS/MJS files

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code (interactive, t2249 session)
- **Observation:** Biome CI check red on PRs #19788, #19789, #19790 for pre-existing violations unrelated to each PR's changes.

## What

Biome CI job at `.github/workflows/code-quality.yml:929` fails on every PR because pre-existing `.agents/scripts/**/*.mjs` and `*.js` files violate Biome rules (`lint/style/useTemplate`, `lint/style/useNodejsImportProtocol`, `lint/correctness/noUnusedImports`, etc.).

## Why

Not a blocker for merge (not a required check), but the persistent red check creates noise on every PR and trains contributors to ignore red checks — the classic "cry wolf" pattern. Also makes legitimately new Biome regressions harder to spot.

## How

Three options, ordered by preference:

1. **Batch-fix the violations** — preferred:
   ```bash
   npx --yes @biomejs/biome@2.4.12 check --apply .agents/scripts/**/*.{js,mjs}
   ```
   Likely ~50-100 auto-fixable changes (template literals, `node:` protocol imports, unused imports). Commit in one PR.

2. **Scope exclusion:** add `.biomeignore` or update `biome.json` to exclude `.agents/scripts/**` if those files aren't part of the published framework surface.

3. **Relax rules:** downgrade specific rules to `warn` in `biome.json` — only if option 1 surfaces intentional non-compliance.

## Tier

Tier:standard. Likely auto-fixable but needs review of the diff before committing. Multiple files, some judgment on which rules survive.

## Acceptance

- [ ] Biome CI passes on new PRs against main.
- [ ] No functional regression in the affected `.mjs` / `.js` scripts.
- [ ] If option 1 chosen: diff reviewed before merge; no behavioural changes (only stylistic).

## Relevant files

- `.github/workflows/code-quality.yml:929` — Biome job definition
- `biome.json` — ruleset (root)
- `.agents/scripts/**/*.mjs` / `*.js` — affected files
