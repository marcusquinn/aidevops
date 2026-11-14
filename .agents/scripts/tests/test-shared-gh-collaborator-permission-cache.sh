#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38242: per-process memo for collaborator permission lookups. Successful
# lookups are reused within the process; failures are never memoized.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=../shared-gh-collaborator-permission.sh
source "${SCRIPT_DIR}/../shared-gh-collaborator-permission.sh"

CALL_FILE=$(mktemp); trap 'rm -f "$CALL_FILE"' EXIT
MODE="ok"
calls() {
	wc -c <"$CALL_FILE" | tr -d " "
	return 0
}
FAILURES=0

_gh_collaborator_permission_request() {
	printf x >>"$CALL_FILE"
	if [[ "$MODE" == "ok" ]]; then
		printf 'HTTP/2 200\n\n{"permission":"write"}\n'
		return 0
	fi
	return 1
}

expect() {
	local name="$1" want="$2" got="$3"
	if [[ "$want" == "$got" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s: want=%s got=%s\n' "$name" "$want" "$got"
		FAILURES=$((FAILURES + 1))
	fi
	return 0
}

perm=""
MODE="fail"
_gh_collaborator_permission_lookup_uncached() { _gh_collaborator_permission_request "$@" >/dev/null; return 2; }
_gh_collaborator_permission_lookup o/r alice perm
rc=$?
expect "failure returns 2" 2 "$rc"
_gh_collaborator_permission_lookup o/r alice perm
expect "failure not memoized (two requests)" 2 "$(calls)"
unset -f _gh_collaborator_permission_lookup_uncached

# Restore the real uncached lookup by re-sourcing it.
unset _SHARED_GH_COLLABORATOR_PERMISSION_LOADED
# shellcheck source=../shared-gh-collaborator-permission.sh
source "${SCRIPT_DIR}/../shared-gh-collaborator-permission.sh"
_gh_collaborator_permission_request() {
	printf x >>"$CALL_FILE"
	if [[ "$MODE" == "ok" ]]; then
		printf 'HTTP/2 200\n\n{"permission":"write"}\n'
		return 0
	fi
	return 1
}

: >"$CALL_FILE"
MODE="ok"
perm=""
_gh_collaborator_permission_lookup o/r Alice perm
rc=$?
expect "first lookup rc" 0 "$rc"
expect "first lookup value" write "$perm"
perm=""
_gh_collaborator_permission_lookup O/R alice perm
expect "memo hit value (case-insensitive key)" write "$perm"
expect "memo hit makes no request" 1 "$(calls)"
_gh_collaborator_permission_lookup o/r bob perm
expect "different login is a new lookup" 2 "$(calls)"

# Recovery must write through to the outer memo wrapper's output variable.
_gh_collaborator_permission_request() {
	local route="$1"
	printf x >>"$CALL_FILE"
	if [[ "$route" == "gh-fallback" || "$(calls)" -gt 1 ]]; then
		printf 'HTTP/2 200\n\n{"permission":"admin"}\n'
		return 0
	fi
	return 1
}
github_app_is_configured() { return 0; }
: >"$CALL_FILE"
_AIDEVOPS_GH_COLLAB_PERMISSION_MEMO=""
perm=""
_gh_collaborator_permission_lookup o/r recovery perm
expect "app fallback returns success" 0 "$?"
expect "app fallback returns recovered value" admin "$perm"
expect "app fallback makes two requests" 2 "$(calls)"
github_app_is_configured() { return 1; }
: >"$CALL_FILE"
_AIDEVOPS_GH_COLLAB_PERMISSION_MEMO=""
perm=""
_gh_collaborator_permission_lookup o/r recovery perm
expect "same-route retry returns success" 0 "$?"
expect "same-route retry returns recovered value" admin "$perm"
expect "same-route retry makes two requests" 2 "$(calls)"

if [[ "$FAILURES" -eq 0 ]]; then
	exit 0
fi
exit 1
