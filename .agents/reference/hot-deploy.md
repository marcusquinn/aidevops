<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hot-Deploy: Immediate Runner Propagation for Critical Fixes (t2398)

## Problem

When a critical fix merges (e.g., an OAuth auth regression that causes every dispatch to HTTP 401), remote runners continue running pre-fix code until their next scheduled `aidevops update` cycle. The regular update check is rate-limited to ~24 hours, creating a window where remote runners are degraded.

**Evidence:** On 2026-04-19, t2392 (OAuth model-availability fix) merged at 18:13 UTC and bumped to v3.8.78. The local runner picked up the fix immediately via manual `setup.sh --non-interactive`. The remote runner continued fast-failing every dispatch cycle for hours.

## Solution

A maintainer-signalled fast path: `version-manager.sh release patch --hotfix` creates a `hotfix-v{version}` tag alongside the normal `v{version}` release tag. Runners poll for hotfix tags on a shorter interval (5 minutes) and either auto-apply or show a banner.

## Architecture

```text
Maintainer:  release patch --hotfix
                  |
                  v
GitHub tags: v3.8.79  +  hotfix-v3.8.79
                            |
                            v
Remote runner:  _check_hotfix_available() polls every 5 min
                            |
              +-------------+-------------+
              |                           |
     auto_hotfix_accept=true     auto_hotfix_accept=false
              |                           |
    git pull + setup.sh         Session banner:
    + restart pulse             "Hotfix available..."
```

## Usage

### Publishing a hotfix (maintainer)

```bash
# Preview what will happen
.agents/scripts/version-manager.sh release patch --hotfix --dry-run

# Execute the hotfix release
.agents/scripts/version-manager.sh release patch --hotfix
```

The `--hotfix` flag:
- Only works with `patch` bumps (enforced)
- Requires maintainer identity (verified via `gh api`)
- Creates `hotfix-v{version}` tag alongside `v{version}`
- Pushes the hotfix tag to the remote

### Receiving a hotfix (runner)

Configure in `~/.aidevops/configs/auto-hotfix.conf`:

```bash
# Auto-apply hotfixes (recommended for trusted remote runners)
auto_hotfix_accept=true
auto_hotfix_restart_pulse=true

# Manual mode (default — shows banner, operator decides)
auto_hotfix_accept=false
```

The config file is deployed by `setup.sh` to `~/.aidevops/configs/auto-hotfix.conf` on first setup. User edits survive `aidevops update`.

## When to use `--hotfix`

Use `--hotfix` for:
- **OAuth/authentication regressions** — every dispatch fails
- **Security fixes** — vulnerability patches
- **Core-loop regressions** — pulse crashes, dispatch failures, merge-pass errors

Do NOT use `--hotfix` for:
- Feature additions
- Documentation updates
- Non-critical bug fixes
- Refactoring

## Safety constraints

1. **Maintainer-only**: The `--hotfix` flag verifies the current user is repo admin/maintain/write via `gh api`. Non-maintainers are rejected.
2. **Patch-only**: Hotfix releases bump the patch version only. Major/minor bumps with `--hotfix` are rejected.
3. **Default off**: Runners default to `auto_hotfix_accept=false` (banner only). Auto-apply requires explicit opt-in per machine.
4. **Rate-limited polling**: Hotfix check runs every 5 minutes max, not on every session start.
5. **Pulse restart gated**: `auto_hotfix_restart_pulse` controls whether the pulse is auto-restarted after applying a hotfix.

## Verification

```bash
# Test dry-run
.agents/scripts/version-manager.sh release patch --hotfix --dry-run

# Test banner (forces the hotfix check regardless of rate limit)
AIDEVOPS_FORCE_HOTFIX_BANNER=1 .agents/scripts/aidevops-update-check.sh --interactive

# Run the test suite
.agents/scripts/tests/test-hot-deploy-flow.sh
```

## Related

- `prompts/build.txt` "Pulse restart after deploying pulse script fixes" — existing manual restart rule
- `reference/cross-runner-coordination.md` — multi-runner coordination
- `reference/auto-update.md` — regular update mechanism
- t2394 (CLAIM_VOID) — complementary fix for cross-runner poisoning
