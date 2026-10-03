<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18519: DataForSEO subagent credential and connection guidance

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive
- **Parent task:** none (lessons from t18517/t18518)
- **Conversation context:** Setting up budgeted DataForSEO rank tracking showed that the subagent recommended plaintext `credentials.sh`, did not distinguish the API password from the account password (HTTP 401), offered no free connection check, and referenced a non-existent `.agents/configs` path.

## What

`.agents/seo/dataforseo.md` documents gopass storage (`DATAFORSEO_API_LOGIN`/`DATAFORSEO_API_PASSWORD`), the API-vs-account password distinction, a verified zero-cost `user_data` connection check via `aidevops secret ... --`, per-consumer credential sources, spend guidance pointing to the keywords budget, and the correct repo `configs/` path.

## How (Approach)

### Files to Modify

- `EDIT: .agents/seo/dataforseo.md`

### Reference pattern

`reference/secret-handling.md` (inject secrets per command; never paste values).

### Files Scope

- .agents/seo/dataforseo.md
- todo/tasks/t18519-brief.md
- todo/tasks/t18520-brief.md

## Verification

```bash
aidevops secret DATAFORSEO_API_LOGIN DATAFORSEO_API_PASSWORD -- bash -c 'curl -s -u "$DATAFORSEO_API_LOGIN:$DATAFORSEO_API_PASSWORD" https://api.dataforseo.com/v3/appendix/user_data | jq "{status_code, cost}"'
.agents/scripts/linters-local.sh --changed
```

## Acceptance Criteria

- [ ] The documented connection check returns `status_code: 20000` and `cost: 0`.
- [ ] The credential-source table matches current code.
- [ ] Changed-file lint passes.
