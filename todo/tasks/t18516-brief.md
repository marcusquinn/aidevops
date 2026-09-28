<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18516: Keywords hub clone from canonical cwd; exported env overrides config

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (follow-up found while configuring the t18509 team hub)
- **Conversation context:** After `aidevops keywords hub set <owner/repo>`, the first `routine-run` from a canonical checkout failed, and a test run pushed fixture data to the real hub.

## What

Keyword hub cloning works from any working directory, and exported `AIDEVOPS_KEYWORDS_*` values override local config.

## Why

1. `keywords_hub.ensure_hub` ran `gh repo clone` / `git clone` with the caller's cwd. When that cwd is a canonical checkout (a Pulse routine or an interactive session), the canonical Git guard blocks the clone (exit 42).
2. `keywords-helper.sh` `_kw_export_env` always read local config, ignoring exported values. With a hub configured, `tests/test-keywords-helper.sh` cloned the real hub and pushed `example__widget` fixture commits to it (cleaned up manually).
3. `aidevops keywords issues --apply` filed auto-dispatch issues without a canonical `### Files Scope`, so Pulse would hold every backfill issue as `status:blocked (missing_files_scope)`. The body now lists bare paths; `pre-dispatch-validator-helper.sh scope-check` returns 0 (was 40).

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/keywords_hub.py` — `ensure_hub` clones with `cwd=path.parent`.
- `EDIT: .agents/scripts/keywords-helper.sh` — new `_kw_env_or_config`: an exported variable (even empty) wins over `config-helper.sh get`.
- `EDIT: .agents/scripts/tests/test-keywords-helper.sh` — export `JSONC_USER` to a scratch path so the operator config is never read.

### Reference pattern

`config-helper.sh` already honours `JSONC_USER` for the user config path.

### Files Scope

- .agents/scripts/keywords_hub.py
- .agents/scripts/keywords-helper.sh
- .agents/scripts/tests/test-keywords-helper.sh
- todo/tasks/t18516-brief.md

## Verification

```bash
bash .agents/scripts/tests/test-keywords-helper.sh   # with a real hub configured: 36/36, no remote commits
AIDEVOPS_KEYWORDS_STORE_DIR=<scratch> .agents/scripts/keywords-helper.sh routine-run   # run from a canonical checkout
```

## Acceptance Criteria

- [ ] `routine-run` from a canonical checkout clones the hub without a guard block.
- [ ] The test suite passes with a hub configured and pushes nothing to it.
- [ ] Exported empty `AIDEVOPS_KEYWORDS_HUB_SLUG` disables the configured hub.
- [ ] The backfill issue body passes `pre-dispatch-validator-helper.sh scope-check <n> <body> 1`.
