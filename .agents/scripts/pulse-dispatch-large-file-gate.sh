#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-large-file-gate.sh — Large-file simplification gate — blocks dispatch when issue targets files exceeding LARGE_FILE_LINE_THRESHOLD and creates simplification-debt issues.
#
# Extracted from pulse-dispatch-core.sh (GH#18832) to bring that file
# below the 2000-line simplification gate.
#
# This module is sourced by pulse-dispatch-core.sh. Depends on
# shared-constants.sh and worker-lifecycle-common.sh being sourced first.
#
# Functions in this module (in source order):
#   - _large_file_gate_precheck_labels
#   - _large_file_gate_extract_paths
#   - _large_file_gate_evaluate_target
#   - _large_file_gate_create_debt_issue
#   - _large_file_gate_apply
#   - _large_file_gate_clear_stale_label
#   - _issue_targets_large_files

[[ -n "${_PULSE_DISPATCH_LARGE_FILE_GATE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_LARGE_FILE_GATE_LOADED=1

# Module-level skip pattern used by the large-file gate — files that are
# large by nature and can't/shouldn't be "simplified" (lockfiles, generated
# data, JSON/YAML configs, binary-adjacent formats). GH#17897: also skips
# data files (.json/.yaml/.yml/.toml/.xml/.csv) which are config, not code.
_LFG_SKIP_PATTERN='(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Cargo\.lock|Gemfile\.lock|poetry\.lock|simplification-state\.json|\.min\.(js|css)$|\.json$|\.yaml$|\.yml$|\.toml$|\.xml$|\.csv$)'

#######################################
# Label-based early-exit precheck for the large-file gate.
# Handles GH#18042 self-simplification auto-clear, force_recheck bypass,
# already-labeled short-circuit, already-dispatched skips, and origin:worker
# race-window guard.
#
# Arguments: issue_number, repo_slug, issue_labels (comma-joined), force_recheck
# Exit codes:
#   0 - continue to path extraction
#   1 - caller should `return 1` (no gate, don't re-check)
#   2 - caller should `return 0` (gate already applied, short-circuit)
#######################################
_large_file_gate_precheck_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_labels="$3"
	local force_recheck="$4"

	# GH#18042: Never gate simplification tasks behind the large-file gate.
	# Issues tagged "simplification" or "simplification-debt" exist to reduce
	# the file — blocking them creates a deadlock where the file can never be
	# simplified because the simplification issue is held by the gate.
	# If the label was already applied (e.g., before this fix), auto-clear it.
	if [[ ",$issue_labels," == *",simplification,"* ]] ||
		[[ ",$issue_labels," == *",simplification-debt,"* ]]; then
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			if gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-label "needs-simplification" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Simplification gate auto-cleared for #${issue_number} (${repo_slug}) — issue is itself a simplification task (GH#18042)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] WARN: failed to remove needs-simplification label from #${issue_number} (${repo_slug}); will retry next cycle (GH#18042)" >>"$LOGFILE"
			fi
		fi
		# Always return 1 (don't gate) — the issue IS simplification work
		# regardless of whether the label removal succeeded.
		return 1
	fi

	# t2088: Never gate parent-task / meta issues behind the large-file gate.
	# Parent tasks are never dispatched directly — dispatch is unconditionally
	# blocked by _is_assigned_check_parent_task() in dispatch-dedup-helper.sh
	# (t1986). Applying needs-simplification to them creates confusing label
	# churn: the label is re-added every cycle even after manual removal because
	# the target file is still large, misleading maintainers into thinking
	# simplification is the only remaining gate when in fact the parent-task
	# block is permanent and independent of file size.
	# If the label was already applied (e.g., before this fix), auto-clear it.
	if [[ ",$issue_labels," == *",parent-task,"* ]] ||
		[[ ",$issue_labels," == *",meta,"* ]]; then
		if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
			if gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-label "needs-simplification" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Simplification gate auto-cleared for #${issue_number} (${repo_slug}) — issue is a parent-task/meta, never dispatched directly (t2088)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] WARN: failed to remove needs-simplification label from #${issue_number} (${repo_slug}); will retry next cycle (t2088)" >>"$LOGFILE"
			fi
		fi
		# Always return 1 (don't gate) — parent tasks are never dispatched
		# directly, regardless of whether the label removal succeeded.
		return 1
	fi

	# Skip if already labeled (avoid re-checking every cycle).
	# EXCEPTION (t1998): when called from _reevaluate_simplification_labels,
	# force_recheck is "true" and we bypass this short-circuit. Without the
	# bypass, the re-eval path can never clear a stale label because it
	# always sees an immediate return 0 on labeled issues. This made
	# #18346 and any similar stale issue impossible to unstick even after
	# the target file had been simplified below threshold.
	if [[ "$force_recheck" != "true" ]] &&
		[[ ",$issue_labels," == *",needs-simplification,"* ]]; then
		return 2
	fi
	# Skip if simplification was already done
	if [[ ",$issue_labels," == *",simplified,"* ]]; then
		return 1
	fi

	# GH#17958: Skip if issue is already dispatched (worker actively running).
	# A second pulse cycle can re-evaluate the same issue and post a spurious
	# simplification comment even though the worker is mid-implementation.
	# The gate should only fire for issues that haven't been claimed yet.
	if [[ ",$issue_labels," == *",status:queued,"* ]] ||
		[[ ",$issue_labels," == *",status:in-progress,"* ]]; then
		return 1
	fi
	# Also skip if assigned with origin:worker — worker was dispatched even if
	# status label hasn't been applied yet (race window between assign and label).
	if [[ ",$issue_labels," == *",origin:worker,"* ]]; then
		local assignee_count
		assignee_count=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json assignees --jq '.assignees | length' 2>/dev/null) || assignee_count="0"
		if [[ "$assignee_count" -gt 0 ]]; then
			return 1
		fi
	fi

	return 0
}

