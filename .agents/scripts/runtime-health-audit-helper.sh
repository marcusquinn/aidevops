#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091
#
# runtime-health-audit-helper.sh — Surface operational bugs the supervisor blind-spots (t3072).
#
# The supervisor LLM cycle triages GitHub state — issues, PRs, labels, scanner
# findings — but never inspects processes, logs, pulse-stats counters, or
# deployed-script mtimes. That is a structural blind spot. Bugs visible to
# any interactive operator running `ps`, `jq`, `tail` go unraised for hours.
#
# This helper runs a registry of small detectors against local files only
# (no GitHub or GraphQL calls — that would amplify the very problem several
# of the detectors surface). When a detector fires, the helper either
# prints the finding (--dry-run, default) or files an auto-dispatch issue
# tagged with a generator marker that the pre-dispatch validator can
# re-evaluate before a worker is spawned.
#
# Detector files live in `.agents/scripts/runtime-audit-rules/*.sh`. Each
# file sources a single function: `runtime_audit_check`. See any rule file
# for the contract.
#
# Usage:
#   runtime-health-audit-helper.sh [--dry-run|--apply] [--only <id>] [--repo <slug>] [--json]
#
# Subcommands:
#   list        — list registered detectors
#   help        — print usage
#   (default)   — run all detectors
#
# Exit codes:
#   0  — completed (with or without findings)
#   1  — fatal error (missing dependency, unreadable rules dir)
#
# Idempotency: each filed issue uses the marker
#   <!-- aidevops:generator=runtime-audit detector=<id> -->
# Before filing, the helper searches for an existing OPEN issue with the
# same marker. If one is found, the new finding is appended as a comment
# rather than re-filing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Optional: gh wrappers (only required for --apply path)
GH_WRAPPERS="${SCRIPT_DIR}/shared-gh-wrappers.sh"

RULES_DIR="${RUNTIME_AUDIT_RULES_DIR:-${SCRIPT_DIR}/runtime-audit-rules}"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
readonly MODE_DRY_RUN="dry-run"
readonly MODE_APPLY="apply"

MODE="$MODE_DRY_RUN"
ONLY_ID=""
REPO_SLUG=""
JSON_OUTPUT=0
SUBCMD=""

