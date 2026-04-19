#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# parent-task-keyword-guard.sh — t2046 PR keyword guard for parent-task issues
# =============================================================================
#
# Prevents the auto-close trap: PR bodies using Resolves/Closes/Fixes on a
# parent-task-labeled issue cause GitHub to auto-close the parent on merge,
# requiring manual reopen (incident: PR #18581 → GH#18458 closed prematurely).
#
# Parent issues must stay open until ALL phase children merge. PR bodies for
# parent-task work MUST use `For #NNN` or `Ref #NNN`, not closing keywords.
#
# Usage:
#   parent-task-keyword-guard.sh check-body --body-file PATH --repo OWNER/REPO [--strict] [--allow-parent-close]
#   parent-task-keyword-guard.sh check-pr <PR_NUMBER> --repo OWNER/REPO [--strict] [--allow-parent-close]
#   parent-task-keyword-guard.sh help
#
# Exit codes:
#   0 — no violations (clean or --allow-parent-close set)
#   1 — warning: closing keyword references a parent-task issue (non-strict mode)
#   2 — block: closing keyword references a parent-task issue (--strict mode)
#
# The `--strict` flag is used by `full-loop-helper.sh commit-and-pr` to abort
# PR creation before the PR is submitted. Use `--allow-parent-close` only for
# the legitimate final-phase PR that intentionally closes the parent tracker.
#
# Non-strict mode (default): prints a warning and exits 1, but does not abort.
# Strict mode: prints an error and exits 2, intended to abort the caller.
#
# gh API failures during label lookup: fail-open (emit warning, exit 0).
# The CI workflow provides belt-and-braces for cases where the client-side
# check is skipped or gh is unavailable.
#
# See also:
#   .github/workflows/parent-task-keyword-check.yml — CI equivalent
#   .agents/AGENTS.md "Parent-task PR keyword rule"
#   templates/brief-template.md "PR Conventions"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit

# Regex that matches GitHub closing keywords followed by an issue reference.
# Matches:
#   Closes #123
#   Resolves #123
#   Fixes #123
#   closes owner/repo#123
#   RESOLVES #123
#   (with optional leading whitespace or markdown bullet prefix)
# Does NOT match: "For #123", "Ref #123", "relates to #123"
_CLOSE_KEYWORD_PATTERN='[Cc][Ll][Oo][Ss][Ee][Ss]|[Rr][Ee][Ss][Oo][Ll][Vv][Ee][Ss]|[Ff][Ii][Xx][Ee][Ss]'

# =============================================================================
# Helpers
# =============================================================================

# _strip_code_spans: read stdin, strip markdown code blocks and inline spans,
# write stdout. Bash 3.2 compatible.
# Fenced blocks (``` ... ```) are removed via an awk state machine.
# Inline code spans (`...`) are removed via sed.
# shellcheck disable=SC2016
# SC2016: single quotes in the sed pattern are intentional — backticks are
# literal sed regex characters, not shell variable/command-substitution syntax.
_strip_code_spans() {
	awk 'BEGIN{in_fence=0} /^[[:space:]]*```/{in_fence = !in_fence; next} !in_fence' |
		sed 's/`[^`]*`//g'
	return 0
}

# _extract_closing_refs: parse a PR body (stdin) and output one issue number
# per line for each closing-keyword reference found.
# Handles both `#NNN` and `OWNER/REPO#NNN` formats.
# Code spans and fenced blocks are stripped first so that keywords inside
# backticks (e.g. `Resolves #N`) do not produce false positives.
_extract_closing_refs() {
	# Use grep + sed for Bash 3.2 compat (no perl regex in bash natively).
	# Pattern: keyword (space or nothing) (#NNN or owner/repo#NNN)
	_strip_code_spans |
		grep -oiE "(Closes|Resolves|Fixes)[[:space:]]+(([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)?#[0-9]+)" |
		grep -oE '#[0-9]+' |
		tr -d '#' |
		sort -un
	return 0
}

# _is_parent_task: check if a given issue number has the parent-task label.
# Args: $1=issue_number $2=repo_slug
# Returns: 0 if parent-task label present, 1 if not, 2 on gh failure
_is_parent_task() {
	local issue_number="$1"
	local repo_slug="$2"

	local labels_json gh_rc=0
	labels_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels 2>/dev/null) || gh_rc=$?

	if [[ "$gh_rc" -ne 0 || -z "$labels_json" ]]; then
		# gh API failure — cannot determine. Return 2 (uncertain).
		return 2
	fi

	local hit
	hit=$(printf '%s' "$labels_json" |
		jq -r '(.labels // [])[].name | select(. == "parent-task" or . == "meta")' | head -n 1 || true)

	if [[ -n "$hit" ]]; then
		return 0
	fi
	return 1
}

