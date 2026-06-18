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
  if ! grep -qE "deterministic_merge_pass timing: repo=${repo} .*list_s=[0-9]+ .*mergeability_s=[0-9]+ .*ruleset_s=[0-9]+ .*branch_protection_s=[0-9]+ .*stuck_detector_s=[0-9]+" "$LOGFILE"; then
    printf 'FAIL: missing structured timing summary for %s\n' "$repo"
    cat "$LOGFILE"
    exit 1
  fi
done

if ! grep -q 'deterministic_merge_pass timing: total_s=' "$LOGFILE"; then
  printf 'FAIL: missing overall deterministic_merge_pass timing summary\n'
  cat "$LOGFILE"
  exit 1
fi

printf 'PASS: timing summaries emitted for multi-repo merge pass\n'
