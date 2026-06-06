---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t3593: Route collaborator permission checks through GitHub App-aware auth

## Pre-flight

- [x] Memory recall: `review issue PR worker-ready brief GitHub issue #24494 collaborator permission API failure` → 0 hits — no relevant lessons found.
- [x] Discovery pass: 0 commits / 0 merged PRs / 0 open PRs touch target files in prework discovery output for `GH#24494 collaborator permission GitHub App auth rate limit failure semantics`.
- [x] File refs verified: 12 direct collaborator-permission probes and 2 reference helpers verified at HEAD with exact search.
- [x] Tier: `tier:standard` — touches trust gates and fallback/error semantics across multiple shell helpers, but follows existing GitHub App REST wrapper patterns.
- [x] Seeded draft PR decision recorded: skipped — this is a worker-ready implementation task, and no current-session code changes should anchor the worker to an unverified partial fix.

## Origin

- **Created:** 2026-06-06
- **Session:** OpenCode interactive review of GH#24494
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** GH#24494 reported that collaborator permission probes use direct `gh api` calls and can classify collaborators as external when the caller's personal token is rate-limited. Review accepted the issue as real but narrowed the fix to existing GitHub App-aware read routing plus explicit API-failure semantics.

## What

Make collaborator-permission read probes use the existing GitHub App-aware REST routing layer where available, while preserving a clear distinction between:

- confirmed collaborator / owner/member,
- confirmed non-collaborator or insufficient permission, and
- permission API failure such as 403, 429, 5xx, timeout, or network failure.

The primary user-visible behaviour change is that pulse merge/approval paths must stop logging or acting as though an author is "not a collaborator" when the permission API failed. They should fail closed with a distinct permission-check-failed message/comment path.

## Why

`.agents/scripts/pulse-merge-author-checks.sh:49` and related helpers bypass the GitHub App-aware REST wrapper and call `gh api` directly. In the merge path, any API failure collapses into return code `1`, and `.agents/scripts/pulse-merge.sh:216-223` logs the PR author as non-collaborator. Under rate-limit or auth failure, this blocks valid maintainer/collaborator PRs with misleading diagnostics and can stall pulse merge cycles.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** Multiple helpers and tests must be audited.
- [ ] **Every target file under 500 lines?** Several target scripts and test files exceed 500 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — implementation needs return-code/error propagation design.
- [ ] **No judgment or design decisions?** No — trust-gate failure semantics must be preserved.
- [ ] **No error handling or fallback logic to design?** No — explicit API failure versus confirmed non-collaborator is central.
- [ ] **No cross-package or cross-module changes?** No — pulse merge, NMR, quality feedback, interactive claim, and auxiliary guards are affected.
- [ ] **Estimate 1h or less?** No.
- [ ] **4 or fewer acceptance criteria?** No.
- [x] **Dispatch-path classification (t2821/t2920):** Files do not match `.agents/configs/self-hosting-files.conf` dispatch/spawn patterns; this is pulse merge/trust-gate code, not worker launch/dedup plumbing.

**Selected tier:** `tier:standard`

**Tier rationale:** Multiple shell helpers and trust gates need consistent auth routing and error propagation, but there are existing wrappers (`github_app_api_call`, `_rest_api_call`) and existing permission-failure UX (`check_permission_failure_pr()`) to model on.

## PR Conventions

