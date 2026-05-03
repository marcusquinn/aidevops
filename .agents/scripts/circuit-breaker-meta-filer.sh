#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# circuit-breaker-meta-filer.sh — File root-cause meta-issues when per-issue
# circuit breakers (t2007 cost, t2769 no_work) trip (t3076).
#
# Background:
#   The existing breakers halt dispatch and apply needs-maintainer-review.
#   NMR is a maintainer-queue dead-end — it surfaces the problem but does
#   not move it forward. This helper turns each trip into a self-healing
#   cycle:
#
#     breaker fires → forensics gathered → meta-issue filed with hypothesis
#     → worker dispatched on meta-issue → fix lands → original unblocks
#
#   Original gets `blocked-by:#<meta>` + a marker comment on the original
#   recording the meta-issue number. Idempotent — second trip on the same
#   original does NOT file a duplicate meta-issue.
#
# Subcommands:
#   file       File a meta-issue for a tripped circuit breaker.
#   help       Show usage.
#
# Environment:
#   AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE  if "1", the file subcommand
#                                               is a no-op (emergency bypass).
#   AIDEVOPS_CIRCUIT_BREAKER_META_LABELS        override labels applied to
#                                               the meta-issue (comma-separated).
#                                               Default:
#                                                 auto-dispatch,tier:thinking,
#                                                 model:opus-4-7,bug,pulse,
#                                                 framework,circuit-breaker-meta
#   AIDEVOPS_CIRCUIT_BREAKER_META_FORENSIC_LINES
#                                               max log lines included in the
#                                               body. Default 50.
#   PULSE_LOG                                   pulse log path (default
#                                               ~/.aidevops/logs/pulse.log).
#   DISPATCH_STAGES_TSV                         dispatch stages file (default
#                                               ~/.aidevops/logs/dispatch-stages.tsv).
#
# Exit codes:
#   0 = meta-issue created OR idempotent skip OR disabled (bypass)
#   1 = invalid args / missing required field
#   2 = gh API failure
#
# Wired by:
#   - worker-lifecycle-common.sh   (t2769 no_work breaker trip)
#   - dispatch-dedup-cost.sh       (t2007 cost breaker trip)
#
# Released by:
#   - pulse-merge.sh               (when meta-PR merges, removes blocked-by
#                                  on the original; clears NMR if no other
#                                  breaker markers remain)

set -uo pipefail

# Resolve SCRIPT_DIR for both direct execution and sourcing.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# shellcheck source=./shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"

readonly _CB_META_MARKER='circuit-breaker-meta-filed'
readonly _CB_META_DEFAULT_LABELS='auto-dispatch,tier:thinking,model:opus-4-7,bug,pulse,framework,circuit-breaker-meta'
readonly _CB_BREAKER_COST='cost'
readonly _CB_BREAKER_NO_WORK='no_work'
readonly _CB_LABEL_COST='t2007 cost'
readonly _CB_LABEL_NO_WORK='t2769 no_work'

#######################################
# Idempotency check: has a meta-issue marker already been recorded
# on this issue? Returns the existing meta-issue number on stdout
# when found, empty otherwise.
#
# Marker format on the original issue (in a comment body):
#   <!-- circuit-breaker-meta-filed:#<NNN> -->
#
# Args: $1=issue_number, $2=repo_slug
# Stdout: existing meta-issue number, or empty
# Returns: 0 always (best-effort)
#######################################
_cb_meta_existing() {
	local issue_number="$1"
	local repo_slug="$2"
	local marker_re
	marker_re='<!-- '"${_CB_META_MARKER}"':#([0-9]+) -->'

	local comments
	comments=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate 2>/dev/null) || comments=""
	if [[ -z "$comments" || "$comments" == "null" ]]; then
		return 0
	fi

	local hit
	hit=$(printf '%s' "$comments" |
		jq -r '.[].body // ""' 2>/dev/null |
		grep -oE "$marker_re" |
		head -1 |
		grep -oE '#[0-9]+' |
		tr -d '#' || true)
	[[ -n "$hit" ]] && printf '%s' "$hit"
	return 0
}

