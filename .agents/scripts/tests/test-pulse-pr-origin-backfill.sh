#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Exercise the PR backfill with live state changing between pulse cycles.
set -eu
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/pr-origin-test.XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT
LOGFILE="$TEST_TMPDIR/pulse.log"
TRACE="$TEST_TMPDIR/trace"
touch "$LOGFILE" "$TRACE"
source "$TEST_DIR/../pulse-issue-reconcile.sh"

gh() {
	local endpoint="${2:-}"
	if [[ "$endpoint" == *'pulls?state=open&per_page=100' ]]; then
		printf '%s\n' '[{"number":1},{"number":2},{"number":3},{"number":4},{"number":5}]'
		return 0
	fi
	local number="${endpoint##*/}" body='<!-- aidevops:origin:worker -->\n<!-- aidevops:sig -->' labels='[]' login='writer'
	case "$number" in
	2) login='outsider' ;;
	3) labels='[{"name":"origin:interactive"}]' ;;
	4) body='<!-- aidevops:origin:worker -->\n<!-- aidevops:origin:interactive -->\n<!-- aidevops:sig -->' ;;
	5) body='<!-- aidevops:origin:interactive -->\n<!-- aidevops:sig -->' ;;
	esac
	if [[ -f "$TEST_TMPDIR/applied-$number" ]]; then labels='[{"name":"origin:worker"}]'; fi
	printf '{"state":"open","pull_request":{},"labels":%s,"body":"%s","user":{"login":"%s"},"author_association":"CONTRIBUTOR"}\n' "$labels" "$body" "$login"
	return 0
}

_gh_actor_has_repo_write_authority() {
	local slug="$1" login="$2" association="$3"
	[[ "$slug" == 'test/repo' && "$login" == 'writer' && "$association" == 'CONTRIBUTOR' ]] || return 1
	return 0
}

set_origin_label() {
	local number="$1" slug="$2" origin="$3" mode="$4"
	printf '%s %s %s %s\n' "$number" "$slug" "$origin" "$mode" >>"$TRACE"
	touch "$TEST_TMPDIR/applied-$number"
	return 0
}

_pir_backfill_pr_origin 'test/repo'
_pir_backfill_pr_origin 'test/repo'
expected=$(printf '1 test/repo worker --pr\n5 test/repo interactive --pr')
actual=$(<"$TRACE")
if [[ "$actual" != "$expected" ]]; then
	printf 'FAIL: unexpected writes: %s\n' "$actual" >&2
	exit 1
fi
printf 'PASS: trusted PR origin backfill and idempotency\n'
