#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# backfill-orphan-todos.sh — one-shot repair tool for the t2548 orphan bug.
#
# Scans a repo's GitHub issues for "orphans" — issues whose title starts
# with `tNNN: ` but whose `tNNN` ID has NO matching entry in TODO.md.
# These are pre-fix leakage from `claim-task-id.sh` creating issues
# without writing TODO.md (fixed in t2548 / GH#20180).
#
# Behaviour:
#   list     (default) — print each orphan as `tNNN<TAB>GH#<num><TAB>title`
#   annotate — append a `- [ ] tNNN <title> ref:GH#<num>` entry to the
#              `## Backlog` section of TODO.md for every open orphan.
#              Idempotent: skips IDs already in TODO.md.
#              WRITES TODO.md in place; run inside a worktree, commit, PR.
#
# Scope:
#   - Open issues only by default. Use `--include-closed` to also
#     annotate orphans from closed issues (audit-trail completeness).
#   - Only issues whose title matches `^t[0-9]+: ` are considered orphans.
#
# Usage:
#   backfill-orphan-todos.sh list [--repo-path <path>] [--include-closed]
#   backfill-orphan-todos.sh annotate [--repo-path <path>] [--include-closed] [--dry-run]
#
# Exit codes:
#   0 — success (or no orphans found)
#   1 — error (missing gh, no TODO.md, etc.)
#
# Cross-references:
#   - t2548: root-cause fix (claim-task-id.sh::_ensure_todo_entry_written)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Fallback helpers when shared-constants.sh is unavailable.
if ! declare -F print_info >/dev/null 2>&1; then
	print_info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
fi
if ! declare -F print_warning >/dev/null 2>&1; then
	print_warning() { printf '[WARN] %s\n' "$*" >&2; return 0; }
fi
if ! declare -F print_error >/dev/null 2>&1; then
	print_error() { printf '[ERROR] %s\n' "$*" >&2; return 0; }
fi

usage() {
	sed -n '7,30p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

COMMAND="list"
REPO_PATH=""
INCLUDE_CLOSED=false
DRY_RUN=false

_parse_args() {
	local cmd="${1:-list}"
	COMMAND="$cmd"
	shift || true
	while [[ $# -gt 0 ]]; do
		local flag="$1"; shift
		case "$flag" in
		--repo-path)
			local _rp_val="$1"; shift
			REPO_PATH="$_rp_val" ;;
		--include-closed)
			INCLUDE_CLOSED=true ;;
		--dry-run)
			DRY_RUN=true ;;
		-h|--help)
			usage; exit 0 ;;
		*)
			print_error "unknown flag: $flag"; usage; exit 1 ;;
		esac
	done
	return 0
}
_parse_args "$@"

[[ -z "$REPO_PATH" ]] && REPO_PATH="$(pwd)"

if ! command -v gh >/dev/null 2>&1; then
	print_error "gh CLI not found"; exit 1
fi

TODO_FILE="${REPO_PATH}/TODO.md"
if [[ ! -f "$TODO_FILE" ]]; then
	print_error "no TODO.md at ${REPO_PATH}"; exit 1
fi

SLUG=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null \
	| sed 's|.*github\.com[:/]||;s|\.git$||' || true)
if [[ -z "$SLUG" ]]; then
	print_error "could not resolve GitHub slug from origin remote in ${REPO_PATH}"
	exit 1
fi

STATE_FILTER="open"
[[ "$INCLUDE_CLOSED" == "true" ]] && STATE_FILTER="all"

print_info "scanning ${SLUG} (${STATE_FILTER}) for tNNN: orphans..."

ISSUES_JSON=$(gh issue list --repo "$SLUG" --state "$STATE_FILTER" \
	--search "t in:title" --limit 1000 \
	--json number,title 2>/dev/null || echo "[]")

CANDIDATES=$(printf '%s' "$ISSUES_JSON" | jq -r '
	.[]
	| select(.title | test("^t[0-9]+:"))
	| [
		(.title | capture("^(?<id>t[0-9]+):") | .id),
		(.number | tostring),
		.title
	]
	| @tsv
' 2>/dev/null || echo "")

if [[ -z "$CANDIDATES" ]]; then
	print_info "no tNNN-prefixed issues found"; exit 0
fi

declare -a ORPHANS=()

_find_orphans() {
	local task_id issue_num title
	while IFS=$'\t' read -r task_id issue_num title; do
		[[ -z "$task_id" || -z "$issue_num" ]] && continue
		if grep -qE "^[[:space:]]*- \[.\] ${task_id}( |$)" "$TODO_FILE"; then
			continue
		fi
		ORPHANS+=("${task_id}"$'\t'"${issue_num}"$'\t'"${title}")
	done <<<"$CANDIDATES"
	return 0
}
_find_orphans

ORPHAN_COUNT=${#ORPHANS[@]}

if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
	print_info "no orphans found in ${SLUG}"; exit 0
fi

_annotate_orphans() {
	print_info "${ORPHAN_COUNT} orphan(s) to annotate in ${TODO_FILE}"
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] would append:"
		local row task_id issue_num title desc
		for row in "${ORPHANS[@]}"; do
			IFS=$'\t' read -r task_id issue_num title <<<"$row"
			desc="${title#"${task_id}": }"
			printf '  - [ ] %s %s ref:GH#%s\n' "$task_id" "$desc" "$issue_num"
		done
		return 0
	fi

	local backlog_start
	backlog_start=$(grep -nE '^## Backlog[[:space:]]*$' "$TODO_FILE" 2>/dev/null \
		| head -1 | cut -d: -f1 || true)

	local tmp
	tmp=$(mktemp)
	trap 'rm -f "$tmp"' RETURN

	local row task_id issue_num title desc
	for row in "${ORPHANS[@]}"; do
		IFS=$'\t' read -r task_id issue_num title <<<"$row"
		desc="${title#"${task_id}": }"
		local todo_line="- [ ] ${task_id} ${desc} ref:GH#${issue_num}"

		if [[ -n "$backlog_start" ]]; then
			local next_heading
			next_heading=$(awk -v s="$backlog_start" \
				'NR > s && /^## / {print NR; exit}' "$TODO_FILE" 2>/dev/null || true)
			if [[ -z "$next_heading" ]]; then
				cat "$TODO_FILE" >"$tmp"
				[[ -n "$(tail -c 1 "$tmp")" ]] && printf '\n' >>"$tmp"
				printf '%s\n' "$todo_line" >>"$tmp"
			else
				awk -v nh="$next_heading" -v line="$todo_line" '
					NR == nh { print line; print "" }
					{ print }
				' "$TODO_FILE" >"$tmp"
			fi
		else
			cat "$TODO_FILE" >"$tmp"
			printf '\n## Backlog (t2548 backfill)\n\n%s\n' "$todo_line" >>"$tmp"
		fi

		[[ -s "$tmp" ]] && mv "$tmp" "$TODO_FILE"
		# Recompute backlog_start for the next iteration (file grew).
		backlog_start=$(grep -nE '^## Backlog' "$TODO_FILE" 2>/dev/null \
			| head -1 | cut -d: -f1 || true)
	done

	print_info "annotated ${ORPHAN_COUNT} orphan(s) — review 'git diff' and commit"
	return 0
}

case "$COMMAND" in
list)
	print_info "${ORPHAN_COUNT} orphan(s) in ${SLUG}:"
	printf '%s\n' "${ORPHANS[@]}"
	exit 0
	;;
annotate)
	_annotate_orphans
	exit 0
	;;
*)
	print_error "unknown command: ${COMMAND}"; usage; exit 1 ;;
esac
