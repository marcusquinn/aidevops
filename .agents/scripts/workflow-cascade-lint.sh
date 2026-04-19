#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# workflow-cascade-lint.sh — detect cascade-vulnerable CI workflows (t2229)
#
# Scans .github/workflows/*.yml for the dangerous combination:
#   1. Label-like event types in triggers (labeled, unlabeled, assigned,
#      unassigned, review_requested, review_request_removed) — these fire
#      once per item, so `gh pr create --label "a,b,c"` fires 3 events.
#   2. cancel-in-progress: true on any concurrency group.
#   3. No effective mitigation (paths-ignore or job-level event-action guard).
#
# This combination causes rapid-fire event cascades where intermediate
# workflow runs get cancelled before completing. See t2220 for the canonical
# failure mode (15 cancelled + 2 success runs of Qlty Regression Gate in
# ~2s on PR #19704).
#
# Usage:
#   workflow-cascade-lint.sh [options] [file...]
#   workflow-cascade-lint.sh --dry-run
#   workflow-cascade-lint.sh --help
#
# Options:
#   --dry-run       List vulnerable files without failing (exit 0)
#   --scan-dir DIR  Directory to scan (default: .github/workflows)
#   -h, --help      Show usage and exit 0
#
# Exit codes:
#   0 — no vulnerable workflows found (or --dry-run)
#   1 — one or more workflows are cascade-vulnerable
#   2 — usage error
#
# When run without file arguments, scans all .github/workflows/*.yml.
# Files are checked with grep-based heuristics — no yq dependency required.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")

# Label-like event types that fire once per item.
# These are the triggers that cause rapid-fire cascades when multiple items
# are applied in a single API call (e.g., gh pr create --label "a,b,c,d").
CASCADE_EVENT_TYPES="labeled|unlabeled|assigned|unassigned|review_requested|review_request_removed"

# ─── Logging ────────────────────────────────────────────────────────────────

log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

die() {
	local _msg="$1"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit 2
}

usage() {
	sed -n '4,35p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ─── Detection helpers ──────────────────────────────────────────────────────

# has_cascade_triggers <file>
# Returns 0 if the file contains label-like event types in a types: context.
# Checks both inline (types: [labeled, ...]) and multi-line (- labeled) forms.
has_cascade_triggers() {
	local _file="$1"
	# Inline form: types: [..., labeled, ...]
	if grep -qE "types:\s*\[.*\b(${CASCADE_EVENT_TYPES})\b" "$_file"; then
		return 0
	fi
	# Multi-line form: a YAML list item that is exactly a cascade event type
	if grep -qE "^\s+-\s+(${CASCADE_EVENT_TYPES})\s*$" "$_file"; then
		return 0
	fi
	return 1
}

# has_cancel_in_progress <file>
# Returns 0 if cancel-in-progress: true is set anywhere (top-level or job-level).
has_cancel_in_progress() {
	local _file="$1"
	grep -qE 'cancel-in-progress:\s*true' "$_file"
	return $?
}

# has_paths_ignore <file>
# Returns 0 if paths-ignore is present under a trigger section.
# paths-ignore scopes the trigger to file-changing events, which prevents
# the cascade for PRs matching the ignore pattern (e.g., docs-only PRs).
has_paths_ignore() {
	local _file="$1"
	grep -qE '^\s+paths-ignore:' "$_file"
	return $?
}

# has_event_action_guard <file>
# Returns 0 if at least one job has an if: condition that gates on
# github.event.action. This catches patterns like:
#   if: github.event.action != 'labeled' || contains(...)
# which prevent cascade by skipping unrelated label events early.
# Note: checking github.event.label.name alone does NOT mitigate cascade
# because the run still enters the concurrency group and can be cancelled.
has_event_action_guard() {
	local _file="$1"
	# Job-level if: referencing event.action
	if grep -qE '^\s+if:.*github\.event\.action' "$_file"; then
		return 0
	fi
	# Step-level early exit on event action (run: block)
	# Pattern: check EVENT_ACTION or github.event.action in a run block
	# and exit 0 before doing work — prevents wasting the concurrency slot.
	if grep -qE 'EVENT_ACTION|github\.event\.action' "$_file" &&
		grep -qE '(exit 0|echo.*skip|echo.*Skipping)' "$_file"; then
		return 0
	fi
	return 1
}

# check_file <file>
# Returns 0 if the file is OK (not vulnerable), 1 if vulnerable.
check_file() {
	local _file="$1"

	# Step 1: Does it have cascade-prone trigger types?
	if ! has_cascade_triggers "$_file"; then
		return 0
	fi

	# Step 2: Does it have cancel-in-progress: true?
	if ! has_cancel_in_progress "$_file"; then
		return 0
	fi

	# Step 3: Check mitigations (either is sufficient)
	if has_paths_ignore "$_file"; then
		log "MITIGATED (paths-ignore): $_file"
		return 0
	fi

	if has_event_action_guard "$_file"; then
		log "MITIGATED (event-action guard): $_file"
		return 0
	fi

	# No mitigation found — vulnerable
	return 1
}

# ─── Output formatting ──────────────────────────────────────────────────────

# print_report <vuln_files_file> <vuln_count>
# Prints a human-readable report of vulnerable workflows.
print_report() {
	local _vuln_file="$1"
	local _count="$2"

	printf '\nCascade-vulnerable workflows detected (%d):\n' "$_count"
	while IFS= read -r _f; do
		printf '  - %s\n' "$_f"
	done < "$_vuln_file"
	printf '\n'
	printf 'Remediation:\n'
	printf '  1. Add paths-ignore under the trigger to scope to file-changing events\n'
	printf '  2. OR add a job-level if: guard on github.event.action\n'
	printf '  3. OR remove cancel-in-progress: true from the concurrency group\n'
	printf '\n'
	printf 'See: t2220 (evidence), t2228 (parent remediation)\n'
	printf 'Override: apply the workflow-cascade-ok label with a justification section\n'
	return 0
}

# print_markdown_report <vuln_files_file> <vuln_count> <scanned_count>
# Prints a markdown-formatted report suitable for PR comments.
print_markdown_report() {
	local _vuln_file="$1"
	local _count="$2"
	local _scanned="$3"

	printf '<!-- workflow-cascade-lint -->\n'
	printf '## Cascade Vulnerability Lint\n\n'
	if [ "$_count" -eq 0 ]; then
		printf 'No cascade-vulnerable workflows detected (%d scanned).\n' "$_scanned"
		return 0
	fi
	printf '**%d workflow(s) have the cascade-vulnerable combination** ' "$_count"
	# Backticks below are intentional markdown formatting, not command substitution.
	# shellcheck disable=SC2016
	printf '(label-like trigger + `cancel-in-progress: true` + no mitigation):\n\n'
	while IFS= read -r _f; do
		# shellcheck disable=SC2016
		printf '- `%s`\n' "$_f"
	done < "$_vuln_file"
	printf '\n'
	printf '### Remediation\n\n'
	# shellcheck disable=SC2016
	printf '1. Add `paths-ignore` under the trigger to scope to file-changing events\n'
	# shellcheck disable=SC2016
	printf '2. OR add a job-level `if:` guard on `github.event.action`\n'
	# shellcheck disable=SC2016
	printf '3. OR remove `cancel-in-progress: true` from the concurrency group\n\n'
	printf 'See: [t2220](https://github.com/marcusquinn/aidevops/pull/19726) (evidence), '
	printf '[t2228 parent](https://github.com/marcusquinn/aidevops/issues/19736) (remediation plan)\n\n'
	# shellcheck disable=SC2016
	printf '**Override:** apply the `workflow-cascade-ok` label AND add a '
	# shellcheck disable=SC2016
	printf '`## Workflow Cascade Justification` section to the PR description.\n'
	return 0
}

# ─── Argument parsing ────────────────────────────────────────────────────────

# Globals set by parse_args (used by main)
_G_DRY_RUN=0
_G_SCAN_DIR=".github/workflows"
_G_OUTPUT_MD=""
_G_FILES=""
_G_FILE_COUNT=0

parse_args() {
	while [ $# -gt 0 ]; do
		local _arg="$1"
		case "$_arg" in
		--dry-run)
			_G_DRY_RUN=1
			shift
			;;
		--scan-dir)
			if [ $# -lt 2 ]; then die "--scan-dir requires a directory argument"; fi
			local _val_dir="$2"
			_G_SCAN_DIR="$_val_dir"
			shift 2
			;;
		--output-md)
			if [ $# -lt 2 ]; then die "--output-md requires a file path argument"; fi
			local _val_md="$2"
			_G_OUTPUT_MD="$_val_md"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			die "Unknown option: $_arg"
			;;
		*)
			_G_FILES="${_G_FILES}${_G_FILES:+$'\n'}$_arg"
			_G_FILE_COUNT=$((_G_FILE_COUNT + 1))
			shift
			;;
		esac
	done
	return 0
}

