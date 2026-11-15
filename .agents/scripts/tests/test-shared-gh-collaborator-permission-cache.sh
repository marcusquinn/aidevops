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

# GH#38282: measure the actual command-substitution loss before enabling sharing.
unset AIDEVOPS_GH_COLLAB_MEMO_FILE AIDEVOPS_GH_COLLAB_STATS_FILE
_AIDEVOPS_GH_COLLAB_PERMISSION_MEMO=""
_gh_collaborator_permission_request() {
	printf x >>"$CALL_FILE"
	printf 'HTTP/2 200\n\n{"permission":"write"}\n'
	return 0
}
: >"$CALL_FILE"
perm=$(_gh_collaborator_permission_lookup o/r subshell)
_gh_collaborator_permission_lookup o/r subshell perm
expect "unset file preserves subshell loss (baseline)" 2 "$(calls)"

memo_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$memo_root" || exit 1
memo_dir=$(mktemp -d "${memo_root}/test-collab.XXXXXXXX") || exit 1
trap 'rm -f "$CALL_FILE"; rm -rf "$memo_dir"' EXIT
AIDEVOPS_GH_COLLAB_MEMO_FILE="$memo_dir/memo"
AIDEVOPS_GH_COLLAB_STATS_FILE="$memo_dir/stats"
: >"$AIDEVOPS_GH_COLLAB_MEMO_FILE"
: >"$AIDEVOPS_GH_COLLAB_STATS_FILE"
chmod 600 "$AIDEVOPS_GH_COLLAB_MEMO_FILE" "$AIDEVOPS_GH_COLLAB_STATS_FILE"
export AIDEVOPS_GH_COLLAB_MEMO_FILE AIDEVOPS_GH_COLLAB_STATS_FILE
_AIDEVOPS_GH_COLLAB_PERMISSION_MEMO=""
: >"$CALL_FILE"
perm=$(_gh_collaborator_permission_lookup o/r subshell)
expect "substitution returns permission" write "$perm"
_gh_collaborator_permission_lookup O/R SUBSHELL perm
expect "substitution then parent shares one request" 1 "$(calls)"
expect "shared hit value" write "$perm"
expect "shared memo records only successful verdict" 'o/r|subshell=write' "$(<"$AIDEVOPS_GH_COLLAB_MEMO_FILE")"
expect "shared stats record miss then hit" $'miss o/r|subshell\nhit' "$(<"$AIDEVOPS_GH_COLLAB_STATS_FILE")"

# Failed/deferred verdicts must not outlive the subshell either.
_gh_collaborator_permission_lookup_uncached() {
	printf x >>"$CALL_FILE"
	return "$MODE"
}
for MODE in 2 75; do
	_AIDEVOPS_GH_COLLAB_PERMISSION_MEMO=""
	: >"$CALL_FILE"
	: >"$AIDEVOPS_GH_COLLAB_MEMO_FILE"
	perm=$(_gh_collaborator_permission_lookup o/r failed)
	expect "failure/defer status $MODE" "$MODE" "$?"
	_gh_collaborator_permission_lookup o/r failed perm
	expect "failure/defer $MODE repeated requests" 2 "$(calls)"
	expect "failure/defer $MODE leaves file empty" "" "$(<"$AIDEVOPS_GH_COLLAB_MEMO_FILE")"
done

# Invalid paths and invalid stored verdicts cannot confer authority.
_gh_collaborator_permission_lookup_uncached() {
	local output="${3:-}"
	printf x >>"$CALL_FILE"
	printf -v "$output" '%s' read
	return 0
}
printf 'o/r|unsafe=admin\n' >"$CALL_FILE"
ln -s "$CALL_FILE" "$memo_dir/link"
for unsafe_file in "$CALL_FILE" "$memo_dir/link"; do
	AIDEVOPS_GH_COLLAB_MEMO_FILE="$unsafe_file"
	_AIDEVOPS_GH_COLLAB_PERMISSION_MEMO=""
	_gh_collaborator_permission_lookup o/r unsafe perm
	expect "unsafe path ignored: $unsafe_file" read "$perm"
done
AIDEVOPS_GH_COLLAB_MEMO_FILE="$memo_dir/memo"
printf 'o/r|unsafe=invalid\n' >"$AIDEVOPS_GH_COLLAB_MEMO_FILE"
_AIDEVOPS_GH_COLLAB_PERMISSION_MEMO=""
_gh_collaborator_permission_lookup o/r unsafe perm
expect "malformed stored verdict ignored" read "$perm"

# A fresh run uses a fresh file, not yesterday's authority.
AIDEVOPS_GH_COLLAB_MEMO_FILE="$memo_dir/next-run"
: >"$AIDEVOPS_GH_COLLAB_MEMO_FILE"
_AIDEVOPS_GH_COLLAB_PERMISSION_MEMO=""
_gh_collaborator_permission_lookup o/r subshell perm
expect "new run observes changed permission" read "$perm"

if [[ "$FAILURES" -eq 0 ]]; then
	exit 0
fi
exit 1
