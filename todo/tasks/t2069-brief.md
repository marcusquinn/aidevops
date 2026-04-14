<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2069: Decompose `.agents/scripts/oauth-pool-lib/pool_ops.py` (8 qlty smells)

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** Third-highest smell file in the repo after the two email_imap_adapter files. `pool_ops.py` carries 8 smells including `cmd_refresh` at cyclomatic **72**, `cmd_rotate` at 31, `cmd_fetch_body` at 31 (typo — may be `cmd_mark_failure`), and several return-statement/boolean-logic smells. Decomposing this file gets us ~7–8% closer to A.

## What

Split `.agents/scripts/oauth-pool-lib/pool_ops.py` into per-command modules so that each `cmd_*` function becomes a focused module with its own helpers. After this change, `qlty smells` reports zero smells on any file matching `oauth-pool-lib/**`.

Preserve the public callsite: `from oauth_pool_lib.pool_ops import cmd_refresh, cmd_rotate, ...` continues to work via a thin `pool_ops.py` facade that re-exports from the new per-command modules.

## Why

- `cmd_refresh` at cyclomatic 72 is the single-highest-complexity function in the entire repo. Any bug in token refresh is effectively unreviewable because humans can't hold 72 branches in their head.
- The OAuth pool is security-adjacent (credential rotation, account cooldowns) — code quality here matters disproportionately. A refactor that makes the flow inspectable is worth more than its smell-reduction count.
- 8 smells on one file is the third-highest density in the repo; unlocking this file lifts us roughly 7–8% of the way toward A.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Refactoring a 72-complexity OAuth function requires understanding the full token-refresh state machine, provider-specific fallback logic, and error paths. Sonnet will miss edge cases; Haiku can't even read the file. Opus-tier.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Baseline smell count and function complexities
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq -r '.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("oauth-pool-lib/pool_ops")) | "\(.ruleId)\t\(.message.text)\t\(.locations[0].physicalLocation.region.startLine)"'
# Expected output:
#   qlty:function-complexity  cmd_auto_clear (19)           121
#   qlty:function-complexity  cmd_rotate (31)               236
#   qlty:function-complexity  cmd_refresh (72)              366
#   qlty:function-complexity  cmd_mark_failure (23)         500
#   + 4 more smells (file-complexity, return-statements, etc.)

# 2. Callers of pool_ops
rg "from oauth_pool_lib.pool_ops import|pool_ops\." .agents/ --type py --type sh

