#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression coverage for GH#22788: FOSS dispatch must not launch workers for
# null issue selections, and one cycle must not launch duplicate workers for the
# same FOSS issue/session key.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/foss-dispatch-XXXXXX")"

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

write_fixture_scripts() {
	mkdir -p "${TEST_TMP}/scripts" "${TEST_TMP}/home/.aidevops/logs" || fail "failed to create fixture dirs"
	cat >"${TEST_TMP}/scripts/foss-contribution-helper.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
	cat >"${TEST_TMP}/headless-runtime-helper.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HEADLESS_INVOCATION_LOG}"
exit 0
EOS
	chmod +x "${TEST_TMP}/scripts/foss-contribution-helper.sh" "${TEST_TMP}/headless-runtime-helper.sh" || fail "failed to chmod fixtures"
	return 0
}

write_repos_json() {
	local repos_json="$1"
	cat >"$repos_json" <<'JSON'
{
  "initialized_repos": [
    {
      "slug": "owner/project",
      "path": "~/Git/project",
      "foss": true,
      "foss_config": {
        "labels_filter": ["help wanted", "needs, triage", "bug"],
        "disclosure": false
      }
    }
  ]
}
JSON
	return 0
}

gh_issue_list() {
	local label=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--label)
			label="$2"
			test -n "$label" || break
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	printf '%s\n' "${label}" >>"${GH_ISSUE_LIST_LABEL_LOG}"
	case "$label" in
	"help wanted")
		printf '%s\n' "${GH_ISSUE_LIST_OUTPUT_HELP_WANTED-${GH_ISSUE_LIST_OUTPUT:-}}"
		;;
	"needs, triage")
		printf '%s\n' "${GH_ISSUE_LIST_OUTPUT_NEEDS_TRIAGE-${GH_ISSUE_LIST_OUTPUT:-}}"
		;;
	bug)
		printf '%s\n' "${GH_ISSUE_LIST_OUTPUT_BUG-${GH_ISSUE_LIST_OUTPUT:-}}"
		;;
	*)
		printf '%s\n' "${GH_ISSUE_LIST_OUTPUT:-}"
		;;
	esac
	return 0
}

sleep() {
	return 0
}

write_fixture_scripts

SCRIPT_DIR="${TEST_TMP}/scripts"
HEADLESS_RUNTIME_HELPER="${TEST_TMP}/headless-runtime-helper.sh"
HEADLESS_INVOCATION_LOG="${TEST_TMP}/headless.log"
GH_ISSUE_LIST_LABEL_LOG="${TEST_TMP}/issue-labels.log"
HOME="${TEST_TMP}/home"
LOGFILE="${TEST_TMP}/pulse.log"
export HEADLESS_INVOCATION_LOG
export GH_ISSUE_LIST_LABEL_LOG

# shellcheck source=../pulse-ancillary-dispatch.sh
source "${SCRIPTS_DIR}/pulse-ancillary-dispatch.sh"

repos_json="${TEST_TMP}/repos.json"
write_repos_json "$repos_json"

GH_ISSUE_LIST_OUTPUT='null|null'
available_after_null="$(FOSS_MAX_DISPATCH_PER_CYCLE=2 dispatch_foss_workers 2 "$repos_json")" || fail "null selection dispatch failed"
[[ "$available_after_null" == "2" ]] || fail "null selection changed available worker count"
[[ ! -f "$HEADLESS_INVOCATION_LOG" ]] || fail "null selection launched a worker"

GH_ISSUE_LIST_OUTPUT=''
available_after_empty="$(FOSS_MAX_DISPATCH_PER_CYCLE=2 dispatch_foss_workers 2 "$repos_json")" || fail "empty selection dispatch failed"
[[ "$available_after_empty" == "2" ]] || fail "empty selection changed available worker count"
[[ ! -f "$HEADLESS_INVOCATION_LOG" ]] || fail "empty selection launched a worker"
if ! grep -q 'FOSS dispatch skipped no issue selection for owner/project' "$LOGFILE"; then
	fail "empty selection did not log an auditable no-work reason"
fi

GH_ISSUE_LIST_OUTPUT='42|Fix duplicate dispatch'
available_output="${TEST_TMP}/available.out"
FOSS_MAX_DISPATCH_PER_CYCLE=2 dispatch_foss_workers 2 "$repos_json" >"$available_output" || fail "duplicate selection dispatch failed"
available_after_duplicate="$(<"$available_output")"
[[ "$available_after_duplicate" == "1" ]] || fail "duplicate selection did not consume exactly one worker slot"
wait

launch_count="$(wc -l <"$HEADLESS_INVOCATION_LOG" | tr -d ' ')"
[[ "$launch_count" == "1" ]] || fail "expected one duplicate-guarded launch, got ${launch_count}"

if ! grep -q -- '--session-key foss-owner/project-42' "$HEADLESS_INVOCATION_LOG"; then
	fail "expected FOSS session key was not used"
fi

: >"$GH_ISSUE_LIST_LABEL_LOG"
: >"$HEADLESS_INVOCATION_LOG"
GH_ISSUE_LIST_OUTPUT_HELP_WANTED=''
GH_ISSUE_LIST_OUTPUT_NEEDS_TRIAGE=''
GH_ISSUE_LIST_OUTPUT_BUG='88|Fallback label issue'
fallback_output="${TEST_TMP}/fallback.out"
FOSS_MAX_DISPATCH_PER_CYCLE=2 dispatch_foss_workers 2 "$repos_json" >"$fallback_output" || fail "label fallback dispatch failed"
available_after_fallback="$(<"$fallback_output")"
[[ "$available_after_fallback" == "1" ]] || fail "label fallback did not consume exactly one worker slot"
wait
launch_count_fallback="$(wc -l <"$HEADLESS_INVOCATION_LOG" | tr -d ' ')"
[[ "$launch_count_fallback" == "1" ]] || fail "expected one fallback launch, got ${launch_count_fallback}"
expected_label_attempts="${TEST_TMP}/expected-labels.log"
cat >"$expected_label_attempts" <<'EOF'
help wanted
needs, triage
bug
EOF
diff -u "$expected_label_attempts" "$GH_ISSUE_LIST_LABEL_LOG" || fail "label fallback did not try configured labels in order"

: >"$HEADLESS_INVOCATION_LOG"
tilde_output="${TEST_TMP}/tilde.out"
FOSS_MAX_DISPATCH_PER_CYCLE=2 dispatch_foss_workers 2 "$repos_json" >"$tilde_output" || fail "tilde path dispatch failed"
available_after_tilde="$(<"$tilde_output")"
[[ "$available_after_tilde" == "1" ]] || fail "tilde path dispatch did not consume exactly one worker slot"
wait
if ! grep -q -- "--dir ${HOME}/Git/project" "$HEADLESS_INVOCATION_LOG"; then
	fail "tilde path was not expanded before worker launch"
fi

printf 'PASS: FOSS null issue selections are skipped\n'
printf 'PASS: FOSS empty issue selections are logged as no work\n'
printf 'PASS: FOSS duplicate session keys are deduplicated per cycle\n'
printf 'PASS: FOSS dispatch falls back across configured labels\n'
printf 'PASS: FOSS repo paths expand leading tilde before worker launch\n'
exit 0
