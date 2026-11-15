#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for per-repo deterministic-merge timing summaries.
# Verifies that a multi-repo merge pass emits one structured timing line per
# repo plus the overall deterministic_merge_pass summary, without changing the
# function return code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export LOGFILE="${TEST_ROOT}/pulse.log"
export STOP_FLAG="${TEST_ROOT}/pulse.stop"
export REPOS_JSON="${TEST_ROOT}/repos.json"
export PULSE_MERGE_BATCH_LIMIT=1

mkdir -p "${HOME}/.config/aidevops"
mkdir -p "${HOME}/.aidevops/logs"

cat >"$REPOS_JSON" <<'JSON'
{"initialized_repos":[
  {"slug":"owner/alpha","path":"/tmp/alpha","pulse":true,"local_only":false},
  {"slug":"owner/beta","path":"/tmp/beta","pulse":true,"local_only":false}
]}
JSON

: >"$LOGFILE"

gh() {
  if [[ "$1" == "api" && "${2:-}" == "user" ]]; then
    printf '%s' '{"login":"tester"}'
    return 0
  fi
  return 0
}

# shellcheck source=/dev/null
source "$MERGE_SCRIPT" >/dev/null 2>&1

gh_pr_list() {
  local repo_slug=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        repo_slug="$2"
        shift 2
        ;;
      --state|--json|--limit)
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  sleep 1
  case "$repo_slug" in
    owner/alpha)
      printf '%s' '[{"number":11,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"alpha","updatedAt":"2026-06-18T00:00:00Z","headRefOid":"a1","headRefName":"alpha","baseRefName":"main","labels":[],"isDraft":false}]'
      ;;
    owner/beta)
      printf '%s' '[{"number":12,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","author":{"login":"owner"},"title":"beta","updatedAt":"2026-06-18T00:00:00Z","headRefOid":"b1","headRefName":"beta","baseRefName":"main","labels":[],"isDraft":false}]'
      ;;
    *)
      printf '[]'
      ;;
  esac
  return 0
}

gh_pr_check_status_rest_batch() {
  sleep 1
  printf '[]'
  return 0
}

repo_allows_pulse_write_actions() {
  export AIDEVOPS_USER_INSTIGATED_EXTERNAL_GH_WRITE="$1"
  return 0
}
_resolve_pr_mergeable_status() { sleep 1; return 0; }
_extract_linked_issue() { printf '101'; return 0; }
_check_pr_merge_gates() { return 0; }
_pr_required_checks_pass() { sleep 1; return 0; }
_check_ruleset_required_reviews_passing() { sleep 1; return 0; }
approve_collaborator_pr() { return 0; }
_pmp_consolidate_duplicate_pr_groups() { return 0; }
_attempt_existing_auto_merge_behind_update_branch() { return 1; }
_attempt_green_behind_update_branch() { return 1; }
_set_native_auto_merge_or_skip() { return 0; }
_handle_post_merge_actions() { return 0; }
pulse_merge_stuck_run_pass() { sleep 1; return 0; }
_pms_count_eligible_unmerged_for_repo() { return 0; }

rc=0
merge_ready_prs_all_repos || rc=$?

if [[ "$rc" -ne 0 ]]; then
  printf 'FAIL: merge_ready_prs_all_repos returned %s\n' "$rc"
  exit 1
fi

if [[ "$(grep -c 'deterministic_merge_pass timing: repo=' "$LOGFILE")" -ne 2 ]]; then
  printf 'FAIL: expected 2 per-repo timing summaries\n'
  cat "$LOGFILE"
  exit 1
fi

for repo in owner/alpha owner/beta; do
	if ! grep -qE "deterministic_merge_pass timing: repo=${repo} .*list_s=[0-9]+ list_state=complete .*mergeability_s=[0-9]+ .*ruleset_s=[0-9]+ .*branch_protection_s=[0-9]+ .*stuck_detector_s=[0-9]+" "$LOGFILE"; then
    printf 'FAIL: missing structured timing summary for %s\n' "$repo"
    cat "$LOGFILE"
    exit 1
  fi
	# GH#38259: the pass deadline runs each evaluator as a background job; the
	# stage it stopped at must still reach the parent's per-repo line.
	if ! grep -qE "deterministic_merge_pass timing: repo=${repo} .*slowest_stages=parse_and_validate:[0-9]+$" "$LOGFILE"; then
    printf 'FAIL: background evaluator stage breakdown lost for %s\n' "$repo"
    cat "$LOGFILE"
    exit 1
  fi
done

