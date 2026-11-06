#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36900: execute the Pulse gate with isolated GitHub/retry boundaries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export LOGFILE="${TEST_ROOT}/pulse.log"
export PULSE_REVIEW_EVIDENCE_SCHEMA="aidevops.review-gate-evidence/v1"
export PULSE_UNKNOWN_STATE="UNKNOWN"
export AGENTS_DIR="${TEST_ROOT}"
mkdir -p "${TEST_ROOT}/scripts"

# Source the production library; extract only the real caller to avoid Pulse
# orchestrator initialization. All network and mutation commands are mocked.
# shellcheck source=../pulse-merge-gates.sh
source "${SCRIPT_DIR}/../pulse-merge-gates.sh"
eval "$(awk '/^_pm_gate_review_bot\(\) \{/,/^}/' "${SCRIPT_DIR}/../pulse-merge.sh")"

cat >"${TEST_ROOT}/scripts/review-bot-gate-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
status-json) printf '%s\n' "$TEST_EVIDENCE" ;;
request-retry)
 printf '%s\n' "$*" >>"$TEST_CALLS"
 [[ "${TEST_RETRY_FAIL:-0}" == 0 ]] || exit 2
 printf '%s\n' "${TEST_RETRY_RESULT:-REQUESTED}"
 ;;
*) exit 2 ;;
esac
STUB

_is_trusted_dependabot_update_pr() { return 1; }
repo_allows_pulse_write_actions() { [[ "$TEST_WRITE_ALLOWED" == 1 ]] || return 1; return 0; }
_pmg_gh_read() {
 [[ "$TEST_API_FAIL" == 0 ]] || return 1
 printf '%s\n' "$TEST_LIVE_PR"
 return 0
}

export TEST_CALLS="${TEST_ROOT}/calls"
BASE_EVIDENCE='{"schema":"aidevops.review-gate-evidence/v1","repo":"org/repo","pr":"42","head_sha":"abc","author":{"login":"contributor","association":"CONTRIBUTOR","class":"external"},"status":"WAITING","exit_code":1,"permitted":false,"state":"waiting","merge_gate":"blocked","reason":"outcome_not_permitted"}'
BASE_PR='{"state":"open","draft":false,"head":{"sha":"abc"},"user":{"login":"contributor"},"labels":[]}'
export TEST_EVIDENCE="$BASE_EVIDENCE"
export TEST_LIVE_PR="$BASE_PR"
export TEST_WRITE_ALLOWED=1 TEST_API_FAIL=0 TEST_RETRY_FAIL=0 TEST_RETRY_RESULT=REQUESTED
TESTS=0

check_gate() {
 local name="$1" expected="$2" rc=0 calls=0
 : >"$TEST_CALLS"
 _pm_gate_review_bot 42 org/repo contributor abc || rc=$?
 [[ "$rc" == 1 ]] || { printf 'FAIL: %s allowed merge\n' "$name"; exit 1; }
 calls=$(wc -l <"$TEST_CALLS")
 [[ "$calls" -eq "$expected" ]] || { printf 'FAIL: %s retry count %s\n' "$name" "$calls"; exit 1; }
 TESTS=$((TESTS + 1))
 printf 'PASS: %s (merge blocked, retries=%s)\n' "$name" "$calls"
 return 0
}

check_gate 'external current-head WAITING requests recovery' 1
for mutation in '.head_sha="other"' '.repo="other/repo"' '.pr="99"' '.author.login="other"' '.author.class="trusted"' '.author.association="OWNER"' 'del(.author.association)' '.status="ERROR"' '.exit_code=2' '.reason="head_changed"' '.permitted=true' '.state="error"' '.merge_gate="clear"'; do
 TEST_EVIDENCE=$(jq -c "$mutation" <<<"$BASE_EVIDENCE")
 check_gate "$mutation" 0
done
TEST_EVIDENCE='invalid'
check_gate 'malformed evidence' 0
TEST_EVIDENCE="$BASE_EVIDENCE"
for mutation in '.head.sha="other"' '.state="closed"' '.draft=true' '.user.login="other"' '.labels=[{"name":"hold-for-review"}]'; do
 TEST_LIVE_PR=$(jq -c "$mutation" <<<"$BASE_PR")
 check_gate "$mutation" 0
done
TEST_LIVE_PR="$BASE_PR"
TEST_API_FAIL=1
check_gate 'API failure' 0
TEST_API_FAIL=0
TEST_WRITE_ALLOWED=0
check_gate 'read-only repository' 0
TEST_WRITE_ALLOWED=1
TEST_RETRY_FAIL=1
check_gate 'retry failure cannot unblock merge' 1
TEST_RETRY_FAIL=0
for TEST_RETRY_RESULT in ALREADY_REQUESTED NO_ACTION HAS_REVIEWS; do
 check_gate "$TEST_RETRY_RESULT does not unblock merge" 1
done
printf '%s recovery cases passed\n' "$TESTS"