Leaf task: use `Resolves #24494` in the implementation PR body.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The review produced enough implementation guidance for a worker, but no code was changed in-session. A seeded draft would risk anchoring the worker to stale assumptions about return-code design.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, prework discovery, exact grep, and targeted file reads performed against current HEAD.
- **Verification run:** `prework-discovery-helper.sh --keywords "GH#24494 collaborator permission GitHub App auth rate limit failure semantics" --files "TODO.md todo/tasks .agents/scripts/pulse-merge-author-checks.sh .agents/scripts/interactive-session-helper.sh .agents/scripts/pulse-nmr-approval.sh .agents/scripts/pulse-simplification-review.sh .agents/scripts/quality-feedback-helper.sh" --repo marcusquinn/aidevops` returned no recent commits/merged PRs/open PRs.
- **Stale-assumption warning:** Re-run the collaborator-permission exact search before editing; additional probes may have landed after this brief.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-merge-author-checks.sh:44-82`, `.agents/scripts/pulse-merge.sh:216-223`, `.agents/scripts/pulse-merge-gates.sh:538-570` — establishes the primary false-negative path and the existing permission-failure comment path.
- **Read next:** `.agents/scripts/shared-gh-wrappers-rest-fallback.sh:144-164`, `.agents/scripts/github-app-auth-helper.sh:301-337` — establishes the existing App-aware read routing pattern.
- **Load only if:** `.agents/reference/gh-command-discipline.md` and `.agents/reference/worker-discipline.md` — if changing GitHub write/comment behaviour or trust-boundary logic beyond the existing permission-failure path.
- **Why:** This task touches auto-merge trust gates. The implementation must reduce rate-limit pressure without weakening GH#17671-style collaborator/approval defences.
- **Stop when:** You have a complete list of collaborator-permission probes, a chosen return-code/status convention, and targeted tests for App-success, PAT fallback, confirmed non-collaborator, and API-failure cases.

### Worker Quick-Start

Critical current matches from HEAD:

```text
.agents/scripts/pulse-merge-author-checks.sh:47,71
.agents/scripts/interactive-session-helper.sh:149
.agents/scripts/pulse-nmr-approval.sh:811
.agents/scripts/pulse-simplification-review.sh:94
.agents/scripts/quality-feedback-helper.sh:134
.agents/scripts/pulse-triage-cache.sh:165
.agents/scripts/quality-feedback-issues-lib.sh:635
.agents/scripts/pulse-simplification-scan.sh:486
.agents/scripts/shared-repo-state-guard.sh:68
.agents/scripts/upstream-watch-helper-issues.sh:75
.agents/scripts/stats-shared.sh:142
.agents/scripts/version-manager-release.sh:261
```

Reference wrapper pattern:

```bash
# Prefer a leading /repos/... path so github_app_api_call can extract repo
# context when selecting an installation token.
github_app_api_call read rest-core gh api \
  "/repos/${repo_slug}/collaborators/${author}/permission" --jq '.permission'

# Where shared-gh-wrappers-rest-fallback.sh is already sourced, prefer:
_rest_api_call read gh api \
  "/repos/${repo_slug}/collaborators/${author}/permission" --jq '.permission'
```

Critical semantic rule: a 404/permission `none` result may mean "not collaborator"; 403, 429, 5xx, timeout, and network failures must be treated as "permission API failed" and must fail closed without claiming the author is non-collaborator.

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge-author-checks.sh:44-82` — route primary permission probes through App-aware read helpers and expose failure-vs-non-collaborator state.
- `EDIT: .agents/scripts/pulse-merge.sh:216-223` — consume the new failure state and call/log the existing permission-failure path instead of "not collaborator" when appropriate.
- `EDIT: .agents/scripts/pulse-merge-gates.sh:538-570,622-665` — preserve `check_permission_failure_pr()` behaviour and update defensive approval checks to honour the new failure state.
- `EDIT: .agents/scripts/interactive-session-helper.sh:149` — update interactive issue claim collaborator check to use App-aware read routing/fallback.
- `EDIT: .agents/scripts/pulse-nmr-approval.sh:811` — update NMR maintainer authority collaborator probe.
- `EDIT: .agents/scripts/pulse-simplification-review.sh:94` — update simplification review collaborator probe.
- `EDIT: .agents/scripts/quality-feedback-helper.sh:134` — update quality feedback collaborator probe.
- `EDIT: .agents/scripts/pulse-triage-cache.sh:165` — update triage-cache last-human-author permission probe if still present.
- `EDIT: .agents/scripts/quality-feedback-issues-lib.sh:635` — update issue feedback trust probe if still present.
- `EDIT: .agents/scripts/pulse-simplification-scan.sh:486` — update simplification scan permission probe if still present.
- `EDIT: .agents/scripts/shared-repo-state-guard.sh:68` — update repo-state collaborator guard if still present.
- `EDIT: .agents/scripts/upstream-watch-helper-issues.sh:75` — update upstream-watch collaborator probe if still present.
- `EDIT: .agents/scripts/stats-shared.sh:142` — update stats collaborator probe if still present.
- `EDIT: .agents/scripts/version-manager-release.sh:261` — update release collaborator probe if still present.
- `EDIT/NEW: .agents/scripts/tests/test-*.sh` — add/update targeted shell tests for the changed trust gates and wrappers.