#######################################
# Gather pulse log lines mentioning the issue.
# Args: $1=issue_number, $2=max_lines
# Stdout: log slice (may be empty)
#######################################
_cb_meta_log_slice() {
	local issue_number="$1"
	local max_lines="${2:-50}"
	local pulse_log="${PULSE_LOG:-${HOME}/.aidevops/logs/pulse.log}"

	[[ -r "$pulse_log" ]] || return 0

	# Match either "#21840" or " 21840" (TSV-style) — bound match to
	# avoid spurious matches on "#218400" by using grep -wE.
	grep -E "(^|[^0-9])#?${issue_number}([^0-9]|$)" "$pulse_log" 2>/dev/null |
		tail -n "$max_lines" || true
	return 0
}

#######################################
# Gather dispatch-stages.tsv lines for the issue.
# Args: $1=issue_number
# Stdout: TSV slice (may be empty)
#######################################
_cb_meta_stages_slice() {
	local issue_number="$1"
	local stages_tsv="${DISPATCH_STAGES_TSV:-${HOME}/.aidevops/logs/dispatch-stages.tsv}"

	[[ -r "$stages_tsv" ]] || return 0

	# TSV columns: timestamp, issue_ref, repo_slug, stage, ms
	grep -E $'\t#?'"${issue_number}"$'\t' "$stages_tsv" 2>/dev/null |
		tail -50 || true
	return 0
}

