<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18518: Keywords read DATAFORSEO_API_LOGIN/API_PASSWORD from gopass

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (follow-up to t18517)
- **Conversation context:** The operator's gopass `DATAFORSEO_PASSWORD` held the dashboard password, which the API rejects (401). The API password was saved as `DATAFORSEO_API_LOGIN` + `DATAFORSEO_API_PASSWORD`; the free `user_data` endpoint returned 200 with that pair.

## What

The gopass fallback in `keywords-helper.sh` prefers `DATAFORSEO_API_LOGIN` + `DATAFORSEO_API_PASSWORD` and falls back to legacy `DATAFORSEO_USERNAME` + `DATAFORSEO_PASSWORD`.

## Why

DataForSEO issues a separate API password. Explicit `API_*` names stop the account login password from being used by mistake, which would make the paid routine fail with 401 while still logging budget estimates.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/keywords-helper.sh` — `_kw_load_credentials` reads the `API_*` pair first.
- `EDIT: .agents/seo/keywords-standard.md` — credentials line names the `API_*` secrets.

### Reference pattern

t18517 gopass fallback in the same function.

### Files Scope

- .agents/scripts/keywords-helper.sh
- .agents/seo/keywords-standard.md
- todo/tasks/t18518-brief.md

## Verification

```bash
shellcheck .agents/scripts/keywords-helper.sh
bash .agents/scripts/tests/test-keywords-helper.sh
```

## Acceptance Criteria

- [ ] With only `API_*` names in gopass, the DataForSEO tracker receives them.
- [ ] Legacy names still work when `API_*` names are absent.
- [ ] Values never appear in output.
