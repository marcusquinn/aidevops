#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# GH#38242: immutable commit cache, per-process login memo and cache pruning.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}" "${TEST_ROOT}/bin"
export GH_LOG="${TEST_ROOT}/gh.log"
: >"$GH_LOG"
export PATH="${TEST_ROOT}/bin:${PATH}"

cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
case "$2" in
user) printf 'runner-bot\n' ;;
*/commits/*)
	sha="${2##*/}"
	if [[ -f "${GH_FAIL_FILE:-/nonexistent}" ]]; then
		printf '{"message":"Server Error"}\n'
		exit 0
	fi
	printf '{"sha":"%s","commit":{"committer":{"date":"2026-01-01T00:00:00Z"}},"files":[{"filename":"a.sh"}]}\n' "$sha"
	;;
esac
exit 0
GHEOF
chmod +x "${TEST_ROOT}/bin/gh"

# shellcheck source=../shared-gh-commit-cache.sh
source "${SCRIPT_DIR}/../shared-gh-commit-cache.sh"
# shellcheck source=../pulse-cleanup.sh
source "${SCRIPT_DIR}/../pulse-cleanup.sh" 2>/dev/null || true

FAILURES=0
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
gh_calls() {
	wc -l <"$GH_LOG" | tr -d ' '
	return 0
}

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

out=$(gh_commit_by_sha_cached o/r "$SHA_A" | jq -r '.commit.committer.date')
expect "first read returns commit" "2026-01-01T00:00:00Z" "$out"
out=$(gh_commit_by_sha_cached o/r "$SHA_A" | jq -r '.files[0].filename')
expect "second read served from cache" "a.sh" "$out"
expect "second read makes no gh call" 1 "$(gh_calls)"
mode=$(stat -c %a "${HOME}/.aidevops/cache/gh-commit/o--r/${SHA_A}.json" 2>/dev/null || stat -f %Lp "${HOME}/.aidevops/cache/gh-commit/o--r/${SHA_A}.json")
expect "cache file mode 600" 600 "$mode"

: >"${TEST_ROOT}/fail"
export GH_FAIL_FILE="${TEST_ROOT}/fail"
gh_commit_by_sha_cached o/r "$SHA_B" >/dev/null 2>&1
rc=$?
expect "error body returns failure" 1 "$rc"
if [[ -e "${HOME}/.aidevops/cache/gh-commit/o--r/${SHA_B}.json" ]]; then
	expect "error body not cached" absent present
else
	expect "error body not cached" absent absent
fi
unset GH_FAIL_FILE

before=$(gh_calls)
gh_commit_by_sha_cached o/r main >/dev/null 2>&1
if [[ -e "${HOME}/.aidevops/cache/gh-commit/o--r/main.json" ]]; then
	expect "non-SHA ref never cached" absent present
else
	expect "non-SHA ref never cached" absent absent
fi
expect "non-SHA ref still queried" $((before + 1)) "$(gh_calls)"

: >"$GH_LOG"
login=""
gh_authenticated_login_cached login
gh_authenticated_login_cached login
expect "login resolved" runner-bot "$login"
expect "login memoized (one gh call)" 1 "$(gh_calls)"

if declare -F _pulse_prune_gh_commit_cache >/dev/null 2>&1; then
	old="${HOME}/.aidevops/cache/gh-commit/o--r/${SHA_A}.json"
	touch -d '8 days ago' "$old" 2>/dev/null || touch -t "$(date -v-8d +%Y%m%d%H%M)" "$old"
	deleted=$(_pulse_prune_gh_commit_cache $((SECONDS + 30)))
	expect "prune deletes entries older than 7 days" 1 "$deleted"
	[[ ! -e "$old" ]] && expect "pruned file removed" ok ok || expect "pruned file removed" ok present
else
	expect "pulse-cleanup prune function available" yes no
fi

[[ "$FAILURES" -eq 0 ]]
