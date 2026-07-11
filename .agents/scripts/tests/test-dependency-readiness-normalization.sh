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
assert_eq "active lifecycle wins blocked available conflict" "in-review" "$(_pick_status_survivor available blocked in-review)"

status_write=""
current_status="status:available"
gh() {
	if [[ "$1 $2" == "issue view" ]]; then
		printf '%s\n' "$current_status"
	elif [[ "$1 $2" == "issue edit" ]]; then
		status_write="$*"
		current_status="status:blocked"
	fi
	return 0
}
export -f gh
_refresh_ensure_unresolved_is_blocked "owner/repo" "20"
assert_eq "available issue normalized blocked" "issue edit 20 --repo owner/repo --remove-label status:available --add-label status:blocked" "$status_write"

status_write=""
current_status="status:available,status:queued"
gh() {
	if [[ "$1 $2" == "issue view" ]]; then
		printf '%s\n' "$current_status"
	fi
	return 0
}
export -f gh
_refresh_ensure_unresolved_is_blocked "owner/repo" "20" || true
assert_eq "concurrent queued transition is preserved" "" "$status_write"

status_write=""
view_counter_file="${TMP_ROOT}/view-count"
printf '0\n' >"$view_counter_file"
gh() {
	if [[ "$1 $2" == "issue view" ]]; then
		local view_count=""
		view_count=$(<"$view_counter_file")
		view_count=$((view_count + 1))
		printf '%s\n' "$view_count" >"$view_counter_file"
		if [[ "$view_count" -eq 1 ]]; then
			printf 'status:available\n'
		else
			printf 'status:queued,status:blocked\n'
		fi
	elif [[ "$1 $2" == "issue edit" ]]; then
		status_write="${status_write}${*}"$'\n'
	fi
	return 0
}
export -f gh
_refresh_ensure_unresolved_is_blocked "owner/repo" "20" || true
assert_true "post-read removes blocked after concurrent queue transition" \
	grep -Fq -- "--remove-label status:blocked" <<<"$status_write"

log_verbose() {
	return 0
}
gh() {
	printf 'GraphQL: Validation failed: already been taken\n'
	return 1
}
export -f gh log_verbose
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/issue-sync-lib-parse.sh"
# shellcheck disable=SC1090
source "${SCRIPTS_DIR}/issue-sync-relationships.sh"
assert_true "concurrent native relationship write is idempotent" _gh_add_blocked_by "I_blocked" "I_blocker"

gh() {
	if [[ "$*" == *"query("* ]]; then
		printf '%s\n' '{"data":{"node":{"blockedBy":{"nodes":[{"id":"I_blocker"}],"pageInfo":{"hasNextPage":false}}}}}'
	else
		printf '%s\n' '{"data":{"removeBlockedBy":{"issue":{"number":10}}}}'
	fi
	return 0
}
export -f gh
assert_true "existing circular native edge is removed" _gh_remove_blocked_by "I_blocked" "I_blocker"

cycle_todo="${TMP_ROOT}/cycle-todo.md"
printf '%s\n' '- [ ] t10 first blocked-by:t20 ref:GH#10' '- [ ] t20 second blocked-by:t10 ref:GH#20' >"$cycle_todo"
assert_true "ascending circular native edge is skipped" \
	_dependency_cycle_should_skip_edge "t10" "t20" "10" "20" "$cycle_todo"

gh() {
	return 1
}
export -f gh
if _hold_dependency_sync_retry "20" "owner/repo" "test"; then
	assert_eq "failed status read propagates retry" "failure" "success"
else
	assert_eq "failed status read propagates retry" "failure" "failure"
fi

