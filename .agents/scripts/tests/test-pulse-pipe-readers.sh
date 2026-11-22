#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

# GH#36240: exercise production readers with input larger than a pipe buffer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="${ROOT}/home"
mkdir -p "$HOME"

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

payload=$(awk 'BEGIN { for (i=0; i<20000; i++) print "padding padding padding padding padding padding" }')

(
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-events-tickle.sh"
	raw=$(printf 'HTTP/2 200\r\netag: W/"first"\r\n%s\nHTTP/2 304\r\netag: "second"\r\n' "$payload")
	[[ "$(_events_tickle_parse_status "$raw")" == 200 ]] || fail 'first HTTP status lost'
	[[ "$(_events_tickle_parse_etag "$raw")" == W/first ]] || fail 'first ETag lost'
	[[ -z "$(_events_tickle_parse_etag "$payload")" ]] || fail 'missing ETag fabricated'
)

(
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-dispatch-worker-launch.sh"
	output=$(printf 'Path: /first worktree\n%s\nCreated worktree at /second\n' "$payload")
	[[ "$(_dlw_extract_worktree_path_from_output "$output")" == '/first worktree' ]] || fail 'first worktree path lost'
	[[ -z "$(_dlw_extract_worktree_path_from_output "$payload")" ]] || fail 'missing worktree path fabricated'
)

(
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-dirty-pr-sweep.sh"
	body=$(printf 'Resolves #36240\n%s\nRef #1\n' "$payload")
	[[ "$(_dps_extract_linked_issue_from_body "$body")" == 36240 ]] || fail 'first issue reference lost'
	labels=$(printf 'parent-task\n%s\n' "$payload")
	_dps_labels_has "$labels" parent-task || fail 'large label list reported no match'
	status=0
	_dps_labels_has "$labels" absent-label || status=$?
	[[ "$status" == 1 ]] || fail 'negative match status changed'
)

(
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/pulse-fix-the-fixer-detector.sh"
	# Compare byte prefixes, including multibyte and newline boundaries, against
	# the production prompt built from an already-bounded body.
	export LC_ALL=C
	for body in "$payload" "$(printf '%s\n%s' 'short first line' "$payload")" "$(printf 'é%s' "$payload")" ''; do
		expected="${body:0:3000}"
		[[ "$(_compose_classification_prompt title "$body")" == "$(_compose_classification_prompt title "$expected")" ]] || fail '3KB prompt prefix changed'
	done
)

# Draining readers must not hide genuine producer errors under pipefail.
status=0
{
	printf 'match\n%s\n' "$payload"
	exit 7
} | grep match >/dev/null || status=$?
[[ "$status" == 7 ]] || fail 'grep hid producer failure'
status=0
{
	printf 'first\n%s\n' "$payload"
	exit 7
} | sed -n '1p' >/dev/null || status=$?
[[ "$status" == 7 ]] || fail 'sed hid producer failure'

printf 'PASS: Pulse large-input pipe readers\n'