# =============================================================================
# check-body subcommand
# =============================================================================
cmd_check_body() {
	local body_file="" repo="" strict=0 allow_parent_close=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body-file)
			body_file="${2:-}"
			shift 2
			;;
		--repo)
			repo="${2:-}"
			shift 2
			;;
		--strict)
			strict=1
			shift
			;;
		--allow-parent-close)
			allow_parent_close=1
			shift
			;;
		*)
			echo "Error: Unknown argument: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$body_file" || -z "$repo" ]]; then
		echo "Error: --body-file and --repo are required" >&2
		return 1
	fi

	if [[ ! -f "$body_file" ]]; then
		echo "Error: body file not found: $body_file" >&2
		return 1
	fi

	if [[ "$allow_parent_close" -eq 1 ]]; then
		# Explicit opt-out — skip check entirely (final-phase PR exemption)
		echo "parent-task-keyword-guard: --allow-parent-close set, skipping check" >&2
		return 0
	fi

	local -a violations=()
	local -a uncertain=()
	local issue_num

	while IFS= read -r issue_num; do
		[[ -z "$issue_num" ]] && continue
		local pt_rc=0
		_is_parent_task "$issue_num" "$repo" || pt_rc=$?
		case "$pt_rc" in
		0)
			violations+=("$issue_num")
			;;
		2)
			uncertain+=("$issue_num")
			;;
		*)
			# Not a parent-task issue — clean
			;;
		esac
	done < <(_extract_closing_refs <"$body_file")

	# Report uncertain lookups (gh failure) — warn only, don't block
	local unc
	for unc in "${uncertain[@]+"${uncertain[@]}"}"; do
		printf 'parent-task-keyword-guard: WARNING: could not check labels for #%s (gh API failure); skipping\n' \
			"$unc" >&2
	done

	if [[ "${#violations[@]}" -eq 0 ]]; then
		return 0
	fi

	# Violations found
	local viol
	for viol in "${violations[@]}"; do
		if [[ "$strict" -eq 1 ]]; then
			printf 'parent-task-keyword-guard: ERROR: PR body uses Closes/Resolves/Fixes on parent-task issue #%s.\n' \
				"$viol" >&2
			printf 'parent-task-keyword-guard: Use "For #%s" or "Ref #%s" instead.\n' \
				"$viol" "$viol" >&2
			printf 'parent-task-keyword-guard: The parent issue must stay open until ALL phase children merge.\n' >&2
			printf 'parent-task-keyword-guard: To override (final-phase PR only): pass --allow-parent-close\n' >&2
		else
			printf 'parent-task-keyword-guard: WARNING: PR body uses Closes/Resolves/Fixes on parent-task issue #%s.\n' \
				"$viol" >&2
			printf 'parent-task-keyword-guard: Consider using "For #%s" or "Ref #%s" to keep the parent open.\n' \
				"$viol" "$viol" >&2
		fi
	done

	if [[ "$strict" -eq 1 ]]; then
		return 2
	fi
	return 1
}

# =============================================================================
# check-pr subcommand
# =============================================================================
cmd_check_pr() {
	local pr_number="${1:-}"
	if [[ -z "$pr_number" ]]; then
		echo "Error: Usage: parent-task-keyword-guard.sh check-pr <PR_NUMBER> --repo OWNER/REPO [--strict] [--allow-parent-close]" >&2
		return 1
	fi
	shift

	local repo="" strict=0 allow_parent_close=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="${2:-}"
			shift 2
			;;
		--strict)
			strict=1
			shift
			;;
		--allow-parent-close)
			allow_parent_close=1
			shift
			;;
		*)
			echo "Error: Unknown argument: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$repo" ]]; then
		echo "Error: --repo is required" >&2
		return 1
	fi

	# Fetch PR body
	local pr_body gh_rc=0
	pr_body=$(gh pr view "$pr_number" --repo "$repo" --json body --jq '.body' 2>/dev/null) || gh_rc=$?

	if [[ "$gh_rc" -ne 0 || -z "$pr_body" ]]; then
		printf 'parent-task-keyword-guard: WARNING: could not fetch PR #%s body (gh rc=%s); skipping check\n' \
			"$pr_number" "$gh_rc" >&2
		return 0
	fi

	# Write to a temp file and delegate to check-body.
	# NOTE: use explicit cleanup (not trap) to avoid unbound-variable error
	# under set -u when the trap fires after the local variable goes out of scope.
	local tmp_body
	tmp_body=$(mktemp)
	printf '%s\n' "$pr_body" >"$tmp_body"

	local check_args=("--body-file" "$tmp_body" "--repo" "$repo")
	[[ "$strict" -eq 1 ]] && check_args+=("--strict")
	[[ "$allow_parent_close" -eq 1 ]] && check_args+=("--allow-parent-close")

	local check_rc=0
	cmd_check_body "${check_args[@]}" || check_rc=$?
	rm -f "$tmp_body"
	return "$check_rc"
}

# =============================================================================
# show_help
# =============================================================================
show_help() {
	cat <<'EOF'
parent-task-keyword-guard.sh — PR body keyword guard for parent-task issues

Prevents closing keywords (Closes/Resolves/Fixes) from auto-closing parent-task
issues on PR merge. Parent issues must stay open until ALL phase children merge.

Usage:
  parent-task-keyword-guard.sh check-body --body-file PATH --repo OWNER/REPO [--strict] [--allow-parent-close]
  parent-task-keyword-guard.sh check-pr <PR_NUMBER> --repo OWNER/REPO [--strict] [--allow-parent-close]
  parent-task-keyword-guard.sh help

Exit codes:
  0 — clean (no violations)
  1 — warning: closing keyword on parent-task issue (non-strict mode)
  2 — block: closing keyword on parent-task issue (--strict mode, used by full-loop-helper.sh)

Flags:
  --strict             Treat violations as errors (exit 2). Used by commit-and-pr.
  --allow-parent-close Skip the check (final-phase PR exemption only).

Examples:
  # Check a PR body file before creating the PR
  parent-task-keyword-guard.sh check-body --body-file /tmp/pr-body.md --repo owner/repo --strict

  # Check an existing PR (CI usage)
  parent-task-keyword-guard.sh check-pr 12345 --repo owner/repo --strict

  # Final-phase PR that intentionally closes the parent
  parent-task-keyword-guard.sh check-body --body-file body.md --repo owner/repo --strict --allow-parent-close
EOF
	return 0
}

# =============================================================================
# main
# =============================================================================
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	check-body) cmd_check_body "$@" ;;
	check-pr) cmd_check_pr "$@" ;;
	help | --help | -h) show_help ;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help >&2
		return 1
		;;
	esac
}

main "$@"
