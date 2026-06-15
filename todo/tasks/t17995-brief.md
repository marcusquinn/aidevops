---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t17995: Make OAuth token-refresh failures visible to automation

## Origin

- **Created:** 2026-06-15
- **Session:** OpenCode interactive diagnostics of OpenAI 401 / token-refresh renewal
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none

## What

Fix OAuth pool refresh automation so a failed account refresh is visible to schedulers such as `aidevops-token-refresh.service`, and so logs distinguish safe HTTP/auth failure labels from generic network errors without exposing credentials.

## Why

Interactive diagnostics found `aidevops-token-refresh.timer` running successfully, but `~/.aidevops/.agent-workspace/logs/token-refresh.log` contained repeated `Failed to refresh: alexey@awardsapp.ai(network)` entries. The systemd service stayed `status=0/SUCCESS` because `.agents/scripts/oauth-pool-manage.sh` prints a warning for refresh failures and then returns `0`. The Python token refresh helper also collapses `HTTPError`, `URLError`, and `OSError` into `None`, so 401/invalid_grant/token-revocation cases are logged as `(network)` instead of actionable auth-safe labels.

## Files to Modify

- `EDIT: .agents/scripts/oauth-pool-manage.sh:368-428` — propagate per-account refresh failures as a non-zero command exit while preserving no-op success when no accounts need refreshing.
- `EDIT: .agents/scripts/oauth-pool-lib/_common.py:131-164` — return/raise a sanitized refresh failure classification that distinguishes HTTP status/auth-style failures from network errors without logging tokens or response bodies.
- `EDIT: .agents/scripts/oauth-pool-lib/pool_ops_refresh.py:81-118,170-220` — carry safe failure labels through `FAILED:` output and keep successful refresh/self-heal behaviour intact.
- `NEW/EDIT: .agents/scripts/oauth-pool-lib/tests/test_pool_ops.py` and/or `.agents/scripts/tests/test-oauth-*.sh` — cover shell exit code and Python classification behaviour.

## Acceptance Criteria

- `oauth-pool-helper.sh refresh openai` exits `0` when no account needs refresh.
- `oauth-pool-helper.sh refresh openai` exits `0` when eligible accounts refresh successfully.
- `oauth-pool-helper.sh refresh openai` exits non-zero when one or more eligible accounts fail to refresh, so systemd marks `aidevops-token-refresh.service` failed.
- Failed refresh output uses sanitized labels such as `http_401`, `auth_invalid_grant`, or `network`, never token values or raw response bodies.
- Existing rotate/status/check behaviours are unchanged unless tests show they already rely on the incorrect silent-success refresh contract.

## Verification

Run targeted tests first, then the relevant shell lint subset:

```bash
python3 -m unittest .agents.scripts.oauth-pool-lib.tests.test_pool_ops
.agents/scripts/tests/test-oauth-pre-dispatch-rotation.sh
.agents/scripts/tests/test-oauth-xdg-aware-path.sh
shellcheck .agents/scripts/oauth-pool-helper.sh .agents/scripts/oauth-pool-manage.sh
```

If `python3 -m unittest` cannot import the dashed directory path directly, run the existing test file by path and record the exact command used.
