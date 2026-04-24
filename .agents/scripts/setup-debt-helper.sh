#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# setup-debt-helper.sh — Aggregate per-repo platform-secret setup debt
#
# DESCRIPTION:
#   Reads ~/.aidevops/advisories/sync-pat-*.advisory files (written by
#   security-posture-helper.sh::_emit_sync_pat_advisory, t2374) and exposes
#   the aggregated count + slug list to two consumers:
#
#     1. aidevops-update-check.sh — emits a single [WARN] toast line so the
#        OpenCode plugin classifier (greeting.mjs) escalates the toast to
#        warning tier when there is non-zero setup debt.
#     2. /setup-git slash command — walks the operator through each gap
#        with platform-specific PAT URLs and gh secret set instructions.
#
#   This helper is purely a read-side aggregator. It NEVER reads, accepts,
#   or emits secret values. It NEVER calls gh secret set. The fix path is
#   always the operator running gh secret set in a separate terminal.
#
# USAGE:
#   setup-debt-helper.sh <command> [args]
#
# COMMANDS:
#   summary [--format=human|toast|json]
#       Aggregate count + summary line.
#       human (default): 3 SYNC_PAT advisories (awardsapp/awardsapp, ...)
#       toast:           [WARN] 3 repos need SYNC_PAT setup — run /setup-git ...
#       json:            {"sync_pat_missing": [...], "count": 3}
#       Empty stdout, exit 0 when count == 0 (suppresses toast lines).
#
#   list-sync-pat-missing
#       One slug per line for repos with active (non-dismissed) SYNC_PAT
#       advisories. Suitable for piping to xargs / for-loop in /setup-git.
#       Empty stdout when none.
#
#   verify-secret <slug> <secret_name>
#       Returns 0 if the named secret exists on the repo, 1 otherwise.
#       Used by /setup-git after the operator runs gh secret set in a
#       separate terminal — confirms the secret landed without ever
#       reading its value.
#
#   help
#       Show this help.
#
# EXAMPLES:
#   setup-debt-helper.sh summary
#   setup-debt-helper.sh summary --format=toast
#   setup-debt-helper.sh list-sync-pat-missing | xargs -I{} echo "Setup: {}"
#   setup-debt-helper.sh verify-secret awardsapp/awardsapp SYNC_PAT
#
# DEPENDENCIES:
#   - jq (for --format=json)
#   - gh (for verify-secret only)
#
# AUTHOR: AI DevOps Framework
# VERSION: 1.0.0
# LICENSE: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly ADVISORIES_DIR="${HOME}/.aidevops/advisories"
readonly DISMISSED_FILE="${ADVISORIES_DIR}/dismissed.txt"
readonly SYNC_PAT_PREFIX="sync-pat-"

# -----------------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------------

# _is_dismissed: check whether an advisory ID appears in dismissed.txt.
# Args: $1 = advisory id (e.g., sync-pat-awardsapp-awardsapp)
# Returns: 0 if dismissed, 1 otherwise
_is_dismissed() {
	local adv_id="$1"
	[[ -f "$DISMISSED_FILE" ]] || return 1
	grep -qxF "$adv_id" "$DISMISSED_FILE" 2>/dev/null
}

# _slug_from_filename: reconstruct OWNER/REPO slug from advisory filename.
# Files are named sync-pat-OWNER-REPO.advisory; the slash is replaced with
# a hyphen at write time. We split on the LAST hyphen so OWNER may itself
# contain hyphens (e.g., essentials-com/essentials.com → essentials-com-essentials.com → split → essentials-com/essentials.com).
# Args: $1 = filename without prefix or extension (e.g., awardsapp-awardsapp)
# Returns: slug on stdout, or empty string if the filename has no separator
_slug_from_filename() {
	local stem="$1"
	# Find the LAST hyphen and split there
	local owner repo
	owner="${stem%-*}"
	repo="${stem##*-}"
	if [[ "$owner" == "$stem" ]]; then
		# No hyphen — malformed advisory filename
		echo ""
		return 0
	fi
	echo "${owner}/${repo}"
	return 0
}

