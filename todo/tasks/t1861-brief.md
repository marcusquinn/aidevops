---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1861: simplification: reduce function complexity in email_jmap_adapter.py

## Origin

- **Created:** 2026-04-03
- **Session:** opencode:qlty-maintainability-recovery
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability grade dropped from A to C. `email_jmap_adapter.py` has total complexity 206 with the worst function `cmd_index_sync` at complexity 57. Also has deeply nested control flow (level 5+).

## What

Reduce function complexity in `.agents/scripts/email_jmap_adapter.py` (1698 lines) from 206 total (worst: `cmd_index_sync` at 57) to under 80 total, with no function exceeding complexity 12. Eliminate all deeply nested control flow (level 5+).

## Why

- `cmd_index_sync` at complexity 57 is the second-worst Python function in the codebase
- Deeply nested control flow (5+ levels) makes the code fragile and hard to maintain
- Total 206 complexity from a JMAP adapter suggests mixed concerns (protocol handling + business logic + error handling)
- Part of the email system (Phase 1) — a core capability

## How (Approach)

### Phase 1: Audit hot functions
1. Run `qlty smells .agents/scripts/email_jmap_adapter.py --sarif` to identify all high-complexity functions
2. Map `cmd_index_sync` control flow — likely handles: fetch changes, diff against local index, update records, handle conflicts, report progress

### Phase 2: Decompose `cmd_index_sync` (complexity 57)
1. **Extract JMAP protocol operations** into helpers: `jmap_fetch_changes()`, `jmap_get_emails()`, `jmap_update_state()`
2. **Extract index operations**: `index_upsert()`, `index_delete()`, `index_diff()`
3. **Extract conflict resolution**: `resolve_sync_conflicts()`
4. **Flatten nested error handling**: replace `try/except` nesting with structured error returns or a result monad pattern
5. **Replace deep nesting** with early returns and guard clauses

### Phase 3: Decompose remaining high-complexity functions
- Apply same patterns: extract protocol layer, extract business logic, flatten nesting
- Functions with many parameters (e.g., `email_to_markdown` with 9 params) → use a dataclass or dict for grouped params

### Phase 4: Structural improvements
- Extract JMAP request/response helpers into a `JmapClient` class or module
- Group related functions (sync, search, send, folders) into clearly commented sections
- Consider splitting into `jmap_client.py` + `jmap_commands.py` if natural seams exist

## Acceptance Criteria

- [ ] `cmd_index_sync` complexity drops below 12 (from 57)
  ```yaml
  verify:
    method: bash
    run: "cd /Users/marcusquinn/Git/aidevops && ~/.qlty/bin/qlty smells .agents/scripts/email_jmap_adapter.py --sarif 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); results=d.get('runs',[])[0].get('results',[]); high=[r for r in results if 'high complexity' in r.get('message',{}).get('text','').lower()]; sys.exit(0 if not high else 1)\""
  ```
- [ ] Total file complexity below 80 (from 206)
- [ ] No function exceeds complexity 12
- [ ] Zero "deeply nested control flow" smells
- [ ] `email_to_markdown` parameter count reduced (group into config object or dataclass)
- [ ] All JMAP commands still work (index-sync, search, send, folders)
  ```yaml
  verify:
    method: bash
    run: "python3 .agents/scripts/email_jmap_adapter.py --help 2>&1 | grep -c 'usage\\|command' || true"
  ```
- [ ] No new Python linting warnings

## Context & Decisions

- This is a pure refactoring task — no feature changes
- The JMAP adapter is used by the email system (Phase 1) — changes must not break email operations
- The 9-parameter `email_to_markdown` function is a known smell — a `EmailRenderConfig` dataclass is the standard fix
- Deeply nested control flow is the most fragile smell type — prioritise flattening over other optimisations

## Relevant Files

- `.agents/scripts/email_jmap_adapter.py:1` — target file (1698 lines, complexity 206)
- `.agents/scripts/email-mailbox-helper.sh` — shell wrapper that invokes this adapter
- `.agents/scripts/email-summary.py` — may depend on output format
- `.agents/scripts/normalise-markdown.py` — may be called by this adapter

## Dependencies

- **Blocked by:** nothing
- **Blocks:** overall qlty A-grade recovery
- **External:** none (JMAP is a protocol adapter; tests can use mocked responses)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | Audit all hot functions, map sync flow |
| Implementation | 3h | Decompose cmd_index_sync + other hot functions |
| Testing | 40m | Qlty before/after, test JMAP commands |
| **Total** | **~4h** | |
