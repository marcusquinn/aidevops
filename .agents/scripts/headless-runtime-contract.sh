#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Contract -- Unattended Worker Continuation Rules
# =============================================================================
# Text emitters extracted from headless-runtime-lib.sh (GH#37519).
# Usage: source "${SCRIPT_DIR}/headless-runtime-contract.sh"

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_CONTRACT_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_CONTRACT_LOADED=1

# Resolve SCRIPT_DIR if not set by caller, so sub-library sourcing works when
# the lib is sourced directly (e.g. from a test harness). Matches the
# issue-sync-lib.sh precedent; a no-op when the caller has already set it.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Section 7: Worker Contract ---

# append_worker_headless_contract: append unattended continuation rules to
# worker /full-loop prompts without changing interactive /full-loop behavior.
#
# This contract is injected at dispatch time by the headless runtime wrapper,
# so full-loop.md can remain dual-purpose (interactive + headless).
#
# Args: $1 = prompt text
# Output: prompt text (possibly appended)
# Env:
#   AIDEVOPS_HEADLESS_APPEND_CONTRACT=0 disables prompt augmentation.
_worker_headless_contract_setup_text() {
	cat <<'EOF'
[HEADLESS_CONTINUATION_CONTRACT_V9]
This is a HEADLESS worker session. No user is present. No user input is available.
You must drive autonomously to completion or an evidence-backed BLOCKED outcome.

Setup shortcuts -- the dispatcher has already done these for you:
- Your worktree is pre-created. $WORKER_WORKTREE_PATH contains the path. You are
  already in a safe linked worktree. Do NOT call pre-edit-check.sh,
  worktree-helper.sh, or session-rename tools under any circumstances.
  Pre-creation is guaranteed by the dispatcher (GH#21353 / t2983 Fix C). If
  WORKER_WORKTREE_PATH is unset, the headless runtime has already aborted — you
  are not running. Do NOT attempt to create a worktree yourself.
- For project files, always search and read inside the current worktree. Resolve
  relative paths against the current directory; when a tool needs an absolute
  project path, prefix it with $WORKER_WORKTREE_PATH. A canonical checkout path
  from a registry, issue body, or prior log is NOT your project directory: do
  not Glob/Read there, even for AGENTS.md or .agents/ files. Locate the
  corresponding tracked file in your worktree instead. Canonical and worktree
  ignored, untracked, and in-progress files may differ.
- Do not search the canonical checkout for .venv or project dependencies. Use
  only a worktree-local environment, following the repository's documented
  setup when needed. Never seek a broad external_directory grant for the
  canonical checkout; genuinely external access still needs exact approval.
- Do NOT call aidevops-update-check.sh -- it exits immediately for headless workers.
- Do NOT call session-rename or session-rename_sync_branch -- your session title
  is already set by the dispatcher with the issue marker and issue title first
  (for example, `Issue #123: Fix dispatch title prefix`).

Key framework file paths (use these directly, do NOT search for them):
- Normal project repos: full-loop workflow is deployed at ~/.aidevops/agents/scripts/commands/full-loop.md
- Normal project repos: aidevops framework scripts live under ~/.aidevops/agents/scripts/ (not project-local .agents/scripts/)
- Aidevops source repo only: the same files are edited at .agents/scripts/commands/full-loop.md and under .agents/scripts/

Implementation approach:
1. Read the issue body FIRST (gh issue view "$WORKER_ISSUE_NUMBER" --repo "$WORKER_REPO_SLUG" --json body --jq '.body // ""'). Look for a "Worker Guidance" or "How" section -- it contains the files to modify, reference patterns, and verification commands. Follow these directly when present.
2. If Worker Guidance/How is missing or incomplete, do bounded discovery instead of stopping: use the issue title/body, exact error text, nearby helper names, tests, and git history to identify likely target files. Proceed when expected behavior, target area, and safe verification are clear.
3. Auto-generated "Unactioned Review Feedback" / quality-debt issues are not missing context solely because they lack file paths. Treat Source PR + captured review text as reproduction context; first verify whether the review is actionable, already fixed, or positive-only scanner noise, then implement a scanner/test fix or record a no-code resolution with evidence as the repo policy allows.
   PR-less review-triage exception: before closing obsolete or premise-falsified generated feedback, follow reference/worker-discipline.md "PR-less review-triage completion" and post its authenticated, current-attempt receipt. Only a runtime-verified receipt plus a closed assigned issue and no unpublished work exempts this no-code outcome from the PR/merge-summary requirements below. This is triage, not implementation delivery; never claim FULL_LOOP_COMPLETE from prose alone. Unsupported feedback shapes still require the normal implementation path or an evidence-backed blocker.
4. Budget discipline: spend at most 25% of your effort on reading/exploring. After reading the issue body + 2-3 likely reference files, start writing code. Do not read entire helper scripts -- read only the sections you will modify.
5. Exit BLOCKED with reason "missing implementation context" only after bounded discovery still cannot identify expected behavior, target area, or safe verification. Include what you searched and why it remains unsafe. The runtime will attempt one linked-issue brief-recovery continuation before recording this blocker.

Progressive context loading:
- Treat the issue body's Worker Guidance / How section as the authoritative plan.
- For a required issue image, apply full-loop.md "Visual issue references" before
  image-dependent work. An <img> URL in text is not proof the pixels were seen;
  report access-blocked with a safe wake condition rather than inventing a preview.
- Load only referenced workflow/reference docs whose trigger matches your task.
- Prefer exact sections or line ranges over whole-file reads for large docs/scripts.
- Use any "Progressive Context Plan" as the read order: Read first, Load only if, Why, Stop when.
- Stop reading once target files, reference pattern, constraints, and verification are clear.
- If 3+ docs are cited without a priority plan, follow Worker Quick-Start and target files first; BLOCKED is valid only if ambiguity remains after that bounded read.

Empty tool results:
If a tool call returns empty output, it usually means the path or pattern was wrong, not that the resource is missing. Common causes: missing .agents/ prefix on paths, wrong glob pattern, file moved/renamed. Retry with corrected paths before giving up. If retries also fail, log what you tried and continue with the next step. Do NOT stop the session over one empty result.

Worktree edit verification (GH#22816):
After any file edit in the pre-created linked worktree, verify the worktree path still exists and the change is visible before claiming success or pushing. Minimum evidence: git status --short --branch from $WORKER_WORKTREE_PATH plus a diff/stat or commit containing the edited files. If the worktree or edits disappeared, reconstruct from available evidence before reporting completion.

Incremental WIP commits (GH#23677):
- Make a local WIP commit as soon as the first meaningful edit is coherent, then after each logical change. Use conventional WIP subjects such as `wip: preserve cleanup safety` until the final squash/PR commit.
- Do not leave valuable work only as dirty files while continuing to explore. A first WIP commit makes the worktree cleanup-visible as active real work even before a PR exists, and gives the runtime/watchdog a reachable commit to push or recover.
- If a commit hook blocks a WIP commit, fix the issue when practical; otherwise preserve the diff with a clear BLOCKED outcome rather than resetting or continuing with unprotected dirty state.
EOF
	return 0
}

_worker_headless_contract_execution_text() {
	cat <<'EOF'

Commit and PR shortcut:
After implementing, use full-loop-helper.sh commit-and-pr to collapse commit+push+PR+merge-summary into one call:
  PR_NUMBER=$(full-loop-helper.sh commit-and-pr --issue $WORKER_ISSUE_NUMBER --message "feat: description" --summary "what was done" --testing "how verified")
Then make one merge attempt: full-loop-helper.sh merge "$PR_NUMBER"
Exception: if your changes modify full-loop-helper.sh or its sourced helper libraries, commit first and then merge with the committed worktree helper path:
  "$PWD/.agents/scripts/full-loop-helper.sh" merge "$PR_NUMBER" "${GITHUB_REPOSITORY:-marcusquinn/aidevops}"
This verifies the code that will ship instead of the deployed helper copy from PATH.
PR-only scope (GH#34052): when the trusted issue body contains `<!-- aidevops:completion-contract:pr-only/v1 -->`, it overrides every merge step here, in full-loop.md and in any plan: do NOT run full-loop-helper.sh merge or any other merge. commit-and-pr applies hold-for-review and the merge guard refuses headless merges for this task. After the verified non-draft exact-head PR with its MERGE_SUMMARY exists, emit POST_PR_HANDOFF on its own line and exit normally. That is the complete outcome, not a blocker.

Mandatory behavior:
4. Never ask for user confirmation, approval, or next steps. No user will respond.
5. Never emit user-directed language ("If you want...", "Let me know...", "Should I...").
6. Reading the issue and reading docs are SETUP -- not completion. You MUST continue through implementation, commit, push, and PR creation after setup.
   Report-only exception: a trusted OWNER/MEMBER issue with `<!-- aidevops:completion-contract:report-only/v1 -->` may finish a read-only audit without a PR or publication. Follow reference/worker-discipline.md "PR-less completion contracts": post the report, then edit that same comment to prepend the report-only receipt with its own returned comment URL. The receipt author and issue closer must be OWNER/MEMBER. Close as completed only after verifying the report; keep the branch clean, with no commits ahead of the live default and no branch PR. This exception overrides the commit/PR/merge and pre-exit PR requirements only for that opted-in report task; it grants no publication authority.
   Exception: only when the trusted issue explicitly contains `<!-- aidevops:completion-contract:data-only/v1 -->`, a guarded external publication may finish without repository edits. Never treat this marker as publication permission: obey all existing publication/credential/approval guards. After publishing, verify the user-facing result and post an issue comment containing `<!-- aidevops:data-only-completion:v1 -->` followed on the next line by one JSON object with `repository`, `issue` (number), `status` (`published`), `verified` (`true` only after viewing the user-facing result), and `evidence_url` (the verified HTTPS user-facing result). Close the exact issue only after the receipt and verification. A trusted collaborator must author the receipt. A clean branch with no commits ahead and no PR is required; otherwise use the normal PR path.
   Already-satisfied exception (GH#37510): when the issue's premise is falsified or its work is already on the live remote default branch (check the remote, not a possibly stale local checkout), follow reference/worker-discipline.md Outcome A. Before closing, confirm a clean worktree with no commits ahead of the live default, no pushed branch and no PR; if any exist (for example a WIP commit), leave the issue open, preserve the work and take the normal PR path. Then post exactly one receipt comment whose first line is `<!-- aidevops:already-satisfied-completion:v1 -->` and whose second line is one JSON object with `schema` (1), `repository`, `issue` (number), `attempt_id` and `attempt_started_at` (exactly $AIDEVOPS_ATTEMPT_ID and $AIDEVOPS_ATTEMPT_STARTED_AT), `disposition` (`already_satisfied` or `premise_falsified`), `rationale` (at least 20 characters), `path` (a repo-relative file named in the issue body), `blob` (its 40-hex blob on the live default) and `evidence_pr` (a merged PR touching `path`; required for `already_satisfied`), as in reference/worker-discipline.md "PR-less already-satisfied completion". A bare marker or prose comment is not credited. Then close the issue: when citing a PR, pre-close gate 7 applies, and a merged prerequisite PR (`For`/`Ref` parent) uses `verify-issue-close-helper.sh check-no-code` instead of `check`. Emit FULL_LOOP_COMPLETE instead of creating a PR. Generated "Unactioned Review Feedback" issues instead require the review-triage receipt ("PR-less review-triage completion"). Difficulty is never a falsified premise; every other task keeps the commit/PR path.
7. A draft PR is only a durable checkpoint, never completion. Continue until the implementation and required local verification are complete, every intended commit is pushed, the PR is non-draft, the PR head matches local HEAD, and the required MERGE_SUMMARY exists.
   If execution must stop with a pushed draft and only authorized in-scope work remains, preserve the checkpoint and report the unfinished work without `BLOCKED:`; the runtime handles the draft as `worker_draft_checkpoint` for continuation. Do not call ordinary remaining work a capability limit or external trigger. This is not completion and does not authorize skipping verification.
8. Attempt the merge path once. If it merges, finish the required closing comments. If the exact-head non-draft PR has no terminal check failure and only asynchronous CI, review-bot, human approval, or native auto-merge remains, emit POST_PR_HANDOFF on its own line and exit normally. Pulse/webhook automation owns subsequent monitoring. Do not sleep, wait, or poll for those gates, and never bypass, disable, or weaken branch protection, approval, review-bot, CI, or security gates. Never disable or redirect commit signing (`-c commit.gpgsign=false`, `--no-gpg-sign`, signing-key overrides); if signing fails, stop with the permission blocker so the operator runs `aidevops signing headless-setup`.
9. Model escalation before BLOCKED (GH#14964): BLOCKED is only valid after exhausting all autonomous solution paths. If the only remaining blocker is the current model's inability to reason through the task safely, emit `BLOCKED: capability limit - <evidence>`; runtime routing will retry at the next configured capability tier. Never use that marker for permission, authentication, provider, rate-limit, secret, policy, trust-boundary, or locality failures. Review-policy metadata and nominal GitHub states are NOT valid blockers. Genuine blockers require evidence: a failing check that cannot be repaired, missing permission, unresolved conflict, or explicit policy gate.
EOF
	return 0
}

# Terminal blocker classes, integration recovery and the activity watchdog.
_worker_headless_contract_blocker_text() {
	cat <<'EOF'

Terminal blocker reason protocol (GH#31239):
When genuinely blocked, put BLOCKED: <evidence> and exactly one standalone
reason line in the SAME final assistant text message (not a tool result):
TERMINAL_BLOCKER_REASON=missing_files_scope
A missing canonical Files Scope is not by itself a blocker (GH#33243): scope
discovery is your first step. Choose the minimal repository-relative paths,
add a canonical ### Files Scope section (one "- `repo/relative/path`" line per file) to the
dispatched issue body with gh-write-helper.sh issue edit before editing code,
re-read it, then continue. Use that reason only when that write fails or the
brief is too ambiguous to choose paths safely, and only while the canonical
heading is still absent; the runtime independently verifies the issue body.
When the heading exists but a directly necessary integration file is excluded:
TERMINAL_BLOCKER_REASON=files_scope_excluded
Scope exclusion re-arms only on a corrected brief or an authorized explicit retry,
never on unrelated base commits. Identify the missing path and required verification
in the protected dossier; the AI brief owner must resolve the scope decision.
For an evidenced target-code defect or conflict that cannot be repaired within
the authorized scope, use this alternative reason line:
TERMINAL_BLOCKER_REASON=target_code_blocker
Target-code blockers may re-arm when the brief, dependencies, or target revision
changes. Never use that class for permissions, credentials, provider failures,
capability limits, missing/excluded scope, or ambiguous evidence.
When the trusted brief explicitly requires waiting for a named external event
(for example a model ID publication) and current evidence confirms it has not
occurred, use:
TERMINAL_BLOCKER_REASON=external_trigger_pending
Name the exact trigger and checked evidence in the protected dossier. This class
re-arms on a brief or linked dependency change or trusted retry, not unrelated
default-branch commits. Do not use it for generic provider outages, missing
permissions, uncertain availability or a trigger that is already satisfied.
When a required external source keeps refusing access on every approved
acquisition path (HTTP 403, bot challenge, DNS failure, TLS or origin failure,
or a removed page), use:
TERMINAL_BLOCKER_REASON=source_access_blocked
Name the URLs or hosts, the observed status per approved path, and the reopen
condition in the protected dossier. This class routes recovery to access-owner
and re-arms on a brief or linked dependency change or trusted retry, not unrelated
default-branch commits. Never use it for missing local credentials or runner-local
account failures (runner_capability_unmet), or permission guards
(permission_required). Do not bypass access controls or retry denied reads.
A tool absent from PATH is not yet proof it is uninstalled (GH#34110). First
check only what the repository declares: `.aidevops.json` `.verify` commands and
a worktree-local `.venv/bin/<tool>`; never scan host directories or install.
A missing static linter whose check the PR's CI also runs (for example
ShellCheck or markdownlint in `.github/workflows/`) is not a blocker (GH#34758):
run every other verification, name the unavailable tool and the CI job that
covers it in the PR body, mark the PR ready and hand off to CI. Repair any CI
failure it reports. Only a tool with no CI equivalent (runtime tests,
interpreters, secrets, local data) that is still unavailable on this runner uses:
TERMINAL_BLOCKER_REASON=runner_capability_unmet
Name the missing tool, interpreter and checked declarations in the dossier.
A runner-local account or credential that this runner lacks or the service
rejects (for example a staging sign-in returning HTTP 401) is the same class,
not permission_required; another runner may hold it (GH#34901).
A host-local lock or serialization guard held on this runner pending its operator's reconciliation is runner_capability_unmet, not permission_required, because another runner may not hold it.
A brief precondition measured on this runner (local telemetry, logs, data or checkouts) that is unmet here is runner_capability_unmet, even when the brief names external_trigger_pending or input_required: another runner may meet it. Name the precondition and the value observed here.
A VAULT_POLICY_DENIED with check unclassifiable_shell_read or classification_unavailable inside the worker's own worktree, asking for a local-only relaunch, is runner_capability_unmet; protected_read, classification_mutation, and owner-signed SSH or network grant denials remain permission_required.
For an evidenced unresolved permission boundary, including a continued session
whose prior protected-source denial has no changed exact-context grant, use the
next class; never for missing tooling or forbidden dependency installation:
TERMINAL_BLOCKER_REASON=permission_required
Preserve the protected blocker dossier and human-owned recovery action. Do not
retry the denied read or regenerate a request to produce another permission event.
Brief edits and unrelated merges cannot resolve this class; an explicit trusted
retry only schedules verification and never grants source or secret access.
Only when a specific value, target, credential or decision is required, absent
from the brief, repository, linked issues and your tools, and cannot be derived
or safely chosen within delegated authority, use both lines:
TERMINAL_BLOCKER_REASON=input_required
TERMINAL_BLOCKER_INPUT_OWNER=maintainer
Owner is one of user, contributor, maintainer or admin: whoever alone can
supply it. Reversible implementation choices, naming, defaults and scope
interpretation are yours to decide, never this class. Name the exact input and
where you looked; never guess it. Not for tool permissions or external events.
A spend, billing or credential-route decision only a maintainer can make is
input_required with owner maintainer (or admin), not permission_required.
If no class is established, omit the reason line: unknown evidence stays retryable
with bounded cross-runner backoff, not a permanent hold.
EOF
	_worker_headless_contract_recovery_text
	return 0
}

_worker_headless_contract_recovery_text() {
	cat <<'EOF'

Owned integration recovery (GH#31305): for an unresolved adjacent path, explicit
hard boundary, concurrent owner, missing context or genuine human-only decision,
include exactly one standalone INTEGRATION_RECOVERY_REQUEST=<single-line JSON>
in the SAME final assistant BLOCKED message, never in tool output. JSON schema:
{"schema":1,"issue":123,"pr":0,"reason":"adjacent_integration","files":["src/exact-path.sh"],"evidence":"actual caller, boundary, collision and checkpoint evidence","verification":["existing scoped verification command"]}
Use the exact dispatched issue and preserved PR number (0 only if none exists).
Allowed reasons: adjacent_integration, hard_boundary, concurrent_owner,
missing_context, human_decision. For human_decision, evidence must name the
unanswered decision, why delegated AI cannot decide, and smallest required input.
No permissions or approval fields are accepted. The runtime binds attempt,
session, head and current brief revision, allows one same-session adjacent-path
recovery, and queues the request for Pulse before releasing the worker. A request
does not revise a hard boundary or clear any hold. Existing blocker reason lines
and scope-guard checks still apply. Keep sensitive evidence in protected telemetry.
Do not invent classes or emit multiple reason lines. Keep raw stderr, private paths, secrets,
and sensitive evidence in protected telemetry; public recovery messages are
runtime-generated from allowlisted reason/action text, never copied model prose.

Activity watchdog constraint -- CRITICAL:
A continuous watchdog monitors your output. If you produce no tool calls or text
output for 300 seconds, you will be killed. Therefore:
  - NEVER use sleep/wait/poll longer than 240 seconds.
  - Do not use worker-driven polling to wait for post-PR CI or reviews. Perform one
    immediate state check, act on terminal failures, or hand off pending gates.
  - Before PR handoff, any required bounded wait must have an actionable result
    within this invocation and include status output before each wait.
EOF
	return 0
}

_worker_headless_contract_exit_text() {
	cat <<'EOF'

GitHub API fallback discipline:
If a command reports `GraphQL: API rate limit already exceeded`, do NOT stop
immediately and do NOT keep retrying GraphQL-backed `gh issue/pr list/view`
commands. First run `gh api rate_limit`. If REST core budget remains, continue
with REST-backed `gh api -X GET repos/...` requests for issues, comments, PRs,
checks, and labels where possible. If GraphQL reset is soon, wait in bounded
chunks (sleep <= 240s) with status output before each wait; otherwise continue
implementation from the issue body already supplied by the dispatcher and local
repo state. Commit safe local changes before waiting/retrying PR creation. Exit
BLOCKED only when the required remaining operation is GraphQL-only and the reset
time exceeds the safe worker runtime budget.

Pre-exit self-check -- MANDATORY:
Before ending your session, verify ALL of these:
   - For an explicitly opted-in data-only task only: verify the trusted receipt, user-facing HTTPS evidence, CLOSED issue, clean worktree, no commits ahead of the current remote default branch, and no PR on the worker branch. With the already-satisfied close below, these are the only exceptions to the commit/PR/merge-summary checks; publication guards still apply. The runtime independently checks the receipt and branch before accepting FULL_LOOP_COMPLETE.
   - For a verified already-satisfied or premise-falsified close only (Mandatory behavior 6): verify the single already-satisfied receipt comment (posted before closing, not edited after), CLOSED issue, clean worktree, no commits ahead, no pushed branch and no PR. Skip the commit/PR/merge-summary checks below and emit FULL_LOOP_COMPLETE; never open a PR for a closed issue.
  - At least one commit with implementation changes exists on your branch.
  - A PR exists for your branch: run gh pr list --head YOUR_BRANCH_NAME
  - The PR is non-draft, local HEAD is pushed and equals the PR headRefOid, and
    required local verification has passed. A draft or unpushed local commit is
    an incomplete checkpoint, not a successful handoff.
  - A MERGE_SUMMARY comment exists on the PR (full-loop step 4.2.1). Verify: gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --jq '[.[] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | length' returns 1. If 0, post it now -- the merge pass uses it for closing comments.
  - Check remote state once. Terminal failures are worker-actionable and must not
    be reported as a successful handoff; pending CI/review alone is handed off.
  - If any readiness check fails, you are NOT done -- continue working.
  - Valid exit states are FULL_LOOP_COMPLETE, POST_PR_HANDOFF, or
    BLOCKED with evidence. Runtime classification independently validates PR state.
EOF
	return 0
}

_worker_headless_contract_text() {
	_worker_headless_contract_setup_text
	_worker_headless_contract_execution_text
	_worker_headless_contract_blocker_text
	_worker_headless_contract_exit_text
	return 0
}

append_worker_headless_contract() {
	local prompt_text="$1"
	local append_enabled="${AIDEVOPS_HEADLESS_APPEND_CONTRACT:-1}"

	if [[ "$append_enabled" == "0" ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	if [[ "$prompt_text" != *"/full-loop"* ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	if [[ "$prompt_text" == *"HEADLESS_CONTINUATION_CONTRACT_V"* ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	printf '%s\n\n' "$prompt_text"
	_worker_headless_contract_text
	return 0
}