# _collect_sync_pat_slugs: emit one slug per line for non-dismissed advisories.
# Stable sort order so test-script assertions are deterministic.
_collect_sync_pat_slugs() {
	if [[ ! -d "$ADVISORIES_DIR" ]]; then
		return 0
	fi

	local advisory_file
	# shellcheck disable=SC2231
	for advisory_file in "$ADVISORIES_DIR"/${SYNC_PAT_PREFIX}*.advisory; do
		[[ -f "$advisory_file" ]] || continue

		local basename adv_id stem slug
		basename="$(basename "$advisory_file" .advisory)"
		adv_id="$basename"
		stem="${basename#"$SYNC_PAT_PREFIX"}"

		if _is_dismissed "$adv_id"; then
			continue
		fi

		slug="$(_slug_from_filename "$stem")"
		[[ -n "$slug" ]] || continue

		echo "$slug"
	done | sort -u
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: summary
# -----------------------------------------------------------------------------

_cmd_summary() {
	local format="human"
	local -a args=("$@")
	local arg
	local i=0
	local arg_count=${#args[@]}

	while [[ $i -lt $arg_count ]]; do
		arg="${args[i]}"
		case "$arg" in
		--format=*)
			format="${arg#--format=}"
			;;
		--format)
			i=$((i + 1))
			format="${args[i]:-human}"
			;;
		--help | -h)
			echo "Usage: setup-debt-helper.sh summary [--format=human|toast|json]"
			return 0
			;;
		*)
			print_error "Unknown option for summary: $arg"
			return 1
			;;
		esac
		i=$((i + 1))
	done

	local slugs
	slugs="$(_collect_sync_pat_slugs)"

	local count=0
	if [[ -n "$slugs" ]]; then
		count=$(printf '%s\n' "$slugs" | wc -l | tr -d ' ')
	fi

	case "$format" in
	human)
		if [[ "$count" -eq 0 ]]; then
			# Suppress on zero-debt: empty stdout, exit 0
			return 0
		fi
		# Comma-separated slug list, capped at 3 with " ..."
		local slug_list
		slug_list="$(printf '%s\n' "$slugs" | head -3 | tr '\n' ',' | sed 's/,$//;s/,/, /g')"
		if [[ "$count" -gt 3 ]]; then
			slug_list="${slug_list}, +$((count - 3)) more"
		fi
		printf '%d SYNC_PAT advisor%s (%s)\n' "$count" "$([[ "$count" -eq 1 ]] && echo "y" || echo "ies")" "$slug_list"
		;;
	toast)
		if [[ "$count" -eq 0 ]]; then
			# Suppress on zero-debt: empty stdout, exit 0. The plugin will
			# omit the warning-tier line when nothing is emitted here.
			return 0
		fi
		# Single line, [WARN] prefix so greeting.mjs::classifyLines buckets
		# this into the warning tier (15s display, more prominent than the
		# per-repo [ADVISORY] info-tier lines below).
		# Singular: "1 repo needs"; plural: "N repos need"
		if [[ "$count" -eq 1 ]]; then
			printf '[WARN] 1 repo needs SYNC_PAT setup — run /setup-git in OpenCode or Claude Code\n'
		else
			printf '[WARN] %d repos need SYNC_PAT setup — run /setup-git in OpenCode or Claude Code\n' "$count"
		fi
		;;
	json)
		if ! command -v jq >/dev/null 2>&1; then
			print_error "--format=json requires jq"
			return 1
		fi
		local slugs_json
		if [[ -n "$slugs" ]]; then
			slugs_json="$(printf '%s\n' "$slugs" | jq -R . | jq -s .)"
		else
			slugs_json="[]"
		fi
		jq -n --argjson slugs "$slugs_json" --argjson count "$count" \
			'{sync_pat_missing: $slugs, count: $count}'
		;;
	*)
		print_error "Unknown format: $format (expected: human, toast, json)"
		return 1
		;;
	esac

	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: list-sync-pat-missing
# -----------------------------------------------------------------------------

_cmd_list_sync_pat_missing() {
	_collect_sync_pat_slugs
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: verify-secret
# -----------------------------------------------------------------------------

_cmd_verify_secret() {
	local slug="${1:-}"
	local name="${2:-}"

	if [[ -z "$slug" || -z "$name" ]]; then
		print_error "Usage: setup-debt-helper.sh verify-secret <slug> <secret_name>"
		return 2
	fi

	if ! command -v gh >/dev/null 2>&1; then
		print_error "gh CLI not installed — cannot verify secret presence"
		return 2
	fi

	if ! gh auth status >/dev/null 2>&1; then
		print_error "gh not authenticated — run gh auth login"
		return 2
	fi

	local found
	found="$(gh secret list --repo "$slug" --json name -q ".[] | select(.name == \"${name}\") | .name" 2>/dev/null)" || found=""

	if [[ -n "$found" ]]; then
		print_success "$name is set for $slug"
		return 0
	fi

	print_warn "$name is NOT set for $slug"
	return 1
}

# -----------------------------------------------------------------------------
# CLI dispatch
# -----------------------------------------------------------------------------

_usage() {
	cat <<'EOF'
setup-debt-helper.sh — Aggregate per-repo platform-secret setup debt

Usage:
  setup-debt-helper.sh <command> [args]

Commands:
  summary [--format=human|toast|json]   Aggregate count + summary line
  list-sync-pat-missing                 One slug per line, non-dismissed only
  verify-secret <slug> <secret_name>    Check if a secret exists on a repo
  help                                  Show this help

Examples:
  setup-debt-helper.sh summary
  setup-debt-helper.sh summary --format=toast
  setup-debt-helper.sh list-sync-pat-missing
  setup-debt-helper.sh verify-secret awardsapp/awardsapp SYNC_PAT

Emits no output and returns 0 when there is no setup debt; this is the
intended quiet-on-clean signal for toast suppression.

See also:
  /setup-git                       Slash command that consumes this helper
  aidevops security check          Generates the SYNC_PAT advisories
  scripts/commands/setup-git.md    Slash command spec
  reference/sync-pat-platforms.md  PAT URL templates and scopes per platform
EOF
	return 0
}

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	summary)
		_cmd_summary "$@"
		;;
	list-sync-pat-missing)
		_cmd_list_sync_pat_missing
		;;
	verify-secret)
		_cmd_verify_secret "$@"
		;;
	help | --help | -h)
		_usage
		;;
	*)
		print_error "Unknown command: $cmd"
		_usage >&2
		return 1
		;;
	esac

	return $?
}

# Only run main when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