### Implementation Steps

1. Re-run exact discovery before editing so the worker catches any new probes:

```bash
rg -n 'collaborators/.*/permission|collaborators/\$\{[^}]+\}/permission|/collaborators/.*/permission' .agents/scripts
```

2. Add or reuse a small helper that performs a collaborator-permission read through existing App-aware routing. Keep function bodies short and return explicitly. Suggested behaviour:

```bash
# Example shape only; adapt names to the target file's sourcing structure.
# Return codes:
#   0 = permission read succeeded and stdout contains permission string
#   1 = confirmed non-collaborator / insufficient permission where caller requested strict role
#   2 = permission API failed (403/429/5xx/timeout/network/unparseable)
_read_collaborator_permission() {
  local repo_slug="$1"
  local user="$2"
  local api_path="/repos/${repo_slug}/collaborators/${user}/permission"
  local permission=""

  # Prefer _rest_api_call when sourced; otherwise call github_app_api_call directly;
  # otherwise fall back to gh api. Do not invent a new token-selection path.
  # Capture exit code distinctly from permission value.

  printf '%s\n' "$permission"
  return 0
}
```

3. Update `_is_collaborator_author()` and `_is_owner_or_member_author()` so callers can distinguish return code `1` (confirmed not allowed) from return code `2` (API failure). Add comments documenting return codes. Avoid `if ! func; then ...` at call sites where `1` and `2` need different handling.

4. In `.agents/scripts/pulse-merge.sh:216-223`, replace the boolean-only collaborator gate with explicit result handling:

```bash
_is_collaborator_author "$pr_author" "$repo_slug"
collab_rc=$?
case "$collab_rc" in
0) ;;
1) # existing non-collaborator / crypto approval / skip logic ;;
2) # call check_permission_failure_pr or equivalent fail-closed path ;;
*) # fail closed and log unexpected return code ;;
esac
```

5. Audit defensive approval and owner/member gates that call these helpers. Any trust-boundary check that receives API-failure state must fail closed and must not auto-approve/auto-merge.

6. Update the other direct probes listed above. Where the code only needs a best-effort advisory, it may warn and continue; where it controls trust, dispatch, approval, or merge, it must fail closed on API failure.

7. Add regression tests. At minimum cover:

- App token route succeeds while the PAT-backed `gh api` route would be rate-limited.
- GitHub App unavailable falls back to normal `gh`/PAT behaviour.
- Confirmed non-collaborator/permission none remains blocked as non-collaborator.
- 403/429/5xx/network failure is not logged as confirmed non-collaborator.
- Existing GH#17671/GH#24473/t3063 trust-boundary bypass tests still pass.

### Complexity Impact

- **Target function:** `_is_collaborator_author` in `.agents/scripts/pulse-merge-author-checks.sh`
- **Current line count:** 15 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +20 to +40 lines if helper extraction is done cleanly
- **Projected post-change:** <60 lines (<60% of threshold)
- **Action required:** None for this function if helper extraction is used; avoid adding large nested API parsing blocks directly into every caller.

### Verification

```bash
.agents/scripts/tests/test-github-app-auth-helper.sh
.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh
.agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh
.agents/scripts/tests/test-pulse-merge-origin-interactive-auto-merge.sh
.agents/scripts/tests/test-interactive-session-claim.sh
.agents/scripts/tests/test-pulse-nmr-maintainer-authority.sh
.agents/scripts/tests/test-quality-feedback-trust-bar.sh
.agents/scripts/tests/test-repo-state-guard.sh
.agents/scripts/tests/test-upstream-watch-issue-gate.sh
.agents/scripts/linters-local.sh
```

### Files Scope

