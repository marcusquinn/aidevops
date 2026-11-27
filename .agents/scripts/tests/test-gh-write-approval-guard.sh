#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#40575: `pr comment` must not warn for expected approval states.
# Exercises _pr_comment_guarded through the real CLI with a stubbed
# approval helper and a stubbed gh, so no network writes occur.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
export TMPDIR="$TEST_ROOT"
export PRIVACY_REPOS_CONFIG="${HOME}/.config/aidevops/repos.json"
export PRIVACY_CACHE_FILE="${HOME}/.aidevops/cache/repo-privacy.json"
export PRIVACY_ENTITY_CONFIG="${HOME}/.aidevops/configs/privacy-guard-private-entities.txt"
export AUDIT_LOG_FILE="${TEST_ROOT}/audit.jsonl"
export GH_CALLS_FILE="${TEST_ROOT}/calls"
export AIDEVOPS_SIG_CLI="OpenCode" AIDEVOPS_SIG_CLI_VERSION="test"
export AIDEVOPS_SIG_MODEL="test" AIDEVOPS_SIG_TOKENS="1"
mkdir -p "${TEST_ROOT}/bin" "${HOME}/.config/aidevops" "${HOME}/.aidevops/configs"
printf '%s\n' '{"initialized_repos":[]}' >"$PRIVACY_REPOS_CONFIG"

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$GH_CALLS_FILE"
case "$1 $2" in
"api repos/public/repo") printf 'false\n' ;;
"auth status") ;;
"pr comment") printf 'comment posted\n' ;;
esac
exit 0
STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"

printf '%s\n' 'ordinary content' >"${TEST_ROOT}/body"

# Writes a stub approval helper that prints the given state and exits rc.
write_approval_stub() {
	local state="$1"
	local rc="$2"
	cat >"${TEST_ROOT}/bin/approval-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${state}'
exit ${rc}
EOF
	chmod +x "${TEST_ROOT}/bin/approval-stub"
	return 0
}

failures=0
report() {
	local label="$1"
	local ok="$2"
	local detail="$3"
	if [[ "$ok" -eq 1 ]]; then
		printf 'PASS %s\n' "$label"
	else
		printf 'FAIL %s: %s\n' "$label" "$detail" >&2
		failures=$((failures + 1))
	fi
	return 0
}

# run_case <label> <state> <helper-rc> <expect-cli-rc> <expect-warn 0|1> <expect-post 0|1>
run_case() {
	local label="$1"
	local state="$2"
	local helper_rc="$3"
	local expect_rc="$4"
	local expect_warn="$5"
	local expect_post="$6"
	write_approval_stub "$state" "$helper_rc"
	: >"$GH_CALLS_FILE"
	: >"$AUDIT_LOG_FILE"
	local actual_rc=0
	AIDEVOPS_APPROVAL_HELPER="${TEST_ROOT}/bin/approval-stub" \
		bash "${SCRIPT_DIR}/gh-write-helper.sh" pr comment 42 --repo public/repo \
		--body-file "${TEST_ROOT}/body" >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr" || actual_rc=$?
	local warned=0
	if grep -Fq '[WARN] approval verification errored' "${TEST_ROOT}/stderr"; then
		warned=1
	fi
	local posted=0
	if grep -q '^pr comment' "$GH_CALLS_FILE"; then
		posted=1
	fi
	local ok=1
	local detail="rc=${actual_rc} warn=${warned} post=${posted}"
	if [[ "$actual_rc" -ne "$expect_rc" || "$warned" -ne "$expect_warn" || "$posted" -ne "$expect_post" ]]; then
		ok=0
	fi
	report "$label" "$ok" "$detail"
	return 0
}

# Nothing to stale: quiet and forwarded.
run_case 'NO_APPROVAL (exit 1) posts without a warning' NO_APPROVAL 1 0 0 1
run_case 'STALE_APPROVAL (exit 4) posts without a warning' STALE_APPROVAL 4 0 0 1
# Genuine verification problems keep the warning so operators notice them.
run_case 'API_ERROR (exit 6) still warns' API_ERROR 6 0 1 1
run_case 'NO_KEY (exit 2) still warns' NO_KEY 2 0 1 1
run_case 'unknown state still warns' UNEXPECTED_STATE 9 0 1 1
run_case 'empty output still warns' '' 1 0 1 1
# A verified approval must block the comment, unchanged behaviour.
run_case 'VERIFIED (exit 0) blocks the comment' VERIFIED 0 2 0 0

if [[ "$failures" -ne 0 ]]; then
	printf '%s approval guard case(s) failed\n' "$failures" >&2
	exit 1
fi
printf 'All approval guard cases passed\n'