cycle_graph='{"open_issues":[10,20],"closed_issues":[],"known_issues":[10,20],"task_to_issue":{"10":10,"20":20},"blocked_by":{"10":{"task_ids":[],"issue_nums":["20"]},"20":{"task_ids":[],"issue_nums":["10"]}}}'
pruned_graph=$(_dep_graph_prune_circular_edges "$cycle_graph")
assert_eq "cycle pruning keeps one dependency direction" '[]' \
	"$(printf '%s' "$pruned_graph" | jq -c '.blocked_by["10"].issue_nums')"

gh_issue_list() {
	printf '%s\n' '[{"number":10,"title":"t10: first","state":"OPEN","body":"Blocked by #20","labels":[]},{"number":20,"title":"t20: second","state":"OPEN","body":"Blocked by #10","labels":[]}]'
	return 0
}
export -f gh_issue_list
built_graph=$(_dep_graph_build_repo_data "owner/repo")
assert_eq "repo graph build prunes circular dependency" '[]' \
	"$(printf '%s' "$built_graph" | jq -c '.blocked_by["10"].issue_nums')"

status_write=""
view_counter_file="${TMP_ROOT}/unblock-view-count"
printf '0\n' >"$view_counter_file"
gh() {
	if [[ "$1 $2" == "issue view" ]]; then
		local view_count=""
		view_count=$(<"$view_counter_file")
		view_count=$((view_count + 1))
		printf '%s\n' "$view_count" >"$view_counter_file"
		case "$view_count" in
			1 | 2) printf 'status:blocked\n' ;;
			*) printf 'status:queued,status:available\n' ;;
		esac
	elif [[ "$1 $2" == "issue edit" ]]; then
		status_write="${status_write}${*}"$'\n'
	fi
	return 0
}
_should_defer_auto_unblock() {
	return 1
}
_refresh_cleanup_resolved_blocker_labels() {
	return 1
}
export -f gh _should_defer_auto_unblock _refresh_cleanup_resolved_blocker_labels
_refresh_try_unblock_issue "owner/repo" "20" '{"task_ids":[],"issue_nums":[]}' '{}' || true
assert_true "concurrent queued transition wins resolved unblock" \
	grep -Fq -- "--remove-label status:available" <<<"$status_write"

_blocked_by_check_native_relationships() {
	return 2
}
_blocked_by_check_issue_num() {
	return 0
}
export -f _blocked_by_check_native_relationships _blocked_by_check_issue_num
if _refresh_dependency_is_resolved "owner/repo" "20" '{"task_ids":[],"issue_nums":["10"]}' '{}' '[]' '[10,20]'; then
	assert_eq "partial native repair still checks declared edge" "blocked" "resolved"
else
	assert_eq "partial native repair still checks declared edge" "blocked" "blocked"
fi

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

# Native clear relationships still require every explicit declared edge closed.
module._native_dependency_state = lambda slug, number: module.NATIVE_CLEAR
module._run_gh_json = lambda cmd: {"state": "CLOSED"}
assert module._dependency_inconsistent("owner/repo", issue(102, "Blocked by #101")) is False

# Native open relationships are always inconsistent with available.
module._native_dependency_state = lambda slug, number: module.NATIVE_UNRESOLVED
assert module._dependency_inconsistent("owner/repo", issue(102, "")) is True

# Text fallback holds ordered roadmap children when native links are absent.
module._native_dependency_state = lambda slug, number: module.NATIVE_ABSENT
module._run_gh_json = lambda cmd: {"state": "OPEN"} if cmd[1:3] == ["issue", "view"] else None
roadmap_child = issue(102, "Blocked by #101")
assert module._dependency_inconsistent("owner/repo", roadmap_child) is True

# Missing textual references fail closed rather than becoming available.
module._run_gh_json = lambda cmd: None
assert module._dependency_inconsistent("owner/repo", issue(103, "Blocked by #999999")) is True

# Native API uncertainty and pagination truncation fail closed and report an error.
module._native_dependency_state = lambda slug, number: module.NATIVE_UNKNOWN
assert module._dependency_diagnostic("owner/repo", issue(104, "")) == (True, True)

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
