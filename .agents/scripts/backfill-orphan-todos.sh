#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# backfill-orphan-todos.sh — one-shot repair tool for the t2548 orphan bug.
#
# Scans a repo's GitHub issues for "orphans" — issues whose title starts
# with `tNNN: ` but whose `tNNN` ID has NO matching entry in TODO.md.
# These are the pre-fix leakage from `claim-task-id.sh` creating issues
# without writing TODO.md (fixed in t2548 / GH#20180).
#
# Behaviour:
#   - `list` (default): print each orphan as `tNNN<TAB>GH#<num><TAB>title`
#   - `annotate`: append a `- [ ] tNNN <title> ref:GH#<num>` entry to
#     the `## Backlog` section of TODO.md for every open orphan.
#     Idempotent — skips IDs that already exist in TODO.md.
#     WRITES TODO.md in place; run inside a worktree, commit, PR.
#
# Scope:
#   - Open issues only by default. Use `--include-closed` to also
#     annotate orphans from closed issues (for audit-trail completeness).
#   - Only issues whose title matches `^t[0-9]+: `. Issues using
#     `GH#NNN:` or other prefix formats are not considered orphans.
#
# Usage:
#   backfill-orphan-todos.sh list [--repo <path>] [--include-closed]
#   backfill-orphan-todos.sh annotate [--repo <path>] [--include-closed] [--dry-run]
#
# Exit codes:
#   0  - success (or no orphans found)
#   1  - error (missing gh, no TODO.md, etc.)
#
# Cross-references:
#   - t2548: root-cause fix (claim-task-id.sh::_ensure_todo_entry_written)
#   - Evidence corpus: johnwaldo/ilds (9 open orphans 2026-04-20)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Fallback log/print helpers if shared-constants.sh isn't available.
if ! declare -F print_info >/dev/null 2>&1; then
	print_info() { printf '[INFO] %s\n' "$*" >&2; }
fi
if ! declare -F print_warning >/dev/null 2>&1; then
	print_warning() { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F print_error >/dev/null 2>&1; then
	print_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi

usage() {
	sed -n '7,32p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

COMMAND=""
REPO_PATH=""
INCLUDE_CLOSED=false
DRY_RUN=false

parse_args() {
	local cmd="$1"
	COMMAND="${cmd:-list}"
	shift || true
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		shift
		case "$flag" in
		--repo)
			local val="$1"
			REPO_PATH="$val"
			shift
			;;
		--include-closed)
			INCLUDE_CLOSED=true
			;;
		--dry-run)
			DRY_RUN=true
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			print_error "unknown flag: $flag"
			usage
			exit 1
			;;
		esac
	done
	return 0
}

parse_args "$@"

if [[ -z "$REPO_PATH" ]]; then
	REPO_PATH="$(pwd)"
fi

if ! command -v gh >/dev/null 2>&1; then
	print_error "gh CLI not found"
	exit 1
fi

TODO_FILE="${REPO_PATH}/TODO.md"
if [[ ! -f "$TODO_FILE" ]]; then
	print_error "no TODO.md at ${REPO_PATH}"
	exit 1
fi

SLUG=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null \
	| sed 's|.*github\.com[:/]||;s|\.git$||' || true)
if [[ -z "$SLUG" ]]; then
	print_error "could not resolve GitHub slug from origin remote in ${REPO_PATH}"
	exit 1
fi

# Fetch issue titles + numbers (tNNN-prefixed only).
STATE_FILTER="open"
if [[ "$INCLUDE_CLOSED" == "true" ]]; then
	STATE_FILTER="all"
fi

print_info "scanning ${SLUG} (${STATE_FILTER}) for tNNN: orphans..."

ISSUES_JSON=$(gh issue list --repo "$SLUG" --state "$STATE_FILTER" \
	--search "t in:title" --limit 1000 \
	--json number,title 2>/dev/null || echo "[]")

# Parse with jq: keep only titles matching ^t[0-9]+:
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
	print_info "no tNNN-prefixed issues found"
	exit 0