- `.agents/scripts/pulse-merge-author-checks.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/pulse-merge-gates.sh`
- `.agents/scripts/interactive-session-helper.sh`
- `.agents/scripts/pulse-nmr-approval.sh`
- `.agents/scripts/pulse-simplification-review.sh`
- `.agents/scripts/quality-feedback-helper.sh`
- `.agents/scripts/pulse-triage-cache.sh`
- `.agents/scripts/quality-feedback-issues-lib.sh`
- `.agents/scripts/pulse-simplification-scan.sh`
- `.agents/scripts/shared-repo-state-guard.sh`
- `.agents/scripts/upstream-watch-helper-issues.sh`
- `.agents/scripts/stats-shared.sh`
- `.agents/scripts/version-manager-release.sh`
- `.agents/scripts/tests/test-github-app-auth-helper.sh`
- `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh`
- `.agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh`
- `.agents/scripts/tests/test-pulse-merge-origin-interactive-auto-merge.sh`
- `.agents/scripts/tests/test-interactive-session-claim.sh`
- `.agents/scripts/tests/test-pulse-nmr-maintainer-authority.sh`
- `.agents/scripts/tests/test-quality-feedback-trust-bar.sh`
- `.agents/scripts/tests/test-repo-state-guard.sh`
- `.agents/scripts/tests/test-upstream-watch-issue-gate.sh`
- `.agents/scripts/tests/test-*collaborator*.sh`
- `.agents/scripts/tests/test-*permission*.sh`

## Acceptance Criteria

- [ ] Primary pulse merge author checks use GitHub App-aware REST read routing when available and preserve normal `gh` fallback when App auth is not configured.

- [ ] Permission API failure is distinguishable from confirmed non-collaborator in merge/approval trust gates.

- [ ] Direct collaborator-permission probes listed in this brief are audited and either routed through App-aware helpers or explicitly justified as safe/fallback-only.

- [ ] Trust-boundary behaviour is preserved: non-collaborators still do not receive auto-approval/auto-merge unless an existing explicit trusted path applies.

- [ ] Regression tests cover App-success, App-unavailable fallback, confirmed non-collaborator, and API-failure-not-non-collaborator cases.

- [ ] Targeted shell tests and `.agents/scripts/linters-local.sh` pass.

## Context & Decisions

- The issue is real, but the literal proposal "should use GitHub App auth" is incomplete. App auth reduces PAT rate pressure; it does not by itself fix the false-negative state collapse.
- Use the existing routing primitives: `github_app_api_call read rest-core gh api ...` or `_rest_api_call read gh api ...`. Do not add a parallel token-selection mechanism.
- Prefer leading `/repos/...` API paths so GitHub App repo extraction works when installation ID is not globally configured.
- Keep GH#24495 separate. Timeout/hanging behaviour for `gh api` is related operationally but is not the collaborator-permission auth/failure-semantics fix.
- Any auto-approval/merge trust change must fail closed and preserve GH#17671-style defence in depth.

## Relevant Files

- `.agents/scripts/pulse-merge-author-checks.sh:44-82` — primary collaborator/owner-member helpers currently collapse API failure into return code `1`.
- `.agents/scripts/pulse-merge.sh:216-223` — user-visible false log path: "author ... is not a collaborator".
- `.agents/scripts/pulse-merge-gates.sh:538-570` — existing permission-failure comment path to reuse.
- `.agents/scripts/shared-gh-wrappers-rest-fallback.sh:144-164` — `_rest_api_call()` wrapper that uses App auth when available and falls back.
- `.agents/scripts/github-app-auth-helper.sh:301-337` — `github_app_api_call()` token-selection and fallback implementation.
- `.agents/scripts/tests/test-pulse-merge-approve-collaborator-guard.sh` — existing collaborator/approval guard regression coverage.
- `.agents/scripts/tests/test-github-app-auth-helper.sh` — existing GitHub App token injection coverage.

## Dependencies

- **Blocked by:** none
- **Blocks:** Reliable pulse auto-merge under PAT rate-limit pressure; accurate diagnostics for GH#24494.
- **External:** GitHub App credentials/configuration may be needed for live manual verification, but tests should stub routes without requiring secrets.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Re-run exact probe search and inspect trust-gate call sites. |
| Implementation | 2h | Add helper/return semantics and route probes. |
| Testing | 1.5h | Update shell stubs and run targeted tests plus linter. |
| **Total** | **4h** | tier:standard |
