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

_register_validators() {
	_VALIDATOR_REGISTRY["ratchet-down"]="_validator_ratchet_down"
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

	local comment_body
	comment_body=$(
		cat <<EOF
> Premise falsified. Pre-dispatch validator for generator \`${generator}\` determined the issue premise is no longer true. The \`${generator}\` check reports no actionable work is available. Not dispatching a worker.

The issue was closed automatically by the pre-dispatch validator (GH#19118). If conditions change and ratchet-down proposals become available again, a new issue will be created by the next pulse cycle.

${sig_footer}
EOF
	)

	# Post rationale comment
	gh issue comment "$issue_number" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 ||
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

	# Extract generator marker
	local generator
	generator=$(printf '%s' "$issue_body" | grep -oE '<!-- aidevops:generator=[a-z-]+ -->' | head -1 |
		sed 's/<!-- aidevops:generator=//;s/ -->//' 2>/dev/null) || generator=""

	if [[ -z "$generator" ]]; then
		_log "INFO" "#${issue_number}: no generator marker found — unregistered generator, dispatch proceeds"
		return 0
	fi

	_log "INFO" "#${issue_number}: generator=${generator}"

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

	# Run validator
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
