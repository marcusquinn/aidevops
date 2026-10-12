#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Exercise the CLI's captured stderr and audit path without network writes.
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
export TEST_PRIVACY_HELPER="${SCRIPT_DIR}/privacy-guard-helper.sh"
export AIDEVOPS_SIG_CLI="OpenCode" AIDEVOPS_SIG_CLI_VERSION="test"
export AIDEVOPS_SIG_MODEL="test" AIDEVOPS_SIG_TOKENS="1"
mkdir -p "${TEST_ROOT}/bin" "${HOME}/.config/aidevops" "${HOME}/.aidevops/configs"
printf '%s\n' '{"initialized_repos":[]}' >"$PRIVACY_REPOS_CONFIG"
# The tagged wrapper matches the full slug; the shim also matches its basename.
printf '%s\n' 'synthetic-owner/synthetic-basename' >"${HOME}/.aidevops/configs/privacy-guard-extra-slugs.txt"
cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$GH_CALLS_FILE"
if [[ "${GH_HELP_ONLY:-0}" == 1 ]]; then
    exit 99
fi
case "$1 $2" in
"api repos/public/repo") printf 'false\n'; exit 0 ;;
"auth status") exit 0 ;;
"issue comment" | "pr comment")
    body_file=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--body-file" ]]; then body_file="$2"; break; fi
        shift
    done
    # shellcheck source=/dev/null
    source "$TEST_PRIVACY_HELPER"
    slugs=$(mktemp)
    privacy_enumerate_private_slugs "$slugs"
    if privacy_scan_text "$(<"$body_file")" "$slugs" >/dev/null; then
        rm -f "$slugs"
        if [[ "$(<"$body_file")" == *synthetic-transport-error* ]]; then
            printf 'synthetic transport error\n' >&2
            exit 7
        fi
        printf 'comment posted\n'
        exit 0
    fi
    rm -f "$slugs"
    printf '[aidevops][privacy-scan][BLOCK] synthetic basename denied\n' >&2
    exit 1 ;;
esac
exit 0
STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"

check_help() {
	: >"$GH_CALLS_FILE"
	: >"$AUDIT_LOG_FILE"
	GH_HELP_ONLY=1 bash "${SCRIPT_DIR}/gh-write-helper.sh" "$@" \
		>"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr"
	grep -Fq 'Usage: gh-write-helper.sh' "${TEST_ROOT}/stdout"
	[[ ! -s "${TEST_ROOT}/stderr" && ! -s "$GH_CALLS_FILE" && ! -s "$AUDIT_LOG_FILE" ]]
	printf 'PASS help without GitHub calls or audit events: %s\n' "$*"
	return 0
}

for help_flag in help --help -h; do
	check_help "$help_flag"
done
for resource in issue pr; do
	for action in create edit comment; do
		for help_flag in --help -h; do
			check_help "$resource" "$action" "$help_flag"
			check_help "$resource" "$action" 1 --repo public/repo --body-file "${TEST_ROOT}/missing-body" "$help_flag"
		done
	done
done

check_cli() {
	local resource="$1"
	local body="$2"
	local expected_rc="$3"
	local marker="$4"
	local rc=0
	printf '%s\n' "$body" >"${TEST_ROOT}/body"
	: >"$GH_CALLS_FILE"
	: >"$AUDIT_LOG_FILE"
	bash "${SCRIPT_DIR}/gh-write-helper.sh" "$resource" comment 1 --repo public/repo \
		--body-file "${TEST_ROOT}/body" >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr" || rc=$?
	[[ "$rc" -eq "$expected_rc" ]]
	if [[ -n "$marker" ]]; then
		grep -Fq "$marker" "${TEST_ROOT}/stderr"
	fi
	if [[ "$marker" == *BLOCK* ]]; then
		grep -Fq 'operation.block' "$AUDIT_LOG_FILE"
		if grep -Fq 'synthetic-basename' "$AUDIT_LOG_FILE" || grep -q 'api .*comments' "$GH_CALLS_FILE"; then
			return 1
		fi
	fi
	printf 'PASS %s comment: %s (exit %s)\n' "$resource" "$marker" "$rc"
	return 0
}

check_cli issue 'synthetic-basename' 1 '[privacy-scan][BLOCK]'
check_cli pr 'synthetic-basename' 1 '[privacy-scan][BLOCK]'
check_cli issue 'synthetic-owner/synthetic-basename' 1 '[privacy-guard][BLOCK]'
check_cli issue 'synthetic-transport-error' 7 'synthetic transport error'
check_cli issue 'ordinary content' 0 ''
grep -Fq 'comment posted' "${TEST_ROOT}/stdout"

# A cached quota failure must not trigger a REST retry after a shim rejection.
# Exercise a function transport too (the timeout wrapper has distinct branches).
bash -eu -o pipefail -c '
    source "$1/shared-gh-wrappers.sh"
    _rest_should_fallback() { return 0; }
    _rest_issue_comment() { printf "unsafe retry\n"; return 0; }
    gh() {
        local command="$1"
        if [[ "$command" == api ]]; then printf "false\n"; return 0; fi
        printf "[aidevops][privacy-scan][BLOCK] synthetic denial\n" >&2
        return 9
    }
    rc=0
    gh_issue_comment 1 --repo public/repo --body "ordinary content" || rc=$?
    [[ "$rc" -eq 9 ]]
' _ "$SCRIPT_DIR" >"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr"
grep -Fq '[privacy-scan][BLOCK] synthetic denial' "${TEST_ROOT}/stderr"
if grep -Fq 'unsafe retry' "${TEST_ROOT}/stdout"; then exit 1; fi
printf 'PASS function transport preserves denial and prevents REST retry\n'

for transport in function external; do
	for capture in secondary response; do
		: >"$GH_CALLS_FILE"
		bash -eu -o pipefail -c '
            source "$1/shared-gh-wrappers.sh"
            transport="$2"; capture="$3"
            privacy_guard_public_write() { return 0; }
            _gh_wrapper_auto_sig() { _GH_WRAPPER_SIG_MODIFIED_ARGS=("$@"); return 0; }
            _rest_should_fallback() { return 0; }
            _rest_issue_comment() { printf "unsafe retry\n"; return 0; }
            mktemp() {
                if [[ "$*" == *"gh-${capture}"* ]]; then return 1; fi
                command mktemp "$@"
                return $?
            }
            if [[ "$transport" == function ]]; then
                gh() { printf "[aidevops][privacy-scan][BLOCK] synthetic denial\n" >&2; return 9; }
            fi
            rc=0
            gh_issue_comment 1 --repo public/repo --body-file "$4" || rc=$?
            [[ "$rc" -ne 0 && "$_GH_WRITE_PRIVACY_BLOCKED" -eq 1 ]]
        ' _ "$SCRIPT_DIR" "$transport" "$capture" "${TEST_ROOT}/body" \
			>"${TEST_ROOT}/stdout" 2>"${TEST_ROOT}/stderr"
		if grep -Fq 'unsafe retry' "${TEST_ROOT}/stdout"; then exit 1; fi
		grep -q '\[BLOCK\]' "${TEST_ROOT}/stderr"
		printf 'PASS %s transport: failed %s capture prevents retry\n' "$transport" "$capture"
	done
done
