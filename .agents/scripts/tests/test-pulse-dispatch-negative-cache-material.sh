#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38261: ranking candidates carry no body (GH#35038). The GH#37943/#38237
# negative-cache reuse path must still survive an updatedAt bump caused only by
# runner coordination comments, and must miss on any material change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT"
LOGFILE="$TEST_ROOT/pulse.log"
GH_CALLS="$TEST_ROOT/gh-calls"
# shellcheck source=../pulse-dispatch-lib.sh
source "$SCRIPT_DIR/../pulse-dispatch-lib.sh"

timeout_sec() { shift; "$@"; return $?; }
ISSUE_JSON=""
COMMENTS_JSON="[]"
gh() {
	[[ "${1:-}" == api ]] || return 1
	printf '%s\n' "$2" >>"$GH_CALLS"
	case "$2" in
	repos/example/repo/issues/38261) [[ -n "$ISSUE_JSON" ]] || return 1; printf '%s\n' "$ISSUE_JSON" ;;
	repos/example/repo/issues/38261/comments*) printf '%s\n' "$COMMENTS_JSON" ;;
	*) return 1 ;;
	esac
	return 0
}

PASS=0
FAIL=0
check() {
	local name="$1"
	shift
	if "$@"; then
		PASS=$((PASS + 1))
		printf 'PASS %s\n' "$name"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL %s\n' "$name" >&2
	fi
	return 0
}

# Production ranking shape: no body, label/assignee names as strings.
candidate_at() {
	local updated="$1"
	jq -cn --arg updated "$updated" '{number: 38261, repo_slug: "example/repo",
		title: "t", updatedAt: $updated, labels: ["bug"], assignees: []}'
	return 0
}
DEFAULT_LABELS='[{"name":"bug"}]'
issue_at() {
	local updated="$1" body="${2:-spec}" labels="${3:-$DEFAULT_LABELS}"
	jq -cn --arg updated "$updated" --arg body "$body" --argjson labels "$labels" \
		'{number: 38261, updated_at: $updated, body: $body, labels: $labels, assignees: []}'
	return 0
}

OLD=2026-11-14T10:00:00Z
NEW=2026-11-14T10:05:00Z
CACHE_FILE=$(_dispatch_negative_cache_path 38261 example/repo)
OPS_COMMENTS='[{"body":"DISPATCH_CLAIM nonce=abc runner=r1 ts=2026-11-14T10:04:00Z"}]'

record_fresh() {
	rm -f "$CACHE_FILE" "$GH_CALLS"
	_DISPATCH_NEGATIVE_CACHE_SOURCE_KEY=""
	ISSUE_JSON=$(issue_at "$OLD")
	_dispatch_negative_cache_record "$(candidate_at "$OLD")" terminal_blocker_circuit
	_DISPATCH_NEGATIVE_CACHE_SOURCE_KEY=""
	: >"$GH_CALLS"
	ISSUE_JSON=$(issue_at "$NEW")
	COMMENTS_JSON="$OPS_COMMENTS"
	return 0
}
material_field() { cut -f8 "$CACHE_FILE"; return 0; }
revision_field() { cut -f2 "$CACHE_FILE"; return 0; }
gh_call_count() { if [[ -f "$GH_CALLS" ]]; then wc -l <"$GH_CALLS" | tr -d ' '; else printf '0'; fi; return 0; }
hits() {
	[[ "$(_dispatch_negative_cache_reason "$@" 2>/dev/null)" == terminal_blocker_circuit ]] || return 1
	return 0
}
misses() {
	if _dispatch_negative_cache_reason "$@" >/dev/null 2>&1; then return 1; fi
	return 0
}
equals() {
	local actual="$1" expected="$2"
	[[ "$actual" == "$expected" ]] || return 1
	return 0
}
prefixed() {
	local actual="$1" prefix="$2"
	[[ "$actual" == "$prefix"* ]] || return 1
	return 0
}

# 1. A body-less record sources body material from one bounded issue read.
rm -f "$GH_CALLS"
ISSUE_JSON=$(issue_at "$OLD")
_dispatch_negative_cache_record "$(candidate_at "$OLD")" terminal_blocker_circuit
check "record stores body material for a body-less candidate" prefixed "$(material_field)" body:
check "record costs exactly one issue read" equals "$(gh_call_count)" 1

# 2. Ops-only bump reuses the hint and refreshes the revision.
record_fresh
check "ops-only bump reuses the hint" hits "$(candidate_at "$NEW")"
check "reuse refreshes the cached revision" equals "$(revision_field)" "$NEW"
check "reuse costs one issue read plus one comments read" equals "$(gh_call_count)" 2

# 3. Steady state after refresh needs no API call.
: >"$GH_CALLS"
check "steady state still hits" hits "$(candidate_at "$NEW")"
check "steady state makes no API call" equals "$(gh_call_count)" 0

# 4. Material and comment changes miss.
record_fresh
COMMENTS_JSON='[{"body":"Please also cover the REST path."}]'
check "non-ops comment misses" misses "$(candidate_at "$NEW")"
record_fresh
COMMENTS_JSON='[{"body":"terminal-blocker-circuit:retry"}]'
check "standalone retry directive misses" misses "$(candidate_at "$NEW")"
record_fresh
ISSUE_JSON=$(issue_at "$NEW" spec '[{"name":"bug"},{"name":"status:blocked"}]')
check "label change misses" misses "$(candidate_at "$NEW")"
record_fresh
ISSUE_JSON=$(issue_at "$NEW" "spec v2")
check "body change misses" misses "$(candidate_at "$NEW")"
record_fresh
ISSUE_JSON=$(jq -c '.assignees = [{"login":"someone"}]' <<<"$ISSUE_JSON")
check "assignee change misses" misses "$(candidate_at "$NEW")"
record_fresh
check "snapshot_only mode misses" misses "$(candidate_at "$NEW")" "" snapshot_only
check "snapshot_only mode makes no API call" equals "$(gh_call_count)" 0
record_fresh
ISSUE_JSON=""
check "issue read failure misses" misses "$(candidate_at "$NEW")"

# 5. A record never vouches for an edit its ceremony did not evaluate.
rm -f "$CACHE_FILE"
_DISPATCH_NEGATIVE_CACHE_SOURCE_KEY=""
ISSUE_JSON=$(issue_at "$NEW" spec '[{"name":"bug"},{"name":"status:blocked"}]')
_dispatch_negative_cache_record "$(candidate_at "$OLD")" terminal_blocker_circuit
check "mid-ceremony edit keeps fail-closed metadata material" prefixed "$(material_field)" metadata:
_DISPATCH_NEGATIVE_CACHE_SOURCE_KEY=""
COMMENTS_JSON="$OPS_COMMENTS"
check "metadata material never reuses across a bump" misses "$(candidate_at "$NEW")"

# 6. A failed issue read at record time keeps metadata material.
rm -f "$CACHE_FILE"
_DISPATCH_NEGATIVE_CACHE_SOURCE_KEY=""
ISSUE_JSON=""
_dispatch_negative_cache_record "$(candidate_at "$OLD")" terminal_blocker_circuit
check "record falls back to metadata material when the read fails" prefixed "$(material_field)" metadata:

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
