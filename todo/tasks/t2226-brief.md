<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2226 Brief — Validator install prerequisite for install-hooks-helper.sh

**Issue:** GH#19747 (marcusquinn/aidevops — filed alongside this brief).

## Session origin

Discovered 2026-04-18 during PR #19712 (t2209) session. PR #19683 (t2191) installed the `.git/hooks/pre-commit` dispatcher. That single install activated 4 dormant validator bugs simultaneously (t2209, t2215, t2216, t2217) that had been latent in the hook source. The install-hooks-helper.sh flow had no smoke test verifying validators would pass against a no-op commit on current HEAD — so it shipped a self-blocking toolchain to every operator that ran `install`.

## What / Why / How

See issue body for:

- Reference pattern: `install-hooks-helper.sh install` already has dispatcher-registration logic — extend with a pre-install `dry_run_validators` step
- Behaviour spec: run hook against HEAD (as if committing an empty change), abort install if any validator raises a violation, report which validator and why
- Install caller mapping: `setup.sh`, `/install-hooks`, any direct invocation

## Acceptance criteria

Listed in issue body. Core assertions:

1. `install-hooks-helper.sh install` invokes a dry-run validator pass before writing `.git/hooks/pre-commit`.
2. Dry-run failure aborts install with actionable error pointing at which validator + which HEAD-file combination failed.
3. `--force-install` flag bypasses the check (for the bootstrap case where the install is itself shipping the fix).
4. Regression test under `.agents/scripts/tests/` covering pass and fail paths.

## Tier

`tier:standard` — new logic path in install flow, but the helper is under 500 lines and the pattern mirrors existing `install_gh_wrapper_guard_hook` chain pattern. Default to standard because the bypass-flag design needs judgment.
