#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-merge-stuck-saturation.sh -- Runner-saturation and zero-progress
# meta-issue helpers for pulse-merge-stuck.sh (GH#37541 file split).
#
# Functions moved verbatim from pulse-merge-stuck.sh: runner-saturation
# meta-issue composition/filing, zero-progress meta-issue lifecycle,
# per-repo eligible-unmerged counting and saturation state computation.
#
# Sourced by pulse-merge-stuck.sh; do not source directly from callers.
# Dependencies: pulse-merge-stuck.sh module variables (_PMS_*), LOGFILE,
# pulse-stats-helper.sh, gh wrappers (resolved lazily at call time).
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_PULSE_MERGE_STUCK_SATURATION_LOADED:-}" ]] && return 0
_PULSE_MERGE_STUCK_SATURATION_LOADED=1

# ── Runner queue saturation meta-issue (t3211, GH#21942) ────────────────────

#######################################
# File ONE meta-issue describing GitHub Actions runner queue saturation in the
# repo. Suppression: the caller (pulse_merge_stuck_run_pass) skips per-PR
# escalations for STUCK_RUNNER_QUEUE_SATURATION classifications when this
# function fires, so the meta-issue is the only escalation surface.
# Dedup'd by the fixed marker — saturation is a repo-level signal, not a
# per-fingerprint signal.
#
# Args:
#   $1 - repo_slug
#   $2 - queued (count of queued workflow runs at detection time)
#   $3 - in_progress (count of in-progress workflow runs at detection time)
#   $4 - ratio (integer queued/max(in_progress,1))
#   $5 - affected_prs (comma-separated PR numbers blocked by saturation)
#   $6 - count (length of affected_prs list)
#######################################
# Compose the meta-issue body for runner-saturation. Extracted from
# _pms_file_runner_saturation_issue to keep the caller under the 100-line
# function-complexity gate. The heredoc itself is the bulk of the work;
# isolating it here also makes the body easier to update without
# perturbing the dedup/file/metrics control flow above.
#
# Echoes the composed body to stdout. Caller captures via $().
_pms_compose_runner_saturation_body() {
	local marker="$1" repo_slug="$2" queued="$3" in_progress="$4"
	local ratio="$5" affected_prs="$6" count="$7"
	# read -r -d '' for bash 3.2 portability (heredoc-in-subshell unsupported).
	local body=""
	IFS='' read -r -d '' body <<EOF || true
${marker}
## What

The pulse stuck-merge detector observed **GitHub Actions runner queue saturation** in this repo, blocking **${count} PR(s)** with required checks stuck in QUEUED status:

- Queued workflow runs: **${queued}**
- In-progress workflow runs: **${in_progress}**
- Saturation ratio (queued / max(in_progress,1)): **${ratio}**

Detection thresholds: queued > \`${AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN:-50}\` AND ratio > \`${AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN:-10}\`. Both conditions held in this cycle.

Per-PR escalation comments are SUPPRESSED for these PRs while saturation persists — the cause is shared (runner pool exhaustion), not per-PR (rebase, fix code). This single meta-issue replaces the N per-PR comments that would otherwise be filed.

## Affected PRs

$(_pms_format_pr_markdown_list "$affected_prs")

## Why

GitHub Actions accounts share a runner pool with rate-limited concurrency. When many workflow runs queue at once (CI cascade triggered by a merge train, bulk push, workflow_dispatch storm, recursive workflow_run trigger), runners are oversubscribed and PRs sit indefinitely with required checks in QUEUED state.

The deterministic merge gate (\`required_status_checks\`) reports these as not-yet-passing — they have not concluded — so PRs that would otherwise auto-merge are blocked. This is distinct from:

- **t2690** (GraphQL points circuit breaker) — GraphQL points and Actions runner-minutes are independent GitHub resource pools.
- **t2922** (fail-closed required-checks) — concerns API errors fetching protection rules, not runner availability.
- **t3193** (per-PR stuck classifications) — surfaces individual PRs with FAILURE checks; saturation is about CHECKS THAT NEVER STARTED.

## How

### Files Scope

Investigation only — the fix is operational (reduce runner load, upgrade plan, prune workflows), not code.

### Investigation steps

1. Confirm saturation persists (run a few minutes after this issue was filed):

\`\`\`bash
	# Add \`&created=>=<UTC now-AIDEVOPS_ACTIONS_QUEUE_SATURATION_WINDOW_HOURS>\`
	# (default 6h; omit it only when the window is explicitly 0).
	gh api "repos/${repo_slug}/actions/runs?status=queued&created=>=<UTC-window-start>&per_page=1" --jq '.total_count'
gh api "repos/${repo_slug}/actions/runs?status=in_progress&per_page=1" --jq '.total_count'
\`\`\`

2. Identify the source of the queue burst:

\`\`\`bash
gh run list --repo ${repo_slug} --status queued --limit 30 \\
  --json workflowName,headBranch,createdAt
\`\`\`

Group by \`workflowName\` — if one workflow dominates, suspect a runaway loop (workflow_dispatch storm, schedule misfire, recursive \`workflow_run\` trigger, label-cascade — see t2229).

3. Cancel runaway runs if detected:

\`\`\`bash
gh run cancel <run-id> --repo ${repo_slug}
# or bulk:
gh run list --repo ${repo_slug} --status queued --limit 100 \\
  --json databaseId,workflowName --jq '.[] | select(.workflowName=="<runaway>") | .databaseId' \\
  | xargs -I{} gh run cancel {} --repo ${repo_slug}
\`\`\`

4. Check concurrency settings — every workflow that triggers on \`pull_request\` should have a \`concurrency\` block keyed by branch with \`cancel-in-progress: true\` (or \`false\` only when serial execution is required, e.g. Maintainer Gate). Workflows without \`concurrency\` multiply the queue under bursty conditions.

5. If saturation is sustained (recurring across multiple meta-issues), consider:

   - Upgrading the GitHub plan tier (increases runner pool size).
   - Migrating long-running jobs to self-hosted runners.
   - Pruning low-value workflows (e.g. duplicate Python lint jobs running in parallel with the same matrix).

### Verification

- The windowed \`gh api "repos/${repo_slug}/actions/runs?status=queued&created=>=<UTC-window-start>&per_page=1" --jq '.total_count'\` query returns ≤ \`${AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN:-50}\`.
- The next pulse cycle does NOT re-fire this meta-issue (saturation cleared).
- Affected PRs above either auto-merge or have their remaining issues triaged individually.

## Acceptance

- [ ] Source of the runner queue burst identified (specific workflow / event / cause).
- [ ] Saturation cleared (queue depth recovered below threshold).
- [ ] All ${count} affected PR(s) above are unblocked (auto-merged, manually merged, or have separate follow-up issues).

## Session Origin

Filed automatically by \`pulse-merge-stuck.sh\` (t3211 / GH#21942) on detecting Actions runner queue saturation in ${repo_slug}. The detector runs once per pulse cycle per repo via \`pulse_merge_stuck_run_pass\`.

<sub>Source: pulse-merge-stuck-detector. Threshold env: \`AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN=${AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN:-50}\`, \`AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN=${AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN:-10}\`.</sub>
EOF
	printf '%s' "$body"
	return 0
}

_pms_file_runner_saturation_issue() {
	local repo_slug="$1"
	local queued="$2"
	local in_progress="$3"
	local ratio="$4"
	local affected_prs="$5"
	local count="$6"

	[[ -n "$repo_slug" ]] || return 0
	[[ "$queued" =~ ^[0-9]+$ ]] || queued=0
	[[ "$in_progress" =~ ^[0-9]+$ ]] || in_progress=0
	[[ "$ratio" =~ ^[0-9]+$ ]] || ratio=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	local marker_text="${_PMS_RUNNER_SATURATION_MARKER_TEXT}"
	local marker="<!-- ${marker_text} -->"

	# Dedup: search for an OPEN issue with this marker in the affected repo.
	# The same repo's saturation events may recur over hours but only one
	# meta-issue stays open at a time — operators close it after triaging.
	local existing
	existing=$(gh issue list --repo "$repo_slug" --state open --search "${marker_text}" \
		--limit 1 --json number --jq '.[0].number' 2>/dev/null)
	if [[ -n "$existing" && "$existing" != "$_PMS_JQ_NULL_GUARD" ]]; then
		echo "[pulse-merge-stuck] _pms_file_runner_saturation_issue: marker already filed as #${existing} in ${repo_slug} — skipping" >>"$LOGFILE"
		# Still increment the events counter — saturation IS happening, even
		# if the meta-issue dedup prevents a fresh filing. This way operators
		# can correlate counter spikes with saturation incidents even when
		# only one meta-issue exists.
		pulse_stats_increment "$_PMS_COUNTER_QUEUE_SATURATION_EVENTS"
		return 0
	fi

	# Compose the meta-issue body via the dedicated composer (extracted to
	# keep this function under the function-complexity gate).
	local title="merge-stuck: GitHub Actions runner queue saturated (${queued} queued / ${in_progress} in-progress) in ${repo_slug}"
	local body
	body=$(_pms_compose_runner_saturation_body "$marker" "$repo_slug" \
		"$queued" "$in_progress" "$ratio" "$affected_prs" "$count")

	# Wrapper-only — see _pms_file_outage_issue rationale above.
	if ! declare -F gh_create_issue >/dev/null 2>&1; then
		echo "[pulse-merge-stuck] _pms_file_runner_saturation_issue: gh_create_issue wrapper unavailable, skipping for ${repo_slug} (queued=${queued})" >>"$LOGFILE"
		return 0
	fi

	# tier:thinking + bug + auto-dispatch matches the _pms_file_outage_issue
	# convention; source:merge-stuck-detector routes the issue to operators
	# familiar with the detector module.
	local labels="auto-dispatch,tier:thinking,bug,source:merge-stuck-detector"
	gh_create_issue --repo "$repo_slug" \
		--title "$title" \
		--body "$body" \
		--label "$labels" >/dev/null 2>&1 || true

	pulse_stats_increment "$_PMS_COUNTER_ESCALATIONS_FILED"
	pulse_stats_increment "$_PMS_COUNTER_QUEUE_SATURATION_EVENTS"
	echo "[pulse-merge-stuck] _pms_file_runner_saturation_issue: filed saturation issue for ${repo_slug} (queued=${queued}, in_progress=${in_progress}, ratio=${ratio}, affected=${count})" >>"$LOGFILE"
	return 0
}

# ── Zero-progress meta-issue ────────────────────────────────────────────────

# File ONE meta-issue when consecutive zero-progress cycles cross the threshold.
# The caller invokes this on the crossing edge; open-issue dedupe is a safety net.
# Disabled while the GraphQL circuit-breaker is tripped — the breaker
# already names the root cause and a meta-issue would just be noise.
_pms_file_zero_progress_meta_issue() {
	local zero_cycles="$1"
	local stuck_summary="$2"

	# Skip if the GraphQL circuit-breaker is tripped — its own counter
	# (pulse_dispatch_circuit_broken) is the authoritative signal.
	local _cb_24h
	_cb_24h=$(pulse_stats_get_24h "pulse_dispatch_circuit_broken" 2>/dev/null) || _cb_24h=0
	[[ "$_cb_24h" =~ ^[0-9]+$ ]] || _cb_24h=0
	if [[ "$_cb_24h" -gt 0 ]]; then
		echo "[pulse-merge-stuck] _pms_file_zero_progress_meta_issue: skipped — circuit breaker tripped in last 24h" >>"$LOGFILE"
		return 0
	fi

	# Use the framework-routing helper if available — meta-issues belong in
	# the framework repo (marcusquinn/aidevops), not in the affected project.
	local meta_repo="marcusquinn/aidevops"
	local marker="<!-- merge-stuck:zero-progress -->"

	# Dedup: find an OPEN meta-issue with this marker (one is enough — the
	# meta-issue stays open for human triage). Reset cadence: when the
	# meta-issue closes (manually) and the underlying cause recurs, a fresh
	# meta-issue is filed.
	local existing
	existing=$(gh issue list --repo "$meta_repo" --state open --search "merge-stuck:zero-progress" \
		--limit 1 --json number --jq '.[0].number' 2>/dev/null)
	if [[ -n "$existing" && "$existing" != "$_PMS_JQ_NULL_GUARD" ]]; then
		echo "[pulse-merge-stuck] _pms_file_zero_progress_meta_issue: meta-issue already open as #${existing} — skipping" >>"$LOGFILE"
		return 0
	fi

	local title="merge-stuck: pulse merge throughput collapse (${zero_cycles} consecutive zero-progress cycles)"
	local body
	body="${marker}
## What

The pulse deterministic merge pass has had **${zero_cycles} consecutive cycles** with eligible-unmerged PRs but zero merges. The threshold is \`AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES}\`.

## Why

Eligible-unmerged means \`APPROVED + MERGEABLE + !draft + !hold-for-review\`. When this is non-zero AND the merge count is zero across multiple cycles, the merge pass is structurally blocked — gates failing closed (e.g. branch-protection 404 mis-fire), GraphQL exhaustion, repo-allowlist mismatch, or a regression in the merge gates themselves.

## How

### Files Scope

Investigation only — no \`Files Scope\` declared.

### Snapshot

\`\`\`
${stuck_summary}
\`\`\`

### Investigation steps

1. Read \`~/.aidevops/logs/pulse.log\` since the meta-issue was filed (\`grep 'Merge pass: skipping' \`) — the per-PR skip reason is logged for every cycle.
2. Cross-check \`pulse-stats.json\` for circuit-breaker fires and the \`pulse_merge_branchprotect_404_skips\` counter — if non-zero, the t2922 fail-closed path is mis-firing.
3. Reproduce the merge gate decision for one stuck PR via \`pulse-diagnose-helper.sh pr <N>\` — it explains what the pulse decided and why.
4. Apply the fix (often a one-line gate adjustment) and verify the next cycle drops zero-progress to 0.

## Acceptance

- [ ] Root cause of the throughput collapse identified.
- [ ] At least one of the stuck PRs successfully auto-merges.
- [ ] \`pulse_merge_zero_progress_cycles\` reads 0 in \`pulse-stats.json\`.

## Session Origin

Filed automatically by \`pulse-merge-stuck.sh\` (t3193). The detector resets the zero-progress counter on any successful merge — if the meta-issue is stale (cause already resolved), close it manually.

<sub>Source: pulse-merge-stuck-detector. Threshold env: \`AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES}\`.</sub>"

	local labels="auto-dispatch,tier:thinking,bug,source:merge-stuck-detector,framework"
	# Wrapper-only — see _pms_file_outage_issue rationale above.
	if ! declare -F gh_create_issue >/dev/null 2>&1; then
		echo "[pulse-merge-stuck] _pms_file_zero_progress_meta_issue: gh_create_issue wrapper unavailable, skipping meta-issue (${zero_cycles} cycles)" >>"$LOGFILE"
		return 0
	fi
	gh_create_issue --repo "$meta_repo" \
		--title "$title" \
		--body "$body" \
		--label "$labels" >/dev/null 2>&1 || true
	pulse_stats_increment "$_PMS_COUNTER_ESCALATIONS_FILED"
	echo "[pulse-merge-stuck] _pms_file_zero_progress_meta_issue: filed meta-issue (${zero_cycles} zero-progress cycles)" >>"$LOGFILE"
	return 0
}

_pms_close_zero_progress_meta_issue_if_recovered() {
	local reason="$1"
	local meta_repo="marcusquinn/aidevops"
	local marker_text="merge-stuck:zero-progress"
	[[ -n "$reason" ]] || reason="merge progress recovered"
	# #aidevops:trust-boundary — public issue comments can succeed for non-collaborators.
	if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 ||
		! repo_allows_pulse_write_actions "$meta_repo"; then
		echo "[pulse-merge-stuck] _pms_close_zero_progress_meta_issue_if_recovered: skipping recovery write in ${meta_repo} — runner lacks repo write permission" >>"$LOGFILE"
		return 0
	fi
	local existing
	existing=$(gh issue list --repo "$meta_repo" --state open --search "$marker_text" \
		--limit 1 --json number --jq '.[0].number' 2>/dev/null) || existing=""
	if [[ -z "$existing" || "$existing" == "$_PMS_JQ_NULL_GUARD" ]]; then
		return 0
	fi
	[[ "$existing" =~ ^[0-9]+$ ]] || return 0

	local body
	body="## Recovery detected

The pulse merge zero-progress detector recovered automatically: ${reason}.

Evidence:
- pulse_merge_zero_progress_cycles was reset to 0.
- A fresh issue is filed only if a new zero-progress streak crosses the threshold.

Closing this stale zero-progress meta-issue so auto-dispatch does not spend worker capacity on an already-recovered incident."

	gh_issue_comment "$existing" --repo "$meta_repo" --body "$body" >/dev/null 2>&1 || true
	gh_issue_close_safe "$existing" --repo "$meta_repo" --reason completed >/dev/null 2>&1 || true
	echo "[pulse-merge-stuck] _pms_close_zero_progress_meta_issue_if_recovered: closed #${existing} — ${reason}" >>"$LOGFILE"
	return 0
}
# Count PRs in $repo_slug that are eligible-but-unmerged this cycle —
# APPROVED + MERGEABLE + !draft + !hold-for-review, then narrowed to PRs
# that are not known to be blocked by the read-only merge gates (NOT age-gated).
# Used by pulse-merge.sh to feed the zero-progress signal across all repos.
#
# Distinct from pulse_merge_stuck_run_pass which adds the AIDEVOPS_MERGE_STUCK_AGE_MINUTES
# age gate — zero-progress detection wants the wider population (any cycle
# with eligible-unmerged > 0 + zero merges is a candidate, regardless of age).
# It must still exclude PRs that the merge pass already proved are not mergeable
# in this cycle (for example failing required checks, origin:interactive PRs
# held for manual merge, or origin:worker PRs with no linked issue), otherwise a
# legitimate skip becomes a false zero-progress structural-block signal.
#
# Args: $1 = repo_slug
# Stdout: integer count
#######################################
# Decide whether a basic eligible PR should contribute to the zero-progress
# denominator. This is intentionally read-only and narrower than the full
# _check_pr_merge_gates stack because that stack can route workers/comments.
#
# Args: $1=repo_slug, $2=pr_number, $3=labels_str (comma-separated), $4=pr_author
# Returns: 0=count it, 1=exclude it from the zero-progress signal
#######################################
_pms_pr_counts_for_zero_progress() {
	local repo_slug="$1"
	local pr_number="$2"
	local labels_str="$3"
	local pr_author="${4:-}"
	local head_sha="${5:-}"

	[[ -n "$repo_slug" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	local labels_tokenized=",${labels_str},"

	if declare -F _check_required_checks_passing >/dev/null 2>&1; then
		if ! _check_required_checks_passing "$repo_slug" "$pr_number" "$head_sha" >/dev/null 2>&1; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — required checks are not provably passing" >>"$LOGFILE"
			return 1
		fi
	fi

	if [[ "$labels_tokenized" == *",origin:interactive,"* ]]; then
		if ! declare -F _interactive_pr_auto_merge_allowed >/dev/null 2>&1 ||
			! _interactive_pr_auto_merge_allowed "$pr_number" "$repo_slug" "$labels_str" >/dev/null 2>&1; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — origin:interactive PR requires manual merge" >>"$LOGFILE"
			return 1
		fi
	fi

	# Keep parity with pulse-merge.sh::_check_pr_merge_gates external-contributor
	# defence-in-depth. These PRs are intentionally skipped unless a linked issue
	# carries maintainer crypto approval; counting them as eligible can produce a
	# false zero-progress collapse when the merge pass is correctly preserving the
	# trust boundary.
	if [[ "$labels_tokenized" == *",external-contributor,"* ]]; then
		local external_linked_issue=""
		if declare -F _extract_linked_issue >/dev/null 2>&1; then
			external_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || external_linked_issue=""
		fi
		if [[ -z "$external_linked_issue" ]]; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — external-contributor PR has no linked issue" >>"$LOGFILE"
			return 1
		fi
		if ! declare -F _has_maintainer_crypto_approval >/dev/null 2>&1 ||
			! _has_maintainer_crypto_approval "$pr_number" "$repo_slug"; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — external-contributor PR linked issue #${external_linked_issue} lacks crypto approval" >>"$LOGFILE"
			return 1
		fi
	fi

	# Keep the zero-progress denominator aligned with the deterministic merge
	# pass trust gate. A MERGEABLE+APPROVED PR authored by a non-collaborator is
	# intentionally skipped unless a maintainer crypto-approval exists; counting
	# it as eligible creates a false structural-stuck signal when every real merge
	# candidate is already drained.
	if declare -F _is_collaborator_author >/dev/null 2>&1; then
		if ! _is_collaborator_author "$pr_author" "$repo_slug"; then
			if ! declare -F _has_maintainer_crypto_approval >/dev/null 2>&1 ||
				! _has_maintainer_crypto_approval "$pr_number" "$repo_slug"; then
				echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — author ${pr_author} is not a collaborator" >>"$LOGFILE"
				return 1
			fi
		fi
	fi

	if [[ "$labels_tokenized" == *",origin:worker,"* ]]; then
		local linked_issue=""
		if declare -F _extract_linked_issue >/dev/null 2>&1; then
			linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_issue=""
		fi
		if [[ -z "$linked_issue" ]]; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — origin:worker PR has no linked issue" >>"$LOGFILE"
			return 1
		fi
	fi

	# The shared PR-list snapshot can outlive a concurrent merge pass. Revalidate
	# the remaining candidate through an uncached REST-compatible read so an
	# already-merged PR cannot keep the denominator non-zero or overwrite recovery.
	# If that read is unavailable, retain the cached candidate: API degradation is
	# not evidence that the PR stopped being eligible, and hiding it would mask a
	# real zero-progress incident.
	local current_state=""
	if declare -F gh_pr_view >/dev/null 2>&1; then
		current_state=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json state --jq '.state // ""' 2>/dev/null) || current_state=""
	else
		current_state=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo_slug" \
			--json state --jq '.state // ""' 2>/dev/null) || current_state=""
	fi
	if [[ -z "$current_state" ]]; then
		echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: retaining PR #${pr_number} in ${repo_slug} — current state is unavailable" >>"$LOGFILE"
		return 0
	fi
	if [[ "$current_state" != "$_PMS_ISSUE_STATE_OPEN" ]]; then
		echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — current state is ${current_state}" >>"$LOGFILE"
		return 1
	fi

	return 0
}

_pms_count_eligible_unmerged_for_repo() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || {
		printf '0'
		return 0
	}
	local same_pass_count=""
	if declare -F _pmp_count_same_pass_eligible_unmerged >/dev/null 2>&1 &&
		same_pass_count=$(_pmp_count_same_pass_eligible_unmerged "$repo_slug" 2>/dev/null); then
		[[ "$same_pass_count" =~ ^[0-9]+$ ]] || return 2
		printf '%s' "$same_pass_count"
		return 0
	fi
	[[ "${AIDEVOPS_PULSE_REQUIRE_SAME_PASS_OUTCOME:-0}" == "1" ]] && return 2

	local pr_json
	pr_json=$(pulse_pr_list_get --repo "$repo_slug" --state open \
		--json "$(_pms_pr_list_json_fields)" \
		--limit 50 2>/dev/null) || pr_json="[]"
	[[ -n "$pr_json" && "$pr_json" != "$_PMS_JQ_NULL_GUARD" ]] || pr_json="[]"
	pr_json=$(_pms_enrich_pr_state "$repo_slug" "$pr_json")

	# Enumerate PRs matching the basic eligibility criteria via jq. .mergeable and
	# .mergeable and .reviewDecision are normalized to upper-case enums. Only a
	# policy-level APPROVED value qualifies; REST history's OBSERVED_APPROVED
	# cannot trigger stuck-PR escalation or sibling-affecting diagnostics.
	local candidates
	candidates=$(printf '%s' "$pr_json" | jq -r '
		[ .[]
		  | select(
			(.mergeable // "") == "MERGEABLE"
			and (.reviewDecision // "") == "APPROVED"
			and (.isDraft // false) == false
			and (([.labels[]?.name] | index("hold-for-review")) == null)
		  )
		  | "\(.number // "")\u001e\([.labels[]?.name] | join(","))\u001e\(.author.login? // "unknown")\u001e\(.headRefOid // "")"
		] | .[]' 2>/dev/null) || candidates=""

	local count=0
	local _RS=$'\x1e'
	local pr_number=""
	local labels_str=""
	local pr_author=""
	local head_sha=""
	while IFS="$_RS" read -r pr_number labels_str pr_author head_sha; do
		[[ -n "$pr_number" ]] || continue
		if _pms_pr_counts_for_zero_progress "$repo_slug" "$pr_number" "$labels_str" "$pr_author" "$head_sha"; then
			count=$((count + 1))
		fi
	done <<<"$candidates"

	printf '%s' "$count"
	return 0
}

#######################################
# Run the stuck-merge detector pass for one repo.
#
# Iterates open PRs, identifies eligible-stuck ones past the age threshold,
# classifies each, fires individual escalations / nudges, then runs the
# pattern-cluster outage detector across the full stuck set.
#
# Updates the gauge `pulse_merge_eligible_stuck_pr_count` to the count of
# eligible-stuck PRs observed in this cycle (across all classifications).
#
# Args: $1 = repo_slug
# Returns: 0 always (instrumentation must not break the pulse)
#######################################
#######################################
# Compute Actions runner-queue saturation state for ONE repo per cycle.
# Extracted from pulse_merge_stuck_run_pass (t3211 / GH#21942) to keep
# the caller under the function-complexity gate.
#
# Echoes 4 lines (KEY=VALUE) the caller parses with grep+cut:
#   queued=N
#   in_progress=N
#   ratio=N
#   saturated=0|1
#
# Fails open if the upstream helper is unavailable (partial deploy):
# echoes the safe defaults (all zeros, saturated=0) so the caller's
# downstream logic degrades to pre-t3211 behaviour.
#######################################
_pms_compute_saturation_state() {
	local repo_slug="$1"

	if ! declare -F _check_actions_queue_saturation >/dev/null 2>&1; then
		printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\n'
		return 0
	fi

	local saturation_output=""
	saturation_output=$(_check_actions_queue_saturation "$repo_slug" 2>/dev/null) || saturation_output=""
	if [[ -z "$saturation_output" ]]; then
		printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\n'
		return 0
	fi

	# Pass through the helper's output verbatim — it already emits the
	# canonical KEY=VALUE format and validates each value against the
	# integer range.
	printf '%s' "$saturation_output"
	return 0
}

#######################################
# Print the value of KEY from _pms_compute_saturation_state output.
# Here-string awk lookup: no early-exit pipe reader under the caller's
# pipefail, and a missing key prints "" with exit 0 (GH#36235).
# Args: $1=state (KEY=VALUE lines)  $2=key
#######################################
_pms_saturation_field() {
	local state="$1"
	local key="$2"
	awk -F= -v key="$key" '$1 == key { print $2; exit }' <<<"$state"
	return 0
}