#######################################
# Extract candidate file paths from an issue body, preserving any trailing
# ":NNN" or ":START-END" line qualifiers (t2024). Combines two extractors:
#   1. "EDIT:" / "NEW:" / "File:" markers referencing agents/scripts paths.
#   2. Backtick-quoted script paths on lines that ALSO carry an
#      "EDIT:" / "NEW:" / "File:" intent prefix (t2164 — list-item
#      backtick paths without an intent prefix are context references,
#      not edit targets, and must not trigger the gate).
# Prints deduplicated, non-empty paths to stdout (one per line).
#######################################
_large_file_gate_extract_paths() {
	local issue_body="$1"

	# t2024: Preserve any trailing ":NNN" or ":START-END" line qualifier so
	# the gate loop below can distinguish scoped ranges from whole-file targets.
	# Previously this extractor stripped the qualifier via `sed 's/:.*//'`,
	# which threw away the one piece of information needed to tell "targeted
	# edit in a 30-line range" from "rewrite the whole 3000-line file".
	local file_paths
	# shellcheck disable=SC2016  # `\s` is grep-regex escape, not shell expansion.
	file_paths=$(printf '%s' "$issue_body" | grep -oE '(EDIT|NEW|File):?\s+[`"]?\.?agents/scripts/[^`"[:space:],]+' 2>/dev/null |
		sed 's/^[A-Z]*:*[[:space:]]*//' | sed 's/^[`"]//' | sed 's/[`"]*$//' | sort -u) || file_paths=""

	# t2164: Match backtick paths only when the line carries an explicit
	# edit-intent prefix (`EDIT:` / `NEW:` / `File:`). The previous regex
	# (`^\s*[-*]\s|^(EDIT|NEW|File):`) matched ANY backtick path on a
	# `-`-list item, which conflated edit targets with context references.
	# Brief authors routinely cite related files for investigation context
	# (e.g. as `grep -rn` search targets), and those citations were tripping
	# the gate. The `EDIT:`/`NEW:`/`File:` markers are the documented
	# convention for declaring edit intent (see templates/brief-template.md);
	# the gate now trusts them rather than guessing from list-item structure.
	#
	# Forms still matched after t2164:
	#   EDIT: `pulse-triage.sh`
	#   - EDIT: `pulse-triage.sh:255-330`
	#   NEW: `tests/test-foo.sh`
	#   File: `pulse-wrapper.sh`
	#
	# Forms NO LONGER matched (correctly, these are context refs):
	#   - `pulse-triage.sh` — search target for grep
	#   * `path/to/file.sh` (mentioned in passing)
	#
	# t2024: Also preserve line qualifiers here. A list-item reference like
	#   - EDIT: `pulse-ancillary-dispatch.sh:221-253`
	# should be parsed as "file + range", not stripped to bare "file".
	local backtick_paths
	# shellcheck disable=SC2016  # Backtick chars in regex are literals, not command subst.
	backtick_paths=$(printf '%s' "$issue_body" | grep -E '^\s*[-*]\s+(EDIT|NEW|File):|^(EDIT|NEW|File):' 2>/dev/null |
		grep -oE '`[^`]*\.(sh|py|js|ts)[^`]*`' 2>/dev/null |
		tr -d '`' | grep -v '^#' | sort -u) || backtick_paths=""

	printf '%s\n%s' "$file_paths" "$backtick_paths" | sort -u | grep -v '^$' || true
	return 0
}