_usage() {
	cat <<EOF
Usage: $(basename "$0") [options] [list|help]

Options:
  --dry-run        Print findings to stdout, do not file issues (default)
  --apply          File auto-dispatch issues for findings
  --only <id>      Run only the detector with the given id
  --repo <slug>    Target repo for --apply (default: current repo from gh)
  --json           Emit JSONL findings (machine-readable; implies --dry-run)

Subcommands:
  list             List registered detectors and exit
  help, --help     Print this help

Detector contract: each file in ${RULES_DIR}/*.sh must define
runtime_audit_check (returns 0 = clean, 1 = finding) and runtime_audit_id
(prints stable identifier).

EOF
	return 0
}

_parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		local next="${2:-}"
		case "$arg" in
			--dry-run) MODE="$MODE_DRY_RUN"; shift ;;
			--apply)   MODE="$MODE_APPLY"; shift ;;
			--only)    ONLY_ID="$next"; shift 2 ;;
			--repo)    REPO_SLUG="$next"; shift 2 ;;
			--json)    JSON_OUTPUT=1; shift ;;
			list)      SUBCMD="list"; shift ;;
			help|--help|-h) _usage; exit 0 ;;
			*) print_warning "Unknown argument: $arg"; _usage; exit 1 ;;
		esac
	done
	return 0
}
_parse_args "$@"

# ---------------------------------------------------------------------------
# Detector discovery
# ---------------------------------------------------------------------------
_list_detectors() {
	local f
	if [[ ! -d "$RULES_DIR" ]]; then
		return 0
	fi
	for f in "$RULES_DIR"/*.sh; do
		[[ -f "$f" ]] || continue
		printf '%s\n' "$f"
	done
	return 0
}

if [[ "$SUBCMD" == "list" ]]; then
	for f in $(_list_detectors); do
		# Source in subshell to extract id without polluting parent env
		id=$(bash -c "source '$f'; runtime_audit_id" 2>/dev/null) || id="?"
		printf '%-40s  %s\n' "$id" "$(basename "$f")"
	done
	exit 0
fi

# ---------------------------------------------------------------------------
# Apply path: idempotency check via marker search
# ---------------------------------------------------------------------------
_resolve_repo_slug() {
	if [[ -n "$REPO_SLUG" ]]; then
		printf '%s\n' "$REPO_SLUG"
		return 0
	fi
	# Try gh repo view
	gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null
	return 0
}

_existing_open_issue_for_detector() {
	local slug="$1"
	local detector_id="$2"
	# The marker we embed in every body
	local marker="aidevops:generator=runtime-audit detector=${detector_id}"
	# Search within the repo. Pull number+url for the first match.
	gh issue list --repo "$slug" --state open --search "in:body \"${marker}\"" \
		--limit 1 --json number,url 2>/dev/null \
		| jq -r '.[0] // empty | "\(.number)\t\(.url)"' 2>/dev/null
	return 0
}

_apply_finding() {
	local slug="$1"
	local detector_id="$2"
	local title="$3"
	local body="$4"

	# Idempotency check
	local existing
	existing=$(_existing_open_issue_for_detector "$slug" "$detector_id")
	if [[ -n "$existing" ]]; then
		local exist_num exist_url
		IFS=$'\t' read -r exist_num exist_url <<<"$existing"
		print_info "runtime-audit: detector=${detector_id} already has open issue #${exist_num} (${exist_url}) — skipping new file, posting refresh comment"
		# Optional: append a refresh comment (small)
		local refresh_body
		# shellcheck disable=SC2016  # intentional literal markdown backticks in format string
		refresh_body=$(printf '> Detector \`%s\` re-fired at %s. Most recent evidence:\n\n%s\n' \
			"$detector_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$body")
		# shellcheck source=./shared-gh-wrappers.sh
		if [[ -f "$GH_WRAPPERS" ]]; then
			source "$GH_WRAPPERS"
			gh_issue_comment "$exist_num" --repo "$slug" --body "$refresh_body" >/dev/null 2>&1 \
				|| print_warning "runtime-audit: refresh comment failed for #${exist_num}"
		fi
		return 0
	fi

	# Create a fresh issue
	if [[ ! -f "$GH_WRAPPERS" ]]; then
		print_error "runtime-audit: gh wrappers not found at ${GH_WRAPPERS} — cannot --apply"
		return 1
	fi
	# shellcheck source=./shared-gh-wrappers.sh
	source "$GH_WRAPPERS"
	local labels="auto-dispatch,tier:standard,bug,framework,source:runtime-audit"
	local issue_url
	issue_url=$(gh_create_issue --repo "$slug" --title "$title" --body "$body" --label "$labels" 2>&1) || {
		print_error "runtime-audit: gh issue create failed for detector=${detector_id}: $issue_url"
		return 1
	}
	print_success "runtime-audit: filed ${issue_url} for detector=${detector_id}"
	return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
if [[ ! -d "$RULES_DIR" ]]; then
	print_error "runtime-audit: rules directory not found: $RULES_DIR"
	exit 1
fi

# Resolve apply-mode prerequisites once
APPLY_SLUG=""
if [[ "$MODE" == "$MODE_APPLY" ]]; then
	APPLY_SLUG=$(_resolve_repo_slug)
	if [[ -z "$APPLY_SLUG" ]]; then
		print_error "runtime-audit: --apply requires --repo <slug> or a gh repo context"
		exit 1
	fi
fi

DETECTOR_FILES=$(_list_detectors)
if [[ -z "$DETECTOR_FILES" ]]; then
	print_warning "runtime-audit: no detectors found in $RULES_DIR"
	exit 0
fi

FINDINGS_COUNT=0
RAN_COUNT=0

for f in $DETECTOR_FILES; do
	# Resolve detector id (cheap subshell)
	id=$(bash -c "source '$f'; runtime_audit_id" 2>/dev/null) || id=""
	[[ -z "$id" ]] && continue
	if [[ -n "$ONLY_ID" && "$ONLY_ID" != "$id" ]]; then
		continue
	fi
	RAN_COUNT=$((RAN_COUNT + 1))

	# Run check in a subshell so detector globals do not leak between rules.
	# The check function emits exactly one JSON object on stdout when it
	# finds something, and exits 1. Otherwise it exits 0 with no output.
	local_output=""
	local_rc=0
	local_output=$(bash -c "
		set -u
		source '${SCRIPT_DIR}/shared-constants.sh'
		source '$f'
		runtime_audit_check
	" 2>/dev/null) || local_rc=$?

	if [[ "$local_rc" -eq 0 ]]; then
		print_info "runtime-audit: detector=${id} clean"
		continue
	fi

	if [[ -z "$local_output" ]]; then
		print_warning "runtime-audit: detector=${id} returned non-zero but emitted no output — skipping"
		continue
	fi

	# Parse the JSON
	finding_id=$(printf '%s' "$local_output" | jq -r '.id // empty' 2>/dev/null)
	finding_title=$(printf '%s' "$local_output" | jq -r '.title // empty' 2>/dev/null)
	finding_body=$(printf '%s' "$local_output" | jq -r '.body // empty' 2>/dev/null)

	if [[ -z "$finding_id" || -z "$finding_title" || -z "$finding_body" ]]; then
		print_warning "runtime-audit: detector=${id} produced unparseable output — skipping"
		continue
	fi

	FINDINGS_COUNT=$((FINDINGS_COUNT + 1))

	if [[ "$JSON_OUTPUT" -eq 1 ]]; then
		printf '%s\n' "$local_output"
		continue
	fi

	if [[ "$MODE" == "$MODE_DRY_RUN" ]]; then
		printf '\n========================================================================\n'
		printf 'FINDING: %s\n' "$finding_title"
		printf 'detector=%s\n' "$finding_id"
		printf '========================================================================\n\n'
		printf '%s\n' "$finding_body"
		continue
	fi

	# apply mode
	_apply_finding "$APPLY_SLUG" "$finding_id" "$finding_title" "$finding_body" \
		|| print_warning "runtime-audit: apply failed for detector=${finding_id}"
done

print_info "runtime-audit: ran ${RAN_COUNT} detector(s), ${FINDINGS_COUNT} finding(s) (mode=${MODE})"
exit 0
