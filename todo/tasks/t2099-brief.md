# t2099: auto-apply `good first issue` label to `tier:simple` issues

## Origin

- **Created:** 2026-04-14
- **Session:** claude:interactive
- **Created by:** ai-interactive
- **Conversation context:** User asked to have every issue tagged `tier:simple` also carry GitHub's community `good first issue` label, then full-loop through to merge.

## What

When `_apply_tier_label_replace` in `issue-sync-helper.sh` applies `tier:simple` to an issue, it must also add the `good first issue` label (creating the label first if it does not exist on the target repo). The label is ONLY added on `tier:simple` — it is never auto-removed when a task later escalates to `tier:standard`/`tier:thinking`, because `good first issue` is already in the `_is_protected_label` set and may have been added by a human.

After shipping, backfill all currently-open `tier:simple` issues across `pulse: true` repos so the label applies retroactively.

## Why

`tier:simple` issues are, by definition, prescriptive single-file pattern-follows with verbatim code blocks — the exact shape of a community-friendly first contribution. Surfacing them via GitHub's standard `good first issue` label exposes them to the built-in GitHub "good first issues" filter and third-party discovery sites (goodfirstissue.dev, up-for-grabs, code-triage). We already produce this pool mechanically; we just were not labelling it for external discovery.

## Tier

### Tier checklist

- [x] 2 or fewer files to modify? (issue-sync-helper.sh + test file; AGENTS.md pointer is a 1-line doc touch)
- [x] Complete code blocks for every edit?
- [x] No judgment or design decisions?
- [x] No error handling or fallback logic to design?
- [x] Estimate 1h or less?
- [x] 4 or fewer acceptance criteria?

**Selected tier:** `tier:simple`

**Tier rationale:** Single-function append in one helper, one test assertion block, one doc pointer. Verbatim code blocks below.

## How

### Files to modify

- EDIT: `.agents/scripts/issue-sync-helper.sh` — extend `_apply_tier_label_replace` to also add `good first issue` when the new tier is `tier:simple`.
- EDIT: `.agents/scripts/tests/test-issue-sync-tier-extraction.sh` — add assertion that applying `tier:simple` triggers `--add-label good first issue`.
- EDIT: `.agents/AGENTS.md` — one-line note on the `tier:simple` bullet that `good first issue` is auto-applied.

### Reference pattern

Model on the existing `_apply_tier_label_replace` flow (`.agents/scripts/issue-sync-helper.sh:132-168`). The final `gh issue edit … --add-label "$new_tier"` line is the extension point — append the `good first issue` ensure-and-add step immediately after, gated on `[[ "$new_tier" == "tier:simple" ]]`.

Use `gh_create_label` (already defined at `.agents/scripts/issue-sync-helper.sh:255-258`) to ensure the label exists before adding it — it is idempotent via `--force`.

### Verification

```bash
shellcheck .agents/scripts/issue-sync-helper.sh
.agents/scripts/tests/test-issue-sync-tier-extraction.sh
```

All existing tier-extraction tests must continue to pass; a new assertion must pass proving `good first issue` is added on `tier:simple`.

## Acceptance Criteria

- [ ] `_apply_tier_label_replace` adds `good first issue` when (and only when) `new_tier == tier:simple`
- [ ] Label is ensured to exist via `gh_create_label` before `--add-label`
- [ ] Test `test-issue-sync-tier-extraction.sh` asserts the new behaviour and all prior tests pass
- [ ] PR merged (closes #19007) and existing open `tier:simple` issues backfilled across pulse repos

## Context

- `_is_protected_label` already protects `good first issue` from tag-derived reconciliation, so the label survives once applied.
- `gh_create_label` uses `--force` and silently succeeds if the label already exists.
- No removal on escalation: keeps logic simple and avoids fighting human intent.
