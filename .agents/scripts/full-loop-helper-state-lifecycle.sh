#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Lifecycle State -- shared initialization, gates, and orchestration
# =============================================================================
# Caller-facing entrypoint for full-loop-helper-state.sh. Source this file only.
# Persistence, phases, and commands live in sibling modules. Gate functions stay
# here to preserve direct-extraction test contracts and function identity keys.
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning, etc.)
#   - full-loop-helper-evidence.sh (fresh merged-PR evidence)
#   - Globals: STATE_DIR, STATE_FILE, DEFAULT_MAX_*, HEADLESS, _FG_PID_FILE
#   - Functions: is_headless, print_phase (defined in orchestrator before sourcing)
# Part of aidevops framework: https://aidevops.sh
# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
# Preserve the existing include guard and shared constant initialization order.
[[ -n "${_FULL_LOOP_STATE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_STATE_LIB_LOADED=1
_FULL_LOOP_RELEASE_NOT_REQUESTED="not-requested"
_FULL_LOOP_RELEASE_PUBLISHED="published"
_FULL_LOOP_RELEASE_SUPERSEDED="superseded"
_FULL_LOOP_RELEASE_STRICT="strict"
_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED="published-reconcile"
_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED="authorized-published-reconcile"
_FULL_LOOP_RELEASE_EVIDENCE_RECEIPT_CONFLICT="receipt-conflict"
_FULL_LOOP_RELEASE_ROLE_AGGREGATED="aggregated"
_FULL_LOOP_WORKFLOW_EVENT_RELEASE="release"
_FULL_LOOP_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_VERSION_TAG_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+$'
_FULL_LOOP_JSON_NUMBER_TYPE="number"
_FULL_LOOP_EXECUTOR_INITIALIZED="initialized-only"
_FULL_LOOP_EXECUTOR_IN_PROGRESS="in-progress"
_FULL_LOOP_PHASE_FAILED="failed"
_FULL_LOOP_PHASE_RUNNING="running"
_FULL_LOOP_PHASE_WAITING="waiting"
_FULL_LOOP_PHASE_COMPLETED="completed"
_FULL_LOOP_PHASE_TASK="task"
_FULL_LOOP_RESOURCE_NONE="none"
_FULL_LOOP_BOOL_TRUE="true"
_FULL_LOOP_BOOL_FALSE="false"
FULL_LOOP_TRANSITION_LOCK_TOKEN=""
FULL_LOOP_TRANSITION_LOCK_DEPTH=0

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=release-authorization-manifest-helper.sh
source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"

if [[ -f "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh" ]]; then
	# shellcheck source=./full-loop-cleanup-receipt.sh
	source "${SCRIPT_DIR}/full-loop-cleanup-receipt.sh"
fi

# shellcheck source=./full-loop-helper-evidence.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-evidence.sh"

# shellcheck source=./full-loop-helper-state-lifecycle-persistence.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-state-lifecycle-persistence.sh"

# shellcheck source=./full-loop-helper-state-lifecycle-phases.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-state-lifecycle-phases.sh"

# --- Gate Checks ---

_issue_thread_is_trusted_maintainer_only() {
	local issue_num="$1"
	local repo="$2"
	local issue_author_association="${3:-}"

	[[ -n "$issue_num" && -n "$repo" ]] || return 1
	case "$issue_author_association" in
	OWNER | MEMBER) ;;
	*)
		return 1
		;;
	esac

	local comments_json
	comments_json=$(gh api "repos/${repo}/issues/${issue_num}/comments" \
		--paginate --slurp 2>/dev/null) || return 1
	[[ -n "$comments_json" && "$comments_json" != "null" ]] || comments_json="[]"

	local untrusted_comment_count
	untrusted_comment_count=$(printf '%s' "$comments_json" | jq -r --arg array_type "array" '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[] | select((.author_association // "") as $a | ($a != "OWNER" and $a != "MEMBER")) ]
		| length
	' 2>/dev/null) || return 1
	[[ "$untrusted_comment_count" =~ ^[0-9]+$ ]] || return 1

	if [[ "$untrusted_comment_count" -eq 0 ]]; then
		return 0
	fi

	return 1
}

_linked_issue_author_allows_start() {
	local issue_num="$1"
	local repo="$2"
	local raw_issue="$3"
	local author_meta="" author_association="NONE" author_type="" author_login="" external_source="$_FULL_LOOP_BOOL_FALSE"

	author_meta=$(printf '%s' "$raw_issue" | jq -r \
		'[.author_association // "NONE", .user.type // "", .user.login // "", (([.labels[]?.name] | index("external-contributor") != null) | tostring)] | join("|")' 2>/dev/null) || author_meta=""
	if [[ -n "$author_meta" ]]; then
		IFS='|' read -r author_association author_type author_login external_source <<<"$author_meta"
	fi
	[[ -n "$author_association" ]] || author_association="NONE"
	if [[ "$author_type" == "Bot" && "$external_source" != "$_FULL_LOOP_BOOL_TRUE" ]]; then
		return 0
	fi

	local authority_rc=1
	if [[ "$external_source" != "$_FULL_LOOP_BOOL_TRUE" ]] && declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1; then
		authority_rc=0
		_gh_actor_has_repo_write_authority "$repo" "$author_login" "$author_association" || authority_rc=$?
	elif [[ "$external_source" != "$_FULL_LOOP_BOOL_TRUE" ]]; then
		authority_rc=2
	fi
	if [[ "$authority_rc" -eq 0 ]]; then
		return 0
	fi

	local approval_helper="${SCRIPT_DIR}/approval-helper.sh"
	local verification=""
	if [[ -x "$approval_helper" ]]; then
		verification=$("$approval_helper" verify "$issue_num" "$repo" 2>/dev/null) || true
	fi
	if [[ "$verification" == "VERIFIED" ]]; then
		return 0
	fi
	if [[ "$verification" == "NO_APPROVAL" ]]; then
		#aidevops:trust-boundary -- containment is best-effort; this live gate is authoritative.
		if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
			gh_issue_edit_safe "$issue_num" --repo "$repo" \
				--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
		else
			gh issue edit "$issue_num" --repo "$repo" \
				--add-label "needs-maintainer-review" >/dev/null 2>&1 || true
		fi
	fi

	_FULL_LOOP_LINKED_AUTHOR_GATE_REASON="author_association=${author_association}, external_source=${external_source}, authority=${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown}, approval=${verification:-unavailable}"
	return 1
}

_linked_issue_trust_blocks_start() {
	local issue_num="$1"
	local repo="$2"
	local raw_issue="$3"
	local labels="$4"
	local issue_author_association="$5"
	_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON=""

	if printf '%s\n' "$labels" | grep -qxF 'needs-maintainer-review'; then
		if ! is_headless && _issue_thread_is_trusted_maintainer_only \
			"$issue_num" "$repo" "$issue_author_association"; then
			print_info "Issue #${issue_num} has needs-maintainer-review, but this interactive thread is maintainer-only; continuing without treating NMR as a maintainer hold."
			return 1
		fi
		_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON="Issue #${issue_num} has \`needs-maintainer-review\` label and is not a trusted maintainer-only interactive thread — a maintainer must approve before work begins.\n"
		return 0
	fi

	if ! _linked_issue_author_allows_start "$issue_num" "$repo" "$raw_issue"; then
		_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON="Issue #${issue_num} does not have trusted author authority or verified maintainer approval (${_FULL_LOOP_LINKED_AUTHOR_GATE_REASON:-unknown}) — work cannot begin merely because the review label is absent.\n"
		return 0
	fi
	return 1
}

_linked_issue_structural_blocker_reasons() {
	local issue_num="$1"
	local repo="$2"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	local found=false

	[[ -x "$dedup_helper" ]] || return 1

	local dedup_out
	dedup_out=$("$dedup_helper" enumerate-blockers "$issue_num" "$repo" "${AIDEVOPS_SESSION_USER:-${USER:-}}" 2>/dev/null || true)
	local _blocker_line
	while IFS= read -r _blocker_line; do
		[[ -z "$_blocker_line" ]] && continue
		case "$_blocker_line" in
		*PARENT_TASK_BLOCKED*)
			found=true
			printf 'Issue #%s carries the %s label (decomposition tracker, not a worker target). Decompose into child phase issues, or remove the label if this is no longer a parent.\n' "$issue_num" "\`parent-task\`"
			;;
		*NO_AUTO_DISPATCH_BLOCKED*)
			# no-auto-dispatch is a worker-routing hold, not a prohibition on
			# explicitly authorized interactive implementation. Keep the hold intact
			# so Pulse cannot dispatch a parallel worker while local work proceeds.
			if [[ "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" == "1" ]] && ! is_headless; then
				continue
			fi
			found=true
			printf 'Issue #%s carries the %s label (explicit worker-dispatch hold). Remove the label only if you intentionally want worker dispatch, or use the interactive issue-start implementation path.\n' "$issue_num" "\`no-auto-dispatch\`"
			;;
		*HOLD_FOR_REVIEW_BLOCKED*)
			found=true
			printf 'Issue #%s carries the %s label (maintainer-requested review hold). Remove the label when the hold is resolved.\n' "$issue_num" "\`hold-for-review\`"
			;;
		esac
	done <<<"$dedup_out"

	[[ "$found" == "$_FULL_LOOP_BOOL_TRUE" ]] || return 1
	return 0
}

