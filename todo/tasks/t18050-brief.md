<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18050: Reach capture workflow into `_inbox/` and `_knowledge/`

## Pre-flight

- [x] Memory recall: `aidevops reach capture inbox knowledge workflow` → 0 hits — no relevant prior lesson found.
- [x] Discovery pass: no t18050 brief/open related PR found; `_inbox` and `_knowledge` helpers/docs are present.
- [x] File refs verified: `.agents/scripts/inbox-helper.sh`, `.agents/templates/inbox-readme.md`, `.agents/aidevops/knowledge-plane.md`, and t18047-t18049 targets are present or declared blockers.
- [x] Tier: `tier:standard` — capture command, metadata schema, privacy boundaries, and tests.
- [x] Seeded draft PR decision recorded: skipped — depends on route/profile/failover base tasks.

## Origin

- **Created:** 2026-07-01
- **Session:** OpenCode interactive reach/capture planning
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** t18047, t18048, t18049
- **Conversation context:** Reach needs a uniform artifact path so web/app evidence is recoverable, dedupable, and reviewable before durable promotion.

## What

Add `reach capture` as the first execution path. It captures public/static or locally provided content into `_inbox/web/` by default, appends sanitized audit metadata to `_inbox/triage.log`, and stages reviewed content toward `_knowledge/` without bypassing trust/sensitivity gates.

## Why

Captures currently scatter across transcripts, screenshots, traces, and ad-hoc files. A consistent transit artifact enables review, provenance, and later performance/feedback loops.

## Tier

**Selected tier:** `tier:standard` — filesystem workflow and metadata tests.

## PR Conventions

Leaf task. Worker PR should resolve this task's own issue only.

## How

### Progressive Context Plan

- **Read first:** `.agents/scripts/inbox-helper.sh:14-31` and `:43-76` — inbox commands/folders/constants.
- **Read first:** `.agents/templates/inbox-readme.md:24-47` — append-only triage log and unverified sensitivity.
- **Read first:** `.agents/aidevops/knowledge-plane.md:25-75` — knowledge directory and metadata contract.
- **Read first:** reach docs/helper from t18047-t18049.
- **Stop when:** `reach capture` can create local fixture captures and append audit records without requiring network in tests.

### Files to Modify

- `EDIT: .agents/scripts/reach-helper.sh` — add `capture` command and metadata writer.
- `EDIT: .agents/templates/inbox-readme.md` — document `reach-capture` source and metadata fields.
- `EDIT: .agents/aidevops/knowledge-plane.md` — document reach-captured sources entering knowledge via inbox/staging.
- `NEW: .agents/scripts/tests/test-reach-capture.sh` — local fixture tests.

### Implementation Steps

1. Add `reach capture --input <url-or-file> --dest inbox|knowledge-inbox --method auto|file|fetch|crawl|browser --format json`.
2. Support local HTML/text file input for deterministic tests; URL capture may use the route-selected backend but tests must not require external network.
3. Write `_inbox/web/<safe-slug>_<timestamp>.html|.md|.meta.json` as appropriate. Metadata fields: `schema_version`, `captured_at`, `source_ref`, `source_hash`, `method`, `backend`, `route_decision`, `profile_label`, `proxy_class`, `failure_class`, `sensitivity`, `trust`, `sha256`, `bytes`, `artifact_paths`, and `review_required`.
4. Append `_inbox/triage.log` with `source:"reach-capture"`, sub-folder, artifact meta path, method/backend, provenance hash, `status:"pending"`, `sensitivity:"unverified"`, and `trust:"unverified"`.
5. Knowledge staging must write only to `_knowledge/inbox/` or staging with unverified trust unless a separate review path promotes it.
6. Never store cookies, authorization headers, proxy credentials, raw private URLs, private paths, or sensitive screenshots in repo artifacts.

### Verification

```bash
shellcheck .agents/scripts/reach-helper.sh .agents/scripts/tests/test-reach-capture.sh
.agents/scripts/tests/test-reach-capture.sh
./aidevops.sh reach capture --input .agents/templates/inbox-readme.md --dest inbox --method file --format json
```

### Files Scope

- `.agents/scripts/reach-helper.sh`
- `.agents/templates/inbox-readme.md`
- `.agents/aidevops/knowledge-plane.md`
- `.agents/scripts/tests/test-reach-capture.sh`

## Acceptance Criteria

- [ ] `reach capture --dest inbox` writes web capture artifacts and metadata.
- [ ] `_inbox/triage.log` receives append-only reach-capture entries.
- [ ] Captures default to `sensitivity:"unverified"` and `trust:"unverified"`.
- [ ] Knowledge staging does not bypass review/trust policy.
- [ ] Tests prove local fixture capture, audit append, metadata shape, and output sanitization.

## Dependencies

- **Blocked by:** t18047, t18048, t18049.
- **Blocks:** t18051 and capture portions of t18052.
