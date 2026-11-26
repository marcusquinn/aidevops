#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Claim Task ID — Args, Validation, Labels and Platform Sub-Library
# =============================================================================
# Extracted from claim-task-id.sh (GH#20224 headroom split). Pure move.
#
# Usage: source "${SCRIPT_DIR}/claim-task-id-args.sh"
#
# Dependencies: shared-constants.sh, issue-sync-lib.sh and the global variables
# declared in claim-task-id.sh (REPO_PATH, REMOTE_NAME, TASK_*, ...).
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_CLAIM_TASK_ID_ARGS_LIB_LOADED:-}" ]] && return 0
_CLAIM_TASK_ID_ARGS_LIB_LOADED=1

# Load project-level config from .aidevops.json in the repo root.
# Populates REMOTE_NAME and COUNTER_BRANCH unless already set by CLI flags.
# Requires: jq (optional — silently skipped if not installed).
load_project_config() {
	local repo_path="$1"
	local config_file="${repo_path}/.aidevops.json"

	if [[ ! -f "$config_file" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		log_warn ".aidevops.json found but jq is not installed — project config ignored"
		return 0
	fi

	log_info "Loading project config from .aidevops.json"

	local remote_val counter_branch_val default_branch_val
	remote_val=$(jq -r '.remote // empty' "$config_file" 2>/dev/null || true)
	counter_branch_val=$(jq -r '.counter_branch // empty' "$config_file" 2>/dev/null || true)
	default_branch_val=$(jq -r '.default_branch // empty' "$config_file" 2>/dev/null || true)

	# CLI flags take precedence over config file
	if [[ -n "$remote_val" ]] && [[ "$_REMOTE_NAME_SET" == "false" ]]; then
		REMOTE_NAME="$remote_val"
		log_info "remote set from .aidevops.json: $REMOTE_NAME"
	fi

	if [[ -n "$counter_branch_val" ]] && [[ "$_COUNTER_BRANCH_SET" == "false" ]]; then
		COUNTER_BRANCH="$counter_branch_val"
		_COUNTER_BRANCH_SET=true
		log_info "counter_branch set from .aidevops.json: $COUNTER_BRANCH"
	fi

	if [[ -n "$default_branch_val" ]]; then
		DEFAULT_BRANCH="$default_branch_val"
		_DEFAULT_BRANCH_SET=true
		log_info "default_branch set from .aidevops.json: $DEFAULT_BRANCH"
	fi

	return 0
}

# Extract hashtags from text and convert to comma-separated labels
extract_hashtags() {
	local text="$1"
	local tags=""

	while [[ "$text" =~ \#([a-zA-Z0-9_-]+) ]]; do
		local tag="${BASH_REMATCH[1]}"
		if [[ -n "$tags" ]]; then
			tags="${tags},${tag}"
		else
			tags="$tag"
		fi
		text="${text#*#"${tag}"}"
	done

	echo "$tags"
}

# Post-parse validation + label normalization. Extracted from parse_args
# (t2838) to keep that function under the function-complexity gate. Runs
# after the option-parser loop completes — never invoked directly.
_validate_and_normalize_args() {
	# Validate batch size
	if [[ "$ALLOC_COUNT" -lt 1 ]]; then
		log_error "Allocation count must be >= 1"
		exit 1
	fi

	# t2838: validate --parent-issue if supplied. Regex rejects 0 and
	# leading-zero forms — GitHub issue numbers are always >=1, and #0
	# resolves to null on the GraphQL side which produces confusing
	# behaviour downstream.
	if [[ -n "$PARENT_ISSUE_NUM" ]] && ! [[ "$PARENT_ISSUE_NUM" =~ ^[1-9][0-9]*$ ]]; then
		log_error "--parent-issue requires a positive integer issue number (got: '$PARENT_ISSUE_NUM')"
		exit 1
	fi

	# Maintenance actions never allocate, so do not require a task title.
	if [[ -z "$TASK_TITLE" && "$ALLOC_COUNT" -eq 1 && "$SYNC_COUNTER_BRANCH" != true && "$REPAIR_COUNTER_BRANCH" != true ]]; then
		log_error "Missing required argument: --title (or use --count N for bulk allocation)"
		exit 1
	fi

	# Auto-extract hashtags from title if no labels provided
	if [[ -n "$TASK_TITLE" ]] && [[ -z "$TASK_LABELS" ]]; then
		local extracted_tags
		extracted_tags=$(extract_hashtags "$TASK_TITLE")
		if [[ -n "$extracted_tags" ]]; then
			TASK_LABELS="$extracted_tags"
			log_info "Auto-extracted labels from title: $TASK_LABELS"
		fi
	fi

	# t2436: Normalise tag aliases via map_tags_to_labels so that callers
	# passing --labels "parent" get "parent-task" (not a bare "parent" label).
	# map_tags_to_labels is sourced from issue-sync-lib.sh at top of this file.
	# 2>/dev/null || true: silently swallows command-not-found if lib unavailable.
	if [[ -n "$TASK_LABELS" ]]; then
		local _normalised_labels=""
		_normalised_labels=$(map_tags_to_labels "$TASK_LABELS" 2>/dev/null) || true
		[[ -n "$_normalised_labels" ]] && TASK_LABELS="$_normalised_labels"
		TASK_LABELS=$(_dedupe_csv_labels "$TASK_LABELS")
	fi

	# GH#21991: advisory structural check on --description before issue creation.
	# Non-blocking by default; set AIDEVOPS_BODY_FORMAT_STRICT=1 to hard-fail.
	_validate_description_format
	if ! _validate_interactive_dispatch_scope; then
		exit 1
	fi
	return 0
}

# _warn_interactive_scope_missing_paths — GH#38978: warn (never fail) about
# literal Files Scope paths missing from the default branch and not declared
# `NEW: path`. The author can still correct a wrong path; a worker reads it as
# an instruction to create the file (GH#38966).
_warn_interactive_scope_missing_paths() {
	local body="$1"
	local missing_path="" missing_paths=""
	declare -F _brief_files_scope_missing_paths >/dev/null 2>&1 || return 0
	missing_paths=$(_brief_files_scope_missing_paths "$body" "$REPO_PATH") || missing_paths=""
	while IFS= read -r missing_path; do
		[[ -n "$missing_path" ]] || continue
		log_warn "Files Scope path not on the default branch: ${missing_path}"
		log_warn "  if intentionally new, declare \`NEW: ${missing_path}\` under ### Files to Modify; otherwise correct it"
	done <<<"$missing_paths"
	return 0
}

# _validate_interactive_dispatch_scope — fail before allocation when an
# interactive session files auto-dispatch work without a canonical Files Scope.
# An explicit pending hold withholds auto-dispatch from the created issue
# (GH#30325), so the gh_create_issue scope gate cannot always see the intent,
# and issue-first (GH#34232) issues dispatch immediately. The author has the
# most context, so ask now; unscoped briefs from other paths are dispatched with
# worker-owned scope discovery (GH#33243) so findings are never lost.
_validate_interactive_dispatch_scope() {
	[[ "$NO_ISSUE" == true || "$DRY_RUN" == true ]] && return 0
	[[ -n "$TASK_DESCRIPTION" ]] || return 0
	[[ "$TASK_LABELS" =~ (^|,)auto-dispatch(,|$) ]] || return 0
	[[ "$(detect_session_origin 2>/dev/null || true)" == "interactive" ]] || return 0

	local scope_lib="${SCRIPT_DIR}/pre-dispatch-validator-lib-brief-scope.sh"
	local fmt_helper="${SCRIPT_DIR}/issue-body-format-helper.sh"
	local body="$TASK_DESCRIPTION" normalized=""
	[[ -r "$scope_lib" ]] || return 0
	if [[ -n "$TASK_BRIEF_FILE" && -f "$TASK_BRIEF_FILE" && -r "$TASK_BRIEF_FILE" ]]; then
		body+=$'\n\n'"$(<"$TASK_BRIEF_FILE")"
	fi
	# shellcheck source=./pre-dispatch-validator-lib-brief-scope.sh
	# shellcheck disable=SC1091
	source "$scope_lib"
	# Normalization derives Files Scope from explicit "Files to Modify" paths.
	if [[ -x "$fmt_helper" ]]; then
		normalized=$("$fmt_helper" normalize "$body" 2>/dev/null) && body="$normalized"
	fi
	_brief_requires_files_scope "$body" 1 || return 0
	if _brief_files_scope_has_path "$body"; then
		_warn_interactive_scope_missing_paths "$body"
		return 0
	fi

	log_error "auto-dispatch brief has no canonical Files Scope; add before claiming:"
	log_error "  ### Files Scope"
	log_error "  - \`repo/relative/existing-file\`"
	log_error "  - \`repo/relative/new-file\`"
	log_error "One exact path per line: no EDIT:/NEW: prefix, no globs, nothing after it."
	log_error "Or declare \`EDIT: path[:lines]\` bullets under '### Files to Modify'; they normalize."
	log_error "Planning-only work: start the body with 'Planning-only:' instead."
	log_error "You hold the most context now; without it the worker must rediscover the scope (GH#33243)."
	return 1
}

# _dedupe_csv_labels — preserve first occurrence while removing duplicate labels.
# GitHub ultimately deduplicates applied labels, but keeping the argv clean avoids
# duplicate-label warnings/noise in tests and wrapper fallbacks.
_dedupe_csv_labels() {
	local labels_csv="$1"
	local result=""
	local label=""
	local trimmed=""
	local -a label_arr=()
	IFS=',' read -r -a label_arr <<<"$labels_csv"
	for label in "${label_arr[@]}"; do
		trimmed="${label#"${label%%[![:space:]]*}"}"
		trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
		[[ -z "$trimmed" ]] && continue
		if [[ ",${result}," == *",${trimmed},"* ]]; then
			continue
		fi
		if [[ -n "$result" ]]; then
			result="${result},${trimmed}"
		else
			result="$trimmed"
		fi
	done
	printf '%s\n' "$result"
	return 0
}

# _validate_description_format — run structural lint on TASK_DESCRIPTION.
# Called at the end of _validate_and_normalize_args (GH#21991).
# Advisory by default; AIDEVOPS_BODY_FORMAT_STRICT=1 hard-fails on non-dispatchable.
# Skipped when: --no-issue, --dry-run, empty description, or helper unavailable.
_validate_description_format() {
	# Skip when issue creation is not happening or description is absent
	[[ "$NO_ISSUE" == true || "$DRY_RUN" == true ]] && return 0
	[[ -z "$TASK_DESCRIPTION" ]] && return 0

	local fmt_helper="${SCRIPT_DIR}/issue-body-format-helper.sh"
	[[ ! -x "$fmt_helper" ]] && return 0

	local rc=0
	"$fmt_helper" check "$TASK_DESCRIPTION" || rc=$?

	# Exit 1 from helper = non-dispatchable body
	if [[ $rc -eq 1 && "${AIDEVOPS_BODY_FORMAT_STRICT:-0}" != "1" ]]; then
		# Advisory only — already warned via helper's log_warn calls.
		rc=0
	fi
	return $rc
}

# _validate_description_scope_before_allocation — reject bodies that issue
# composition would refuse, before advancing the CAS counter. GH#33527: run
# the exact post-allocation gates (_compose_issue_body) on the same inputs —
# description normalization and the caller brief's scope-check — so a body
# cannot pass here and then fail after an ID is spent.
_validate_description_scope_before_allocation() {
	[[ "$NO_ISSUE" == true || "$DRY_RUN" == true || "$OFFLINE_MODE" == true ]] && return 0

	local fmt_helper="${SCRIPT_DIR}/issue-body-format-helper.sh"
	local readiness_helper="${SCRIPT_DIR}/brief-readiness-helper.sh"

	if [[ -n "$TASK_DESCRIPTION" && -x "$fmt_helper" ]]; then
		if ! "$fmt_helper" normalize "$TASK_DESCRIPTION" >/dev/null; then
			log_error "Description body cannot be canonicalized before task-ID allocation."
			log_error "Recovery: under an existing '### Files Scope', use bare '- path/to/file' bullets."
			return 1
		fi
	fi

	if [[ -n "$TASK_BRIEF_FILE" && -f "$TASK_BRIEF_FILE" && -r "$TASK_BRIEF_FILE" && -r "$readiness_helper" ]]; then
		if ! bash "$readiness_helper" scope-check "$(<"$TASK_BRIEF_FILE")" >&2; then
			log_error "Brief file ${TASK_BRIEF_FILE} fails the Files Scope check; no task ID was allocated."
			log_error "Recovery: under '### Files Scope', list one bare '- path/to/file' (or '- \`path\`') bullet per line, with no notes."
			return 1
		fi
	fi
	return 0
}

# t2436: Scan TODO.md for the task entry matching task_id and derive
# creation-time labels from its tags. Closes the race window where
# parent-task (and other protected labels) would otherwise only be applied
# by the asynchronous issue-sync workflow triggered on a TODO.md push.
#
# Called after the task ID is allocated (so it is present in TODO.md when
# the maintainer pre-wrote the entry before claiming) and before issue
# creation. Non-blocking — returns empty string on any failure.
#
# Arguments:
#   $1 - task_id (e.g. t2436)
#   $2 - repo_path
# Outputs comma-separated label names on stdout. Empty if not found or no tags.
_scan_todo_labels_for_task() {
	local task_id="$1"
	local repo_path="$2"
	local todo_file="${repo_path}/TODO.md"

	[[ -z "$task_id" || ! -f "$todo_file" ]] && return 0

	# Find the task line matching the task ID (active or completed).
	# The pattern anchors to the start of the line to avoid matching
	# sub-task IDs (e.g. t2436.1) as the parent t2436.
	local task_line
	task_line=$(grep -m1 -E "^[[:space:]]*-[[:space:]]\[.\][[:space:]]*${task_id}([[:space:]]|\.|$)" \
		"$todo_file" 2>/dev/null || echo "")
	[[ -z "$task_line" ]] && return 0

	# Extract hashtags — mirrors parse_task_line() in issue-sync-lib.sh.
	local tags
	tags=$(printf '%s' "$task_line" | grep -oE '#[a-z][a-z0-9-]*' | tr '\n' ',' | sed 's/,$//')
	[[ -z "$tags" ]] && return 0

	# Convert tags to labels via the shared resolver.
	# map_tags_to_labels() is sourced from issue-sync-lib.sh at top of this file.
	# 2>/dev/null || true: silently swallows command-not-found if lib unavailable.
	local derived_labels=""
	derived_labels=$(map_tags_to_labels "$tags" 2>/dev/null) || true
	[[ -n "$derived_labels" ]] && echo "$derived_labels"
	return 0
}

# Detect git platform from remote URL
detect_platform() {
	local remote_url
	remote_url=$(cd "$REPO_PATH" && git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "")

	if [[ -z "$remote_url" ]]; then
		echo "unknown"
		return
	fi

	if [[ "$remote_url" =~ github\.com ]]; then
		echo "github"
	elif [[ "$remote_url" =~ gitlab\.com ]]; then
		echo "gitlab"
	elif [[ "$remote_url" =~ gitea ]]; then
		echo "gitea"
	else
		echo "unknown"
	fi
}

# Check if CLI tool is available
check_cli() {
	local platform="$1"

	case "$platform" in
	github)
		command -v gh &>/dev/null && return 0
		;;
	gitlab)
		command -v glab &>/dev/null && return 0
		;;
	esac

	return 1
}

# Create GitHub issue (post-allocation, non-blocking)
# t1324: Delegates to issue-sync-helper.sh push when available for rich
# issue bodies, proper labels (including auto-dispatch), and duplicate
# detection. Falls back to bare gh issue create if helper not found.
# t2548: Guarantees TODO.md entry after verified issue creation on both paths.
create_github_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"
	local canonical_labels="$labels"
	local skip_wrapper_auto_assignment=0
	if [[ ",${canonical_labels}," == *",auto-dispatch,"* ||
		",${canonical_labels}," == *",parent-task,"* ]]; then
		skip_wrapper_auto_assignment=1
	fi

	cd "$repo_path" || return 1

	# t2548: extract task_id once — used on both creation paths to write
	# the TODO.md entry after verified issue creation.
	local _task_id_for_todo=""
	[[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*) ]] && _task_id_for_todo="${BASH_REMATCH[1]}"

	# t2442: resolve repo slug once — used both by the delegation path
	# and the bare-fallback path for the parent-task warn call. Must run
	# BEFORE delegation because the delegation branch returns early.
	local _slug_for_warn=""
	_slug_for_warn=$(_extract_github_slug "$repo_path" "${REMOTE_NAME:-origin}")

	# Try rich delegation first (t1324)
	local issue_num
	if issue_num=$(AIDEVOPS_PLANNING_PUBLICATION_STATE="$TASK_PUBLICATION_STATE" \
		_try_issue_sync_delegation "$title" "$repo_path"); then
		_auto_assign_issue "$issue_num" "$repo_path"
		_interactive_session_auto_claim_new_task "$issue_num" "$repo_path"
		_lock_maintainer_issue_at_creation "$issue_num" "$repo_path"
		# t2838: explicit sub-issue link when --parent-issue N was supplied.
		# Delegation path goes through gh_create_issue → _gh_auto_link_sub_issue
		# wrapper which DOES detect the Parent: line, but we re-run the helper
		# defensively in case the wrapper's detector misses (different body
		# composition path). Idempotent: addSubIssue swallows duplicates.
		_link_parent_issue_post_create "$issue_num" "$repo_path"
		# t2548: ensure TODO.md has the entry. On the delegation path
		# issue-sync-helper.sh _push_process_task silently returns SKIPPED
		# when the task line is absent from TODO.md — issue is created but
		# TODO never written. This call closes that gap idempotently.
		if ! _converge_created_issue_ref \
			"$_task_id_for_todo" "$issue_num" "$title" "$labels" "$repo_path"; then
			log_warn "Delegated issue #${issue_num}, but failed to persist task mapping for ${_task_id_for_todo}"
			return 1
		fi
		# t2442: warn if parent-task label applied but body has no markers.
		# The delegation path creates the issue via issue-sync-helper.sh
		# cmd_push which ALREADY fires this warn — so we skip here to
		# avoid duplicate comments. The bare-fallback path below runs the
		# warn unconditionally because it uses `gh issue create` directly.
		echo "$issue_num"
		return 0
	fi

	# Dedup check before bare creation (t1446)
	local dup_rc=0
	issue_num=$(_check_duplicate_issue "$title") || dup_rc=$?
	if [[ $dup_rc -eq 2 ]]; then
		# GH#33157: the ID belongs to another session's differently titled issue.
		log_error "TASK_ID_COLLISION: ${_task_id_for_todo} is already in use by another issue; no issue created. Re-run to allocate the next ID."
		return 1
	fi
	if [[ $dup_rc -eq 0 ]]; then
		# GH#22381: issue-sync-helper.sh push can create the issue but emit no
		# parseable number. The duplicate lookup then recovers the issue number;
		# stamp/verify TODO.md before reporting success so dispatchability sees
		# the same state as the returned issue number.
		if [[ "$TASK_PUBLICATION_STATE" == pending ]] &&
			! _verify_publication_pending_label "$issue_num" "$_slug_for_warn"; then
			log_warn "Recovered issue #${issue_num}, but publication:pending could not be verified"
			return 1
		fi
		if ! _converge_created_issue_ref \
			"$_task_id_for_todo" "$issue_num" "$title" "$labels" "$repo_path"; then
			log_warn "Recovered issue #${issue_num}, but failed to persist task mapping for ${_task_id_for_todo}"
			return 1
		fi
		echo "$issue_num"
		return 0
	fi

	_create_github_issue_fallback "$title" "$description" "$labels" "$repo_path" \
		"$_task_id_for_todo" "$_slug_for_warn" "$skip_wrapper_auto_assignment"
	return $?
}

