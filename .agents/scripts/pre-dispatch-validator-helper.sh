#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pre-dispatch-validator-helper.sh — Pre-dispatch no-op validator for auto-generated issues (GH#19118)
#
# Before the pulse spawns a worker for an auto-generated issue, this helper
# fetches the issue body, extracts the generator marker, and runs the
# registered validator for that generator type. The result determines whether
# dispatch proceeds, is blocked with a rationale comment, or falls back with
# a warning.
#
# Generator identification uses hidden HTML comment markers of the form:
#   <!-- aidevops:generator=<name> -->
# Parsing titles or labels is explicitly rejected as too brittle.
#
# Exit codes (returned by the `validate` subcommand):
#   0  — dispatch proceeds (premise holds, or no validator registered)
#   10 — premise falsified; caller closes the issue with a rationale comment
#   20 — validator error; dispatch proceeds with a warning log
#
# Usage:
#   pre-dispatch-validator-helper.sh validate <issue-number> <slug>
#   pre-dispatch-validator-helper.sh help
#
# Emergency bypass:
#   AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 — exit 0 immediately (with log)
#
# Extension: to add a new validator, define a function named
#   _validator_<generator-name>()
# and register it in _register_validators(). The function receives no
# arguments and must exit with 0 (valid), 10 (falsified), or 20 (error).
# It may use $SCRATCH_DIR for temporary files; cleanup is handled by trap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

if [[ -f "${SCRIPT_DIR}/pulse-repo-meta.sh" ]]; then
	# shellcheck source=./pulse-repo-meta.sh
	source "${SCRIPT_DIR}/pulse-repo-meta.sh"
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log() {
	local level="$1"
	shift
	printf '[pre-dispatch-validator] %s: %s\n' "$level" "$*" >&2
	return 0
}

# ---------------------------------------------------------------------------
# Registry — maps generator name → validator function name
# Add new validators here by calling _register_validators() pattern.
# ---------------------------------------------------------------------------
declare -A _VALIDATOR_REGISTRY=()
_PREDISPATCH_CLOSE_REASON_NOT_PLANNED="not planned"

# ---------------------------------------------------------------------------
# Self-hosting dispatch-path file patterns (t2819, t2821)
#
# When an issue body references any of these files, the issue modifies the
# worker dispatch/spawn path. Workers dispatched to fix this code run through
# the code being fixed — a tautology loop that wastes cascade attempts.
#
# Canonical list lives in .agents/configs/self-hosting-files.conf (t2821).
# Loaded at runtime; falls back to the hardcoded defaults if conf is missing.
# ---------------------------------------------------------------------------
# Label applied when self-hosting pattern is detected
_SELF_HOSTING_TARGET_LABEL="model:opus-4-7"
_SELF_HOSTING_TIER_REQUIRED="tier:thinking"

