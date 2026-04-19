<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2265 — Add `init_scope` field to scope `aidevops init` scaffolding

## Session Origin

Interactive session with marcusquinn on 2026-04-19. While initialising four
new `local_only: true` Jersey website repos (`trinityjoinery.je`,
`trinitywindows.je`, `autocarejersey.com`, `connections.je`), we confirmed
that `aidevops init planning` creates ~14 files per repo — and for a private
WP single-site repo that will never have an external contributor, >50% of
those files are pure noise (`LICENCE`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`,
`SECURITY.md`, `CHANGELOG.md`, `DESIGN.md`, `MODELS.md`, plus four redundant
one-liner pointer files `.cursorrules` / `.windsurfrules` / `.clinerules` /
`.github/copilot-instructions.md`).

User's observation: "we'll always have the master aidevops installed on this
or any user machine to use for the scripts needed" — so per-repo duplicates
of framework-level boilerplate are waste.

## What

Add a new optional `init_scope` field to each entry in
`~/.config/aidevops/repos.json` and to the per-project `.aidevops.json` file.
Values: `"minimal"`, `"standard"`, `"public"`. Default is inferred from the
registration context when absent (see "Defaults" below).

`cmd_init` reads this scope and gates which scaffolding functions run. When
set to `"minimal"`, init only creates files that carry project-specific
content — never public-repo boilerplate.

## Why

- Private websites (5 of the 33 repos in the current `repos.json`) will never
  have external contributors. They do not need `CODE_OF_CONDUCT.md`,
  `CONTRIBUTING.md`, or `SECURITY.md`.
- Four collaborator pointer files (`.cursorrules`, `.windsurfrules`,
  `.clinerules`, `.github/copilot-instructions.md`) each contain the identical
  one-line string `Read AGENTS.md for all project context and instructions.`
  — that's four files for a 10-byte instruction.
- The framework lives at `~/.aidevops/agents/` globally. Every init'd repo
  duplicating framework-level MIT boilerplate (LICENCE) or pattern-of-the-day
  templates (DESIGN.md, MODELS.md) is noise the human has to stare past.
- This landed bug blocks option A from the session: re-initing every repo
  in `repos.json` at current scaffolding volume would commit ~100 unnecessary
  files across the ecosystem.

## How

### 1. Scope definitions

| File / directory | minimal | standard (current default) | public |
|---|---|---|---|
| `TODO.md` | ✅ | ✅ | ✅ |
| `todo/PLANS.md`, `todo/tasks/.gitkeep` | ✅ | ✅ | ✅ |
| `.aidevops.json` | ✅ | ✅ | ✅ |
| `.gitignore` (aidevops-runtime entries) | ✅ | ✅ | ✅ |
| `.gitattributes` (ai-training=false) | ✅ | ✅ | ✅ |
| `AGENTS.md` (root) | ✅ | ✅ | ✅ |
| `.agents/AGENTS.md` | ✅ | ✅ | ✅ |
| `.agents/commands/` symlink | ✅ | ✅ | ✅ |
| Mission control starter | ✅ (if scope matches) | ✅ | ✅ |
| `DESIGN.md` skeleton | ❌ | ✅ | ✅ |
| `MODELS.md` leaderboard | ❌ | ✅ | ✅ |
| `.cursorrules` / `.windsurfrules` / `.clinerules` / `.github/copilot-instructions.md` | ❌ | ✅ | ✅ |
| `README.md` | ❌ (user writes theirs) | ✅ | ✅ |
| `LICENCE` (MIT boilerplate) | ❌ | ❌ | ✅ |
| `CHANGELOG.md` | ❌ | ❌ | ✅ |
| `CONTRIBUTING.md` | ❌ | ❌ | ✅ |
| `SECURITY.md` | ❌ | ❌ | ✅ |
| `CODE_OF_CONDUCT.md` | ❌ | ❌ | ✅ |

Rationale: "standard" matches the current behaviour minus the courtesy files
(which are the real noise for internal tooling). "public" preserves the
current full set for genuine open-source repos.

### 2. Default inference (when `init_scope` absent)

Implemented as a helper `_infer_init_scope` called from both `cmd_init` and
`register_repo`:

- If `.aidevops.json` already has a non-empty `init_scope`, use it.
- If `repos.json` entry has `init_scope`, use it.
- If `local_only: true` OR no git remote → `"minimal"`.
- If the remote slug is under an owner with `public_default_init_scope: "public"`
  in a new `~/.config/aidevops/init-scope-defaults.json` (optional file) → `"public"`.
- Otherwise → `"standard"` (current behaviour — backward compatible).

### 3. Files to modify

- **EDIT** `/usr/local/bin/aidevops` (the CLI; in-repo source at
  `bin/aidevops` or wherever the build writes from — trace via `aidevops doctor`
  or `file $(which aidevops)` to confirm):
  - `cmd_init` (currently at `/usr/local/bin/aidevops:1675-2356`): read
    `init_scope` early, gate each optional scaffold call behind a
    `_scope_includes <feature>` check.
  - `register_repo` (currently at `/usr/local/bin/aidevops:351-449`):
    preserve user-set `init_scope` on re-registration (same pattern as
    `pulse`, `priority`, `maintainer` preservation already in the jq
    update block).
  - `scaffold_repo_courtesy_files` (currently at `/usr/local/bin/aidevops:1270-1336`):
    accept a scope argument, skip LICENCE/CHANGELOG/CONTRIBUTING/SECURITY/CoC
    for non-`public` scopes.
  - Collaborator pointer generation (currently at
    `/usr/local/bin/aidevops:2199-2215`): skip entire block for `minimal`.
  - `DESIGN.md` seed (currently at `/usr/local/bin/aidevops:2217-2227`):
    skip for `minimal`.
  - `MODELS.md` generation (currently at `/usr/local/bin/aidevops:2232-2243`):
    skip for `minimal`.

- **EDIT** `.agents/configs/` (if there is a per-feature-flag config file):
  document the new scope field.
- **EDIT** `AGENTS.md` (deployed from `.agents/AGENTS.md`): add a short
  note under the init section describing `init_scope` behaviour.
- **NEW** `.agents/scripts/tests/test-init-scope.sh`: unit test that
  creates three tmp repos (minimal, standard, public), runs `aidevops init
  planning` in each, asserts each scope creates only the expected files.

### 4. Reference pattern

Model on the existing feature-flag handling in `cmd_init`
(`enable_planning`, `enable_database`, `enable_beads` etc.). Each already
gates a block of scaffolding behind a boolean. `init_scope` is the same
pattern but one level up — it decides whether the universal (non-feature)
blocks run.

### 5. Backward compatibility

- Existing `.aidevops.json` files have no `init_scope` → falls through to
  `_infer_init_scope` which returns `"standard"` for non-local_only repos,
  preserving today's behaviour.
- Existing `repos.json` entries without `init_scope` → same inference applies.
- `aidevops upgrade-planning` is unaffected (it only touches TODO/PLANS
  templates).

## Acceptance criteria

1. `aidevops init planning` in a `local_only: true` folder creates **no**
   `LICENCE`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`,
   `CODE_OF_CONDUCT.md`, `DESIGN.md`, `MODELS.md`, `.cursorrules`,
   `.windsurfrules`, `.clinerules`, or `.github/copilot-instructions.md`
   files when no `init_scope` is set (default inference picks `minimal`).
2. `aidevops init planning` in a repo with `init_scope: "public"` in
   `repos.json` creates the full current file set.
3. Re-running `aidevops init` on an existing repo preserves its
   `init_scope` (round-trip survival).
4. `.agents/scripts/tests/test-init-scope.sh` passes and covers all three
   scopes.
5. `aidevops doctor` surfaces repos whose on-disk scaffolding does not
   match their declared `init_scope` (e.g., a `"minimal"` repo still
   carrying a `CODE_OF_CONDUCT.md`). Advisory only — does not auto-remove.

## Out of scope

- **Retroactive cleanup.** Deleting existing courtesy files from already-
  init'd repos is a separate task (follow-up after this ships). Each repo
  needs a small PR that removes `CONTRIBUTING.md` etc. — this task only
  prevents NEW repos from inheriting them.
- **Scope migration tooling.** Changing a repo from `standard` → `minimal`
  requires deletion of now-excluded files; that's `aidevops init --reconcile`
  territory (future).

## Context

- Session thread: 2026-04-19 interactive run; user picked option A when
  presented the tradeoff between mass-init-now (option B) and fix-init-first
  (option A).
- Companion task: repo aidevops health keeper routine (filed separately in
  `aidevops-routines`) will use `init_scope` once this ships.
- Related framework files already parse `.aidevops.json`:
  `workflows/plans.md`, `scripts/feature-flag-helper.sh`, and
  `security-posture-helper.sh` — none of these need changes, but the new
  field should be documented in the same config-schema references.
