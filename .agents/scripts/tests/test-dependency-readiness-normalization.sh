#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for t18100 dependency readiness normalization.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
LOGFILE="${TMP_ROOT}/test.log"
: >"$LOGFILE"

pass=0
fail=0

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS: %s\n' "$label"
		pass=$((pass + 1))
	else
		printf 'FAIL: %s (expected=%q actual=%q)\n' "$label" "$expected" "$actual" >&2
		fail=$((fail + 1))
	fi
	return 0
}

assert_true() {
	local label="$1"
	shift
	if "$@"; then
		printf 'PASS: %s\n' "$label"
		pass=$((pass + 1))
	else
		printf 'FAIL: %s\n' "$label" >&2
		fail=$((fail + 1))
	fi
	return 0
}

# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/pulse-dep-graph.sh"

acc='{"open_nums":[],"closed_nums":[],"known_nums":[],"task_to_issue":{},"blocked_by_map":{},"defer_flags_map":{}}'
# shellcheck disable=SC2016  # Markdown backticks are literal fixture content.
issue='{"number":20,"title":"t20: roadmap child","state":"OPEN","body":"**Blocked by:** `t20`, #20, #10","labels":[]}'
parsed=$(_dep_graph_process_issue_json "$issue" "$acc")
assert_eq "self task reference ignored" '[]' "$(printf '%s' "$parsed" | jq -c '.blocked_by_map["20"].task_ids')"
assert_eq "self issue reference ignored" '["10"]' "$(printf '%s' "$parsed" | jq -c '.blocked_by_map["20"].issue_nums')"

entry='{"task_ids":["10"],"issue_nums":["11"]}'
assert_true "closed roadmap predecessors resolve" \
	_refresh_all_blockers_resolved "$entry" '{"10":10}' '[10,11]' '[10,11,20]'
if _refresh_all_blockers_resolved "$entry" '{"10":10}' '[10]' '[10,20]'; then
	assert_eq "missing issue fails closed" "blocked" "resolved"
else
	assert_eq "missing issue fails closed" "blocked" "blocked"
fi
if _refresh_all_blockers_resolved '{"task_ids":["404"],"issue_nums":[]}' '{}' '[]' '[20]'; then
	assert_eq "missing task fails closed" "blocked" "resolved"
else
	assert_eq "missing task fails closed" "blocked" "blocked"
fi

ISSUE_STATUS_LABEL_PRECEDENCE=("done" "in-review" "in-progress" "queued" "claimed" "available" "blocked")
ISSUE_TIER_LABEL_RANK=(reasoning standard simple)
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/pulse-issue-reconcile-normalize.sh"
assert_eq "blocked wins inconsistent available pair" "blocked" "$(_pick_status_survivor available blocked)"

status_write=""
gh() {
	printf 'status:available\n'
	return 0
}
set_issue_status() {
	local issue_num="$1"
	local slug="$2"
	local status="$3"
	status_write="${issue_num}|${slug}|${status}"
	return 0
}
export -f gh set_issue_status
_refresh_ensure_unresolved_is_blocked "owner/repo" "20"
assert_eq "available issue normalized blocked" "20|owner/repo|blocked" "$status_write"

status_write=""
gh() {
	printf 'status:available,status:queued\n'
	return 0
}
export -f gh
_refresh_ensure_unresolved_is_blocked "owner/repo" "20" || true
assert_eq "concurrent queued transition is preserved" "" "$status_write"

log_verbose() {
	return 0
}
gh() {
	printf 'GraphQL: Validation failed: already been taken\n'
	return 1
}
export -f gh log_verbose
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/issue-sync-relationships.sh"
assert_true "concurrent native relationship write is idempotent" _gh_add_blocked_by "I_blocked" "I_blocker"

python3 - "$SCRIPTS_DIR/pulse-check-queue-scan.py" <<'PY'
import datetime as dt
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("queue_scan", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

def issue(number, body, labels=None):
    return {
        "number": number,
        "title": f"t{number}: child",
        "body": body,
        "labels": [{"name": name} for name in (labels or ["status:available", "auto-dispatch"])],
        "assignees": [],
        "updatedAt": "2026-07-11T00:00:00Z",
    }

# Native closed relationships take precedence over stale body text.
module._native_dependency_state = lambda slug, number: False
assert module._dependency_inconsistent("owner/repo", issue(102, "Blocked by #101")) is False

# Native open relationships are always inconsistent with available.
module._native_dependency_state = lambda slug, number: True
assert module._dependency_inconsistent("owner/repo", issue(102, "")) is True

# Text fallback holds ordered roadmap children when native links are absent.
module._native_dependency_state = lambda slug, number: None
module._run_gh_json = lambda cmd: {"state": "OPEN"} if cmd[1:3] == ["issue", "view"] else None
roadmap_child = issue(102, "Blocked by #101")
assert module._dependency_inconsistent("owner/repo", roadmap_child) is True

# Missing textual references fail closed rather than becoming available.
module._run_gh_json = lambda cmd: None
assert module._dependency_inconsistent("owner/repo", issue(103, "Blocked by #999999")) is True

# Parent tasks remain unavailable through their independent blocking label.
aggregate = module._empty_aggregate()
parent = issue(200, "", ["status:available", "auto-dispatch", "parent-task"])
parent["dependency_inconsistent"] = False
available = module._count_issue(aggregate, parent, dt.datetime.now(dt.timezone.utc), 30)
assert available is False

# Dependency-inconsistent availability is reported separately and excluded.
aggregate = module._empty_aggregate()
roadmap_child["dependency_inconsistent"] = True
available = module._count_issue(aggregate, roadmap_child, dt.datetime.now(dt.timezone.utc), 30)
assert available is False
assert aggregate["dependency_inconsistent_available"] == 1
assert aggregate["available_unassigned"] == 0
print("PASS: queue scanner native/text/missing/parent diagnostics")
PY
python_rc=$?
if [[ "$python_rc" -eq 0 ]]; then
	pass=$((pass + 1))
else
	fail=$((fail + 1))
fi

printf '\nResults: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
exit 0
