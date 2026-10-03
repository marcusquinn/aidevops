<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18517: Keywords DataForSEO credentials fall back to gopass

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (follow-up to t18509 / t18516 rollout)
- **Conversation context:** The operator enabled DataForSEO for the monthly paid keyword routine and asked that credentials live in `aidevops secret` (gopass).

## What

`keywords-helper.sh` loads `DATAFORSEO_USERNAME` / `DATAFORSEO_PASSWORD` from the environment, then `credentials.sh`, then gopass `aidevops/DATAFORSEO_*`.

## Why

Pulse runs `scripts/keywords-helper.sh routine-run --paid` directly. gopass secrets reach scripts only through `aidevops secret run`, so the paid routine never saw credentials stored with `aidevops secret set` and silently skipped DataForSEO.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/keywords-helper.sh` — `_kw_load_credentials` gopass fallback.
- `EDIT: .agents/seo/keywords-standard.md` — credentials line in Quick Reference.

### Reference pattern

`manyreach-helper.sh` and `virustotal-helper.sh` use `gopass show -o "aidevops/<NAME>"` with an error-suppressed fallback.

### Files Scope

- .agents/scripts/keywords-helper.sh
- .agents/seo/keywords-standard.md
- todo/tasks/t18517-brief.md

## Verification

```bash
shellcheck .agents/scripts/keywords-helper.sh
bash .agents/scripts/tests/test-keywords-helper.sh
aidevops keywords budget   # after `aidevops secret set DATAFORSEO_USERNAME|PASSWORD`
```

## Acceptance Criteria

- [ ] With credentials only in gopass, `routine-run --paid` exports them to the Python tracker.
- [ ] Values never appear in output or logs.
- [ ] Test suite passes.
