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
      "path": "/tmp/project",
      "foss": true,
      "foss_config": {
        "labels_filter": ["bug"],
        "disclosure": false
      }
    },
    {
      "slug": "owner/project",
      "path": "/tmp/project",
      "foss": true,
      "foss_config": {
        "labels_filter": ["bug"],
        "disclosure": false
      }
    }
  ]
}
JSON
	return 0
}

gh_issue_list() {
	printf '%s\n' "${GH_ISSUE_LIST_OUTPUT:-}"
	return 0
}

sleep() {
	return 0
}

write_fixture_scripts

SCRIPT_DIR="${TEST_TMP}/scripts"
HEADLESS_RUNTIME_HELPER="${TEST_TMP}/headless-runtime-helper.sh"
HEADLESS_INVOCATION_LOG="${TEST_TMP}/headless.log"
HOME="${TEST_TMP}/home"
LOGFILE="${TEST_TMP}/pulse.log"
export HEADLESS_INVOCATION_LOG

# shellcheck source=../pulse-ancillary-dispatch.sh
source "${SCRIPTS_DIR}/pulse-ancillary-dispatch.sh"

repos_json="${TEST_TMP}/repos.json"
write_repos_json "$repos_json"

GH_ISSUE_LIST_OUTPUT='null|null'
available_after_null="$(FOSS_MAX_DISPATCH_PER_CYCLE=2 dispatch_foss_workers 2 "$repos_json")" || fail "null selection dispatch failed"
[[ "$available_after_null" == "2" ]] || fail "null selection changed available worker count"
[[ ! -f "$HEADLESS_INVOCATION_LOG" ]] || fail "null selection launched a worker"

GH_ISSUE_LIST_OUTPUT='42|Fix duplicate dispatch'
available_after_duplicate="$(FOSS_MAX_DISPATCH_PER_CYCLE=2 dispatch_foss_workers 2 "$repos_json")" || fail "duplicate selection dispatch failed"
[[ "$available_after_duplicate" == "1" ]] || fail "duplicate selection did not consume exactly one worker slot"

launch_count="$(wc -l <"$HEADLESS_INVOCATION_LOG" | tr -d ' ')"
[[ "$launch_count" == "1" ]] || fail "expected one duplicate-guarded launch, got ${launch_count}"

if ! grep -q -- '--session-key foss-owner/project-42' "$HEADLESS_INVOCATION_LOG"; then
	fail "expected FOSS session key was not used"
fi

printf 'PASS: FOSS null issue selections are skipped\n'
printf 'PASS: FOSS duplicate session keys are deduplicated per cycle\n'
exit 0