# GH#38259: breakdown counters written inside a background evaluator used to
# be discarded with its subshell, so production logged mergeability_s=0
# ruleset_s=0 branch_protection_s=0 trust_gate_s=0 on every pass.
background_counter_regression() {
  local timing_prefix="bg_" bg_mergeability_s=3 bg_ruleset_s=0 bg_branch_protection_s=0 bg_trust_gate_s=0
  local collected="" rc=0
  local _PMP_STAGE_TIMING_FILE=""
  declare -F _gh_run_bounded_function >/dev/null 2>&1 || return 1
  _pmp_stage_fake_gate() { bg_mergeability_s=$((bg_mergeability_s + 5)); bg_trust_gate_s=2; return 10; }
  _pmp_stage_timing_reset "$timing_prefix"
  _gh_run_bounded_function 10 _pmp_run_timed_stage _pmp_stage_fake_gate || rc=$?
  [[ "$rc" -eq 10 && "$bg_mergeability_s" -eq 3 ]] || return 1
  _pmp_collect_stage_timing "$timing_prefix" collected || return 1
  [[ "$collected" =~ ^fake_gate:[0-9]+$ && "$bg_mergeability_s" -eq 8 && "$bg_trust_gate_s" -eq 2 ]] || return 1
  _pmp_stage_timing_discard
  return 0
}

if ! (background_counter_regression); then
  printf 'FAIL: background evaluator counters were not adopted by the parent\n'
  exit 1
fi
if [[ -n "${_PMP_STAGE_TIMING_FILE:-}" ]]; then
  printf 'FAIL: per-repo stage timing file was not discarded\n'
  exit 1
fi

# GH#38259: a stage still open when the deadline killed the evaluator is
# attributed to that stage; nested post-merge actions report inside finalize.
stage_collect_regression() {
  local timing_prefix="sc_" sc_mergeability_s=2 sc_ruleset_s=0 sc_branch_protection_s=0 sc_trust_gate_s=0
  local sc_pr_s=0 sc_slowest_pr="" sc_slowest_stages="" collected=""
  local _PMP_STAGE_TIMING_FILE=""
  _pmp_now_epoch() { printf '200'; return 0; }
  _pmp_now_epoch_into() { printf -v "$1" '%s' '200'; return 0; }
  _pmp_stage_timing_reset "$timing_prefix"
  [[ -n "$_PMP_STAGE_TIMING_FILE" ]] || return 1
  printf '%s\n' '@required_checks 150' 'required_checks:12 7 1 0 3' '@finalize_merge 162' \
    '@handle_post_merge_actions 163' 'handle_post_merge_actions:30 7 1 0 3' '@admin_merge 190' >>"$_PMP_STAGE_TIMING_FILE"
  _pmp_collect_stage_timing "$timing_prefix" collected || return 1
  [[ "$collected" == "required_checks:12,handle_post_merge_actions:30,finalize_merge:38+unfinished,admin_merge:10+unfinished" ]] || {
    printf 'collected=%s\n' "$collected"
    return 1
  }
  # The evaluator's newer counters are adopted; an older copy never lowers them.
  [[ "$sc_mergeability_s" -eq 7 && "$sc_ruleset_s" -eq 1 && "$sc_trust_gate_s" -eq 3 ]] || return 1
  _pmp_stage_timing_reset "$timing_prefix"
  printf '%s\n' '@parse_and_validate 199' 'parse_and_validate:1 4 0 0 0' >>"$_PMP_STAGE_TIMING_FILE"
  _pmp_record_pr_processing_timing "$timing_prefix" 150 42 || return 1
  [[ "$sc_slowest_pr" == "#42:50s" && "$sc_slowest_stages" == "parse_and_validate:1" && "$sc_mergeability_s" -eq 7 ]] || return 1
  _pmp_stage_timing_discard
  [[ -z "$_PMP_STAGE_TIMING_FILE" ]] || return 1
  return 0
}

if ! (stage_collect_regression); then
  printf 'FAIL: stage collection, unfinished-stage attribution or counter adoption regressed\n'
  exit 1
fi

LIST_TIMEOUT_FILE="${TEST_ROOT}/list-timeout"
pulse_pr_list_get() {
	printf '%s' "${AIDEVOPS_GH_READ_TIMEOUT:-unset}" >"$LIST_TIMEOUT_FILE"
	printf '%s' 'request timed out' >&2
	return 124
}
failed_merged=0 failed_closed=0 failed_count=0 failed_pr_count=0
failed_list_s=0 failed_list_state="complete"
_merge_ready_prs_for_repo "owner/failure" failed_merged failed_closed failed_count failed_pr_count "failed_"
if [[ "$(<"$LIST_TIMEOUT_FILE")" != "45" ]]; then
	printf 'FAIL: merge PR list did not receive its list-specific 45s timeout\n'
	exit 1
fi
if [[ "$failed_list_state" != "incomplete" || "$failed_pr_count" -ne 0 ]]; then
	printf 'FAIL: failed PR list was not recorded as incomplete with zero observed PRs\n'
	exit 1
fi
_pmp_log_repo_timing_summary "owner/failure" 0 "$failed_list_s" 0 0 0 0 0 0 0 "$failed_pr_count" "$failed_list_state"
if ! grep -q 'deterministic_merge_pass timing: repo=owner/failure .*list_state=incomplete' "$LOGFILE"; then
	printf 'FAIL: missing explicit incomplete PR-list timing telemetry\n'
	exit 1
fi

_pmp_now_epoch() { printf '100'; }
_pmp_now_epoch_into() { printf -v "$1" '%s' "$(_pmp_now_epoch)"; return 0; }
_PMP_MERGE_PASS_DEADLINE_EPOCH=110
if [[ "$(_pmp_merge_pr_list_timeout_seconds)" != "10" ]]; then
	printf 'FAIL: PR-list timeout was not clamped to the remaining pass deadline\n'
	exit 1
