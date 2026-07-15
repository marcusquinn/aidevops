<!-- aidevops:brief-schema=v2 -->

# t18132: Prevent cross-install upstream-watch duplicate issues

## Pre-flight

- [x] Memory recall: `upstream-watch cross-install duplicate issue designated publisher closed history dedup auto-dispatch` → 0 hits — no relevant lessons
- [x] Discovery pass: 0 commits since 2026-07-13 / 0 open PRs / 0 open issues touch or duplicate the target behavior; merged PR #22502 only gates non-collaborators and coalesces same-run batches
- [x] File refs verified: 3 target refs checked, all present at HEAD
- [x] Tier: `tier:standard` — three coordinated shell/test surfaces, shared-history fallback behavior, and race/idempotency handling disqualify simple
- [x] Seeded draft PR decision recorded: skipped — the issue has a verified approach, but implementation belongs to the auto-dispatched worker

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive session investigating #27805
- **Created by:** AI DevOps (ai-interactive), at the user's request
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** Issues #27805-#27807 were created by one authorized collaborator installation after the same upstream values had already been reviewed and acknowledged by another installation. The owner's pre-dispatch validator then closed them, producing avoidable notifications and duplicate review setup.

## What

Prevent separate authorized aidevops installations from creating public upstream-watch issues for an upstream value that the repository has already handled. Restrict public publication to the repository owner or an explicit designated-publisher override, and use a deterministic per-value identity plus closed-history lookup so owner installations also deduplicate across machines and runs.

## Why

Upstream-watch acknowledgement state lives in each installation's `~/.aidevops/cache/upstream-watch-state.json`. A fresh collaborator cache therefore reports `Previous: none` even when the framework repository already reviewed that exact value. The existing permission gate accepts `write`, `maintain`, and `admin`, while issue deduplication searches only open issues. This generated #27805-#27807 after the same Cloudron values had already been reviewed in PR #23946.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The implementation coordinates publisher authorization, stable update identities, open/closed GitHub history, batch filtering, and shell mocks. Existing functions are large enough that helper extraction is required rather than inline growth.

## PR Conventions