# Create a structured issue when delegation and duplicate recovery did not succeed.
_create_github_issue_fallback() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"
	local _task_id_for_todo="$5"
	local _slug_for_warn="$6"
	local skip_wrapper_auto_assignment="$7"
	local canonical_labels="$labels"
	local issue_num

	# Fallback: bare issue creation with structured body.
	# t3039: use gh_create_issue (REST-aware wrapper, from shared-gh-wrappers.sh sourced
	# transitively via shared-constants.sh) instead of raw gh issue create so that issue
	# creation succeeds even when GraphQL is exhausted (the "fallback also uses GraphQL"
	# failure mode observed at GraphQL=0/5000).
	local create_args=(--title "$title")
	# Pass --repo explicitly so the REST fallback path inside gh_create_issue
	# can build the /repos/{owner}/{repo}/issues endpoint without relying on cwd
	# (t3039: _rest_issue_create requires --repo).
	[[ -n "$_slug_for_warn" ]] && create_args+=(--repo "$_slug_for_warn")

	local body=""
	local compose_rc=0
	body=$(_compose_issue_body "$title" "$description") || compose_rc=$?
	# The task ID is already secured. Preserve the typed composition outcome so
	# supplied-but-invalid input is never misreported as an absent description.
	if [[ $compose_rc -ne 0 || -z "$body" ]]; then
		[[ $compose_rc -eq 0 ]] && compose_rc="$CLAIM_COMPOSE_FAILED_RC"
		_report_issue_body_compose_failure "$title" "$compose_rc"
		return 1
	fi
	create_args+=(--body "$body")

	# Published tasks retain the historical status default. Tasks created before
	# their planning reaches the default branch withhold positive dispatch labels
	# and carry an independently enforced publication blocker instead.
	if [[ "$TASK_PUBLICATION_STATE" == pending ]]; then
		labels=$(_publication_pending_labels "$labels")
	fi

	# t2789: Ensure canonical new issues are immediately dispatchable by applying
	# status:available when the caller did not specify any status:* label.
	# Without this default, new issues have no status label, and the pulse
	# dispatcher's candidate filter (which requires status:available) skips
	# them entirely until a human or downstream process labels them.
	# Callers that pass an explicit status:* (e.g. status:queued, status:blocked,
	# status:in-review) are respected verbatim — this only fills the gap.
	if [[ "$TASK_PUBLICATION_STATE" == "canonical" && ",${labels}," != *",status:"* ]]; then
		if [[ -n "$labels" ]]; then
			labels="${labels},status:available"
		else
			labels="status:available"
		fi
	fi
	[[ -n "$labels" ]] && labels=$(_dedupe_csv_labels "$labels")

	# Pass labels to gh_create_issue; origin label is appended automatically by
	# the wrapper (avoids duplicate-label injection, t3039).
	[[ -n "$labels" ]] && create_args+=(--label "$labels")

	local issue_url
	if ! issue_url=$(AIDEVOPS_GH_SKIP_AUTO_ASSIGNMENT="$skip_wrapper_auto_assignment" \
		gh_create_issue "${create_args[@]}" 2>&1); then
		log_warn "Failed to create GitHub issue: $issue_url"
		return 1
	fi

	# Extract issue number from the GitHub URL pattern (/issues/NNN).
	# gh_create_issue captures stderr via 2>&1, so $issue_url may contain
	# log lines like "[INFO] ... per t2157" whose trailing digits would
	# match a naive '[0-9]+$' pattern, producing phantom numbers. Anchoring
	# to the URL shape (/issues/NNN) is immune to log message contamination.
	# Capture the last /issues/NNN match to defend against future multi-line URL
	# output (t3039/GH#21770), while avoiding echo and a multi-process pipeline.
	issue_num=$(printf '%s\n' "$issue_url" | awk 'match($0, /\/issues\/[0-9]+/) { num=substr($0, RSTART + 8, RLENGTH - 8) } END { print num }')

	if [[ -z "$issue_num" ]]; then
		log_warn "Failed to extract issue number from: $issue_url"
		return 1
	fi
	if [[ "$TASK_PUBLICATION_STATE" == pending ]] &&
		! _verify_publication_pending_label "$issue_num" "$_slug_for_warn"; then
		log_warn "Created issue #${issue_num}, but publication:pending could not be verified"
		return 1
	fi

	_finalize_github_issue_fallback "$issue_num" "$repo_path" "$title" "$labels" "$body" "$_slug_for_warn"

	# Persist the canonical labels, not the publication-filtered API labels.
	if ! _converge_created_issue_ref \
		"$_task_id_for_todo" "$issue_num" "$title" "$canonical_labels" "$repo_path"; then
		log_warn "Created issue #${issue_num}, but failed to persist task mapping for ${_task_id_for_todo}"
		return 1
	fi

	echo "$issue_num"
	return 0
}

