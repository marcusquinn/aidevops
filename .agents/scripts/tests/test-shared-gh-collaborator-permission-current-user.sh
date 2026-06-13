#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../shared-gh-collaborator-permission.sh"

TEST_ROOT=""
GH_LOG=""
REST_LOG=""

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	GH_LOG="${TEST_ROOT}/gh.log"
	REST_LOG="${TEST_ROOT}/rest.log"
	: >"$GH_LOG"
	: >"$REST_LOG"
	export GH_LOG

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"

if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
	jq_expr=""
	while [[ "$#" -gt 0 ]]; do
		arg="$1"
		shift
		if [[ "$arg" == "--jq" && "$#" -gt 0 ]]; then
			jq_expr="$1"
			break
		fi
	done
	case "$jq_expr" in
	'.login // ""')
		printf '\n'
		;;
	'.login')
		printf 'null\n'
		;;
	*)
		printf 'unexpected-jq:%s\n' "$jq_expr"
		;;
	esac
	exit 0
fi

exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

test_current_user_null_maps_to_lookup_failure() {
	# shellcheck source=../shared-gh-collaborator-permission.sh
	source "$HELPER_SCRIPT"

	_rest_api_call() {
		printf '%s\n' "$*" >>"$REST_LOG"
		return 2
	}

	local result=0
	_gh_current_user_allows_repo_write "owner/repo" || result=$?

	[[ "$result" -eq 1 ]] || fail "expected return 1 for missing current user, got ${result}"
	[[ "${AIDEVOPS_GH_WRITE_PERMISSION_USER-}" == "" ]] || fail "expected empty current user, got '${AIDEVOPS_GH_WRITE_PERMISSION_USER}'"
	[[ "${AIDEVOPS_GH_WRITE_PERMISSION_REASON:-}" == "current-user-lookup-failed" ]] || fail "expected current-user-lookup-failed, got '${AIDEVOPS_GH_WRITE_PERMISSION_REASON:-}'"
	[[ ! -s "$REST_LOG" ]] || fail "collaborator lookup should not run for empty current user: $(<"$REST_LOG")"
	grep -qF -- "--jq .login // \"\"" "$GH_LOG" || fail "expected gh user lookup to request jq null fallback; log: $(<"$GH_LOG")"
	return 0
}

test_current_user_lookup_keeps_stderr_visible() {
	grep -qF "current_user=\$(gh api user --jq '.login // \"\"') || current_user=\"\"" "$HELPER_SCRIPT" \
		|| fail "current user lookup should use jq null fallback without redirecting stderr"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	test_current_user_null_maps_to_lookup_failure
	test_current_user_lookup_keeps_stderr_visible
	printf 'PASS shared gh collaborator current-user tests\n'
	return 0
}

main "$@"