This is a leaf task. The implementation PR should use `Resolves #<issue-number>`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The worker-ready issue records the verified failure and implementation constraints; pre-seeding code would create unnecessary ownership overlap with auto-dispatch.
- **Status:** `not-created`
- **Freshness evidence:** Memory, issue/PR collision discovery, source line verification, and recent target-file history were checked against HEAD on 2026-07-15.
- **Verification run:** Brief readiness only; implementation tests are unrun.
- **Stale-assumption warning:** Re-check for an open PR touching the target files and confirm current GitHub search/wrapper behavior before editing.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/upstream-watch-helper-issues.sh:69-106` — narrow public publication authorization from any write-capable collaborator to the repository owner or an explicit trusted designated-publisher override.
- `EDIT: .agents/scripts/upstream-watch-helper-issues.sh:134-159,265-298,301-482` — add a deterministic full-value update key, filter already-handled items before individual/batch publication, and query open plus closed repository history before creating an issue.
- `EDIT: .agents/scripts/tests/test-upstream-watch-issue-gate.sh:1-174` — cover owner/non-owner publication, explicit override, open/closed exact-value deduplication, changed-value publication, and batch filtering.

### Complete Write Surface

- **Callers/readers:** `_check_single_github_repo()` and `_check_non_github_upstreams()` in `.agents/scripts/upstream-watch-helper-check.sh:307-388,404-500` queue updates; `_flush_upstream_update_issue_queue()` and `_file_upstream_update_issue()` consume them.
- **Writers/mutation paths:** `_file_upstream_update_issue()` and `_file_upstream_batch_update_issue()` are the only public issue writers in `.agents/scripts/upstream-watch-helper-issues.sh`; `_write_upstream_watch_local_report()` remains the non-publisher fallback.
- **Tests/fixtures:** `.agents/scripts/tests/test-upstream-watch-issue-gate.sh` mocks `gh`, `gh_create_issue`, list/search output, permissions, and report writes.
- **Schemas/config:** `.agents/scripts/upstream-watch-helper-issues.sh` defines the generated issue-body markers; add the deterministic key there as a backward-compatible marker and retain the legacy slug marker for validators. No persistent state schema changes.
- **Generated/deployed mirrors:** Source changes deploy through `setup.sh`; do not edit `~/.aidevops/agents/` directly.
- **Migrations/backfills:** Historical records are GitHub issues rather than a local schema; `.agents/scripts/upstream-watch-helper-issues.sh` must recognize their exact normalized title/value without modifying them, including #27805-style values.
- **Cleanup/rollback paths:** Reverting `.agents/scripts/upstream-watch-helper-issues.sh` restores the old publication policy without state cleanup. On GitHub lookup failure, do not infer that history is empty; fall back to a local report or skip public creation with a warning.

### Implementation Steps

1. Add a focused helper that parses the repository owner from the verified `owner/repo` slug and authorizes public creation only when the authenticated login equals that owner. Preserve `AIDEVOPS_UPSTREAM_WATCH_ALLOW_PUBLIC_ISSUES=1` as the explicit designated-publisher override. Keep the collaborator-permission lookup only if another caller still needs it; do not allow ordinary `write`/`maintain` collaborators by default.
2. Generate a stable identity from the full upstream slug/name, kind, and untruncated new value. Render it into individual and batch issue bodies as an HTML marker while retaining human-readable titles.
3. Before issue creation, query repository issues across both states and compare exact markers. For historical unmarked issues, compare the exact normalized title containing the slug, kind, and displayed value. A handled exact value suppresses creation; a newer/different value must still publish.
4. Apply the handled-value filter to queued items before the batch threshold is calculated. Zero remaining items creates nothing; remaining items retain existing individual/coalesced behavior.
5. Treat GitHub lookup/API failure as unknown, not "no match": write a local report or skip with a warning. Ensure retries and concurrent runs are idempotent; where search-then-create cannot eliminate a race, add a post-create reconciliation path or document/test deterministic duplicate closure.
6. Extract helpers rather than extending `_file_upstream_update_issue()`, currently approximately 98 lines (`385-482`), beyond the 100-line function-complexity limit.

### Complexity Impact

- `_file_upstream_update_issue()` is already approximately 98 lines and must not grow.
- `_flush_upstream_update_issue_queue()` is approximately 28 lines and may remain an orchestrator.
- Put publisher identity, update-key generation, history lookup, and queue filtering into focused new functions, each with explicit `return 0`/`return 1` and `local var="$1"` argument capture.

### Hazards and Compatibility

- **Concurrency/atomicity:** GitHub search followed by create is not atomic. Minimize the race with deterministic keys and idempotent reconciliation; never overwrite a different upstream value.
- **Migration/rollback:** Existing issues lack the new marker, so exact-title fallback is required. Removing the change restores current behavior without state migration.
- **Mixed-version/backward compatibility:** Older installations may still create unkeyed issues. New publishers and validators must recognize both keyed and legacy titles.
- **Idempotency/retry:** Repeated checks for the same full value must create at most one durable tracker. API uncertainty must not fail open into public issue creation.
- **Partial failure/recovery:** Authentication, history-search, local-report, and issue-write failures must produce explicit diagnostics; failed history lookup must stop public creation, while a failed local report remains retryable on the next 0-to-1 transition or explicit check.
- **Preserved behavior:** Non-publishers still receive local reports; the designated publisher still creates new-value issues; existing open same-slug issues may still be updated only when the new identity proves the upstream advanced.

### Verification Before Dispatch

- **Surface mapping:** The focused test covers publisher authorization, individual/history deduplication, and queue/batch filtering; ShellCheck and `bash -n` cover both modified scripts; changed-file lint covers repository integration and complexity gates.

```bash
bash .agents/scripts/tests/test-upstream-watch-issue-gate.sh
```

Validates publisher authorization, local-report fallback, exact-value history deduplication, changed-value publication, and batch behavior.

```bash
shellcheck .agents/scripts/upstream-watch-helper-issues.sh .agents/scripts/tests/test-upstream-watch-issue-gate.sh
bash -n .agents/scripts/upstream-watch-helper-issues.sh .agents/scripts/tests/test-upstream-watch-issue-gate.sh
```

Validates shell style, explicit returns, argument capture, and syntax on every modified script.

```bash
.agents/scripts/linters-local.sh --changed
```

Runs the repository's changed-file gates because the issue-publication helper is shared framework infrastructure.

## Acceptance Criteria

- [ ] A collaborator with `write` or `maintain` permission who is not the repository owner cannot create public upstream-watch issues by default and receives a local report instead.
- [ ] The repository owner and an explicitly enabled designated publisher can still publish a genuinely new upstream value.
- [ ] An exact upstream value already present in open or closed issue history is not recreated, including historical issues without the new marker.
- [ ] A different/newer value for the same upstream is not suppressed by the historical-value dedupe.
- [ ] Batch thresholding happens after handled values are removed, and an entirely handled batch creates no issue.
- [ ] GitHub history lookup failure does not fail open into public issue creation.
- [ ] Focused tests, ShellCheck, syntax checks, and changed-file repository lint pass.

## Context and Decisions

- #27805's false-premise closure was correct because `cloudron/base:5.0.0` was already acknowledged and documented, but its creation exposed cross-install local-state divergence.
- #27805-#27807 were authored by a separate authorized collaborator installation and closed minutes later by the owner's validator.
- PR #22502 solved non-collaborator issue spam and same-run batch coalescing, but intentionally allows `write`/`maintain` collaborators and checks only open issues.
- Local cache remains useful for local pending status but must not be treated as the repository-wide acknowledgement ledger.
- Do not introduce a committed per-release state file: that would require a code PR for every "reviewed, no adoption needed" acknowledgement. GitHub issue history is the shared operational ledger.