# Preserve bare-creation assignment, locking, relationships and parent warnings.
_finalize_github_issue_fallback() {
	local issue_num="$1"
	local repo_path="$2"
	local title="$3"
	local labels="$4"
	local body="$5"
	local _slug_for_warn="$6"

	# Auto-assign to current user to prevent duplicate dispatch
	_auto_assign_issue "$issue_num" "$repo_path"
	_interactive_session_auto_claim_new_task "$issue_num" "$repo_path"

	# Lock maintainer/worker issues at creation to prevent comment
	# prompt-injection. Issues created by the maintainer or their workers
	# are implementation targets, not discussion threads. External
	# contributor issues are left unlocked for community interaction.
	_lock_maintainer_issue_at_creation "$issue_num" "$repo_path"

	# t2838: explicit sub-issue link when --parent-issue N was supplied.
	# Bare path uses raw `gh issue create` which BYPASSES gh_create_issue
	# and therefore the _gh_auto_link_sub_issue wrapper — without this
	# call, the Parent: body line stays prose-only and the GitHub
	# sub-issue relationship field is never populated. Idempotent.
	_link_parent_issue_post_create "$issue_num" "$repo_path"

	# Sync parent-child and blocked-by relationships (GH#18735)
	# The rich delegation path (issue-sync-helper.sh push) handles this
	# automatically; the bare fallback needs an explicit call.
	local task_id_for_rels=""
	[[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*) ]] && task_id_for_rels="${BASH_REMATCH[1]}"
	if [[ -n "$task_id_for_rels" && -f "$repo_path/TODO.md" ]]; then
		local sync_helper="${SCRIPT_DIR}/issue-sync-helper.sh"
		if [[ -x "$sync_helper" ]]; then
			"$sync_helper" relationships "$task_id_for_rels" >/dev/null 2>&1 || true
		fi
	fi

	# t2442: post the parent-task no-markers warning if this issue was
	# created with the `parent-task` label but the body lacks phase/children
	# markers. Only fires on the bare-fallback path; the delegation path
	# above runs the warn inside issue-sync-helper.sh cmd_push.
	# Non-blocking: failure is silent (try/true).
	if [[ -n "$_slug_for_warn" && ",${labels}," == *",parent-task,"* ]]; then
		if declare -F _parent_body_has_phase_markers >/dev/null 2>&1 && \
			declare -F _post_parent_task_no_markers_warning >/dev/null 2>&1; then
			if ! _parent_body_has_phase_markers "$body"; then
				_post_parent_task_no_markers_warning "$_slug_for_warn" "$issue_num" || true
			fi
		fi
	fi

	return 0
}

