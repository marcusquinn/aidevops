<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2408: approval-helper.sh missing source of shared-constants.sh

**Issue:** GH#19997
**Origin:** interactive (user hit the bug running `sudo aidevops approve issue 19992`)
**Tier:** simple
**Estimate:** ~15m

## What

Add a conditional `source` of `shared-constants.sh` near the top of `approval-helper.sh` so the `gh_issue_comment` and `gh_pr_comment` wrappers are defined by the time `_approve_target` and `_post_issue_approval_updates` call them.

## Why

PR #19953 (t2393, merged 2026-04-19 19:16Z) replaced `gh issue comment` and `gh pr comment` with the `gh_issue_comment` / `gh_pr_comment` wrappers at:

- `approval-helper.sh:396` (PR approval lock comment)
- `approval-helper.sh:442` (issue approval comment)
- `approval-helper.sh:447` (PR approval comment)

The wrappers are defined in `shared-constants.sh:1167,1174` so they auto-append the t2393 signature footer. `approval-helper.sh` does NOT source `shared-constants.sh`, so under `sudo aidevops approve issue <N>` the wrappers are unbound and bash emits:

```
approval-helper.sh: line 442: gh_issue_comment: command not found
[ERROR] Failed to post approval comment on issue #<N>
```

This blocks cryptographic approval entirely — the whole point of the `sudo aidevops approve` gate is to post the SSH-signed comment. Currently every approval attempt fails.

PR #19953 also touched `circuit-breaker-helper.sh` and `loop-common.sh`, but both of those already source `shared-constants.sh` (circuit-breaker-helper.sh:29-32, loop-common.sh:33), so they weren't affected. `approval-helper.sh` is the only directly-invoked caller that was missed.

## How

### Files to modify

- **EDIT:** `.agents/scripts/approval-helper.sh` — add a sourcing block mirroring `circuit-breaker-helper.sh:29-32` after the `set -euo pipefail` line (24) and before the `_resolve_real_home` helper (32). Must be conditional (`[[ -f ]] && source`) so the script doesn't hard-fail if `shared-constants.sh` goes missing on a partial install.

- **NEW:** `.agents/scripts/tests/test-approval-wrappers-available.sh` — regression test that sources `approval-helper.sh` in a subshell and asserts both `gh_issue_comment` and `gh_pr_comment` are defined as functions. Must exit 0 when the wrappers are bound and exit 1 with a diagnostic when they aren't. This catches any future refactor that removes the source line.

### Reference pattern

`.agents/scripts/circuit-breaker-helper.sh:29-32`:

```bash
# Source shared-constants for gh_create_issue wrapper (t1756)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
```

Copy this block verbatim into `approval-helper.sh`, adjusting only the comment to mention the t2393 wrappers (`gh_issue_comment` / `gh_pr_comment`) rather than `gh_create_issue`.

### Verification

Inside the worktree:

```bash
# 1. Shellcheck clean
shellcheck .agents/scripts/approval-helper.sh

# 2. Wrappers resolvable after sourcing
bash -c 'source .agents/scripts/approval-helper.sh 2>/dev/null || true; declare -f gh_issue_comment >/dev/null && echo "OK gh_issue_comment" || echo "MISS gh_issue_comment"; declare -f gh_pr_comment >/dev/null && echo "OK gh_pr_comment" || echo "MISS gh_pr_comment"'

# 3. Regression test
.agents/scripts/tests/test-approval-wrappers-available.sh

# 4. End-to-end (separate terminal, requires sudo)
sudo aidevops approve issue 19997
```

## Acceptance criteria

- [ ] `approval-helper.sh` sources `shared-constants.sh` using the conditional pattern from `circuit-breaker-helper.sh:29-32`
- [ ] `gh_issue_comment` and `gh_pr_comment` are defined after sourcing `approval-helper.sh`
- [ ] `test-approval-wrappers-available.sh` exists and passes
- [ ] Shellcheck clean on `approval-helper.sh`
- [ ] `sudo aidevops approve issue <N>` posts a signed approval comment end-to-end

## Tier rationale

`tier:simple`: single file, <10 lines added, verbatim pattern copy from an existing caller, one small test. No judgment calls, no architectural decisions.

## Context

- Downstream impact: every `sudo aidevops approve issue <N>` / `sudo aidevops approve pr <N>` has failed since PR #19953 merged (~3 hours before this task was filed). Issue GH#19992 is currently blocked on manual approval.
- No revert is needed — PR #19953's t2393 goal (signature footer on approval comments) is still desirable; we just need the wrappers to be reachable.
- Related: memory recall returned no prior lesson for "gh_issue_comment approval-helper"; store one on completion.