#######################################
# Evaluate one candidate target against the large-file threshold.
# Parses an optional "file:NNN" or "file:START-END" qualifier (t2024),
# applies the skip-pattern filter, resolves the path relative to the repo
# (checking bare, .agents/, and .-prefixed variants), handles single-line
# and scoped-range citations, then compares `wc -l` to LARGE_FILE_LINE_THRESHOLD.
#
# Arguments: raw_target, repo_path, issue_number
# Stdout: "fpath|line_count" when the file exceeds threshold (exit 0)
# Exit codes:
#   0 - file is large, output emitted on stdout
#   1 - file is under threshold
#   2 - target was skipped (invalid, missing, skip-pattern, single-line, scoped-range)
#######################################
_large_file_gate_evaluate_target() {
	local raw_target="$1"
	local repo_path="$2"
	local issue_number="$3"
	[[ -n "$raw_target" ]] || return 2

	# t2024: Parse optional line qualifier off the end of the target.
	#   "file.sh"            → fpath="file.sh", line_spec=""
	#   "file.sh:1477"       → fpath="file.sh", line_spec="1477"
	#   "file.sh:221-253"    → fpath="file.sh", line_spec="221-253"
	# Only accept a line qualifier when it's numeric (optionally ranged).
	# Anything else (colons inside shell-safe paths, rare but possible)
	# is preserved as part of the path.
	local fpath="$raw_target"
	local line_spec=""
	if [[ "$raw_target" =~ ^(.+):([0-9]+(-[0-9]+)?)$ ]]; then
		fpath="${BASH_REMATCH[1]}"
		line_spec="${BASH_REMATCH[2]}"
	fi

	# Skip non-simplifiable files (lockfiles, generated data, configs)
	local basename_fpath
	basename_fpath=$(basename "$fpath")
	if printf '%s' "$basename_fpath" | grep -qE "$_LFG_SKIP_PATTERN" 2>/dev/null; then
		return 2
	fi

	# Resolve path relative to repo
	local full_path=""
	if [[ -f "${repo_path}/${fpath}" ]]; then
		full_path="${repo_path}/${fpath}"
	elif [[ -f "${repo_path}/.agents/${fpath}" ]]; then
		full_path="${repo_path}/.agents/${fpath}"
	elif [[ -f "${repo_path}/.${fpath}" ]]; then
		full_path="${repo_path}/.${fpath}"
	else
		return 2
	fi

	# t2024: scoped-range and single-line qualifier handling.
	#
	# 1. Single-line references (no range) are context for the human
	#    reader — they help locate the bug but do not describe an edit
	#    target. Skip them for gate evaluation entirely.
	# 2. Ranged references that fit inside SCOPED_RANGE_THRESHOLD bypass
	#    the file-size check — the worker only navigates the cited range.
	# 3. Anything else (no qualifier, or range too large) falls through
	#    to the file-size check as before.
	if [[ "$line_spec" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Large-file gate: #${issue_number} skipping ${fpath}:${line_spec} (single-line citation — context reference, not edit target)" >>"$LOGFILE"
		return 2
	fi
	if [[ "$line_spec" =~ ^([0-9]+)-([0-9]+)$ ]]; then
		local _range_start="${BASH_REMATCH[1]}"
		local _range_end="${BASH_REMATCH[2]}"
		local _range_size=$((_range_end - _range_start + 1))
		if [[ "$_range_size" -gt 0 && "$_range_size" -le "$SCOPED_RANGE_THRESHOLD" ]]; then
			echo "[pulse-wrapper] Large-file gate: #${issue_number} scoped-range pass for ${fpath}:${line_spec} (${_range_size} lines, threshold ${SCOPED_RANGE_THRESHOLD})" >>"$LOGFILE"
			return 2
		fi
	fi

	local line_count=0
	line_count=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ') || line_count=0
	if [[ "$line_count" -ge "$LARGE_FILE_LINE_THRESHOLD" ]]; then
		printf '%s|%s\n' "$fpath" "$line_count"
		return 0
	fi
	return 1
}

#######################################
# t2164 helper — resolve a large-file path against the repo_path, checking
# bare, .agents/-prefixed, and .-prefixed variants (mirrors
# _large_file_gate_evaluate_target). Prints the resolved full path on stdout
# and returns 0 when found; returns 1 and prints nothing otherwise.
#######################################
_large_file_gate_resolve_full_path() {
	local lf_path="$1"
	local repo_path="$2"
	if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
		return 1
	fi
	if [[ -f "${repo_path}/${lf_path}" ]]; then
		printf '%s' "${repo_path}/${lf_path}"
		return 0
	fi
	if [[ -f "${repo_path}/.agents/${lf_path}" ]]; then
		printf '%s' "${repo_path}/.agents/${lf_path}"
		return 0
	fi
	if [[ -f "${repo_path}/.${lf_path}" ]]; then
		printf '%s' "${repo_path}/.${lf_path}"
		return 0
	fi
	return 1
}

#######################################
# t2164 — verify whether a closed simplification-debt issue's PR actually
# reduced the file below threshold. Returns:
#   0 — "continuation is valid" (file now under threshold OR measurement
#       unavailable; caller should emit the continuation reference)
#   1 — "continuation is phantom" (file still over threshold; caller should
#       fall through to create a fresh debt issue, and this helper has
#       already logged the skip to $LOGFILE)
#
# Arguments: existing_issue_num, lf_path, repo_path
#######################################
_large_file_gate_verify_prior_reduced_size() {
	local existing_issue="$1"
	local lf_path="$2"
	local repo_path="$3"

	local _verify_full_path
	_verify_full_path=$(_large_file_gate_resolve_full_path "$lf_path" "$repo_path") || _verify_full_path=""

	if [[ -z "$_verify_full_path" ]]; then
		# Couldn't resolve path — preserve pre-t2164 behaviour: trust the
		# closed-issue signal (safer than creating noisy duplicates when
		# measurement is unavailable, e.g. running outside a checkout).
		return 0
	fi

	local _verify_lines=0
	_verify_lines=$(wc -l <"$_verify_full_path" 2>/dev/null | tr -d ' ') || _verify_lines=0

	if [[ "$_verify_lines" -gt 0 && "$_verify_lines" -lt "$LARGE_FILE_LINE_THRESHOLD" ]]; then
		# Prior PR genuinely reduced the file below threshold.
		return 0
	fi
	if [[ "$_verify_lines" -ge "$LARGE_FILE_LINE_THRESHOLD" ]]; then
		# File still over threshold — log the phantom-continuation skip
		# so the gate's audit trail captures why a fresh issue is filed.
		echo "[pulse-wrapper] Large-file gate: prior simplification-debt #${existing_issue} closed but ${lf_path} still ${_verify_lines} lines (threshold ${LARGE_FILE_LINE_THRESHOLD}); filing fresh debt issue (t2164)" >>"$LOGFILE"
		return 1
	fi
	# wc -l returned 0 (empty file / read error) — treat same as unavailable.
	return 0
}

#######################################
# t2164 helper — find an open or recently-closed simplification-debt issue
# that mentions `_lf_basename`. Prints "<state>:<number>" on stdout when
# found (state is "open" or "closed"); prints nothing otherwise.
#
# State is emitted as a stdout prefix instead of via `printf -v` because the
# caller invokes this helper in a command substitution `$(…)`, which runs in
# a subshell — `printf -v` in the subshell cannot reach the caller's scope.
# Encoding both values in stdout sidesteps the subshell boundary entirely.
#
# Arguments: repo_slug, lf_basename
# Stdout: "open:12345", "closed:18706", or empty
#######################################
_large_file_gate_find_existing_debt_issue() {
	local repo_slug="$1"
	local lf_basename="$2"

	local _open
	_open=$(gh issue list --repo "$repo_slug" --state open \
		--label "simplification-debt" --search "$lf_basename" \
		--json number --jq '.[0].number // empty' --limit 5 2>/dev/null) || _open=""
	if [[ -n "$_open" ]]; then
		printf 'open:%s' "$_open"
		return 0
	fi

	local _reopen_days="${LFG_DEBT_REOPEN_DAYS:-30}"
	local _recent_date
	_recent_date=$(date -u "-v-${_reopen_days}d" "+%Y-%m-%d" 2>/dev/null ||
		date -u -d "${_reopen_days} days ago" "+%Y-%m-%d" 2>/dev/null || true)
	if [[ -z "$_recent_date" ]]; then
		return 1
	fi

	local _closed
	_closed=$(gh issue list --repo "$repo_slug" \
		--state closed --label "simplification-debt" \
		--search "$lf_basename closed:>$_recent_date" \
		--json number --jq '.[0].number // empty' \
		--limit 5 2>/dev/null) || _closed=""
	if [[ -n "$_closed" ]]; then
		printf 'closed:%s' "$_closed"
		return 0
	fi
	return 1
}

#######################################
# t2164 helper — create a fresh simplification-debt issue via gh_create_issue.
# Prints "#NNN (new)" on success and empty on failure (gh failure is logged).
# Accepts an optional `prior_attempt_issue` for the body's "Prior attempt"
# footnote (t2164 phantom-continuation audit trail).
#######################################
_large_file_gate_file_new_debt_issue() {
	local lf_path="$1"
	local parent_issue="$2"
	local repo_slug="$3"
	local prior_attempt_issue="${4:-}"

	local _prior_attempt_ref=""
	if [[ -n "$prior_attempt_issue" ]]; then
		_prior_attempt_ref="

**Prior attempt:** #${prior_attempt_issue} closed without reducing file size below the ${LARGE_FILE_LINE_THRESHOLD}-line threshold (current size verified by gate). This issue is the file-size follow-up."
	fi

	# GH#18644: ensure the `simplification-debt` label exists before creation.
	gh label create "simplification-debt" \
		--repo "$repo_slug" \
		--description "Target file needs simplification before implementation work can proceed" \
		--color "D93F0B" \
		--force 2>/dev/null || true

	local _new_num _create_body _create_combined
	_create_body="## What
Simplify \`${lf_path}\` — currently over ${LARGE_FILE_LINE_THRESHOLD} lines. Break into smaller, focused modules.

## Why
Issue #${parent_issue} is blocked by the large-file gate. Workers dispatched against this file spend most of their context budget reading it, leaving insufficient capacity for implementation.${_prior_attempt_ref}

## How
- EDIT: \`${lf_path}\`
- Extract cohesive function groups into separate files
- Keep a thin orchestrator in the original file that sources/imports the extracted modules
- Verify: \`wc -l ${lf_path}\` should be below ${LARGE_FILE_LINE_THRESHOLD}

_Created by large-file simplification gate (pulse-dispatch-core.sh)_"
	# t2115: Use gh_create_issue wrapper for origin label + signature auto-append.
	_create_combined=$(gh_create_issue --repo "$repo_slug" \
		--title "simplification-debt: ${lf_path} exceeds ${LARGE_FILE_LINE_THRESHOLD} lines" \
		--label "simplification-debt,auto-dispatch,origin:worker" \
		--body "$_create_body" 2>&1) || true
	_new_num=$(printf '%s' "$_create_combined" |
		grep -oE 'https://github\.com/[^ ]+/issues/[0-9]+' |
		head -1 |
		grep -oE '[0-9]+$' || true)
	if [[ -n "$_new_num" ]]; then
		printf '#%s (new)' "$_new_num"
		echo "[pulse-wrapper] Created simplification-debt issue #${_new_num} for ${lf_path} (blocking #${parent_issue})" >>"$LOGFILE"
	else
		# Log the gh failure so the next cycle's operator can see why
		# the gate "created" nothing. 200-char truncation matches
		# issue-sync-helper.sh style.
		echo "[pulse-wrapper] WARN: failed to create simplification-debt issue for ${lf_path} (blocking #${parent_issue}): ${_create_combined:0:200}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Create a simplification-debt issue for one large-file target. Idempotent:
# if an open simplification-debt issue already mentions the file, emit a
# reference to it instead of creating a new one.
#
# t2021: `gh issue create` does NOT support --json; the issue number is
# parsed from the issue URL on stdout. The `|| true` on the $() guards
# against gh non-zero exits (label application failing server-side while
# the issue still creates — see issue-sync-helper.sh:441-464, GH#15234).
#
# GH#18644: the `simplification-debt` label is created idempotently so
# first-use in a fresh repo doesn't fail.
#
# t2164: `repo_path` parameter added so the recently-closed continuation
# branch (GH#18960) can verify the prior PR actually reduced the file
# below threshold before declaring continuation. Without this check, a
# closed simplification-debt issue whose PR did not shrink the file
# (or even grew it) gets cited as "in flight" continuation, and the
# parent stays held by the gate forever (or until the 30-day window
# expires) with no real work scheduled.
#
# Arguments: lf_path, parent_issue, repo_slug, repo_path
# Stdout: "#NNN (existing)" or "#NNN (new)" or
#         "#NNN (recently-closed — continuation)" on success; empty on failure
# Exit: 0 always (non-fatal; failure is logged)
#######################################
_large_file_gate_create_debt_issue() {
	local lf_path="$1"
	local parent_issue="$2"
	local repo_slug="$3"
	local repo_path="${4:-}"
	local _lf_basename
	_lf_basename=$(basename "$lf_path")

	# t2164: helper encodes state in stdout as "<state>:<number>" — subshell
	# boundary prevents `printf -v` from crossing the command substitution.
	local _existing_combined _existing _existing_state
	_existing_combined=$(_large_file_gate_find_existing_debt_issue "$repo_slug" "$_lf_basename") || _existing_combined=""
	if [[ -n "$_existing_combined" && "$_existing_combined" == *:* ]]; then
		_existing_state="${_existing_combined%%:*}"
		_existing="${_existing_combined#*:}"
	else
		_existing_state=""
		_existing=""
	fi

	if [[ "$_existing_state" == "open" ]]; then
		printf '#%s (existing)' "$_existing"
		return 0
	fi

	if [[ "$_existing_state" == "closed" ]]; then
		# t2164: verify the prior PR actually reduced file size before
		# declaring continuation. Helper logs the skip when it fires.
		if _large_file_gate_verify_prior_reduced_size "$_existing" "$lf_path" "$repo_path"; then
			printf '#%s (recently-closed — continuation)' "$_existing"
			return 0
		fi
		# Fall through: prior attempt did not reduce file size — file a
		# fresh debt issue that references the failed prior attempt.
		_large_file_gate_file_new_debt_issue "$lf_path" "$parent_issue" "$repo_slug" "$_existing"
		return 0
	fi

	_large_file_gate_file_new_debt_issue "$lf_path" "$parent_issue" "$repo_slug" ""
	return 0
}

#######################################
# Apply the large-file gate: add `needs-simplification` label to the parent
# issue, create one simplification-debt issue per large file (dedup-aware),
# and post the gate comment on the parent issue.
#
# t2164: `repo_path` parameter added so the per-file debt-issue creator can
# verify the prior PR actually reduced the file size before declaring
# "recently-closed continuation".
#
# Arguments:
#   $1 - issue_number (parent, being gated)
#   $2 - repo_slug
#   $3 - large_files_display ("path (N lines), " comma-trailed display string)
#   $4 - large_file_paths (newline-separated paths, may contain \n escapes)
#   $5 - repo_path (filesystem path to repo for wc -l verification, optional)
#######################################
_large_file_gate_apply() {
	local issue_number="$1"
	local repo_slug="$2"
	local large_files_display="$3"
	local large_file_paths="$4"
	local repo_path="${5:-}"

	# Add label to hold dispatch
	gh label create "needs-simplification" \
		--repo "$repo_slug" \
		--description "Issue targets large file(s) needing simplification first" \
		--color "D93F0B" \
		--force 2>/dev/null || true
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "needs-simplification" 2>/dev/null || true

	large_files_display="${large_files_display%, }"

	# Create simplification-debt issues for each large file immediately
	# (don't wait for the daily complexity scan). Dedup: skip if an open
	# simplification-debt issue already mentions this file.
	local _created_issues=""
	local _lf_path _debt_ref
	while IFS= read -r _lf_path; do
		[[ -z "$_lf_path" ]] && continue
		_debt_ref=$(_large_file_gate_create_debt_issue "$_lf_path" "$issue_number" "$repo_slug" "$repo_path")
		if [[ -n "$_debt_ref" ]]; then
			_created_issues="${_created_issues}${_debt_ref}, "
		fi
	done < <(printf '%b' "$large_file_paths")

	_created_issues="${_created_issues%, }"
	local simplification_body="## Large File Simplification Gate

This issue references file(s) exceeding ${LARGE_FILE_LINE_THRESHOLD} lines: ${large_files_display}.

Workers dispatched against large files spend most of their context budget reading the file, leaving insufficient capacity for implementation.

**Simplification issues:** ${_created_issues:-none created}

**Status:** Held from dispatch until simplification completes. The \`needs-simplification\` label will be removed automatically when the target file(s) are below threshold.

_Automated by \`_issue_targets_large_files()\` in pulse-wrapper.sh_"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"## Large File Simplification Gate" "$simplification_body"

	echo "[pulse-wrapper] Large-file gate: #${issue_number} in ${repo_slug} targets ${large_files_display}" >>"$LOGFILE"
	return 0
}

#######################################
# Clear a stale `needs-simplification` label when no large files remain
# (e.g., all targets now excluded by skip pattern or simplified below
# threshold). Posts a follow-up "CLEARED" comment via the triage helper
# so the original "Held from dispatch" comment doesn't mislead readers (t2042).
#
# Arguments: issue_number, repo_slug
#######################################
_large_file_gate_clear_stale_label() {
	local issue_number="$1"
	local repo_slug="$2"
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "needs-simplification" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Simplification gate cleared for #${issue_number} (${repo_slug}) — no large files after exclusion filter" >>"$LOGFILE"
	# t2042: post follow-up "CLEARED" comment so the original
	# "Held from dispatch" comment doesn't mislead readers. Helper
	# is defined in pulse-triage.sh which is sourced before this
	# file (see pulse-wrapper.sh:169-172).
	if declare -F _post_simplification_gate_cleared_comment >/dev/null 2>&1; then
		_post_simplification_gate_cleared_comment "$issue_number" "$repo_slug"
	fi
	return 0
}

#######################################
# Thin orchestrator for the large-file gate. Delegates label precheck,
# path extraction, per-target evaluation, gate application, and stale-label
# cleanup to the `_large_file_gate_*` helpers above. Byte-for-byte
# behaviourally equivalent to the pre-GH#18654 monolithic implementation.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - issue_body
#   $4 - repo_path
#   $5 - force_recheck (optional, default "false"; t1998 re-eval bypass)
#
# Exit codes:
#   0 - gate applied (dispatch blocked)
#   1 - gate not applied (dispatch may proceed)
#######################################
_issue_targets_large_files() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body="$3"
	local repo_path="$4"
	# t1998: force_recheck bypasses the skip-if-already-labeled short-circuit.
	# The normal dispatch path leaves this false (perf optimisation — no need
	# to re-run wc -l on an issue we just gated). The re-evaluation path in
	# pulse-triage.sh _reevaluate_simplification_labels() passes "true" so it
	# can detect when a previously-gated file has been simplified below
	# threshold and clear the label.
	local force_recheck="${5:-false}"

	[[ -n "$issue_body" ]] || return 1
	[[ -d "$repo_path" ]] || return 1

	local issue_labels
	issue_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""

	local _precheck_rc=0
	_large_file_gate_precheck_labels "$issue_number" "$repo_slug" "$issue_labels" "$force_recheck" || _precheck_rc=$?
	case "$_precheck_rc" in
	1) return 1 ;;
	2) return 0 ;;
	esac

	local all_paths
	all_paths=$(_large_file_gate_extract_paths "$issue_body")
	[[ -n "$all_paths" ]] || return 1

	local found_large=false
	local large_files=""
	local large_file_paths=""
	local raw_target eval_output eval_rc
	while IFS= read -r raw_target; do
		[[ -z "$raw_target" ]] && continue
		eval_rc=0
		eval_output=$(_large_file_gate_evaluate_target "$raw_target" "$repo_path" "$issue_number") || eval_rc=$?
		if [[ "$eval_rc" -eq 0 && -n "$eval_output" ]]; then
			local _f="${eval_output%|*}" _c="${eval_output##*|}"
			found_large=true
			large_files="${large_files}${_f} (${_c} lines), "
			# shellcheck disable=SC2129  # two appends to large_file_paths is clearer as separate statements
			large_file_paths="${large_file_paths}${_f}\n"
		fi
	done <<<"$all_paths"

	if [[ "$found_large" == "true" ]]; then
		# t2164: thread repo_path through so _large_file_gate_create_debt_issue
		# can verify recently-closed continuations actually reduced the file size.
		_large_file_gate_apply "$issue_number" "$repo_slug" "$large_files" "$large_file_paths" "$repo_path"
		return 0
	fi

	# If was_already_labeled but no large files found (e.g., all files now
	# excluded by skip pattern or simplified below threshold), auto-clear.
	if [[ ",$issue_labels," == *",needs-simplification,"* ]]; then
		_large_file_gate_clear_stale_label "$issue_number" "$repo_slug"
	fi

	return 1
}