# Framework routing guard (GH#5149)
# Warns when claim-task-id.sh is called from a non-aidevops repo with a title
# that contains framework-level indicators. This catches the most common failure
# mode: workers creating framework tasks in project repos.
#
# This is a WARN, not a block — the worker may have a legitimate reason to
# allocate an ID in the current repo (e.g., a project-level task that happens
# to mention a framework script). The warning surfaces the routing question
# so the worker can make an explicit decision.
check_framework_routing() {
	local title="$1"
	local repo_path="$2"

	# Skip if no title (batch mode) or if explicitly suppressed
	[[ -z "$title" ]] && return 0
	if [[ "${SKIP_FRAMEWORK_ROUTING_CHECK:-}" == true ]]; then
		log_info "SKIP_FRAMEWORK_ROUTING_CHECK=true — suppressing framework routing warning for: $title (GH#20146 audit)"
		return 0
	fi

	# Check if we're already in the aidevops repo — no routing needed
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
	if grep -qE "marcusquinn/aidevops(\.git)?$" <<<"$remote_url"; then
		return 0
	fi

	# Check if the title contains framework-level indicators
	local framework_helper="${SCRIPT_DIR}/framework-issue-helper.sh"
	if [[ ! -x "$framework_helper" ]]; then
		return 0
	fi

	local detection_result
	detection_result=$("$framework_helper" detect "$title" 2>/dev/null || echo "project")

	if [[ "$detection_result" == "framework" ]]; then
		log_warn "FRAMEWORK ROUTING WARNING (GH#5149):"
		log_warn "  Title contains framework-level indicators: $title"
		log_warn "  You are in: $repo_path"
		log_warn "  Framework issues should be filed on marcusquinn/aidevops, not this repo."
		log_warn "  Use instead: framework-issue-helper.sh log --title \"$title\""
		log_warn "  To suppress this warning: SKIP_FRAMEWORK_ROUTING_CHECK=true claim-task-id.sh ..."
		log_warn "  Proceeding with allocation in current repo (override if intentional)."
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Pre-flight label validation (t2800)
#
# Validates that every label in TASK_LABELS exists in the target repo before
# the CAS counter is advanced. An invalid label currently causes issue creation
# to fail AFTER the counter has been incremented, stranding the task ID.
#
# Approach (A) — validate first, abort early:
#   1. Fetch the repo's label list once via `gh label list`, cache in a session
#      temp file ($AIDEVOPS_LABEL_CACHE_FILE or auto-created).
#   2. Split TASK_LABELS on comma, trim whitespace, grep-check each against cache.
#   3. Any missing label → log which labels are invalid + lookup command → return 1.
#   4. API failure during list → fail-open (skip validation, let issue creation
#      fail naturally; the caller can then recover using approach B — label-after-create).
#
# Exit codes (for _validate_labels_exist):
#   0  - All labels exist (or validation skipped / fail-open).
#   1  - One or more labels are invalid.
#
# Call site exits with code 3 (invalid-labels) if this returns 1.
# Skipped when: --skip-label-validation, --offline, --dry-run, --no-issue,
#               no labels provided, platform != github, or gh not available.
# ---------------------------------------------------------------------------

# _extract_github_slug — extract owner/repo slug from a git remote URL.
# Args: $1 repo_path, $2 remote_name (default: origin).
# Prints the slug (owner/repo) on stdout; prints nothing on failure.
_extract_github_slug() {
	local repo_path="$1"
	local remote_name="${2:-origin}"
	git -C "$repo_path" remote get-url "$remote_name" 2>/dev/null \
		| sed 's|.*github\.com[:/]||;s|\.git$||' || true
	return 0
}

# _auto_create_blocked_by_label — create a missing blocked-by:tNNN / blocked-by:GH#NNN /
# blocked-by:#NNN label in the repo when it does not yet exist.
# Updates the session label cache on success.
# Args: $1 repo_slug (owner/repo), $2 label name (e.g. "blocked-by:t324"), $3 cache_file path.
# Returns: 0 = label created (or already exists), 1 = creation failed (rate limit / permission).
# Callers MUST treat a non-zero return as a validation error — do NOT use || true (GH#21633).
_auto_create_blocked_by_label() {
	local repo_slug="$1"
	local label="$2"
	local cache_file="$3"
	local predecessor="${label#blocked-by:}"

	if gh label create "$label" --repo "$repo_slug" \
		--color "5319E7" \
		--description "Blocked by predecessor task ${predecessor}" \
		>/dev/null 2>&1; then
		# Append to session cache so subsequent lookups in this invocation hit
		printf '%s\n' "$label" >>"$cache_file" 2>/dev/null || true
		log_info "Auto-created label '${label}' in ${repo_slug} (t2823/t2800 auto-create exception)"
		return 0
	else
		log_warn "Could not auto-create label '${label}' in ${repo_slug} (rate limit or permission) — proceeding without it"
		return 1
	fi
}

# _prepare_label_cache — populate the session label cache ($AIDEVOPS_LABEL_CACHE_FILE)
# from `gh label list` once per session; reuse it when already populated.
# Args: $1 repo_slug (owner/repo).
# Returns: 0 = cache ready (path in AIDEVOPS_LABEL_CACHE_FILE), 1 = unavailable (fail-open).
_prepare_label_cache() {
	local repo_slug="$1"
	local cache_file="${AIDEVOPS_LABEL_CACHE_FILE:-}"

	if [[ -z "$cache_file" ]]; then
		cache_file=$(mktemp /tmp/aidevops-label-cache-XXXXXX 2>/dev/null) || return 1
		export AIDEVOPS_LABEL_CACHE_FILE="$cache_file"
		# shellcheck disable=SC2064
		trap "rm -f '${cache_file}' 2>/dev/null || true" EXIT
	fi

	# Fetch label list if cache is empty or stale (> 0 bytes = populated)
	if [[ ! -s "$cache_file" ]]; then
		if ! gh label list --repo "$repo_slug" --limit 1000 \
			--json name --jq '.[].name' >"$cache_file" 2>/dev/null; then
			log_warn "Label list query failed (rate limit or network) — skipping label validation (fail-open)"
			return 1
		fi
	fi
	return 0
}

# _ensure_publication_pending_label — make sure the framework-owned
# publication:pending label exists before the counter advances. The issue
# projection (_publication_pending_labels) always appends it for pending tasks,
# so a fresh repository without it would strand the allocated ID.
# Args: $1 repo_slug (owner/repo).
# Returns: 0 = exists/created (or fail-open when labels cannot be listed),
#          1 = creation failed — caller must abort before allocation.
_ensure_publication_pending_label() {
	local repo_slug="$1"
	local label="publication:pending"

	[[ -z "$repo_slug" ]] && return 0
	command -v gh >/dev/null 2>&1 || return 0
	gh auth status >/dev/null 2>&1 || return 0

	_prepare_label_cache "$repo_slug" || return 0
	local cache_file="${AIDEVOPS_LABEL_CACHE_FILE:-}"
	[[ -n "$cache_file" ]] || return 0

	grep -Fxq "$label" "$cache_file" 2>/dev/null && return 0

	if gh label create "$label" --repo "$repo_slug" \
		--color "FBCA04" \
		--description "Opt-in hold until TODO+brief land on default branch; auto-clears, Pulse repairs after 6h" \
		>/dev/null 2>&1; then
		printf '%s\n' "$label" >>"$cache_file" 2>/dev/null || true
		log_info "Auto-created label '${label}' in ${repo_slug}"
		return 0
	fi

	log_error "Could not create required label '${label}' in ${repo_slug} (permission or rate limit)"
	log_error "  Create it manually and re-run: gh label create '${label}' --repo \"${repo_slug}\""
	log_error "  Claim aborted — counter NOT advanced."
	return 1
}

# _validate_labels_exist — check that every label in $2 exists in repo $1.
# Args: $1 repo_slug (owner/repo), $2 comma-separated label names.
# Returns: 0 = all valid (or fail-open), 1 = invalid labels found.
#
# Auto-create exception (GH#21474): labels matching ^blocked-by:(t[0-9]+|GH#[0-9]+|#[0-9]+)$
# are auto-created when missing — they are a deterministic function of the predecessor
# task ID and safe to create on demand. Creation failure aborts the claim (GH#21633).
# All other invalid labels still abort (exit 3).
_validate_labels_exist() {
	local repo_slug="$1"
	local labels_csv="$2"

	[[ -z "$repo_slug" || -z "$labels_csv" ]] && return 0

	# Require gh CLI and authentication
	command -v gh >/dev/null 2>&1 || return 0
	gh auth status >/dev/null 2>&1 || return 0

	# Populate label cache once per session (or reuse if already set).
	# API failure → fail-open: skip validation, proceed with claim.
	_prepare_label_cache "$repo_slug" || return 0
	local cache_file="${AIDEVOPS_LABEL_CACHE_FILE:-}"
	[[ -n "$cache_file" ]] || return 0

	# Regex for the auto-create exception class (blocked-by:tNNN / blocked-by:GH#NNN / blocked-by:#NNN).
	# _normalise_ref() in _detect_predecessor_refs produces GH#NNN for GitHub issue refs,
	# so the GH# prefix must be included or those normalised labels fail the check and abort.
	# All other invalid labels still abort.
	local _BLOCKED_BY_AUTO_CREATE_REGEX='^blocked-by:(t[0-9]+|GH#[0-9]+|#[0-9]+)$'

	# Check each label against the cache
	local invalid_labels=""
	local label
	# Split on comma, trim whitespace
	local IFS_SAVE="$IFS"
	IFS=','
	local -a label_arr
	read -ra label_arr <<<"$labels_csv"
	IFS="$IFS_SAVE"

	for label in "${label_arr[@]}"; do
		label="${label#"${label%%[![:space:]]*}"}"  # trim leading whitespace
		label="${label%"${label##*[![:space:]]}"}"  # trim trailing whitespace
		[[ -z "$label" ]] && continue
		if ! grep -Fxq "$label" "$cache_file" 2>/dev/null; then
			# Auto-create exception: blocked-by:tNNN / blocked-by:GH#NNN / blocked-by:#NNN
			# labels are synthesised by t2823 from description text and may not exist yet in
			# fresh consumer repos. Create them on demand (t2800/GH#21474).
			# If creation fails (e.g. insufficient permissions), treat the label as invalid
			# so the claim aborts BEFORE the counter is advanced — preserves atomic-claim
			# guarantee (GH#21633: stranded task ID on failed auto-create).
			if [[ "$label" =~ $_BLOCKED_BY_AUTO_CREATE_REGEX ]]; then
				if ! _auto_create_blocked_by_label "$repo_slug" "$label" "$cache_file"; then
					# Creation failed — fall through to the invalid_labels accumulator below.
					: # (intentional — do not continue, let the guard below record the label)
				else
					# Creation succeeded — skip normal validation for this label.
					continue
				fi
			fi
			if [[ -n "$invalid_labels" ]]; then
				invalid_labels="${invalid_labels}, '${label}'"
			else
				invalid_labels="'${label}'"
			fi
		fi
	done

	if [[ -n "$invalid_labels" ]]; then
		log_error "Pre-flight label validation failed — label(s) do not exist in this repo: ${invalid_labels}"
		log_error ""
		log_error "Each invalid label must be created before claiming, OR use one of these options:"
		log_error "  (a) Create the label and re-run:"
		log_error "        gh label create '<name>' --repo \"${repo_slug}\" --color '0075ca' --description '...'"
		log_error "  (b) If the label was auto-emitted from a --description predecessor reference,"
		log_error "      skip it: re-run with --no-blocked-by (dependency still recorded in body text)"
		log_error "  (c) Use a different blocking label that already exists, e.g. 'status:blocked'"
		log_error ""
		log_error "  Claim aborted — counter NOT advanced."
		return 1
	fi

	return 0
}
