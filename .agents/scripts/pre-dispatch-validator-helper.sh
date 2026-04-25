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
	_VALIDATOR_REGISTRY["function-complexity-gate"]="_validator_function_complexity_gate"
	_VALIDATOR_REGISTRY["upstream-watch"]="_validator_upstream_watch"
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
_validator_large_file_simplification_gate() {
	local slug="$1"

	if [[ -z "${CITED_FILE:-}" || -z "${CITED_THRESHOLD:-}" ]]; then
		_log "WARN" "large-file-simplification-gate validator: missing cited_file or threshold in marker"
		return 20
	fi

	_log "INFO" "large-file-simplification-gate validator: re-measuring ${CITED_FILE} (threshold=${CITED_THRESHOLD})"

	# Clone repo into scratch dir for a fresh read against HEAD
	local clone_url
	clone_url="https://github.com/${slug}.git"

	if ! git clone --depth 1 --quiet "$clone_url" "${SCRATCH_DIR}/repo" 2>/dev/null; then
		_log "WARN" "large-file-simplification-gate validator: git clone failed for ${slug}"
		return 20
	fi

	local target_file="${SCRATCH_DIR}/repo/${CITED_FILE}"
	if [[ ! -f "$target_file" ]]; then
		_log "INFO" "large-file-simplification-gate validator: file ${CITED_FILE} no longer exists — premise falsified"
		VALIDATOR_RATIONALE="File \`${CITED_FILE}\` no longer exists on HEAD. Premise falsified. Not dispatching."
		return 10
	fi

	local line_count
	line_count=$(wc -l < "$target_file" 2>/dev/null | tr -d ' ') || line_count=0

	if [[ "$line_count" -lt "$CITED_THRESHOLD" ]]; then
		_log "INFO" "large-file-simplification-gate validator: ${CITED_FILE} is now ${line_count} lines (threshold ${CITED_THRESHOLD}) — premise falsified"
		VALIDATOR_RATIONALE="File \`${CITED_FILE}\` is now ${line_count} lines, below the ${CITED_THRESHOLD}-line threshold. Premise falsified. Not dispatching."
		return 10
	fi

	_log "INFO" "large-file-simplification-gate validator: ${CITED_FILE} is still ${line_count} lines (threshold ${CITED_THRESHOLD}) — premise holds"
	return 0
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

	# Scope scan to implementation sections only (## Files to modify / ## How).
	# Scanning the full body risks matching incidental mentions (e.g. in narrative
	# prose or rationale text) that do not indicate the issue actually modifies the
	# dispatch path — leading to unintended model:opus-4-7 escalation.
	# Extract content after the first occurrence of either heading up to the next
	# top-level heading (or end of body). Both headings are tried and concatenated.
	local scan_target=""
	local files_section how_section
	files_section=$(printf '%s' "$issue_body" | \
		awk '/^## Files to modify/{found=1; next} found && /^## /{found=0} found{print}')
	how_section=$(printf '%s' "$issue_body" | \
		awk '/^## How/{found=1; next} found && /^## /{found=0} found{print}')
	scan_target="${files_section}${how_section}"

	# Fall back to full body if neither section is present (older/manual issue format)
	if [[ -z "$scan_target" ]]; then
		scan_target="$issue_body"
	fi

	# Check if implementation sections reference any dispatch-path files
	local matched_pattern=""
	local pattern
	for pattern in "${_SELF_HOSTING_PATTERNS[@]}"; do
		if printf '%s' "$scan_target" | grep -qF "$pattern"; then
			matched_pattern="$pattern"
			break
		fi
	done

	if [[ -z "$matched_pattern" ]]; then
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

	# Idempotency check: look for existing comment marker.
	# Use --paginate so all comment pages are fetched — without it the first-page
	# limit (30 comments) can cause the marker to be missed on active issues,
	# leading to duplicate audit comments.  Each page emits one integer via jq;
	# we sum them to get a total match count.
	local marker='<!-- self-hosting-tier-override -->'
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

	# Dry-run mode
	if [[ "${AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN:-}" == "1" ]]; then
		_log "INFO" "#${issue_number}: DRY-RUN — would apply ${_SELF_HOSTING_TARGET_LABEL} (matched: ${matched_pattern})"
		return 0
	fi

	# Apply the label
	if ! gh issue edit "$issue_number" --repo "$slug" \
		--add-label "$_SELF_HOSTING_TARGET_LABEL" >/dev/null 2>&1; then
		_log "WARN" "#${issue_number}: failed to apply ${_SELF_HOSTING_TARGET_LABEL} label — continuing"
		return 0
	fi

	_log "INFO" "#${issue_number}: applied ${_SELF_HOSTING_TARGET_LABEL} label (self-hosting dispatch-path task)"

	# Post provenance-wrapped audit comment
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
	gh issue close "$issue_number" --repo "$slug" --reason "not planned" >/dev/null 2>&1 ||
		_log "WARN" "Failed to close issue #${issue_number}"

	_log "INFO" "Closed issue #${issue_number} in ${slug} as not planned (premise falsified)"
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
	issue_body=$(gh api "repos/${slug}/issues/${issue_number}" --jq '.body // ""' 2>/dev/null) || {
		_log "WARN" "Failed to fetch issue body for #${issue_number} — proceeding (validator error)"
		return 20
	}

	# Run self-hosting detector BEFORE generator-marker validators (t2819).
	# Always returns 0; label mutation is advisory, not a dispatch block.
	_detect_self_hosting_task "$issue_number" "$slug" "$issue_body"

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

	# Extract optional attributes: cited_file, threshold, upstream_slug
	CITED_FILE=$(printf '%s' "$generator_line" | grep -oE 'cited_file=[^ >]+' | sed 's/cited_file=//' 2>/dev/null) || CITED_FILE=""
	CITED_THRESHOLD=$(printf '%s' "$generator_line" | grep -oE 'threshold=[0-9]+' | sed 's/threshold=//' 2>/dev/null) || CITED_THRESHOLD=""
	UPSTREAM_SLUG=$(printf '%s' "$generator_line" | grep -oE 'upstream_slug=[^ >]+' | sed 's/upstream_slug=//' 2>/dev/null) || UPSTREAM_SLUG=""

	_log "INFO" "#${issue_number}: generator=${generator} cited_file=${CITED_FILE:-<none>} threshold=${CITED_THRESHOLD:-<none>}"

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