#######################################
# Compose the meta-issue body. t1900-compliant — includes Files Scope and
# verification steps so the worker dispatched against the meta-issue can
# act without re-discovering context.
#
# Args:
#   $1=issue_number  (original issue)
#   $2=repo_slug
#   $3=breaker_type  (cost|no_work)
#   $4=failure_count
#   $5=reason        (free-text, may be empty)
#   $6=tier          (used by cost breaker; may be empty)
#   $7=spent_tokens  (used by cost breaker; may be empty)
#   $8=budget_tokens (used by cost breaker; may be empty)
#######################################
#######################################
# Body section: intro (What/Why/Tracking/Hypothesis intro).
# Args: $1=issue, $2=slug, $3=breaker_label, $4=trip_marker,
#        $5=failure_count, $6=safe_reason, $7=cost_block
#######################################
_cb_meta_body_intro() {
	local issue_number="$1" repo_slug="$2" breaker_label="$3"
	local trip_marker="$4" failure_count="$5" safe_reason="$6"
	local cost_block="$7"

	cat <<EOF
<!-- aidevops:generator=circuit-breaker-meta-filer -->

## What

Diagnose why the **${breaker_label}** circuit breaker fired on ${repo_slug}#${issue_number} after ${failure_count} consecutive worker failure(s), and ship the systemic fix that prevents the same class of failure on subsequent issues.

The breaker tripping is the SYMPTOM. This issue is for finding and fixing the ROOT CAUSE — typically a dispatch path bug, a worker setup race, an exit-classifier defect, or a brief-quality gap that caused workers to crash before reading the brief.

## Why

The existing breaker (\`${breaker_label}\`) halts dispatch and applies \`needs-maintainer-review\` on the original, but does not move the underlying problem forward. NMR is a maintainer-queue dead-end. Filing this meta-issue converts the trip into a self-healing cycle: forensics → hypothesis → fix → original unblocks automatically.

The original (#${issue_number}) gets \`blocked-by:#<this>\` and clears automatically when this meta-issue's PR merges (handled by \`pulse-merge.sh::_unblock_circuit_breaker_meta_original\`).

## Tracking original issue

- Original: ${repo_slug}#${issue_number}
- Breaker: \`${breaker_label}\` (\`${trip_marker}\`)
- Failure count: ${failure_count}
- Last failure reason: ${safe_reason}${cost_block}

## Hypothesis (starting point — verify first)

The most common root causes for \`${breaker_label}\` trips are:

EOF
	return 0
}

#######################################
# Body section: hypothesis bullets specific to the breaker class.
# Args: $1=breaker_type
#######################################
_cb_meta_body_hypothesis() {
	local breaker_type="$1"

	if [[ "$breaker_type" == "$_CB_BREAKER_NO_WORK" ]]; then
		cat <<'EOF'
- **Worker exit classifier defect** — workers killed by SIGTERM/SIGKILL before producing a session may be misclassified as `reason=clean` (see #21818 / #21754). Check `headless-runtime-failure.sh::classify_worker_exit` and the wait_status sentinel propagation.
- **Plugin init crash** — opencode plugin (`opencode-aidevops`) failing during boot due to FD exhaustion, env pollution, or a stale cache. Check the worker's stderr in `~/.aidevops/logs/worker-*-stderr.log`.
- **Branch naming race** — worker tries to checkout a branch that another concurrent worker just consumed.
- **Auth refresh race** — `gh` token rotation interrupts the worker mid-setup.
- **Footprint overlap** — another open issue/PR touches the same files; `dispatch-dedup-helper.sh` defers and the worker exits clean (this is the normal/expected case for `no_work` and should not trip the breaker — investigate why it did).
EOF
	else
		cat <<'EOF'
- **Brief is unimplementable as written** — refine scope or split the task; flag for `needs-decomposition`.
- **Hidden blocker** — missing dependency, environment issue, design conflict that cumulative worker attempts could not resolve.
- **Worker stuck in a loop** — model can't decompose the task; consider tier escalation OR scope reduction.
- **Wrong tier assigned** — downgrade a `tier:thinking` task to `standard`, or vice versa.
- **Breaker firing too early** — calibration problem in `dispatch-cost-budgets.conf`; investigate whether the budget is reasonable for the tier.
EOF
	fi
	return 0
}

#######################################
# Body section: How / Forensics / Acceptance / Verification.
# Args: $1=issue, $2=slug, $3=max_lines, $4=log_slice, $5=stages_slice
#######################################
_cb_meta_body_guidance() {
	local issue_number="$1" repo_slug="$2" max_lines="$3"
	local log_slice="$4" stages_slice="$5"

	cat <<EOF

## How (mentor's guidance for the next worker)

Treat the original (#${issue_number}) as evidence, not as the work to do. The work is **here** — diagnose the systemic gap that lets workers fail in this pattern, ship the fix, and the original unblocks itself.

### Files to inspect first

- \`EDIT: .agents/scripts/dispatch-dedup-cost.sh\` — t2007 cost breaker definition and trip site.
- \`EDIT: .agents/scripts/dispatch-dedup-stale.sh\` — stale-assignment recovery; false stale recovery can record \`stale_timeout\` / \`no_work\` fast-fails without a worker reaching the brief.
- \`EDIT: .agents/scripts/worker-lifecycle-common.sh\` — t2769 no_work breaker definition and trip site (around the \`no_work_loop\` marker).
- \`EDIT: .agents/scripts/headless-runtime-failure.sh\` — worker exit classifier (the prime suspect for misclassification).
- \`EDIT: .agents/scripts/circuit-breaker-meta-filer.sh\` — this filer; if it filed too eagerly, fix the trip-detection upstream rather than the filer.
- \`EDIT: .agents/scripts/pulse-merge.sh::_handle_post_merge_actions\` — meta-PR merge cleanup that unblocks the original.

### Reference pattern

- Existing breaker NMR application paths in \`worker-lifecycle-common.sh\` (no_work) and \`dispatch-dedup-cost.sh\` (cost) for the trip → label → comment flow that this filer hooks into.
- \`dispatch-dedup-stale.sh::_is_stale_assignment\` for the comment-activity pagination path; it must aggregate all pages before sorting activity timestamps.
- \`pulse-nmr-approval.sh::_nmr_application_is_circuit_breaker_trip\` for the marker-recognition pattern (this filer's marker \`${_CB_META_MARKER}\` is also recognised).

### Forensics: pulse log slice (last ${max_lines} lines mentioning the issue)

\`\`\`
${log_slice:-(no matching log lines)}
\`\`\`

### Forensics: dispatch stages (\`dispatch-stages.tsv\` slice)

\`\`\`
${stages_slice:-(no matching stage records)}
\`\`\`

### Acceptance

1. Root cause identified and named explicitly in the PR description (which file/function/race).
2. Fix lands as a normal PR with \`Resolves #<this>\` (NOT \`Resolves #${issue_number}\` — this meta-issue is the unit of work, the original is downstream).
3. PR merge automatically removes \`blocked-by:#<this>\` from #${issue_number} via \`_unblock_circuit_breaker_meta_original\`.
4. If no other circuit-breaker markers remain on #${issue_number}, NMR is also cleared automatically.
5. A regression test exists for the specific failure mode identified (test in \`.agents/scripts/tests/\`).

### Verification

\`\`\`bash
# After the fix lands and #${issue_number} unblocks, dispatch should proceed normally:
gh issue view ${issue_number} --repo ${repo_slug} --json labels --jq '[.labels[].name]'
# Expect: no needs-maintainer-review, no blocked-by:#<this>

# Re-run the regression test:
bash .agents/scripts/tests/test-circuit-breaker-meta-filer.sh
\`\`\`
EOF
	return 0
}

#######################################
# Body section: Files Scope / Tier Checklist / Auto-filed-by tail.
# Args: (none)
#######################################
_cb_meta_body_tail() {
	cat <<'EOF'

## Files Scope

- `.agents/scripts/dispatch-dedup-cost.sh`
- `.agents/scripts/dispatch-dedup-stale.sh`
- `.agents/scripts/worker-lifecycle-common.sh`
- `.agents/scripts/headless-runtime-failure.sh`
- `.agents/scripts/headless-runtime-helper.sh`
- `.agents/scripts/circuit-breaker-meta-filer.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/pulse-merge-feedback.sh`
- `.agents/scripts/pulse-nmr-approval.sh`
- `.agents/scripts/tests/**`

## Tier Checklist

- [x] Architecture: cross-cutting between dispatch + lifecycle + merge paths.
- [x] LLM judgment needed for hypothesis selection and root-cause naming.
- [x] No verbatim oldString/newString possible — design + integration work.

## Auto-filed by

`circuit-breaker-meta-filer.sh` (t3076). To suppress: set `AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE=1` in the pulse environment.
EOF
	return 0
}

_cb_meta_body() {
	local issue_number="$1"
	local repo_slug="$2"
	local breaker_type="$3"
	local failure_count="$4"
	local reason="${5:-}"
	local tier="${6:-}"
	local spent="${7:-}"
	local budget="${8:-}"

	local max_lines="${AIDEVOPS_CIRCUIT_BREAKER_META_FORENSIC_LINES:-50}"

	local breaker_label="$_CB_LABEL_NO_WORK" trip_marker='cost-circuit-breaker:no_work_loop'
	if [[ "$breaker_type" == "$_CB_BREAKER_COST" ]]; then
		breaker_label="$_CB_LABEL_COST"
		trip_marker='cost-circuit-breaker:fired'
	fi

	local log_slice stages_slice
	log_slice=$(_cb_meta_log_slice "$issue_number" "$max_lines")
	stages_slice=$(_cb_meta_stages_slice "$issue_number")

	local cost_block=""
	if [[ "$breaker_type" == "$_CB_BREAKER_COST" && -n "$spent" && -n "$budget" ]]; then
		cost_block="
- **Tier**: \`tier:${tier:-standard}\`
- **Spent**: ${spent} tokens
- **Budget**: ${budget} tokens"
	fi

	local safe_reason
	safe_reason=$(_sanitize_markdown "${reason:-(not provided)}" 2>/dev/null || printf '%s' "${reason:-(not provided)}")

	_cb_meta_body_intro "$issue_number" "$repo_slug" "$breaker_label" \
		"$trip_marker" "$failure_count" "$safe_reason" "$cost_block"
	_cb_meta_body_hypothesis "$breaker_type"
	_cb_meta_body_guidance "$issue_number" "$repo_slug" "$max_lines" \
		"$log_slice" "$stages_slice"
	_cb_meta_body_tail
	return 0
}

#######################################
# Apply blocked-by:#<meta> label to the original issue and post the
# marker comment that records the meta-issue number for idempotency.
#
# Args: $1=original_issue, $2=repo_slug, $3=meta_issue_number,
#        $4=breaker_type, $5=failure_count
#######################################
_cb_meta_link_original() {
	local original_issue="$1"
	local repo_slug="$2"
	local meta_number="$3"
	local breaker_type="$4"
	local failure_count="$5"

	local breaker_label="$_CB_LABEL_NO_WORK"
	[[ "$breaker_type" == "$_CB_BREAKER_COST" ]] && breaker_label="$_CB_LABEL_COST"

	# Best-effort: ensure the blocked-by label exists, then apply it.
	# We use a per-meta label so multiple concurrent breakers can each
	# unblock independently (matches t2442 parent-task linkage style).
	local blocked_label="blocked-by:#${meta_number}"
	gh issue edit "$original_issue" --repo "$repo_slug" \
		--add-label "$blocked_label" 2>/dev/null || true

	# Marker comment for idempotency. The HTML marker line is the canonical
	# idempotency signal; the human-readable text is for maintainers.
	local body
	body="<!-- ${_CB_META_MARKER}:#${meta_number} -->
## Circuit Breaker Meta-Issue Filed (t3076)

The **${breaker_label}** breaker tripped after ${failure_count} consecutive failure(s) on this issue. A root-cause meta-issue has been filed:

→ Tracking: #${meta_number}

This issue is now \`blocked-by:#${meta_number}\` and will unblock automatically when the meta-issue's PR merges. NMR will also clear if no other breaker markers remain.

_Auto-filed by \`circuit-breaker-meta-filer.sh\` (t3076). Set \`AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE=1\` to suppress._"

	gh_issue_comment "$original_issue" --repo "$repo_slug" \
		--body "$body" 2>/dev/null || true

	return 0
}

#######################################
# CLI: file a meta-issue for a tripped circuit breaker.
#
# Required:
#   --issue NNN
#   --repo SLUG
#   --breaker {cost|no_work}
#   --failure-count N
#
# Optional:
#   --reason TEXT       last failure reason (free-text)
#   --tier T            tier label (cost breaker only)
#   --spent N           token spend (cost breaker only)
#   --budget N          token budget (cost breaker only)
#
# Stdout: meta-issue URL on success
# Returns: 0=success or idempotent skip, 1=arg error, 2=gh failure
#######################################
#######################################
# Parse `cmd_file` long-options into globals consumed by cmd_file.
# Sets: _CB_ARG_ISSUE, _CB_ARG_REPO, _CB_ARG_BREAKER, _CB_ARG_FAILURE_COUNT,
#       _CB_ARG_REASON, _CB_ARG_TIER, _CB_ARG_SPENT, _CB_ARG_BUDGET.
# Args: $@=cmd_file argv
# Returns: 0 on success, 1 on unknown flag.
#######################################
_cb_meta_parse_file_args() {
	_CB_ARG_ISSUE="" _CB_ARG_REPO="" _CB_ARG_BREAKER="" _CB_ARG_FAILURE_COUNT=""
	_CB_ARG_REASON="" _CB_ARG_TIER="" _CB_ARG_SPENT="" _CB_ARG_BUDGET=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--issue) _CB_ARG_ISSUE="${2:-}"; shift 2 ;;
		--repo) _CB_ARG_REPO="${2:-}"; shift 2 ;;
		--breaker) _CB_ARG_BREAKER="${2:-}"; shift 2 ;;
		--failure-count) _CB_ARG_FAILURE_COUNT="${2:-}"; shift 2 ;;
		--reason) _CB_ARG_REASON="${2:-}"; shift 2 ;;
		--tier) _CB_ARG_TIER="${2:-}"; shift 2 ;;
		--spent) _CB_ARG_SPENT="${2:-}"; shift 2 ;;
		--budget) _CB_ARG_BUDGET="${2:-}"; shift 2 ;;
		*)
			log_error "[circuit-breaker-meta-filer] unknown arg: $arg" >&2
			return 1
			;;
		esac
	done
	return 0
}

cmd_file() {
	_cb_meta_parse_file_args "$@" || return 1

	local issue_number="$_CB_ARG_ISSUE"
	local repo_slug="$_CB_ARG_REPO"
	local breaker_type="$_CB_ARG_BREAKER"
	local failure_count="$_CB_ARG_FAILURE_COUNT"
	local reason="$_CB_ARG_REASON"
	local tier="$_CB_ARG_TIER"
	local spent="$_CB_ARG_SPENT"
	local budget="$_CB_ARG_BUDGET"

	if [[ "${AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE:-0}" == "1" ]]; then
		log_info "[circuit-breaker-meta-filer] disabled via AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE — skip" >&2
		return 0
	fi

	if [[ -z "$issue_number" || -z "$repo_slug" || -z "$breaker_type" || -z "$failure_count" ]]; then
		log_error "[circuit-breaker-meta-filer] required: --issue --repo --breaker --failure-count" >&2
		return 1
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ ! "$failure_count" =~ ^[0-9]+$ ]]; then
		log_error "[circuit-breaker-meta-filer] --issue and --failure-count must be integers" >&2
		return 1
	fi

	if [[ "$breaker_type" != "$_CB_BREAKER_COST" && "$breaker_type" != "$_CB_BREAKER_NO_WORK" ]]; then
		log_error "[circuit-breaker-meta-filer] --breaker must be '${_CB_BREAKER_COST}' or '${_CB_BREAKER_NO_WORK}'" >&2
		return 1
	fi

	# Idempotency: bail out if a meta-issue already exists for this original.
	local existing_meta
	existing_meta=$(_cb_meta_existing "$issue_number" "$repo_slug")
	if [[ -n "$existing_meta" ]]; then
		log_info "[circuit-breaker-meta-filer] idempotent: meta-issue #${existing_meta} already filed for ${repo_slug}#${issue_number}" >&2
		printf 'https://github.com/%s/issues/%s\n' "$repo_slug" "$existing_meta"
		return 0
	fi

	local body title
	body=$(_cb_meta_body "$issue_number" "$repo_slug" "$breaker_type" \
		"$failure_count" "$reason" "$tier" "$spent" "$budget")

	local breaker_label="$_CB_LABEL_NO_WORK"
	[[ "$breaker_type" == "$_CB_BREAKER_COST" ]] && breaker_label="$_CB_LABEL_COST"
	title="Circuit-breaker meta: diagnose ${breaker_label} trip on ${repo_slug}#${issue_number}"

	local labels="${AIDEVOPS_CIRCUIT_BREAKER_META_LABELS:-${_CB_META_DEFAULT_LABELS}}"

	local meta_url
	if ! meta_url=$(gh_create_issue --repo "$repo_slug" \
		--title "$title" \
		--body "$body" \
		--label "$labels" 2>&1); then
		log_error "[circuit-breaker-meta-filer] gh_create_issue failed: ${meta_url}" >&2
		return 2
	fi

	# Extract issue number from URL
	local meta_number
	meta_number=$(printf '%s' "$meta_url" | grep -oE '[0-9]+$' | head -1)
	if [[ -z "$meta_number" ]]; then
		log_error "[circuit-breaker-meta-filer] could not parse meta-issue number from URL: ${meta_url}" >&2
		return 2
	fi

	_cb_meta_link_original "$issue_number" "$repo_slug" "$meta_number" \
		"$breaker_type" "$failure_count"

	log_success "[circuit-breaker-meta-filer] filed meta-issue ${meta_url} for ${repo_slug}#${issue_number} (${breaker_label}, count=${failure_count})" >&2
	printf '%s\n' "$meta_url"
	return 0
}

#######################################
# Extract the original issue number from a meta-issue's body.
# The meta-issue body contains a "## Tracking original issue" section
# with a line "- Original: <slug>#<NNN>". This function returns that
# number for the given meta-issue number.
#
# Args: $1=meta_issue_number, $2=repo_slug
# Stdout: original issue number, or empty
# Returns: 0 always (best-effort)
#######################################
_cb_meta_extract_original() {
	local meta_number="$1"
	local repo_slug="$2"

	local body
	body=$(gh api "repos/${repo_slug}/issues/${meta_number}" \
		--jq '.body // ""' 2>/dev/null) || body=""
	[[ -z "$body" || "$body" == "null" ]] && return 0

	# Match "- Original: owner/repo#NNN" — slug-aware so cross-repo metas
	# (a future possibility) still resolve to the right number.
	printf '%s' "$body" |
		grep -E '^- Original: ' |
		head -1 |
		grep -oE '#[0-9]+' |
		head -1 |
		tr -d '#' || true
	return 0
}

#######################################
# Check whether any OTHER circuit-breaker trip markers remain in the
# original issue's comments. Used to decide whether NMR can be cleared
# alongside the blocked-by label removal.
#
# Markers checked:
#   cost-circuit-breaker:fired
#   cost-circuit-breaker:no_work_loop
#   stale-recovery-tick:escalated
#   circuit-breaker-escalated
#
# Args: $1=original_issue, $2=repo_slug, $3=meta_number_to_ignore
# Returns: 0 if other markers remain, 1 if none remain (NMR safe to clear)
#######################################
_cb_meta_other_markers_remain() {
	local original_issue="$1"
	local repo_slug="$2"

	local comments
	comments=$(gh api "repos/${repo_slug}/issues/${original_issue}/comments" \
		--paginate 2>/dev/null) || return 0

	local hits
	hits=$(printf '%s' "$comments" |
		jq -r '.[].body // ""' 2>/dev/null |
		grep -cE '(cost-circuit-breaker:(fired|no_work_loop)|stale-recovery-tick:escalated|circuit-breaker-escalated)' \
			2>/dev/null) || hits=0
	[[ "$hits" =~ ^[0-9]+$ ]] || hits=0

	# We expect at least one trip marker (the one this meta-issue resolved).
	# More than one means another breaker also tripped and is still
	# unresolved — keep NMR.
	[[ "$hits" -gt 1 ]] && return 0
	return 1
}

#######################################
# Unblock an original issue when its meta-issue's PR has merged.
# Removes blocked-by:#<meta>; if no other breaker markers remain,
# also clears needs-maintainer-review and posts an unblock comment.
# Idempotent — second call is a no-op.
#
# Args: $1=meta_issue_number, $2=repo_slug
# Returns: 0 on success / no-op, 2 on gh failure
#######################################
cmd_unblock_on_merge() {
	local meta_number=""
	local repo_slug=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--meta)
			meta_number="${2:-}"
			shift 2
			;;
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		*)
			log_error "[circuit-breaker-meta-filer] unblock: unknown arg: $arg" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$meta_number" || -z "$repo_slug" ]]; then
		log_error "[circuit-breaker-meta-filer] unblock: required: --meta --repo" >&2
		return 1
	fi

	local original_issue
	original_issue=$(_cb_meta_extract_original "$meta_number" "$repo_slug")
	if [[ -z "$original_issue" ]]; then
		log_info "[circuit-breaker-meta-filer] unblock: no original-issue line in #${meta_number} body — not a meta-issue, skip" >&2
		return 0
	fi

	local blocked_label="blocked-by:#${meta_number}"
	gh issue edit "$original_issue" --repo "$repo_slug" \
		--remove-label "$blocked_label" 2>/dev/null || true

	local nmr_cleared="no"
	if ! _cb_meta_other_markers_remain "$original_issue" "$repo_slug"; then
		gh issue edit "$original_issue" --repo "$repo_slug" \
			--remove-label "needs-maintainer-review" 2>/dev/null || true
		nmr_cleared="yes"
	fi

	gh_issue_comment "$original_issue" --repo "$repo_slug" \
		--body "<!-- circuit-breaker-meta-unblocked:#${meta_number} -->
## Circuit Breaker Meta-Issue Resolved (t3076)

The meta-issue #${meta_number} (which was diagnosing the breaker trip on this issue) has merged its fix. \`blocked-by:#${meta_number}\` has been removed.

NMR cleared: **${nmr_cleared}** _(no other breaker markers remained)_.

If dispatch should now proceed, the next pulse cycle will pick this up.

_Auto-released by \`circuit-breaker-meta-filer.sh\` (t3076) via \`pulse-merge.sh::_handle_post_merge_actions\`._" 2>/dev/null || true

	log_success "[circuit-breaker-meta-filer] unblocked ${repo_slug}#${original_issue} (meta=#${meta_number}, nmr_cleared=${nmr_cleared})" >&2
	return 0
}

cmd_help() {
	cat <<'EOF'
circuit-breaker-meta-filer.sh — File root-cause meta-issues for tripped breakers (t3076)

USAGE:
  circuit-breaker-meta-filer.sh file --issue NNN --repo SLUG \
    --breaker {cost|no_work} --failure-count N \
    [--reason "text"] [--tier T] [--spent N] [--budget N]

  circuit-breaker-meta-filer.sh unblock-on-merge --meta NNN --repo SLUG

  circuit-breaker-meta-filer.sh help

ENVIRONMENT:
  AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE   set to 1 to disable
  AIDEVOPS_CIRCUIT_BREAKER_META_LABELS         override labels (CSV)
  AIDEVOPS_CIRCUIT_BREAKER_META_FORENSIC_LINES max log lines (default 50)

EXIT CODES:
  0 = filed (or idempotent skip / disabled)
  1 = invalid arguments
  2 = gh API failure

WIRED BY:
  worker-lifecycle-common.sh (t2769 no_work)
  dispatch-dedup-cost.sh     (t2007 cost)

CLEANUP:
  pulse-merge.sh::_unblock_circuit_breaker_meta_original removes
  blocked-by:#<meta> from the original when the meta-PR merges.
EOF
	return 0
}

# Allow sourcing without executing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	subcmd="${1:-help}"
	shift || true
	case "$subcmd" in
	file) cmd_file "$@" ;;
	unblock-on-merge) cmd_unblock_on_merge "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown subcommand: ${subcmd}" >&2
		cmd_help >&2
		exit 1
		;;
	esac
fi