# Load patterns from shared conf file (t2821). Non-blocking if conf missing.
_load_self_hosting_patterns() {
	local conf_file="${AIDEVOPS_DISPATCH_PATH_FILES_CONF:-${SCRIPT_DIR}/../configs/self-hosting-files.conf}"
	local patterns=()
	if [[ -f "$conf_file" ]]; then
		while IFS= read -r line; do
			# Skip blank lines and comments
			[[ -z "$line" || "$line" == \#* ]] && continue
			patterns+=("$line")
		done <"$conf_file"
	fi
	# Fallback hardcoded defaults when conf unavailable
	if [[ ${#patterns[@]} -eq 0 ]]; then
		patterns=(
			"pulse-wrapper.sh"
			"pulse-dispatch-"
			"pulse-cleanup.sh"
			"headless-runtime-helper.sh"
			"headless-runtime-lib.sh"
			"worker-lifecycle-common.sh"
			"shared-dispatch-dedup.sh"
			"shared-claim-lifecycle.sh"
			"worker-activity-watchdog.sh"
		)
	fi
	# Export via global for callers (bash 3.2: no namerefs)
	_SELF_HOSTING_PATTERNS=("${patterns[@]}")
	return 0
}

_SELF_HOSTING_PATTERNS=()
_load_self_hosting_patterns

_register_validators() {
	_VALIDATOR_REGISTRY["ratchet-down"]="_validator_ratchet_down"
	_VALIDATOR_REGISTRY["large-file-simplification-gate"]="_validator_large_file_simplification_gate"
	_VALIDATOR_REGISTRY["agent-doc-simplification-gate"]="_validator_agent_doc_simplification_gate"
	_VALIDATOR_REGISTRY["function-complexity-gate"]="_validator_function_complexity_gate"
	_VALIDATOR_REGISTRY["upstream-watch"]="_validator_upstream_watch"
	_VALIDATOR_REGISTRY["runtime-audit"]="_validator_runtime_audit"
	return 0
}

# ---------------------------------------------------------------------------
# Merge-stuck zero-progress meta-issue validator (GH#24729)
# ---------------------------------------------------------------------------
_zero_progress_gauge_from_stats() {
	local stats_file="${PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"

	if [[ ! -f "$stats_file" ]]; then
		return 1
	fi

	local gauge_value
	gauge_value=$(jq -r '(.gauges.pulse_merge_zero_progress_cycles.value // empty) | tostring' \
		"$stats_file" 2>/dev/null) || return 1
	if [[ -z "$gauge_value" ]]; then
		return 1
	fi

	printf '%s\n' "$gauge_value"
	return 0
}

_close_zero_progress_meta_if_recovered() {
	local issue_number="$1"
	local slug="$2"
	local issue_body="$3"

	if [[ "$issue_body" != *"merge-stuck:zero-progress"* ]]; then
		return 0
	fi

	local zero_progress_cycles
	zero_progress_cycles=$(_zero_progress_gauge_from_stats) || {
		_log "WARN" "#${issue_number}: zero-progress meta validator could not read pulse_merge_zero_progress_cycles — dispatch proceeds"
		return 0
	}
	if [[ "$zero_progress_cycles" != "0" ]]; then
		_log "INFO" "#${issue_number}: zero-progress meta premise still active (pulse_merge_zero_progress_cycles=${zero_progress_cycles}) — dispatch proceeds"
		return 0
	fi
	# #aidevops:trust-boundary — recovered-meta handling writes comments and
	# closes issues. Public issue comments can succeed for non-collaborators, so
	# never write unless the runner is admin/maintain/write on this repo.
	if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
		|| ! repo_allows_pulse_write_actions "$slug"; then
		_log "WARN" "#${issue_number}: recovered zero-progress meta issue left untouched — runner lacks repo write permission"
		return 0
	fi

	local comment_body
	comment_body="## Recovery detected

The pulse merge zero-progress detector recovered before worker dispatch: \`pulse_merge_zero_progress_cycles\` is 0.

Closing this stale zero-progress meta-issue in the pre-dispatch validator so auto-dispatch does not spend worker capacity on an already-recovered incident. A fresh issue will be filed if a new zero-progress streak crosses the threshold."

	gh issue comment "$issue_number" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 ||
		_log "WARN" "#${issue_number}: failed to comment on recovered zero-progress meta-issue"
	gh issue close "$issue_number" --repo "$slug" --reason completed >/dev/null 2>&1 ||
		_log "WARN" "#${issue_number}: failed to close recovered zero-progress meta-issue"
	_log "INFO" "#${issue_number}: zero-progress meta premise recovered — issue closed, dispatch blocked"
	return 10
}

# ---------------------------------------------------------------------------
# Function-complexity-sweep duplicate detector.
#
# The quality sweep emits one issue per cited file. Older sweep versions
# deduped by title using the full path even though the title only contained the
# basename, which allowed duplicate issues for the same cited_file marker. Close
# later duplicates before worker launch so two workers do not race the same file.
# ---------------------------------------------------------------------------
_extract_function_complexity_sweep_cited_file() {
	local issue_body="$1"
	local generator_line=""

	generator_line=$(printf '%s' "$issue_body" | grep -oE '<!-- aidevops:generator=function-complexity-sweep[^>]*-->' | head -1) || generator_line=""
	[[ -n "$generator_line" ]] || return 1

	printf '%s' "$generator_line" | grep -oE 'cited_file=[^ >]+' | sed 's/cited_file=//' || return 1
	return 0
}

_function_complexity_sweep_duplicate_rows() {
	local slug="$1"
	local cited_file="$2"

	gh issue list --repo "$slug" \
		--label "function-complexity-debt" --state open \
		--search "\"cited_file=${cited_file}\" in:body" \
		--json number,labels \
		--jq '.[] | [.number, ([.labels[].name] | join(","))] | @tsv' 2>/dev/null
	return $?
}

_function_complexity_row_is_active() {
	local labels="$1"

	case ",$labels," in
	*,status:in-progress,* | *,status:in-review,* | *,status:claimed,*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

_select_function_complexity_survivor() {
	local rows="$1"
	local survivor=""
	local first_number=""
	local number=""
	local labels=""

	while IFS=$'\t' read -r number labels; do
		[[ "$number" =~ ^[0-9]+$ ]] || continue
		if [[ -z "$first_number" || "$number" -lt "$first_number" ]]; then
			first_number="$number"
		fi
		if _function_complexity_row_is_active "$labels"; then
			if [[ -z "$survivor" || "$number" -lt "$survivor" ]]; then
				survivor="$number"
			fi
		fi
	done <<<"$rows"

	printf '%s' "${survivor:-$first_number}"
	return 0
}

_close_function_complexity_duplicate_issue() {
	local issue_number="$1"
	local slug="$2"
	local cited_file="$3"
	local survivor="$4"

	local comment_body=""
	comment_body="## Duplicate quality-sweep issue

This issue targets the same quality-sweep marker as #${survivor}: cited_file=${cited_file}.

Closing it before worker dispatch so automation does not launch duplicate workers against the same file. Continue via #${survivor}."

	gh_issue_comment "$issue_number" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 ||
		_log "WARN" "#${issue_number}: failed to comment on duplicate function-complexity-sweep issue"
	gh issue close "$issue_number" --repo "$slug" --reason "$_PREDISPATCH_CLOSE_REASON_NOT_PLANNED" >/dev/null 2>&1 ||
		_log "WARN" "#${issue_number}: failed to close duplicate function-complexity-sweep issue"
	_log "INFO" "#${issue_number}: duplicate function-complexity-sweep issue closed; survivor=#${survivor} cited_file=${cited_file}"
	return 0
}

_close_function_complexity_sweep_duplicates() {
	local issue_number="$1"
	local slug="$2"
	local issue_body="$3"
	local cited_file=""

	cited_file=$(_extract_function_complexity_sweep_cited_file "$issue_body") || return 0
	[[ -n "$cited_file" ]] || return 0

	local rows=""
	if ! rows=$(_function_complexity_sweep_duplicate_rows "$slug" "$cited_file"); then
		_log "WARN" "#${issue_number}: duplicate function-complexity-sweep lookup failed for ${cited_file} — dispatch proceeds"
		return 0
	fi
	[[ -n "$rows" ]] || return 0

	local issue_count="0"
	issue_count=$(printf '%s\n' "$rows" | awk -F '\t' '$1 ~ /^[0-9]+$/ { count++ } END { print count+0 }') || issue_count="0"
	[[ "$issue_count" -gt 1 ]] || return 0

	local survivor=""
	survivor=$(_select_function_complexity_survivor "$rows")
	[[ -n "$survivor" ]] || return 0

	if [[ "$issue_number" != "$survivor" ]]; then
		_close_function_complexity_duplicate_issue "$issue_number" "$slug" "$cited_file" "$survivor"
		return 10
	fi

	local duplicate_number=""
	local duplicate_labels=""
	while IFS=$'\t' read -r duplicate_number duplicate_labels; do
		: "$duplicate_labels"
		[[ "$duplicate_number" =~ ^[0-9]+$ ]] || continue
		[[ "$duplicate_number" == "$survivor" ]] && continue
		_close_function_complexity_duplicate_issue "$duplicate_number" "$slug" "$cited_file" "$survivor"
	done <<<"$rows"

	return 0
}

# ---------------------------------------------------------------------------
# Ratchet-down validator
#
# Clones the target repo into a scratch directory and runs:
#   complexity-scan-helper.sh ratchet-check . 5
# If the output contains "No ratchet-down available" the premise is falsified.
# ---------------------------------------------------------------------------
_validator_ratchet_down() {
	local slug="$1"

	_log "INFO" "ratchet-down validator: running ratchet-check on ${slug}"

	# Allow test override via env var; fall back to co-located script.
	local scan_helper="${COMPLEXITY_SCAN_HELPER:-${SCRIPT_DIR}/complexity-scan-helper.sh}"
	if [[ ! -x "$scan_helper" ]]; then
		_log "WARN" "ratchet-down validator: complexity-scan-helper.sh not found at ${scan_helper}"
		return 20
	fi

	# Clone repo into scratch dir for a fresh read (avoids stale worktree reads)
	local clone_url
	clone_url="https://github.com/${slug}.git"

	if ! git clone --depth 1 --quiet "$clone_url" "${SCRATCH_DIR}/repo" 2>/dev/null; then
		_log "WARN" "ratchet-down validator: git clone failed for ${slug} — treating as validator error"
		return 20
	fi

	local ratchet_output
	local ratchet_rc=0
	ratchet_output=$("$scan_helper" ratchet-check "${SCRATCH_DIR}/repo" 5 2>/dev/null) || ratchet_rc=$?

	# ratchet-check exits 0 with output when proposals available,
	# exits non-zero when thresholds are already tight (no proposals).
	# Both cases: check the output text for the no-op sentinel.
	if printf '%s' "$ratchet_output" | grep -q "No ratchet-down available"; then
		_log "INFO" "ratchet-down validator: premise falsified — no ratchet-down available"
		return 10
	fi

	if [[ "$ratchet_rc" -ne 0 ]] && [[ -z "$ratchet_output" ]]; then
		# scan errored without a meaningful result — treat as validator error
		_log "WARN" "ratchet-down validator: ratchet-check exited ${ratchet_rc} with empty output — validator error"
		return 20
	fi

	_log "INFO" "ratchet-down validator: premise holds — ratchet-down proposals available"
	return 0
}

# ---------------------------------------------------------------------------
# Large-file simplification gate validator (t2367)
#
# Re-measures the cited file against current HEAD. If the file is now below
# the threshold, the premise is falsified — the debt was resolved before the
# worker could be dispatched.
#
# Expects CITED_FILE and CITED_THRESHOLD to be set by cmd_validate() after
# parsing the marker attributes.
# ---------------------------------------------------------------------------
_validator_file_line_threshold_gate() {
	local slug="$1"
	local generator_name="$2"
	local subject_label="$3"

	if [[ -z "${CITED_FILE:-}" || -z "${CITED_THRESHOLD:-}" ]]; then
		_log "WARN" "${generator_name} validator: missing cited_file or threshold in marker"
		return 20
	fi

	_log "INFO" "${generator_name} validator: re-measuring ${CITED_FILE} (threshold=${CITED_THRESHOLD})"

	# Clone repo into scratch dir for a fresh read against HEAD
	local clone_url
	clone_url="https://github.com/${slug}.git"

	if ! git clone --depth 1 --quiet "$clone_url" "${SCRATCH_DIR}/repo" 2>/dev/null; then
		_log "WARN" "${generator_name} validator: git clone failed for ${slug}"
		return 20
	fi

	local target_file="${SCRATCH_DIR}/repo/${CITED_FILE}"
	if [[ ! -f "$target_file" ]]; then
		_log "INFO" "${generator_name} validator: file ${CITED_FILE} no longer exists — premise falsified"
		VALIDATOR_RATIONALE="${subject_label} \`${CITED_FILE}\` no longer exists on HEAD. Premise falsified. Not dispatching."
		return 10
	fi

	local line_count
	line_count=$(wc -l < "$target_file" 2>/dev/null | tr -d ' ') || line_count=0

	if [[ "$line_count" -lt "$CITED_THRESHOLD" ]]; then
		_log "INFO" "${generator_name} validator: ${CITED_FILE} is now ${line_count} lines (threshold ${CITED_THRESHOLD}) — premise falsified"
		VALIDATOR_RATIONALE="${subject_label} \`${CITED_FILE}\` is now ${line_count} lines, below the ${CITED_THRESHOLD}-line threshold. Premise falsified. Not dispatching."
		return 10
	fi

	_log "INFO" "${generator_name} validator: ${CITED_FILE} is still ${line_count} lines (threshold ${CITED_THRESHOLD}) — premise holds"
	return 0
}

_validator_large_file_simplification_gate() {
	local slug="$1"
	_validator_file_line_threshold_gate "$slug" "large-file-simplification-gate" "File"
	return $?
}

_validator_agent_doc_simplification_gate() {
	local slug="$1"
	_validator_file_line_threshold_gate "$slug" "agent-doc-simplification-gate" "Agent doc"
	return $?
}

# ---------------------------------------------------------------------------
# Function-complexity gate validator (t2367)
#
# Re-measures function complexity in the cited file. If no functions exceed
# the threshold, the premise is falsified.
#
# Expects CITED_FILE and CITED_THRESHOLD to be set by cmd_validate().
# ---------------------------------------------------------------------------
_validator_function_complexity_gate() {
	local slug="$1"

	if [[ -z "${CITED_FILE:-}" || -z "${CITED_THRESHOLD:-}" ]]; then
		_log "WARN" "function-complexity-gate validator: missing cited_file or threshold in marker"
		return 20
	fi

	_log "INFO" "function-complexity-gate validator: re-measuring ${CITED_FILE} (threshold=${CITED_THRESHOLD})"

	# Clone repo into scratch dir for a fresh read against HEAD
	local clone_url
	clone_url="https://github.com/${slug}.git"

	if ! git clone --depth 1 --quiet "$clone_url" "${SCRATCH_DIR}/repo" 2>/dev/null; then
		_log "WARN" "function-complexity-gate validator: git clone failed for ${slug}"
		return 20
	fi

	local target_file="${SCRATCH_DIR}/repo/${CITED_FILE}"
	if [[ ! -f "$target_file" ]]; then
		_log "INFO" "function-complexity-gate validator: file ${CITED_FILE} no longer exists — premise falsified"
		VALIDATOR_RATIONALE="File \`${CITED_FILE}\` no longer exists on HEAD. Premise falsified. Not dispatching."
		return 10
	fi

	# Count functions exceeding the threshold (same awk as complexity-scan-helper.sh)
	local violation_count
	violation_count=$(awk -v threshold="$CITED_THRESHOLD" '
		/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
		fname && /^\}$/ { lines=NR-start; if(lines+0>threshold+0) count++; fname="" }
		END { print count+0 }
	' "$target_file" 2>/dev/null) || violation_count=0

	if [[ "$violation_count" -eq 0 ]]; then
		_log "INFO" "function-complexity-gate validator: no functions exceed ${CITED_THRESHOLD} lines in ${CITED_FILE} — premise falsified"
		VALIDATOR_RATIONALE="File \`${CITED_FILE}\` has 0 functions exceeding ${CITED_THRESHOLD} lines on HEAD. Premise falsified. Not dispatching."
		return 10
	fi

# ---------------------------------------------------------------------------
# Runtime-audit validator (t3072)
#
# Re-runs the cited detector against current local state. Detectors are
# self-contained and read local files only — no GitHub API calls — so
# the re-validation cost is seconds and bounded.
#
# Expects DETECTOR_ID to be set by cmd_validate() after parsing the
# detector=<id> attribute from the generator marker. If the detector now
# returns 0 (no finding), the premise is falsified — the underlying
# regression has resolved between detection and dispatch.
# ---------------------------------------------------------------------------
_validator_runtime_audit() {
	local slug="$1"
	# slug is passed for parity with other validators but is unused: the
	# detectors run against local pulse state, not remote git state.
	# (lint-friendly no-op assignment to mark intent)
	: "$slug"

	if [[ -z "${DETECTOR_ID:-}" ]]; then
		_log "WARN" "runtime-audit validator: missing detector=<id> attribute in marker"
		return 20
	fi

	local rules_dir="${RUNTIME_AUDIT_RULES_DIR:-${SCRIPT_DIR}/runtime-audit-rules}"
	local detector_file="${rules_dir}/${DETECTOR_ID}.sh"

	if [[ ! -f "$detector_file" ]]; then
		_log "WARN" "runtime-audit validator: detector file not found: ${detector_file}"
		return 20
	fi

	# Re-run the detector in a clean subshell so its globals do not leak.
	local detector_rc=0
	bash -c "
		set -u
		source '${SCRIPT_DIR}/shared-constants.sh'
		source '${detector_file}'
		runtime_audit_check >/dev/null
	" || detector_rc=$?

	if [[ "$detector_rc" -eq 0 ]]; then
		_log "INFO" "runtime-audit validator: detector=${DETECTOR_ID} now returns clean — premise falsified"
		VALIDATOR_RATIONALE="Re-running detector \`${DETECTOR_ID}\` against current local state shows no finding. The underlying regression resolved between detection and dispatch."
		return 10
	fi

	if [[ "$detector_rc" -eq 1 ]]; then
		_log "INFO" "runtime-audit validator: detector=${DETECTOR_ID} still firing — premise holds"
		return 0
	fi

	_log "WARN" "runtime-audit validator: detector=${DETECTOR_ID} returned rc=${detector_rc} (unexpected) — validator error"
	return 20
}

	_log "INFO" "function-complexity-gate validator: ${violation_count} function(s) still exceed ${CITED_THRESHOLD} lines in ${CITED_FILE} — premise holds"
	return 0
}

# ---------------------------------------------------------------------------
# Upstream-watch validator (t2810)
#
# Re-checks the upstream-watch state file. If the upstream slug has
# updates_pending == 0, the user has already acked and the issue premise
# is falsified.
#
# Expects UPSTREAM_SLUG to be set by cmd_validate() after parsing the
# generator marker attributes.
# ---------------------------------------------------------------------------
_validator_upstream_watch() {
	local slug="$1"

	if [[ -z "${UPSTREAM_SLUG:-}" ]]; then
		_log "WARN" "upstream-watch validator: no upstream_slug attribute found in generator marker"
		return 20
	fi

	local state_file="${AIDEVOPS_UPSTREAM_WATCH_STATE:-${HOME}/.aidevops/cache/upstream-watch-state.json}"
	if [[ ! -f "$state_file" ]]; then
		_log "WARN" "upstream-watch validator: state file not found at ${state_file}"
		return 20
	fi

	# Check updates_pending for both GitHub repos and non-GitHub upstreams
	local pending_github pending_nongithub
	pending_github=$(jq -r --arg name "$UPSTREAM_SLUG" '.repos[$name].updates_pending // -1' "$state_file" 2>/dev/null) || pending_github="-1"
	pending_nongithub=$(jq -r --arg name "$UPSTREAM_SLUG" '.non_github[$name].updates_pending // -1' "$state_file" 2>/dev/null) || pending_nongithub="-1"

	# Determine which store has the entry
	local pending="-1"
	if [[ "$pending_github" != "-1" ]]; then
		pending="$pending_github"
	elif [[ "$pending_nongithub" != "-1" ]]; then
		pending="$pending_nongithub"
	fi

	if [[ "$pending" == "0" ]]; then
		_log "INFO" "upstream-watch validator: ${UPSTREAM_SLUG} has updates_pending=0 — premise falsified (already acked)"
		VALIDATOR_RATIONALE="Upstream \`${UPSTREAM_SLUG}\` has \`updates_pending: 0\` (already acknowledged). Premise falsified. Not dispatching."
		return 10
	fi

	if [[ "$pending" == "-1" ]]; then
		_log "WARN" "upstream-watch validator: ${UPSTREAM_SLUG} not found in state file — validator error"
		return 20
	fi

	_log "INFO" "upstream-watch validator: ${UPSTREAM_SLUG} has updates_pending=${pending} — premise holds"
	return 0
}

# ---------------------------------------------------------------------------
# Self-hosting dispatch-path detector helpers (t2819)
#
# Private helpers for _detect_self_hosting_task(). Named with _sht_ prefix
# to avoid collisions with other helpers in this file.
# ---------------------------------------------------------------------------

# Extract the implementation-scoped scan target from an issue body.
# Scans ## Files to modify and ## How sections only; falls back to full body.
# Outputs the scan target text to stdout.
_sht_extract_scan_target() {
	local issue_body="$1"
	local files_section how_section scan_target

	files_section=$(printf '%s' "$issue_body" | \
		awk '/^## Files to modify/{found=1; next} found && /^## /{found=0} found{print}')
	how_section=$(printf '%s' "$issue_body" | \
		awk '/^## How/{found=1; next} found && /^## /{found=0} found{print}')
	scan_target="${files_section}${how_section}"

	# Fall back to full body if neither section is present (older/manual issue format)
	if [[ -z "$scan_target" ]]; then
		scan_target="$issue_body"
	fi

	printf '%s' "$scan_target"
	return 0
}

# Scan scan_target for the first matching dispatch-path pattern.
# Outputs the matched pattern name to stdout.
# Returns 0 if a match is found, 1 if no match.
_sht_match_dispatch_pattern() {
	local scan_target="$1"
	local pattern

	for pattern in "${_SELF_HOSTING_PATTERNS[@]}"; do
		if printf '%s' "$scan_target" | grep -qF "$pattern"; then
			printf '%s' "$pattern"
			return 0
		fi
	done

	return 1
}

# Check whether the self-hosting audit comment has already been posted.
# If the marker exists: ensures label is applied (idempotent recovery).
# Returns 0 when caller should skip re-posting, 1 when posting is needed.
# Uses --paginate to avoid missing the marker on high-comment issues.
_sht_check_comment_idempotent() {
	local issue_number="$1"
	local slug="$2"
	local marker="$3"

	local existing=""
	existing=$(gh api --paginate "repos/${slug}/issues/${issue_number}/comments" \
		--jq "[.[] | select(.body | contains(\"${marker}\"))] | length" \
		2>/dev/null | awk '{s+=$1} END{print s+0}') || existing="0"

	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		_log "INFO" "#${issue_number}: self-hosting comment already posted — ensuring label"
		# Ensure label even if comment exists (in case label was manually removed)
		if [[ "${AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN:-}" != "1" ]]; then
			gh issue edit "$issue_number" --repo "$slug" \
				--add-label "$_SELF_HOSTING_TARGET_LABEL" >/dev/null 2>&1 || true
		fi
		return 0
	fi

	return 1
}

# Apply the self-hosting tier-override label and post the provenance-wrapped
# audit comment. Always returns 0 (failures are logged, not fatal).
_sht_apply_label_and_comment() {
	local issue_number="$1"
	local slug="$2"
	local matched_pattern="$3"
	local marker="$4"

	if ! gh issue edit "$issue_number" --repo "$slug" \
		--add-label "$_SELF_HOSTING_TARGET_LABEL" >/dev/null 2>&1; then
		_log "WARN" "#${issue_number}: failed to apply ${_SELF_HOSTING_TARGET_LABEL} label — continuing"
		return 0
	fi

	_log "INFO" "#${issue_number}: applied ${_SELF_HOSTING_TARGET_LABEL} label (self-hosting dispatch-path task)"

	local comment_body
	comment_body="${marker}
<!-- provenance:start -->
## Self-Hosting Tier Override

Pre-dispatch self-hosting detector applied \`${_SELF_HOSTING_TARGET_LABEL}\` to this \`${_SELF_HOSTING_TIER_REQUIRED}\` issue.

**Matched pattern:** \`${matched_pattern}\` in issue body

**Rationale:** Issues modifying the dispatch path have a self-referential property — workers dispatched to fix them run through the code being fixed. Starting at opus-4-6 wastes 1-2 attempts before the cascade reaches the tier needed for these task sizes. Applying \`${_SELF_HOSTING_TARGET_LABEL}\` upfront eliminates wasted dispatch cycles.

**Bypass:** \`AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1\`

_Automated by \`pre-dispatch-validator-helper.sh\` (t2819). This comment is posted once via the \`${marker}\` marker; re-runs are no-ops._
<!-- provenance:end -->"

	gh_issue_comment "$issue_number" --repo "$slug" --body "$comment_body" \
		>/dev/null 2>&1 || _log "WARN" "#${issue_number}: self-hosting audit comment post failed — label still applied"

	return 0
}

# ---------------------------------------------------------------------------
# Self-hosting dispatch-path detector (t2819)
#
# Scans the issue body for references to dispatch-path scripts. When found
# on a tier:thinking issue without model:opus-4-7, applies the label to
# short-circuit the cascade (which would eventually reach opus-4-7 anyway
# after 1-2 wasted attempts at opus-4-6).
#
# Always returns 0 — this is an advisory pre-step, not a dispatch blocker.
#
# Arguments:
#   $1 - issue_number
#   $2 - slug (owner/repo)
#   $3 - issue_body (already fetched by cmd_validate)
#
# Environment:
#   AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1    — skip entirely
#   AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN=1 — emit what-would-be-applied
# ---------------------------------------------------------------------------
_detect_self_hosting_task() {
	local issue_number="$1"
	local slug="$2"
	local issue_body="$3"

	# Bypass guard
	if [[ "${AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR:-}" == "1" ]]; then
		_log "INFO" "AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1 — skipping self-hosting detector"
		return 0
	fi

	# Quick-exit: empty body has nothing to scan
	if [[ -z "$issue_body" ]]; then
		return 0
	fi

	# Extract implementation sections only (## Files to modify / ## How).
	# Scanning the full body risks matching incidental mentions in prose that do
	# not indicate the issue actually modifies the dispatch path, leading to
	# unintended model:opus-4-7 escalation.
	local scan_target
	scan_target=$(_sht_extract_scan_target "$issue_body")

	# Check if implementation sections reference any dispatch-path files
	local matched_pattern
	if ! matched_pattern=$(_sht_match_dispatch_pattern "$scan_target"); then
		_log "INFO" "#${issue_number}: no dispatch-path patterns found — self-hosting detector skips"
		return 0
	fi

	_log "INFO" "#${issue_number}: dispatch-path pattern detected: ${matched_pattern}"

	# Fetch issue labels to check tier and existing model label
	local labels
	labels=$(gh api "repos/${slug}/issues/${issue_number}" --jq '[.labels[].name] | join(",")' 2>/dev/null) || labels=""

	# Must have the required tier label
	if ! printf '%s' "$labels" | grep -qF "$_SELF_HOSTING_TIER_REQUIRED"; then
		_log "INFO" "#${issue_number}: not ${_SELF_HOSTING_TIER_REQUIRED} — self-hosting detector skips"
		return 0
	fi

	# Already has target label — idempotent no-op
	if printf '%s' "$labels" | grep -qF "$_SELF_HOSTING_TARGET_LABEL"; then
		_log "INFO" "#${issue_number}: already has ${_SELF_HOSTING_TARGET_LABEL} — self-hosting detector no-op"
		return 0
	fi

	local marker='<!-- self-hosting-tier-override -->'

	# Idempotency check: look for existing comment marker
	if _sht_check_comment_idempotent "$issue_number" "$slug" "$marker"; then
		return 0
	fi

	# Dry-run mode
	if [[ "${AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN:-}" == "1" ]]; then
		_log "INFO" "#${issue_number}: DRY-RUN — would apply ${_SELF_HOSTING_TARGET_LABEL} (matched: ${matched_pattern})"
		return 0
	fi

	# Apply the label and post the audit comment
	_sht_apply_label_and_comment "$issue_number" "$slug" "$matched_pattern" "$marker"
	return 0
}

# ---------------------------------------------------------------------------
# Review-feedback / quality-debt supersession detector (t3569, GH#23101)
# ---------------------------------------------------------------------------

_rf_extract_file_paths_from_text() {
	local text="$1"
	local paths=""
	local dir_paths=""
	local backtick_files=""
	local bare_files=""

	dir_paths=$(printf '%s' "$text" | grep -oE '[a-zA-Z0-9._-]+/[a-zA-Z0-9._/-]+\.[a-zA-Z]{1,10}' | sort -u || true)
	if [[ -n "$dir_paths" ]]; then
		paths="${paths}${dir_paths}"$'\n'
	fi

	# shellcheck disable=SC2016 # Literal backtick regex, not shell expansion.
	backtick_files=$(printf '%s' "$text" | grep -oE '`[a-zA-Z0-9._/-]+\.(sh|ts|js|py|md|json|yaml|yml|toml|go|rs|tsx|jsx|css|html|sql|rb|php|java|c|h|cpp|hpp|cs|dart|jl|kt|m|mm|r|scala|swift)(:[0-9]+(-[0-9]+)?)?`' | tr -d '`' | sed 's/:[0-9]*\(-[0-9]*\)\{0,1\}$//' | sort -u || true)
	if [[ -n "$backtick_files" ]]; then
		paths="${paths}${backtick_files}"$'\n'
	fi

	bare_files=$(printf '%s' "$text" | grep -oE '\b[a-zA-Z0-9_-]+\.(sh|ts|js|py|json|yaml|yml|toml|go|rs|tsx|jsx|css|html|sql|rb|php|java|c|h|cpp|hpp|cs|dart|jl|kt|m|mm|r|scala|swift)\b' | sort -u || true)
	if [[ -n "$bare_files" ]]; then
		paths="${paths}${bare_files}"$'\n'
	fi

	printf '%s' "$paths" | sort -u | grep -v '^$' | grep -vE '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true
	return 0
}

_rf_is_stopword() {
	local word="$1"

	case "$word" in
	aidevops | automated | auto | body | cited | code | debt | dispatch | file | files | fix | fixed | fixing | from | generated | guidance | issue | label | labels | line | lines | merged | modify | path | paths | please | quality | review | should | source | status | task | that | the | then | there | this | updates | what | when | where | with | worker | workers)
		return 0
		;;
	esac

	return 1
}

_rf_extract_keywords() {
	local text="$1"
	local keyword_text=""
	local words=""
	local word=""
	local count=0

	# shellcheck disable=SC2016 # Literal backtick regex, not shell expansion.
	keyword_text=$(printf '%s' "$text" | sed -E 's/`[A-Za-z0-9._\/-]+\.[A-Za-z0-9]{1,10}(:[0-9]+(-[0-9]+)?)?`/ /g; s#[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+\.[A-Za-z]{1,10}# #g')
	words=$(printf '%s' "$keyword_text" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]_' '\n' | grep -E '^[a-z][a-z0-9_]{3,}$' | sort -u || true)
	while IFS= read -r word; do
		[[ -z "$word" ]] && continue
		if _rf_is_stopword "$word"; then
			continue
		fi
		printf '%s\n' "$word"
		count=$((count + 1))
		if [[ "$count" -ge 40 ]]; then
			break
		fi
	done <<<"$words"

	return 0
}

_rf_issue_in_supersession_scope() {
	local issue_body="$1"
	local labels="$2"
	local title="$3"
	local labels_lc=""
	local title_lc=""

	labels_lc=$(printf '%s' "$labels" | tr '[:upper:]' '[:lower:]')
	case ",${labels_lc}," in
	*",source:review-feedback,"* | *",quality-debt,"* | *",review-followup,"* | *",source:review-scanner,"*)
		return 0
		;;
	esac

	if printf '%s' "$issue_body" | grep -Eq '<!-- (source:review-feedback|source:review-scanner|review-followup:PR)'; then
		return 0
	fi

	title_lc=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
	if printf '%s' "$title_lc" | grep -Eq '(^|[^[:alnum:]-])(quality-debt|review-feedback|review feedback|review-followup|review followup)([^[:alnum:]-]|$)'; then
		return 0
	fi

	return 1
}

_rf_search_merged_pr_numbers() {
	local slug="$1"
	local search_after="$2"
	local search_date="${search_after%%T*}"
	local limit="${AIDEVOPS_REVIEW_FEEDBACK_SUPERSESSION_LIMIT:-25}"

	if [[ -z "$search_date" || "$search_date" == "$search_after" ]]; then
		return 1
	fi

	gh api -X GET search/issues \
		-f q="repo:${slug} is:pr is:merged merged:>=${search_date}" \
		-f sort=updated \
		-f order=desc \
		-f per_page="$limit" \
		--jq '.items[]?.number' 2>/dev/null || true
	return 0
}

_rf_extract_source_pr_number() {
	local issue_body="$1"
	local issue_title="$2"
	local source_pr=""

	source_pr=$(printf '%s\n%s\n' "$issue_body" "$issue_title" | sed -En 's/.*\*\*Source PR\*\*:[[:space:]]*#?([0-9]+).*/\1/p; s/.*Review followup:[[:space:]]*PR[[:space:]]*#?([0-9]+).*/\1/p' | tail -1)
	if [[ "$source_pr" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$source_pr"
		return 0
	fi

	return 1
}

_rf_get_source_pr_merged_at() {
	local slug="$1"
	local source_pr="$2"
	local merged_at=""

	merged_at=$(gh api "repos/${slug}/pulls/${source_pr}" --jq '.merged_at // ""' 2>/dev/null) || return 1
	if [[ -n "$merged_at" && "$merged_at" == *T* ]]; then
		printf '%s\n' "$merged_at"
		return 0
	fi

	return 1
}

_rf_get_pr_files() {
	local slug="$1"
	local pr_number="$2"

	gh api --paginate "repos/${slug}/pulls/${pr_number}/files" --jq '.[].filename' 2>/dev/null
	return $?
}

_rf_get_pr_patch_text() {
	local slug="$1"
	local pr_number="$2"

	gh api --paginate "repos/${slug}/pulls/${pr_number}/files" --jq '.[] | (.filename + "\n" + (.patch // ""))' 2>/dev/null
	return $?
}

_rf_find_overlapping_paths() {
	local issue_paths="$1"
	local pr_files="$2"
	local issue_path=""
	local pr_path=""
	local issue_basename=""
	local pr_basename=""
	local overlaps=""

	while IFS= read -r issue_path; do
		[[ -z "$issue_path" ]] && continue
		issue_basename="${issue_path##*/}"
		while IFS= read -r pr_path; do
			[[ -z "$pr_path" ]] && continue
			pr_basename="${pr_path##*/}"
			if [[ "$issue_path" == */* ]]; then
				if [[ "$pr_path" == "$issue_path" || "$pr_path" == *"/${issue_path}" ]]; then
					overlaps="${overlaps}${pr_path}"$'\n'
				fi
			elif [[ "$pr_basename" == "$issue_basename" ]]; then
				overlaps="${overlaps}${pr_path}"$'\n'
			fi
		done <<<"$pr_files"
	done <<<"$issue_paths"

	if [[ -n "$overlaps" ]]; then
		printf '%s' "$overlaps" | sort -u
		return 0
	fi

	return 1
}

_RF_KEYWORD_SCORE=0
_RF_MATCHED_KEYWORDS=""

_rf_score_keywords() {
	local keywords="$1"
	local evidence="$2"
	local evidence_lc=""
	local keyword=""
	local score=0
	local matched=""

	evidence_lc=$(printf '%s' "$evidence" | tr '[:upper:]' '[:lower:]')
	while IFS= read -r keyword; do
		[[ -z "$keyword" ]] && continue
		if printf '%s' "$evidence_lc" | grep -qwF "$keyword"; then
			score=$((score + 1))
			matched="${matched}${keyword}"$'\n'
		fi
	done <<<"$keywords"

	_RF_KEYWORD_SCORE="$score"
	_RF_MATCHED_KEYWORDS=$(printf '%s' "$matched" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
	return 0
}

_rf_pr_references_issue() {
	local issue_number="$1"
	local evidence="$2"
	local evidence_lc=""

	evidence_lc=$(printf '%s' "$evidence" | tr '[:upper:]' '[:lower:]')
	if printf '%s' "$evidence_lc" | grep -Eq "(^|[^0-9])#${issue_number}([^0-9]|$)|gh#${issue_number}([^0-9]|$)"; then
		return 0
	fi

	return 1
}

_rf_comment_marker_exists() {
	local issue_number="$1"
	local slug="$2"
	local marker="$3"
	local existing=""

	existing=$(gh api --paginate "repos/${slug}/issues/${issue_number}/comments" \
		--jq "[.[] | select(.body | contains(\"${marker}\"))] | length" \
		2>/dev/null | awk '{s+=$1} END{print s+0}') || existing="0"

	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		return 0
	fi

	return 1
}

_rf_join_lines() {
	local text="$1"
	local joined=""

	joined=$(printf '%s' "$text" | tr '\n' ',' | sed 's/,$//;s/,/, /g')
	printf '%s' "$joined"
	return 0
}

_rf_post_ambiguous_comment() {
	local issue_number="$1"
	local slug="$2"
	local issue_paths="$3"
	local keywords="$4"
	local ambiguous_evidence="$5"
	local search_context="$6"
	local marker='<!-- review-feedback-supersession-ambiguous -->'

	if _rf_comment_marker_exists "$issue_number" "$slug" "$marker"; then
		_log "INFO" "#${issue_number}: ambiguous supersession comment already exists — dispatch proceeds"
		return 0
	fi

	local compact_paths=""
	local compact_keywords=""
	local comment_body=""
	compact_paths=$(_rf_join_lines "$issue_paths")
	compact_keywords=$(_rf_join_lines "$keywords")
	[[ -n "$compact_keywords" ]] || compact_keywords="<none extracted>"

	comment_body=$(cat <<EOF
${marker}
## Possible review-feedback supersession

Pre-dispatch found merged PRs in the ${search_context} that touched cited file paths, but the diff/title/body keyword evidence was not strong enough to skip worker dispatch.

- **Cited files:** ${compact_paths}
- **Finding keywords:** ${compact_keywords}
- **Ambiguous candidates:**
${ambiguous_evidence}

Dispatch proceeds because the supersession evidence is ambiguous; only clear same-file + finding-signal matches are skipped automatically.
EOF
	)

	gh_issue_comment "$issue_number" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 ||
		_log "WARN" "#${issue_number}: failed to post ambiguous supersession comment"
	return 0
}

_rf_close_with_supersession() {
	local issue_number="$1"
	local slug="$2"
	local pr_number="$3"
	local merged_at="$4"
	local overlaps="$5"
	local matched_keywords="$6"
	local search_context="$7"
	local source_pr="$8"
	local marker='<!-- review-feedback-superseded-by-merged-pr -->'
	local sig_footer=""

	if [[ -x "${SCRIPT_DIR}/gh-signature-helper.sh" ]]; then
		sig_footer=$("${SCRIPT_DIR}/gh-signature-helper.sh" footer --issue "${slug}#${issue_number}" 2>/dev/null || true)
	fi

	local compact_overlaps=""
	local source_pr_line=""
	local comment_body=""
	compact_overlaps=$(_rf_join_lines "$overlaps")
	[[ -n "$matched_keywords" ]] || matched_keywords="issue reference"
	if [[ -n "$source_pr" ]]; then
		source_pr_line="- **Source PR:** #${source_pr}"
	fi

	comment_body=$(cat <<EOF
${marker}
> Superseded. Pre-dispatch review-feedback validator found merged PR #${pr_number} in the ${search_context}. The PR touches the cited file path(s) and matches the finding signal, so worker dispatch is skipped.

${source_pr_line}
- **Merged PR:** #${pr_number}
- **Merged at:** ${merged_at}
- **Overlapping files:** ${compact_overlaps}
- **Matched signal:** ${matched_keywords}

Closed automatically by the review-feedback supersession validator (t3569, GH#23101). If the finding recurs, a new review-feedback issue will be created by the next scan.

${sig_footer}
EOF
	)

	gh_issue_comment "$issue_number" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 ||
		_log "WARN" "#${issue_number}: failed to post review-feedback supersession rationale"
	gh issue close "$issue_number" --repo "$slug" --reason "$_PREDISPATCH_CLOSE_REASON_NOT_PLANNED" >/dev/null 2>&1 ||
		_log "WARN" "#${issue_number}: failed to close superseded review-feedback issue"

	_log "INFO" "#${issue_number}: closed as superseded by merged PR #${pr_number}"
	return 0
}

_detect_review_feedback_supersession() {
	local issue_number="$1"
	local slug="$2"
	local issue_body="$3"
	local issue_api_path="$4"

	if [[ "${AIDEVOPS_SKIP_REVIEW_FEEDBACK_SUPERSESSION:-}" == "1" ]]; then
		_log "INFO" "AIDEVOPS_SKIP_REVIEW_FEEDBACK_SUPERSESSION=1 — skipping review-feedback supersession detector"
		return 0
	fi

	local issue_meta=""
	local created_at=""
	local issue_title=""
	local labels=""
	issue_meta=$(gh api "$issue_api_path" --jq '[.created_at // "", .title // "", ([.labels[]?.name] | join(","))] | @tsv' 2>/dev/null) || {
		_log "WARN" "#${issue_number}: failed to fetch issue metadata for review-feedback supersession check — dispatch proceeds"
		return 0
	}
	IFS=$'\t' read -r created_at issue_title labels <<<"$issue_meta"

	if ! _rf_issue_in_supersession_scope "$issue_body" "$labels" "$issue_title"; then
		_log "INFO" "#${issue_number}: not review-feedback/quality-debt — supersession detector skips"
		return 0
	fi

	if [[ -z "$created_at" || "$created_at" != *T* ]]; then
		_log "WARN" "#${issue_number}: missing created_at metadata — review-feedback supersession check fails open"
		return 0
	fi

	local issue_paths=""
	issue_paths=$(_rf_extract_file_paths_from_text "$issue_body")
	if [[ -z "$issue_paths" ]]; then
		_log "INFO" "#${issue_number}: no cited file paths — review-feedback supersession detector skips"
		return 0
	fi

	local keywords=""
	keywords=$(_rf_extract_keywords "$issue_body")

	local source_pr=""
	local source_merged_at=""
	local search_after="$created_at"
	local search_context="issue-created window after ${created_at}"
	if source_pr=$(_rf_extract_source_pr_number "$issue_body" "$issue_title"); then
		if source_merged_at=$(_rf_get_source_pr_merged_at "$slug" "$source_pr"); then
			search_after="$source_merged_at"
			search_context="source PR #${source_pr} merge window after ${source_merged_at}"
		else
			_log "WARN" "#${issue_number}: failed to fetch source PR #${source_pr} merged_at — using issue-created supersession window"
			source_pr=""
		fi
	fi

	local candidate_numbers=""
	candidate_numbers=$(_rf_search_merged_pr_numbers "$slug" "$search_after") || candidate_numbers=""
	if [[ -z "$candidate_numbers" ]]; then
		_log "INFO" "#${issue_number}: no merged PR candidates in ${search_context} — dispatch proceeds"
		return 0
	fi

	local pr_number=""
	local ambiguous_evidence=""
	while IFS= read -r pr_number; do
		[[ "$pr_number" =~ ^[0-9]+$ ]] || continue

		local pr_meta=""
		local merged_at=""
		local pr_title=""
		local pr_body=""
		pr_meta=$(gh api "repos/${slug}/pulls/${pr_number}" --jq '[.merged_at // "", .title // "", .body // ""] | @tsv' 2>/dev/null) || {
			_log "WARN" "#${issue_number}: failed to fetch PR #${pr_number} metadata — skipping candidate"
			continue
		}
		IFS=$'\t' read -r merged_at pr_title pr_body <<<"$pr_meta"

		if [[ -z "$merged_at" || "$merged_at" < "$search_after" || "$merged_at" == "$search_after" ]]; then
			continue
		fi

		local pr_files=""
		pr_files=$(_rf_get_pr_files "$slug" "$pr_number") || {
			_log "WARN" "#${issue_number}: failed to fetch PR #${pr_number} files — skipping candidate"
			continue
		}

		local overlaps=""
		if ! overlaps=$(_rf_find_overlapping_paths "$issue_paths" "$pr_files"); then
			continue
		fi

		local pr_patch=""
		pr_patch=$(_rf_get_pr_patch_text "$slug" "$pr_number") || pr_patch=""
		local evidence="${pr_title}"$'\n'"${pr_body}"$'\n'"${pr_patch}"
		_rf_score_keywords "$keywords" "$evidence"

		if _rf_pr_references_issue "$issue_number" "$evidence" || [[ "$_RF_KEYWORD_SCORE" -ge 2 ]]; then
			_rf_close_with_supersession "$issue_number" "$slug" "$pr_number" "$merged_at" "$overlaps" "$_RF_MATCHED_KEYWORDS" "$search_context" "$source_pr"
			return 10
		fi

		ambiguous_evidence="${ambiguous_evidence}- PR #${pr_number} merged at ${merged_at}; same-file overlap: $(_rf_join_lines "$overlaps"); keyword matches: ${_RF_KEYWORD_SCORE}"$'\n'
	done <<<"$candidate_numbers"

	if [[ -n "$ambiguous_evidence" ]]; then
		_rf_post_ambiguous_comment "$issue_number" "$slug" "$issue_paths" "$keywords" "$ambiguous_evidence" "$search_context"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Compose and post the falsified-premise closure comment, then close the issue.
# ---------------------------------------------------------------------------
_close_with_rationale() {
	local issue_number="$1"
	local slug="$2"
	local generator="$3"

	local sig_footer=""
	if [[ -x "${SCRIPT_DIR}/gh-signature-helper.sh" ]]; then
		sig_footer=$("${SCRIPT_DIR}/gh-signature-helper.sh" footer --issue "${slug}#${issue_number}" 2>/dev/null || true)
	fi

	# Use specific validator rationale if available, otherwise generic message
	local rationale_detail="${VALIDATOR_RATIONALE:-The \`${generator}\` check reports no actionable work is available.}"

	local comment_body
	comment_body=$(
		cat <<EOF
> Premise falsified. Pre-dispatch validator for generator \`${generator}\` determined the issue premise is no longer true. ${rationale_detail} Not dispatching a worker.

The issue was closed automatically by the pre-dispatch validator (GH#19118, t2367). If conditions change, a new issue will be created by the next pulse cycle.

${sig_footer}
EOF
	)

	# Post rationale comment
	gh_issue_comment "$issue_number" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 ||
		_log "WARN" "Failed to post rationale comment on #${issue_number}"

	# Close the issue with reason "not planned"
	gh issue close "$issue_number" --repo "$slug" --reason "$_PREDISPATCH_CLOSE_REASON_NOT_PLANNED" >/dev/null 2>&1 ||
		_log "WARN" "Failed to close issue #${issue_number}"

	_log "INFO" "Closed issue #${issue_number} in ${slug} as not planned (premise falsified)"
	return 0
}

_run_pre_generator_validators() {
	local issue_number="$1"
	local slug="$2"
	local issue_body="$3"
	local issue_api_path="$4"

	# Run self-hosting detector BEFORE generator-marker validators (t2819).
	# Always returns 0; label mutation is advisory, not a dispatch block.
	_detect_self_hosting_task "$issue_number" "$slug" "$issue_body"

	# Run review-feedback/quality-debt supersession detector before launching a
	# worker. Exit 10 only on clear same-file + finding-signal matches; ambiguous
	# matches are commented and fail open so dispatch can proceed.
	local review_feedback_rc=0
	_detect_review_feedback_supersession "$issue_number" "$slug" "$issue_body" "$issue_api_path" || review_feedback_rc=$?
	if [[ "$review_feedback_rc" -eq 10 ]]; then
		return 10
	fi
	if [[ "$review_feedback_rc" -ne 0 ]]; then
		_log "WARN" "#${issue_number}: review-feedback supersession detector returned rc=${review_feedback_rc} — dispatch proceeds"
	fi

	local quality_duplicate_rc=0
	_close_function_complexity_sweep_duplicates "$issue_number" "$slug" "$issue_body" || quality_duplicate_rc=$?
	if [[ "$quality_duplicate_rc" -eq 10 ]]; then
		return 10
	fi
	if [[ "$quality_duplicate_rc" -ne 0 ]]; then
		_log "WARN" "#${issue_number}: function-complexity-sweep duplicate detector returned rc=${quality_duplicate_rc} — dispatch proceeds"
	fi

	local zero_progress_rc=0
	_close_zero_progress_meta_if_recovered "$issue_number" "$slug" "$issue_body" || zero_progress_rc=$?
	if [[ "$zero_progress_rc" -eq 10 ]]; then
		return 10
	fi
	if [[ "$zero_progress_rc" -ne 0 ]]; then
		_log "WARN" "#${issue_number}: zero-progress meta validator returned rc=${zero_progress_rc} — dispatch proceeds"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# validate — main subcommand
#
# Arguments:
#   $1 - issue_number
#   $2 - slug (owner/repo)
#
# Exit codes:
#   0  — dispatch proceeds
#   10 — premise falsified (caller should close issue; this function already did)
#   20 — validator error (dispatch proceeds with warning)
# ---------------------------------------------------------------------------
cmd_validate() {
	local issue_number="$1"
	local slug="$2"

	# Bypass guard — emergency exit
	if [[ "${AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR:-}" == "1" ]]; then
		_log "INFO" "AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1 — skipping validator for #${issue_number}"
		return 0
	fi

	if [[ -z "$issue_number" || -z "$slug" ]]; then
		_log "ERROR" "validate requires <issue-number> <slug>"
		return 20
	fi

	# Fetch issue body
	local issue_body
	local issue_api_path="repos/${slug}/issues/${issue_number}"
	issue_body=$(gh api "$issue_api_path" --jq '.body // ""' 2>/dev/null) || {
		_log "WARN" "Failed to fetch issue body for #${issue_number} — proceeding (validator error)"
		return 20
	}

	local pre_generator_rc=0
	_run_pre_generator_validators "$issue_number" "$slug" "$issue_body" "$issue_api_path" || pre_generator_rc=$?
	if [[ "$pre_generator_rc" -eq 10 ]]; then
		return 10
	fi
	if [[ "$pre_generator_rc" -ne 0 ]]; then
		_log "WARN" "#${issue_number}: pre-generator validator returned rc=${pre_generator_rc} — dispatch proceeds"
	fi

	# Extract generator marker (supports both simple and attributed forms):
	#   <!-- aidevops:generator=<name> -->
	#   <!-- aidevops:generator=<name> cited_file=<path> threshold=<N> -->
	local generator_line
	generator_line=$(printf '%s' "$issue_body" | grep -oE '<!-- aidevops:generator=[a-z0-9_-]+[^>]*-->' | head -1) || generator_line=""

	local generator
	generator=$(printf '%s' "$generator_line" | sed 's/<!-- aidevops:generator=//;s/ .*//' 2>/dev/null) || generator=""

	if [[ -z "$generator" ]]; then
		_log "INFO" "#${issue_number}: no generator marker found — unregistered generator, dispatch proceeds"
		return 0
	fi

	# Extract optional attributes: cited_file, threshold, upstream_slug, detector
	CITED_FILE=$(printf '%s' "$generator_line" | grep -oE 'cited_file=[^ >]+' | sed 's/cited_file=//' 2>/dev/null) || CITED_FILE=""
	CITED_THRESHOLD=$(printf '%s' "$generator_line" | grep -oE 'threshold=[0-9]+' | sed 's/threshold=//' 2>/dev/null) || CITED_THRESHOLD=""
	UPSTREAM_SLUG=$(printf '%s' "$generator_line" | grep -oE 'upstream_slug=[^ >]+' | sed 's/upstream_slug=//' 2>/dev/null) || UPSTREAM_SLUG=""
	DETECTOR_ID=$(printf '%s' "$generator_line" | grep -oE 'detector=[a-z0-9_-]+' | sed 's/detector=//' 2>/dev/null) || DETECTOR_ID=""

	_log "INFO" "#${issue_number}: generator=${generator} cited_file=${CITED_FILE:-<none>} threshold=${CITED_THRESHOLD:-<none>} detector=${DETECTOR_ID:-<none>}"

	# Look up validator
	_register_validators
	local validator_fn="${_VALIDATOR_REGISTRY[$generator]:-}"
	if [[ -z "$validator_fn" ]]; then
		_log "INFO" "#${issue_number}: generator '${generator}' has no registered validator — dispatch proceeds"
		return 0
	fi

	# Set up scratch dir with cleanup trap
	SCRATCH_DIR=$(mktemp -d 2>/dev/null) || {
		_log "WARN" "Failed to create scratch dir — treating as validator error"
		return 20
	}
	# shellcheck disable=SC2064
	trap "rm -rf '${SCRATCH_DIR}'" EXIT

	# Run validator (VALIDATOR_RATIONALE may be set by the validator for
	# specific evidence in the closure comment)
	VALIDATOR_RATIONALE=""
	local validator_rc=0
	"$validator_fn" "$slug" || validator_rc=$?

	case "$validator_rc" in
	0)
		_log "INFO" "#${issue_number}: validator passed — dispatch proceeds"
		return 0
		;;
	10)
		_log "INFO" "#${issue_number}: premise falsified by validator — closing issue"
		_close_with_rationale "$issue_number" "$slug" "$generator"
		return 10
		;;
	*)
		_log "WARN" "#${issue_number}: validator returned rc=${validator_rc} (error) — dispatch proceeds"
		return 20
		;;
	esac
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------
_usage() {
	cat <<EOF
Usage:
  pre-dispatch-validator-helper.sh validate <issue-number> <slug>
  pre-dispatch-validator-helper.sh help

Exit codes (validate):
  0  — dispatch proceeds
  10 — premise falsified; issue closed with rationale comment
  20 — validator error; dispatch proceeds with warning

Environment:
  AIDEVOPS_SKIP_PREDISPATCH_VALIDATOR=1  — bypass all validators (exit 0)
EOF
	return 0
}

case "${1:-help}" in
validate) cmd_validate "${2:-}" "${3:-}" ;;
help | --help | -h) _usage ;;
*)
	_log "ERROR" "Unknown subcommand: ${1:-}"
	_usage
	exit 1
	;;
esac