# collect_files — populate _G_FILES from _G_SCAN_DIR when no explicit files given
collect_files() {
	if [ "$_G_FILE_COUNT" -gt 0 ]; then
		return 0
	fi
	if [ ! -d "$_G_SCAN_DIR" ]; then
		log "No workflow directory found at $_G_SCAN_DIR — nothing to scan."
		exit 0
	fi
	while IFS= read -r _f; do
		_G_FILES="${_G_FILES}${_G_FILES:+$'\n'}$_f"
		_G_FILE_COUNT=$((_G_FILE_COUNT + 1))
	done < <(find "$_G_SCAN_DIR" -maxdepth 1 -name '*.yml' -type f | sort)
	if [ "$_G_FILE_COUNT" -eq 0 ]; then
		log "No .yml files found in $_G_SCAN_DIR."
		exit 0
	fi
	return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
	parse_args "$@"
	collect_files

	local _vuln_count=0
	local _scanned=0
	local _vuln_tmp
	_vuln_tmp=$(mktemp)

	while IFS= read -r _f; do
		[ -z "$_f" ] && continue
		if [ ! -f "$_f" ]; then
			log "SKIP (not a file): $_f"
			continue
		fi
		_scanned=$((_scanned + 1))

		if ! check_file "$_f"; then
			_vuln_count=$((_vuln_count + 1))
			printf '%s\n' "$_f" >> "$_vuln_tmp"
			printf 'VULN %s\n' "$_f"
		fi
	done <<< "$_G_FILES"

	log "Scanned $_scanned workflow(s): $_vuln_count vulnerable."

	# Write markdown report if requested
	if [ -n "$_G_OUTPUT_MD" ]; then
		print_markdown_report "$_vuln_tmp" "$_vuln_count" "$_scanned" > "$_G_OUTPUT_MD"
	fi

	# Dry-run: always exit 0
	if [ "$_G_DRY_RUN" -eq 1 ]; then
		rm -f "$_vuln_tmp"
		exit 0
	fi

	if [ "$_vuln_count" -gt 0 ]; then
		print_report "$_vuln_tmp" "$_vuln_count"
		rm -f "$_vuln_tmp"
		exit 1
	fi

	rm -f "$_vuln_tmp"
	exit 0
}

main "$@"