fi

# Load TODO.md IDs once (outside code fences, via literal scan is fine for
# this audit — false-positives inside code fences just mean we SKIP a real
# orphan, which is safe).
declare -a ORPHANS=()

while IFS=$'\t' read -r task_id issue_num title; do
	[[ -z "$task_id" || -z "$issue_num" ]] && continue
	# Check whether TODO.md has a `- [.] tNNN ` entry outside code fences
	# (rough check: grep the whole file — if TODO.md has tNNN anywhere
	# as a task line, assume it's tracked).
	if grep -qE "^[[:space:]]*- \[.\] ${task_id}( |\$)" "$TODO_FILE"; then
		continue
	fi
	ORPHANS+=("${task_id}"$'\t'"${issue_num}"$'\t'"${title}")
done <<<"$CANDIDATES"

ORPHAN_COUNT=${#ORPHANS[@]}

if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
	print_info "no orphans found in ${SLUG}"
	exit 0
fi

case "$COMMAND" in
list)
	print_info "${ORPHAN_COUNT} orphan(s) in ${SLUG}:"
	printf '%s\n' "${ORPHANS[@]}"
	exit 0
	;;
annotate)
	print_info "${ORPHAN_COUNT} orphan(s) to annotate in ${TODO_FILE}"
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] would append:"
		for row in "${ORPHANS[@]}"; do
			IFS=$'\t' read -r task_id issue_num title <<<"$row"
			desc="${title#"${task_id}": }"
			printf '  - [ ] %s %s ref:GH#%s\n' "$task_id" "$desc" "$issue_num"
		done
		exit 0
	fi

	# Find ## Backlog insertion point.
	BACKLOG_LINE=$(grep -nE '^## Backlog[[:space:]]*$' "$TODO_FILE" 2>/dev/null | head -1 | cut -d: -f1 || true)

	TMP=$(mktemp)
	trap 'rm -f "$TMP"' EXIT

	if [[ -n "$BACKLOG_LINE" ]]; then
		NEXT_HEADING=$(awk -v s="$BACKLOG_LINE" 'NR > s && /^## / {print NR; exit}' "$TODO_FILE" 2>/dev/null || true)
		# Build the block of lines to insert.
		BLOCK=""
		for row in "${ORPHANS[@]}"; do
			IFS=$'\t' read -r task_id issue_num title <<<"$row"
			desc="${title#"${task_id}": }"
			BLOCK+="- [ ] ${task_id} ${desc} ref:GH#${issue_num}"$'\n'
		done

		if [[ -z "$NEXT_HEADING" ]]; then
			# Backlog is last — append block at end of file.
			cat "$TODO_FILE" >"$TMP"
			# Ensure trailing newline, then block.
			[[ -n "$(tail -c 1 "$TMP" 2>/dev/null)" ]] && printf '\n' >>"$TMP"
			printf '%s' "$BLOCK" >>"$TMP"
		else
			# Insert block immediately before NEXT_HEADING.
			awk -v nh="$NEXT_HEADING" -v block="$BLOCK" '
				NR == nh { printf "%s\n", block }
				{ print }
			' "$TODO_FILE" >"$TMP"
		fi
	else
		# No Backlog — append with heading.
		cat "$TODO_FILE" >"$TMP"
		printf '\n## Backlog (t2548 backfill)\n\n' >>"$TMP"
		for row in "${ORPHANS[@]}"; do
			IFS=$'\t' read -r task_id issue_num title <<<"$row"
			desc="${title#"${task_id}": }"
			printf -- '- [ ] %s %s ref:GH#%s\n' "$task_id" "$desc" "$issue_num" >>"$TMP"
		done
	fi

	mv "$TMP" "$TODO_FILE"
	trap - EXIT
	print_info "annotated ${ORPHAN_COUNT} orphan(s) into ${TODO_FILE} — review with 'git diff' and commit"
	exit 0
	;;
*)
	print_error "unknown command: ${COMMAND}"
	usage
	exit 1
	;;
esac