fi
rm -f "$LIST_TIMEOUT_FILE"
_PMP_MERGE_PASS_DEADLINE_EPOCH=100
expired_rc=0
_merge_ready_prs_for_repo "owner/expired" failed_merged failed_closed failed_count failed_pr_count "failed_" || expired_rc=$?
if [[ "$expired_rc" -ne 5 || -f "$LIST_TIMEOUT_FILE" || "$failed_list_state" != "incomplete" ]]; then
	printf 'FAIL: expired deadline did not pause before the PR-list provider call\n'
	exit 1
fi
_PMP_MERGE_PASS_DEADLINE_EPOCH=0

if ! grep -q 'deterministic_merge_pass timing: total_s=' "$LOGFILE"; then
  printf 'FAIL: missing overall deterministic_merge_pass timing summary\n'
  cat "$LOGFILE"
  exit 1
fi

unset_accumulator_regression() {
  local elapsed_total
  _pmp_add_elapsed_seconds elapsed_total "$(_pmp_now_epoch)"
  [[ "$elapsed_total" =~ ^[0-9]+$ ]]
  return $?
}

if ! unset_accumulator_regression; then
  printf 'FAIL: declared-but-unset timing accumulator was not initialized safely\n'
  exit 1
fi

# Exercise the shared final gate, so every call site inherits cumulative timing
# without relying on a caller-specific timer or wall-clock sleeps.
final_gate_timing_regression() {
  local timing_prefix="gate_" gate_trust_gate_s=0 fake_epoch=100
  local failure="" rc=0
  local pr_number=7 repo_slug="owner/repo" pr_head_ref_oid="sha-reviewed"
  local linked_issue=101 pr_labels="origin:worker" pr_updated_at=""
  local route_calls=0 routed_evidence=""
  local fresh_evidence='[{"name":"current-check","bucket":"fail"}]'
  _pmp_now_epoch() { printf '%s' "$fake_epoch"; return 0; }
  _pmp_now_epoch_into() { printf -v "$1" '%s' "$fake_epoch"; return 0; }
  _pulse_merge_admin_safety_check() { fake_epoch=$((fake_epoch + 1)); [[ "$failure" != authority ]]; return $?; }
  _pulse_merge_refresh_review_gate_evidence() { fake_epoch=$((fake_epoch + 1)); [[ "$failure" != review ]]; return $?; }
  worker_briefed_trust_verdict() { fake_epoch=$((fake_epoch + 1)); [[ "$failure" != worker ]]; return $?; }
  _pulse_merge_preflight_snapshot_gate() {
    fake_epoch=$((fake_epoch + 1))
    if [[ "$failure" == snapshot ]]; then
      _PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON="$fresh_evidence"
      return 1
    fi
    return 0
  }
  _pulse_merge_maybe_dispatch_preflight_remediation() { return 0; }
  _route_pr_to_fix_worker() { local checks_json="${9:-}"; route_calls=$((route_calls + 1)); routed_evidence="$checks_json"; return 0; }
  for failure in authority review worker snapshot; do
    _PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON='[{"name":"previous-pr-check","bucket":"fail"}]'
    rc=0
    _pmp_admin_final_gate_or_route || rc=$?
    [[ "$rc" -eq 1 ]] || return 1
    if [[ "$failure" != snapshot ]]; then
      [[ "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" == "[]" && "$route_calls" -eq 0 ]] || return 1
    else
      [[ "$route_calls" -eq 1 && "$routed_evidence" == "$fresh_evidence" ]] || return 1
    fi
  done
  [[ "$gate_trust_gate_s" -eq 10 ]] || return 1
  failure=""
  _pulse_merge_final_trust_gate 7 owner/repo sha-reviewed || return 1
  [[ "$gate_trust_gate_s" -eq 14 ]] || return 1
  # A real native-auto enable uses the same shared timer.
  _PULSE_FINAL_REQUIRES_SYNCHRONOUS_MERGE=0
  _enable_native_auto_merge_for_head 7 owner/repo sha-reviewed 1 || return 1
  [[ "$gate_trust_gate_s" -eq 18 ]] || return 1
  # Disabling telemetry must not change authorization or add elapsed time.
  timing_prefix=""
  _pulse_merge_final_trust_gate 7 owner/repo sha-reviewed || return 1
  [[ "$gate_trust_gate_s" -eq 18 ]] || return 1
  return 0
}

if ! (final_gate_timing_regression); then
  printf 'FAIL: final-gate cumulative timing or stale-evidence isolation regressed\n'
  exit 1
fi

unset LOGFILE
_pmp_log_repo_timing_summary "owner/fallback"
if ! grep -q 'deterministic_merge_pass timing: repo=owner/fallback' "${HOME}/.aidevops/logs/pulse.log"; then
  printf 'FAIL: unset LOGFILE did not use the standard pulse log path\n'
  exit 1
fi

printf 'PASS: timing summaries emitted for multi-repo merge pass\n'