# Pre-start maintainer gate check (GH#17810, t2890).
# Extracts the first issue number from the prompt and verifies the linked
# issue does not have needs-maintainer-review label or, for headless workers,
# a missing assignee (GH#17810). Interactive maintainer sessions may self-claim
# an unassigned issue supplied directly in the prompt (GH#22854). Then inherits
# the pulse-side structural dispatch gates via
# dispatch-dedup-helper.sh::enumerate-blockers so /full-loop honors hard
# structural holds. no-auto-dispatch remains enforced for workers while the
# explicit interactive issue-start path may implement locally without removing
# the worker-routing hold. Mirrors .github/workflows/maintainer-gate.yml.
#
# Returns:
#   0 — gate passes (safe to start)
#   1 — gate blocked (do NOT start work)
#
# Skips gracefully when:
#   - No issue number found in prompt (not all tasks have linked issues)
#   - Issue is closed (already reviewed)
# Once a prompt resolves to an issue and repository, metadata lookup failures
# block rather than silently converting unknown input into trusted input.
_check_linked_issue_gate() {
	local prompt="$1"
	local repo="${2:-}"

	# Extract first issue number from prompt — look for #NNN or issue/NNN patterns
	local issue_num
	issue_num=$(echo "$prompt" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
	if [[ -z "$issue_num" ]]; then
		# No issue number in prompt — skip gate (not all tasks reference issues)
		return 0
	fi

	# Resolve repo from git remote if not provided
	if [[ -z "$repo" ]]; then
		repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||;s|\.git$||' || true)
	fi
	if [[ -z "$repo" ]]; then
		if is_headless; then
			print_error "Maintainer gate pre-check: cannot resolve repository for linked issue #${issue_num}"
			return 1
		fi
		return 0
	fi

	# Fetch issue data. Every mode fails closed because the prompt has already
	# supplied both an issue reference and repository context.
	# Keep stderr separate: successful shim diagnostics must not corrupt JSON.
	local raw_issue issue_error_file issue_error=""
	issue_error_file=$(mktemp) || {
		print_error "Maintainer gate pre-check: cannot capture linked issue #${issue_num} lookup errors — refusing start"
		return 1
	}
	raw_issue=$(gh api "repos/${repo}/issues/${issue_num}" 2>"$issue_error_file") || {
		issue_error=$(<"$issue_error_file")
		rm -f "$issue_error_file"
		print_error "Maintainer gate pre-check: could not fetch linked issue #${issue_num} — refusing start"
		[[ -z "$issue_error" ]] || printf 'gh lookup error: %s\n' "$issue_error" >&2
		return 1
	}
	rm -f "$issue_error_file"

	local state labels assignees issue_author_association
	state=$(echo "$raw_issue" | jq -r '.state' 2>/dev/null || echo "unknown")
	labels=$(echo "$raw_issue" | jq -r '[.labels[]?.name] | .[]' 2>/dev/null || true)
	assignees=$(echo "$raw_issue" | jq -r '[.assignees[]?.login] | .[]' 2>/dev/null || true)
	issue_author_association=$(echo "$raw_issue" | jq -r '.author_association // ""' 2>/dev/null || true)

	# Skip closed issues — they've already been reviewed
	if [[ "$state" == "closed" ]]; then
		return 0
	fi

	local blocked=false reasons=""

	# Check 1: labels are advisory; author authority or signed approval is also
	# required when the creation-time review label is absent.
	if _linked_issue_trust_blocks_start "$issue_num" "$repo" "$raw_issue" \
		"$labels" "$issue_author_association"; then
		blocked=true
		reasons="${reasons}${_FULL_LOOP_LINKED_TRUST_BLOCKER_REASON}"
	fi

	# Check 2: no assignee (exempt quality-debt issues per GH#6623).
	# GH#22854: OWNER/MEMBER interactive sessions can fix an unassigned issue by
	# claiming it immediately after this gate. Keep the stricter block for
	# headless workers so dispatched automation still requires an explicit claim.
	if [[ -z "$assignees" ]]; then
		if ! is_headless; then
			: # interactive self-claim path handles this below
		elif echo "$labels" | grep -q 'quality-debt'; then
			: # exempt
		else
			blocked=true
			reasons="${reasons}Issue #${issue_num} has no assignee — assign the issue before starting work.\n"
		fi
	fi

	# Check 3 (t2890, t2894): inherit pulse-side structural dispatch gates by
	# calling dispatch-dedup-helper.sh::enumerate-blockers — which runs ALL
	# unconditional label checks in a single pass and emits each matching
	# signal on a separate line. Replaces the former is-assigned call + case
	# statement that short-circuited on the first match, so users now see
	# every blocker in one /full-loop invocation instead of one per retry.
	# Cost-budget, hydration window, and ownership-by-other are intentionally
	# out of scope (need nuanced interactive UX). Fail-open on missing helper
	# or empty stdout. Author/API trust checks above remain independently fail-closed.
	local structural_reasons
	if structural_reasons=$(_linked_issue_structural_blocker_reasons "$issue_num" "$repo"); then
		blocked=true
		reasons="${reasons}${structural_reasons}"
	fi

	if [[ "$blocked" == "$_FULL_LOOP_BOOL_TRUE" ]]; then
		print_error "Maintainer gate pre-check BLOCKED — cannot start work:"
		printf '%b' "$reasons" >&2
		printf "To unblock: address the blocker labels above; use signed approval only for \`needs-maintainer-review\`, and remove \`hold-for-review\` only when the maintainer hold is resolved.\n" >&2
		return 1
	fi

	return 0
}

# Interactive claim (t2056 hardening): structurally enforce issue ownership
# when an interactive session starts a full-loop. Extracts issue number from
# the prompt and calls interactive-session-helper.sh claim, which applies
# status:in-review + self-assigns + posts a claim comment. This replaces
# prompt-only enforcement that was missed in practice (GH#18775 incident).
#
# Skips silently when:
#   - Headless mode (workers have their own dispatch claim)
#   - No issue number in prompt
#   - interactive-session-helper.sh not available
#
# Always returns 0 — claim failure is non-blocking (warn-and-continue).
_auto_claim_interactive() {
	local prompt="$1"

	# Skip in headless — workers use dispatch claims, not interactive claims
	if is_headless; then
		return 0
	fi
	# Opt-out for scripted bulk worktree operations
	if [[ -n "${AIDEVOPS_SKIP_AUTO_CLAIM:-}" ]]; then
		return 0
	fi

	# Extract issue number (same pattern as _check_linked_issue_gate)
	local issue_num
	issue_num=$(echo "$prompt" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
	if [[ -z "$issue_num" ]]; then
		return 0
	fi

	# Resolve repo slug
	local repo
	repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||;s|\.git$||' || true)
	if [[ -z "$repo" ]]; then
		return 0
	fi

	# Call the interactive claim helper — it handles offline, idempotency,
	# maintainer-permission checks, self-assign, status label, stamp, and
	# claim comment internally. External upstream repos skip the claim path.
	local helper="${SCRIPT_DIR}/interactive-session-helper.sh"
	if [[ -x "$helper" ]]; then
		local -a claim_args=(claim "$issue_num" "$repo" --worktree "$(pwd)")
		if [[ "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" == "1" ]]; then
			claim_args+=(--implementing)
		fi
		"$helper" "${claim_args[@]}" || true
		print_info "Interactive claim checked: #${issue_num} in ${repo}"
	else
		print_warning "interactive-session-helper.sh not found — skipping interactive claim"
	fi
	return 0
}

# shellcheck source=./full-loop-helper-state-lifecycle-commands.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime via SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-state-lifecycle-commands.sh"