# 3. Existing test coverage
ls .agents/scripts/oauth-pool-lib/tests/ 2>/dev/null || ls .agents/scripts/tests/ | grep -i oauth
```

### Files to Modify

- `EDIT: .agents/scripts/oauth-pool-lib/pool_ops.py` — becomes a facade
- `NEW: .agents/scripts/oauth-pool-lib/pool_ops_refresh.py` — hosts `cmd_refresh` + helpers
- `NEW: .agents/scripts/oauth-pool-lib/pool_ops_rotate.py` — hosts `cmd_rotate` + helpers
- `NEW: .agents/scripts/oauth-pool-lib/pool_ops_mark_failure.py` — hosts `cmd_mark_failure` + helpers
- `NEW: .agents/scripts/oauth-pool-lib/pool_ops_auto_clear.py` — hosts `cmd_auto_clear`
- `NEW: .agents/scripts/oauth-pool-lib/_refresh_strategies.py` — the provider-specific refresh strategies extracted from `cmd_refresh` (the 72-complexity function is 72 because it dispatches across provider types; extract each provider strategy into a function)
- `EDIT: any caller` — imports continue to resolve through the facade (no caller changes needed if facade is correct)
- `EDIT/NEW: .agents/scripts/tests/test-oauth-pool-*.sh` or equivalent — tests covering refresh, rotate, mark-failure paths

### Implementation Steps

1. **Inventory `cmd_refresh`.** Before any restructure: read the full 134-line function, identify each branch. Likely branches: (anthropic|openai|cursor|google) × (refresh_token|device_code|api_key) × (success|expired|revoked|transient_error). Catalog them.

2. **Extract per-provider refresh strategies** into `_refresh_strategies.py`:

   ```python
   def refresh_anthropic(account, store): ...
   def refresh_openai(account, store): ...
   def refresh_cursor(account, store): ...
   def refresh_google(account, store): ...

   REFRESH_STRATEGIES = {
       "anthropic": refresh_anthropic,
       "openai": refresh_openai,
       "cursor": refresh_cursor,
       "google": refresh_google,
   }
   ```

3. **Rewrite `cmd_refresh`** in the new `pool_ops_refresh.py` as a thin dispatcher:

   ```python
   def cmd_refresh(provider, account_id, ...):
       strategy = REFRESH_STRATEGIES.get(provider)
       if strategy is None:
           return error(f"unknown provider: {provider}")
       try:
           return strategy(account, store)
       except TransientError as e:
           return retry_with_backoff(...)
   ```

   Target cyclomatic ≤ 10 for the dispatcher. Each strategy function should be ≤ 15.

4. **Apply the same pattern to `cmd_rotate`, `cmd_mark_failure`, `cmd_auto_clear`** — likely all have the same "dispatch by provider" shape.

5. **Facade `pool_ops.py`:**

   ```python
   """Backwards-compatible re-exports. New code should import from submodules."""
   from .pool_ops_refresh import cmd_refresh
   from .pool_ops_rotate import cmd_rotate
   from .pool_ops_mark_failure import cmd_mark_failure
   from .pool_ops_auto_clear import cmd_auto_clear
   __all__ = ["cmd_refresh", "cmd_rotate", "cmd_mark_failure", "cmd_auto_clear"]
   ```

6. **Tests.** Before any split: pin behaviour with a characterisation test for each `cmd_*` covering happy path + one error path per provider. Run the test against the pre-refactor code to ensure it passes; then refactor; then re-run.

### Verification

```bash
# Zero smells on oauth-pool-lib/
~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null \
  | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test("oauth-pool-lib"))] | length'
# Expected: 0 or ≤2 residual

# Callers still resolve
python3 -c "from oauth_pool_lib.pool_ops import cmd_refresh, cmd_rotate; print('ok')"

# Tests pass
.agents/scripts/tests/test-oauth-pool-*.sh
```

## Acceptance Criteria

- [ ] `qlty smells` reports **zero** smells on files matching `oauth-pool-lib/**`
  ```yaml
  verify:
    method: bash
    run: "test 0 -eq \"$(~/.qlty/bin/qlty smells --all --sarif --no-snippets --quiet 2>/dev/null | jq '[.runs[0].results[] | select(.locations[0].physicalLocation.artifactLocation.uri | test(\"oauth-pool-lib\"))] | length')\""
  ```
- [ ] `cmd_refresh` cyclomatic drops from 72 to ≤10 (dispatcher only)
- [ ] Backwards-compatible imports from `oauth_pool_lib.pool_ops` continue to work (facade in place)
- [ ] Characterisation tests added and passing for refresh/rotate/mark_failure/auto_clear
- [ ] Repo-wide total smell count drops by at least 6
- [ ] `python3 -m py_compile .agents/scripts/oauth-pool-lib/*.py` succeeds

## Context & Decisions

- **Why per-command files rather than per-provider?** The public surface is `cmd_*` commands. Keeping the per-command boundary preserves the CLI mental model. Provider-specific strategies are internal helpers one layer down.
- **Don't attempt to rewrite the OAuth state machine.** This is a refactor, not a redesign. Preserve behaviour byte-for-byte on observable outcomes.
- **Security sensitivity:** credential rotation bugs can lock all accounts. Characterisation tests are **mandatory before any line of production code moves**.

## Relevant Files

- `.agents/scripts/oauth-pool-lib/pool_ops.py` — primary target
- `.agents/scripts/oauth-pool-lib/pool_store.py` (if exists) — state storage; read to understand the data model before refactoring
- `.agents/scripts/oauth-pool-helper.sh` — likely CLI wrapper that calls `cmd_*`; verify it doesn't break

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none (no credentials needed for the refactor; tests should use mock responses)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Full file + callers + existing tests |
| Characterisation tests | 1.5h | Pin behaviour before refactor |
| Implementation | 3h | Split + facade |
| Testing | 1h | Re-run + smoke |
| **Total** | **~6.5h** | |
