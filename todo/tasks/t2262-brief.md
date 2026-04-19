<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2262: Pre-commit SC1091 warnings on sourced files despite .shellcheckrc disable

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code (interactive, t2249 session)
- **Observation:** Pre-commit shellcheck emits SC1091 ("Not following: external file ...") for `headless-runtime-helper.sh:23,25,53` which source `shared-constants.sh`, `worker-lifecycle-common.sh`, and `headless-runtime-lib.sh`. `.shellcheckrc` at repo root attempts to disable this but shellcheck 0.11 still fires.

## What

Directive syntax in `.shellcheckrc` or per-file source hints is not suppressing SC1091 on shellcheck 0.11. Forced `--no-verify` during t2249 PR commits — undesirable because bypass also skips OTHER pre-commit checks, not just the noisy one.

## Why

Noisy pre-commit hooks train bypass. Every `--no-verify` commit is a lost opportunity to catch a real issue.

## How

Three options, ordered by preference:

1. **Per-site source directives** — preferred, explicit and local:
   ```bash
   # shellcheck source=./shared-constants.sh
   source "${SCRIPT_DIR}/shared-constants.sh"
   ```
   Add at each of the three source sites in `headless-runtime-helper.sh:23,25,53` (and audit other helpers that source siblings).

2. **Update `.shellcheckrc`** — if directive syntax changed between 0.9 and 0.11:
   - Try `external-sources=false` (suppress, don't follow).
   - Try `source-path=SCRIPTDIR` combined with per-file `# shellcheck source-path=.`.

3. **Pin shellcheck version** — add a version check in the pre-commit hook if 0.11 has a genuine regression.

## Tier

Tier:simple. Preferred approach is a targeted line-by-line edit with verbatim directive syntax.

## Acceptance

- [ ] `shellcheck .agents/scripts/headless-runtime-helper.sh` emits no SC1091.
- [ ] Pre-commit hook passes without `--no-verify` on clean-source commits.
- [ ] Audit other helpers for the same pattern (at minimum: the files touched by t2249).

## Relevant files

- `.agents/scripts/headless-runtime-helper.sh:23,25,53` — source sites
- `.shellcheckrc` — repo-level config
- `.agents/scripts/shared-constants.sh` — sourced file
- `.agents/scripts/worker-lifecycle-common.sh` — sourced file
- `.agents/scripts/headless-runtime-lib.sh` — sourced file
