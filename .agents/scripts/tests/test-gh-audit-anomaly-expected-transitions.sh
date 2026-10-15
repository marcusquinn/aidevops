#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#28997 and GH#29141: expected lifecycle transitions
# remain audited without hiding destructive changes. Unavailable-only state
# reads remain in the audit log but are not actionable security anomalies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../gh-audit-anomaly-helper.sh"
LOG_HELPER="${SCRIPT_DIR}/../gh-audit-log-helper.sh"
SAFE_EDIT_HELPER="${SCRIPT_DIR}/../shared-gh-wrappers-safe-edit.sh"
TEST_ROOT=""

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

TEST_ROOT="$(mktemp -d -t aidevops-gh-anomaly-XXXXXX)"
LOG_FILE="${TEST_ROOT}/gh-audit.log"
mkdir -p "${TEST_ROOT}/bin"
cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" && "${2:-}" == "repos/public/repo" ]]; then
	printf '%s\n' public
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "repos/private/repo" ]]; then
	printf '%s\n' private
	exit 0
fi
exit 1
EOF
chmod +x "${TEST_ROOT}/bin/gh"
PATH="${TEST_ROOT}/bin:$PATH"
export PATH

cat >"$LOG_FILE" <<'EOF'
{"ts":"2026-07-31T00:00:00Z","op":"issue_edit","repo":"example/repo","number":1,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["auto-dispatch","status:available"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":["auto-dispatch","status:available"]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:01:00Z","op":"issue_edit","repo":"example/repo","number":2,"caller_script":"/workspace/.agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:02:00Z","op":"issue_edit","repo":"private/repo","number":3,"caller_script":"/tmp/close-issue.sh","caller_function":"main","before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:done"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-review"],"labels_added":["status:done"]},"suspicious":["protected_label_removed:status:in-review"]}
{"ts":"2026-07-31T00:03:00Z","op":"issue_edit","repo":"inaccessible/repo","number":4,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":0,"labels":["auto-dispatch"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":-100,"labels_removed":["needs-maintainer-review"],"labels_added":["auto-dispatch"]},"suspicious":["protected_label_removed:needs-maintainer-review","body_delta_pct=-100"]}
{"ts":"2026-07-31T00:04:00Z","op":"issue_edit","repo":"public/repo","number":5,"caller_script":42,"caller_function":"_approval_apply_issue_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:05:00Z","op":"issue_edit","repo":"example/repo","number":6,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:06:00Z","op":"pr_edit","repo":"example/repo","number":7,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_pr_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:07:00Z","op":"pr_edit","repo":"example/repo","number":8,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_pr_lifecycle_updates","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:08:00Z","op":"issue_edit","repo":"example/repo","number":9,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-permissions"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":["needs-maintainer-permissions"]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:09:00Z","op":"issue_edit","repo":"example/repo","number":10,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":0,"labels":["needs-maintainer-permissions"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":-100,"labels_removed":["status:in-progress"],"labels_added":["needs-maintainer-permissions"]},"suspicious":["protected_label_removed:status:in-progress","body_delta_pct=-100"]}
{"ts":"2026-07-31T00:10:00Z","op":"issue_edit","repo":"example/repo","number":11,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":[]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:11:00Z","op":"issue_edit","repo":"example/repo","number":12,"caller_script":"/runtime/agents/scripts/routine-log-helper.sh","caller_function":"_update_tracking_issue","flags":{},"before":{"capture_status":"ok","title_len":27,"body_len":1822,"labels":["routines","routine-tracking"]},"after":{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null},"delta":{"comparable":false,"title_delta_pct":null,"body_delta_pct":null,"labels_removed":null,"labels_added":null},"suspicious":["state_capture_unavailable:after"]}
{"ts":"2026-07-31T00:12:00Z","op":"issue_edit","repo":"example/repo","number":13,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress","status:in-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review","needs-maintainer-permissions"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":["needs-maintainer-permissions"]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:13:00Z","op":"issue_edit","repo":"example/repo","number":14,"caller_script":"/runtime/agents/scripts/pulse-nmr-approval.sh","caller_function":"_nmr_edit_issue_labels","flags":{"trusted_author_nmr_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review","needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:14:00Z","op":"issue_edit","repo":"example/repo","number":15,"caller_script":"/runtime/agents/scripts/pulse-nmr-approval.sh","caller_function":"_nmr_edit_issue_labels","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:15:00Z","op":"issue_edit","repo":"example/repo","number":16,"caller_script":"/runtime/agents/scripts/pulse-nmr-approval.sh","caller_function":"_nmr_edit_issue_labels","flags":{"trusted_author_nmr_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":0,"labels":["auto-dispatch"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":-100,"labels_removed":["needs-maintainer-review"],"labels_added":["auto-dispatch"]},"suspicious":["protected_label_removed:needs-maintainer-review","body_delta_pct=-100"]}
{"ts":"2026-07-31T00:16:00Z","op":"issue_edit","repo":"example/repo","number":17,"caller_script":"/workspace/.agents/scripts/pulse-nmr-approval.sh","caller_function":"_nmr_edit_issue_labels","flags":{"trusted_author_nmr_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":["hold-for-review"]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:17:00Z","op":"issue_edit","repo":"example/repo","number":18,"caller_script":"/runtime/agents/scripts/routine-log-helper.sh","caller_function":"_update_tracking_issue","before":{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null},"after":{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null},"delta":{"comparable":false,"title_delta_pct":null,"body_delta_pct":null,"labels_removed":null,"labels_added":null},"suspicious":["state_capture_unavailable:before","state_capture_unavailable:after"]}
{"ts":"2026-07-31T00:18:00Z","op":"issue_edit","repo":"example/repo","number":19,"caller_script":"/runtime/agents/scripts/routine-log-helper.sh","caller_function":"_update_tracking_issue","before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["monitoring"]},"after":{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null},"delta":{"comparable":false,"title_delta_pct":null,"body_delta_pct":null,"labels_removed":null,"labels_added":null},"suspicious":["state_capture_unavailable:after","body_delta_pct=-100"]}
{"ts":"2026-07-31T00:19:00Z","op":"issue_edit","repo":"example/repo","number":20,"caller_script":"/runtime/agents/scripts/full-loop-helper-commit.sh","caller_function":"_label_issue_in_review","flags":{"pr_review_handoff_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":["status:in-review"]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:20:00Z","op":"issue_edit","repo":"example/repo","number":21,"caller_script":"/runtime/agents/scripts/full-loop-helper-commit.sh","caller_function":"_label_issue_in_review","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":["status:in-review"]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:21:00Z","op":"issue_edit","repo":"example/repo","number":22,"caller_script":"/runtime/agents/scripts/full-loop-helper.sh","caller_function":"main","flags":{"pr_review_handoff_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":["status:in-review"]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:22:00Z","op":"issue_edit","repo":"example/repo","number":23,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["monitoring"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["monitoring","needs-maintainer-permissions"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":["needs-maintainer-permissions"]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:23:00Z","op":"issue_edit","repo":"example/repo","number":24,"caller_script":"/runtime/agents/scripts/planning-publication-reconcile.sh","caller_function":"_publication_reconcile_one","flags":{"planning_publication_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["no-auto-dispatch","publication:pending"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["auto-dispatch","status:blocked","publication:pending"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["no-auto-dispatch"],"labels_added":["auto-dispatch","status:blocked"]},"suspicious":["protected_label_removed:no-auto-dispatch"]}
{"ts":"2026-07-31T00:24:00Z","op":"issue_edit","repo":"example/repo","number":25,"caller_script":"/runtime/agents/scripts/planning-publication-reconcile.sh","caller_function":"_publication_reconcile_one","flags":{"planning_publication_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["no-auto-dispatch"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["auto-dispatch"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["no-auto-dispatch"],"labels_added":["auto-dispatch"]},"suspicious":["protected_label_removed:no-auto-dispatch"]}
{"ts":"2026-07-31T00:25:00Z","op":"issue_edit","repo":"example/repo","number":26,"caller_script":"/runtime/agents/scripts/pulse-merge-feedback.sh","caller_function":"main","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["origin:worker","source:ci-feedback","status:in-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["origin:worker","source:ci-feedback","status:available"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-review"],"labels_added":["status:available"]},"suspicious":["protected_label_removed:status:in-review"]}
{"ts":"2026-07-31T00:26:00Z","op":"issue_edit","repo":"example/repo","number":27,"caller_script":"/runtime/agents/scripts/pulse-merge-feedback.sh","caller_function":"main","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["origin:worker","status:in-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["origin:worker","source:ci-feedback","status:available"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-review"],"labels_added":["status:available","source:ci-feedback"]},"suspicious":["protected_label_removed:status:in-review"]}
{"ts":"2026-07-31T00:27:00Z","op":"issue_edit","repo":"example/repo","number":28,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-permissions","status:blocked"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-review"],"labels_added":["needs-maintainer-permissions","status:blocked"]},"suspicious":["protected_label_removed:status:in-review"]}
EOF

output=$(GH_AUDIT_LOG_FILE="$LOG_FILE" GH_ANOMALY_STATE_FILE="${TEST_ROOT}/state.json" \
	GH_AUDIT_QUIET=true "$HELPER" scan --all --dry-run)

[[ "$output" == *"**Anomalies found:** 15"* ]] || fail "expected transitions were not excluded exactly"
[[ "$output" == *"| #3 |"* ]] || fail "unexpected lifecycle transition was hidden"
[[ "$output" == *"| #4 |"* ]] || fail "approval transition with an additional signal was hidden"
[[ "$output" == *"| #5 |"* ]] || fail "malformed provenance was dropped instead of retained"
[[ "$output" == *"| #6 |"* ]] || fail "unverified approval provenance was trusted"
[[ "$output" == *"| #8 |"* ]] || fail "unverified PR approval provenance was trusted"
[[ "$output" == *"| #10 |"* ]] || fail "permission block with an additional signal was hidden"
[[ "$output" == *"| #11 |"* ]] || fail "permission block without its blocker label was hidden"
[[ "$output" == *"| #13 |"* ]] || fail "permission block with a lingering active status was hidden"
[[ "$output" == *"| #15 |"* ]] || fail "unverified trusted-author NMR removal was hidden"
[[ "$output" == *"| #16 |"* ]] || fail "trusted-author NMR transition with an additional signal was hidden"
[[ "$output" == *"| #19 |"* ]] || fail "unavailable capture with an additional destructive signal was hidden"
[[ "$output" == *"| #21 |"* ]] || fail "unverified full-loop handoff was hidden"
[[ "$output" == *"| #23 |"* ]] || fail "permission block without a prior active status was hidden"
[[ "$output" == *"| #25 |"* ]] || fail "planning transition without publication evidence was hidden"
[[ "$output" == *"| #27 |"* ]] || fail "feedback redispatch with an additional label change was hidden"
[[ "$output" == *"The audit log stores lengths, not content."* ]] || fail "recovery guidance overclaimed audit content"
[[ "$output" != *"private/repo"* ]] || fail "private repository name leaked into the report"
[[ "$output" != *"inaccessible/repo"* ]] || fail "unverified repository name leaked into the report"
[[ "$output" == *"[private repository]"* ]] || fail "redacted repository placeholder was missing"
[[ "$output" == *"public/repo"* ]] || fail "verified public repository name was redacted"
[[ "$output" != *"| #1 |"* && "$output" != *"| #2 |"* && "$output" != *"| #7 |"* && "$output" != *"| #9 |"* &&
	"$output" != *"| #12 |"* && "$output" != *"| #14 |"* && "$output" != *"| #17 |"* &&
	"$output" != *"| #18 |"* && "$output" != *"| #20 |"* && "$output" != *"| #22 |"* &&
	"$output" != *"| #24 |"* && "$output" != *"| #26 |"* && "$output" != *"| #28 |"* ]] ||
	fail "an exact expected transition remained actionable"

MALFORMED_LOG="${TEST_ROOT}/malformed-audit.log"
cat >"$MALFORMED_LOG" <<'EOF'
{"suspicious":[]}
not-json
{"ts":"2026-07-31T00:13:00Z","op":"issue_edit","repo":"example/repo","number":14,"caller_function":"main","suspicious":["body_delta_pct=-100"]}
EOF
malformed_rc=0
GH_AUDIT_LOG_FILE="$MALFORMED_LOG" GH_ANOMALY_STATE_FILE="${TEST_ROOT}/malformed-state.json" \
	GH_AUDIT_QUIET=true "$HELPER" scan --all --dry-run >/dev/null 2>&1 || malformed_rc=$?
[[ "$malformed_rc" -ne 0 ]] || fail "malformed NDJSON did not fail the scan closed"
[[ ! -e "${TEST_ROOT}/malformed-state.json" ]] || fail "malformed NDJSON advanced the scan checkpoint"

# shellcheck source=../shared-gh-wrappers-safe-edit.sh
source "$SAFE_EDIT_HELPER"
PROOF_LOG="${TEST_ROOT}/proof-audit.log"
export GH_AUDIT_LOG_FILE="$PROOF_LOG"
GH_TIMEOUT_TRACE="${TEST_ROOT}/gh-timeout-calls.log"
_gh_with_timeout() {
	local op_class="$1"
	shift
	printf '%s|%s\n' "$op_class" "$*" >>"$GH_TIMEOUT_TRACE"
	"$@"
	return $?
}
cmd_verify() {
	local target_type="${1:-}"
	local target_number="${2:-}"
	if [[ "$target_type" == "issue" && "$target_number" == "20" ]] ||
		[[ "$target_type" == "pr" && "$target_number" == "21" ]]; then
		printf 'VERIFIED\n'
		return 0
	fi
	printf 'WRONG_TARGET\n'
	return 1
}
_gh_audit_record_op \
	"issue_edit" "example/repo" "20" \
	'{"title_len":1,"body_len":1,"labels":["needs-maintainer-review"]}' \
	'{"title_len":1,"body_len":1,"labels":[]}' \
	"/runtime/agents/scripts/approval-helper.sh" \
	"_approval_apply_issue_lifecycle_updates" "1"
jq -e 'select(.number == 20) | .flags.approval_verified == "v2-current-state"' "$PROOF_LOG" >/dev/null ||
	fail "successful current-state verification did not produce audit proof"
_gh_audit_record_op \
	"pr_edit" "example/repo" "21" \
	'{"title_len":1,"body_len":1,"labels":["needs-maintainer-review"]}' \
	'{"title_len":1,"body_len":1,"labels":[]}' \
	"/runtime/agents/scripts/approval-helper.sh" \
	"_approval_apply_pr_lifecycle_updates" "1"
jq -e 'select(.number == 21) | .flags.approval_verified == "v2-current-state"' "$PROOF_LOG" >/dev/null ||
	fail "successful PR verification did not produce audit proof"

cmd_verify() {
	printf 'STALE_APPROVAL\n'
	return 4
}
_gh_audit_record_op \
	"pr_edit" "example/repo" "22" \
	'{"title_len":1,"body_len":1,"labels":["needs-maintainer-review"]}' \
	'{"title_len":1,"body_len":1,"labels":[]}' \
	"/runtime/agents/scripts/approval-helper.sh" \
	"_approval_apply_pr_lifecycle_updates" "1"
jq -e -s 'map(select(.number == 22))[0].flags == {}' "$PROOF_LOG" >/dev/null ||
	fail "failed approval verification produced trusted audit proof"

CURRENT_ACTOR="trusted-runner"
gh() {
	local command="$1"
	local resource="${2:-}"
	[[ "$command" == "api" ]] || return 1
	case "$resource" in
	repos/example/repo/issues/25 | repos/example/repo/issues/27)
		printf '%s\n' '{"user":{"login":"trusted-author","type":"User"},"author_association":"COLLABORATOR","labels":[{"name":"hold-for-review"}]}'
		;;
	repos/example/repo/issues/26)
		printf '%s\n' '{"user":{"login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","labels":[]}'
		;;
	user)
		printf '%s\n' "$CURRENT_ACTOR"
		;;
	*) return 1 ;;
	esac
	return 0
}
_gh_actor_has_repo_write_authority() {
	local repo_slug="$1"
	local actor="$2"
	local association="${3:-NONE}"
	[[ "$repo_slug" == "example/repo" ]] || return 2
	[[ "$actor" == "trusted-runner" || ("$actor" == "trusted-author" && "$association" == "COLLABORATOR") ]]
	return $?
}
gh() {
	local command="$1"
	local resource="${2:-}"
	[[ "$command" == "api" && "$resource" == "repos/example/repo/issues/24" ]] || return 1
	printf '%s\n' '{"state":"open","labels":[{"name":"auto-dispatch"},{"name":"status:blocked"},{"name":"publication:pending"}]}'
	return 0
}
_gh_audit_record_op \
	"issue_edit" "example/repo" "24" \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["no-auto-dispatch","publication:pending"]}' \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["auto-dispatch","status:blocked","publication:pending"]}' \
	"/runtime/agents/scripts/planning-publication-reconcile.sh" \
	"_publication_reconcile_one" "1"
jq -e 'select(.number == 24) | .flags.planning_publication_verified == "v1-current-state"' "$PROOF_LOG" >/dev/null ||
	fail "verified planning publication transition did not produce audit proof"

gh() {
	local command="$1"
	local resource="${2:-}"
	[[ "$command" == "api" ]] || return 1
	case "$resource" in
	repos/example/repo/issues/25 | repos/example/repo/issues/27)
		printf '%s\n' '{"user":{"login":"trusted-author","type":"User"},"author_association":"COLLABORATOR","labels":[{"name":"hold-for-review"}]}'
		;;
	repos/example/repo/issues/26)
		printf '%s\n' '{"user":{"login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","labels":[]}'
		;;
	user)
		printf '%s\n' "$CURRENT_ACTOR"
		;;
	*) return 1 ;;
	esac
	return 0
}
_gh_audit_record_op \
	"issue_edit" "example/repo" "25" \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review","needs-maintainer-review"]}' \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review"]}' \
	"/runtime/agents/scripts/pulse-nmr-approval.sh" \
	"_nmr_edit_issue_labels" "1"
jq -e 'select(.number == 25) | .flags.trusted_author_nmr_verified == "v1-current-state"' "$PROOF_LOG" >/dev/null ||
	fail "trusted-author NMR transition did not produce current-state audit proof"
_gh_audit_record_op \
	"issue_edit" "example/repo" "26" \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]}' \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]}' \
	"/runtime/agents/scripts/pulse-nmr-approval.sh" \
	"_nmr_edit_issue_labels" "1"
jq -e -s 'map(select(.number == 26))[0].flags == {}' "$PROOF_LOG" >/dev/null ||
	fail "external-author NMR removal produced trusted-author audit proof"
CURRENT_ACTOR="read-only-runner"
_gh_audit_record_op \
	"issue_edit" "example/repo" "27" \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review","needs-maintainer-review"]}' \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review"]}' \
	"/runtime/agents/scripts/pulse-nmr-approval.sh" \
	"_nmr_edit_issue_labels" "1"
jq -e -s 'map(select(.number == 27))[0].flags == {}' "$PROOF_LOG" >/dev/null ||
	fail "read-only current actor produced trusted-author audit proof"
unset CURRENT_ACTOR
unset GH_AUDIT_LOG_FILE

gh() {
	local command="$1"
	local resource="${2:-}"
	[[ "$command" == "api" && "$resource" == "repos/example/repo/issues/28" ]] || return 1
	printf '%s\n' '{"state":"open","labels":[{"name":"status:in-review"}]}'
	return 0
}
HANDOFF_LOG="${TEST_ROOT}/handoff-audit.log"
GH_AUDIT_LOG_FILE="$HANDOFF_LOG" _gh_audit_record_op \
	"issue_edit" "example/repo" "28" \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]}' \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review"]}' \
	"/runtime/agents/scripts/full-loop-helper-commit.sh" \
	"_label_issue_in_review" "1"
jq -e 'select(.number == 28) | .flags.pr_review_handoff_verified == "v1-current-state"' "$HANDOFF_LOG" >/dev/null ||
	fail "verified full-loop handoff did not produce audit proof"

# GH#34614: exercise the actual managed-write CLI dispatch and safe-edit audit,
# not just a synthetic caller string. Only remote transport/privacy is stubbed.
CLI_HANDOFF_LOG="${TEST_ROOT}/cli-handoff-audit.log"
(
	CLI_SCRIPT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
	# shellcheck source=../shared-gh-wrappers.sh
	source "${CLI_SCRIPT_DIR}/shared-gh-wrappers.sh"
	# Source the real CLI harmlessly to load its entrypoint and dispatch functions.
	# shellcheck source=../gh-write-helper.sh
	source "${CLI_SCRIPT_DIR}/gh-write-helper.sh" help >/dev/null
	export GH_AUDIT_LOG_FILE="$CLI_HANDOFF_LOG"
	HANDOFF_STAGE="status:in-progress"
	HANDOFF_CASE="valid"
	handoff_issue_json() {
		jq -n --arg status "$HANDOFF_STAGE" --arg scenario "$HANDOFF_CASE" '
			{state: (if $scenario == "closed" then "closed" else "open" end),
			 title: "Owned issue", body: "Preserved body",
			 assignees: [{login: (if $scenario == "unowned" then "other" else "runner" end)}],
			 labels: [{name: $status}]}'
		return 0
	}
	gh_issue_view() { handoff_issue_json; return 0; }
	_gh_guard_public_write_args() { return 0; }
	gh() {
		local command="$1" resource="${2:-}"
		[[ "$HANDOFF_CASE" != "unavailable" ]] || return 1
		case "${command}:${resource}" in
		api:user) printf '%s\n' runner ;;
		api:repos/example/repo/issues/29) handoff_issue_json ;;
		pr:view)
			jq -n --arg scenario "$HANDOFF_CASE" --arg stage "$HANDOFF_STAGE" '
				{state: (if $scenario == "merged" then "MERGED" else "OPEN" end),
				 isDraft: ($scenario == "draft" or ($scenario == "race" and $stage == "status:in-review")),
				 author: {login: (if $scenario == "other-author" then "other" else "runner" end)},
				 closingIssuesReferences: [{number: (if $scenario == "unlinked" then 99 else 29 end),
				 repository: {owner: {login: (if $scenario == "cross-repo" then "other" else "example" end)}, name: "repo"}}]}'
			;;
		issue:edit) HANDOFF_STAGE="status:in-review" ;;
		*) return 1 ;;
		esac
		return 0
	}
	main issue review-handoff 29 --repo example/repo --pr 30 || fail "real CLI handoff failed"
	jq -e '.caller_function == "_issue_review_handoff" and
		.flags.pr_review_handoff_verified == "v2-owned-pr-current-state"' "$CLI_HANDOFF_LOG" >/dev/null ||
		fail "real CLI handoff did not emit live verified provenance"
	for HANDOFF_CASE in draft merged unlinked cross-repo unowned other-author closed unavailable; do
		HANDOFF_STAGE="status:in-progress"
		if main issue review-handoff 29 --repo example/repo --pr 30; then
			fail "unsafe CLI handoff accepted: $HANDOFF_CASE"
		fi
		[[ "$HANDOFF_STAGE" == "status:in-progress" ]] || fail "failed preflight mutated labels"
	done
	HANDOFF_CASE="race"
	HANDOFF_STAGE="status:in-progress"
	main issue review-handoff 29 --repo example/repo --pr 30 || fail "race fixture mutation failed"
	HANDOFF_CASE="valid"
	HANDOFF_STAGE="status:in-progress"
	_GH_REVIEW_HANDOFF_PR=30 main issue edit 29 --repo example/repo \
		--remove-label status:in-progress --add-label status:in-review || fail "generic edit fixture failed"
	jq -e -s 'length == 3 and .[1].flags == {} and .[2].flags == {}' "$CLI_HANDOFF_LOG" >/dev/null ||
		fail "race or generic edit acquired verified provenance"
)
cli_output=$(GH_AUDIT_LOG_FILE="$CLI_HANDOFF_LOG" GH_ANOMALY_STATE_FILE="${TEST_ROOT}/cli-state.json" \
	GH_AUDIT_QUIET=true "$HELPER" scan --all --dry-run)
[[ "$cli_output" == *"**Anomalies found:** 2"* ]] ||
	fail "scanner did not exclude exactly the verified real-path handoff"

gh_issue_view() {
	printf '%s\n' '{"title":"REST issue snapshot","body":"Protected body","labels":[{"name":"monitoring"}]}'
	return 0
}
gh_pr_view() {
	printf '%s\n' '{"title":"REST PR snapshot","body":"Protected body","labels":[{"name":"monitoring"}]}'
	return 0
}
gh() {
	return 1
}
wrapped_issue="$(_gh_audit_fetch_issue_state_json "8" "example/repo")"
wrapped_pr="$(_gh_audit_fetch_pr_state_json "9" "example/repo")"
jq -e '.capture_status == "ok" and .title_len == 19 and .body_len == 14 and .labels == ["monitoring"]' \
	<<<"$wrapped_issue" >/dev/null || fail "issue audit capture bypassed the REST-capable read wrapper"
jq -e '.capture_status == "ok" and .title_len == 16 and .body_len == 14 and .labels == ["monitoring"]' \
	<<<"$wrapped_pr" >/dev/null || fail "PR audit capture bypassed the REST-capable read wrapper"

gh_issue_view() {
	return 1
}
gh_pr_view() {
	return 1
}
gh() {
	local resource="${1:-}"
	local operation="${2:-}"
	[[ "$operation" == "view" ]] || return 1
	case "$resource" in
	issue) printf '%s\n' '{"title":"Native issue snapshot","body":"Protected body","labels":[{"name":"monitoring"}]}' ;;
	pr) printf '%s\n' '{"title":"Native PR snapshot","body":"Protected body","labels":[{"name":"monitoring"}]}' ;;
	*) return 1 ;;
	esac
	return 0
}
native_fallback_issue="$(_gh_audit_fetch_issue_state_json "8" "example/repo")"
native_fallback_pr="$(_gh_audit_fetch_pr_state_json "9" "example/repo")"
jq -e '.capture_status == "ok" and .title_len == 21 and .body_len == 14 and .labels == ["monitoring"]' \
	<<<"$native_fallback_issue" >/dev/null || fail "issue audit capture did not fall back after the REST-capable wrapper failed"
jq -e '.capture_status == "ok" and .title_len == 18 and .body_len == 14 and .labels == ["monitoring"]' \
	<<<"$native_fallback_pr" >/dev/null || fail "PR audit capture did not fall back after the REST-capable wrapper failed"
grep -Fqx 'read|gh issue view 8 --repo example/repo --json title,body,labels' "$GH_TIMEOUT_TRACE" ||
	fail "native issue audit fallback bypassed _gh_with_timeout"
grep -Fqx 'read|gh pr view 9 --repo example/repo --json title,body,labels' "$GH_TIMEOUT_TRACE" ||
	fail "native PR audit fallback bypassed _gh_with_timeout"

gh() {
	return 1
}
_rest_issue_view() {
	printf '%s\n' '{"title":"REST issue fallback","body":"Protected body","labels":[{"name":"monitoring"}]}'
	return 0
}
_rest_pr_view() {
	printf '%s\n' '{"title":"REST PR fallback","body":"Protected body","labels":[{"name":"monitoring"}]}'
	return 0
}
fallback_issue="$(_gh_audit_fetch_issue_state_json "8" "example/repo")"
fallback_pr="$(_gh_audit_fetch_pr_state_json "9" "example/repo")"
jq -e '.capture_status == "ok" and .title_len == 19 and .body_len == 14 and .labels == ["monitoring"]' \
	<<<"$fallback_issue" >/dev/null || fail "failed issue wrapper did not exhaust the direct REST fallback"
jq -e '.capture_status == "ok" and .title_len == 16 and .body_len == 14 and .labels == ["monitoring"]' \
	<<<"$fallback_pr" >/dev/null || fail "failed PR wrapper did not exhaust the direct REST fallback"
unset -f gh_issue_view gh_pr_view _rest_issue_view _rest_pr_view

gh() {
	local resource="${1:-}"
	if [[ "$resource" != "issue" && "$resource" != "pr" ]]; then
		return 1
	fi
	return 1
}
unavailable_issue="$(_gh_audit_fetch_issue_state_json "8" "example/repo")"
unavailable_pr="$(_gh_audit_fetch_pr_state_json "9" "example/repo")"
jq -e '.capture_status == "unavailable" and .title_len == null and .body_len == null and .labels == null' \
	<<<"$unavailable_issue" >/dev/null || fail "failed issue read was encoded as an empty state"
jq -e '.capture_status == "unavailable" and .title_len == null and .body_len == null and .labels == null' \
	<<<"$unavailable_pr" >/dev/null || fail "failed PR read was encoded as an empty state"

gh() {
	local resource="${1:-}"
	if [[ "$resource" != "issue" && "$resource" != "pr" ]]; then
		return 1
	fi
	printf '%s\n' '{"title":"Protected title","body":"Protected body","labels":[{"name":"monitoring"}]}'
	return 0
}
available_issue="$(_gh_audit_fetch_issue_state_json "8" "example/repo")"
jq -e '.capture_status == "ok" and .title_len == 15 and .body_len == 14 and .labels == ["monitoring"]' \
	<<<"$available_issue" >/dev/null || fail "successful issue read was not marked comparable"

CAPTURE_LOG="${TEST_ROOT}/capture-audit.log"
GH_AUDIT_LOG_FILE="$CAPTURE_LOG" GH_AUDIT_QUIET=true "$LOG_HELPER" record \
	--op issue_edit --repo example/repo --number 23 \
	--before-json '{"capture_status":"ok","title_len":1,"body_len":1,"labels":["monitoring"]}' \
	--after-json '{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null}' \
	--caller-script routine-log-helper.sh --caller-function _update_tracking_issue --caller-line 1
jq -e '
	.delta.comparable == false
	and .delta.title_delta_pct == null
	and .delta.body_delta_pct == null
	and .delta.labels_removed == null
	and .delta.labels_added == null
	and .suspicious == ["state_capture_unavailable:after"]
' "$CAPTURE_LOG" >/dev/null || fail "unavailable capture produced a destructive delta"

MISSING_CAPTURE_LOG="${TEST_ROOT}/missing-capture-audit.log"
GH_AUDIT_LOG_FILE="$MISSING_CAPTURE_LOG" GH_AUDIT_QUIET=true "$LOG_HELPER" record \
	--op issue_edit --repo example/repo --number 24 \
	--caller-script unknown.sh --caller-function main --caller-line 1
jq -e '
	.before.capture_status == "unavailable"
	and .after.capture_status == "unavailable"
	and .delta.comparable == false
	and .suspicious == ["state_capture_unavailable:before", "state_capture_unavailable:after"]
' "$MISSING_CAPTURE_LOG" >/dev/null || fail "omitted snapshots became synthetic empty state"

# GH#34775: live release verification and exact-shape filtering, including the
# mixed-version generic main path which must remain actionable.
BLOCKED_LOG="${TEST_ROOT}/blocked-audit.log"
(
	export GH_AUDIT_LOG_FILE="$BLOCKED_LOG"
	BLOCKED_CASE=valid
	gh() {
		local command="$1" endpoint="${2:-}"
		[[ "$command" == api && "$BLOCKED_CASE" != unavailable ]] || return 1
		case "$endpoint" in
		user) printf 'runner\n' ;;
		repos/example/repo/issues/80)
			jq -cn --arg scenario "$BLOCKED_CASE" '{state:"open",labels:
				([{name:"status:blocked"}] + if $scenario == "active" then [{name:"status:queued"}] else [] end)}'
			;;
		repos/example/repo/issues/80/comments*)
			jq -cn --arg scenario "$BLOCKED_CASE" '[[
				{id:1,author_association:"OWNER",body:"DISPATCH_CLAIM nonce=first"},
				{id:2,author_association:(if $scenario == "untrusted" then "NONE" else "OWNER" end),
				 body:"CLAIM_RELEASED reason=blocked runner=runner \n<!-- aidevops:terminal-blocker-observation revision=abc -->"}
			] + if $scenario == "stale" then [{id:3,author_association:"OWNER",body:"DISPATCH_CLAIM nonce=next"}] else [] end]'
			;;
		*) return 1 ;;
		esac
		return 0
	}
	for BLOCKED_CASE in valid stale untrusted active unavailable; do
		_gh_audit_record_op issue_edit example/repo 80 \
			'{"capture_status":"ok","title_len":10,"body_len":10,"labels":["status:in-progress"]}' \
			'{"capture_status":"ok","title_len":10,"body_len":10,"labels":["status:blocked"]}' \
			"$(cd "${SCRIPT_DIR}/.." && pwd)/headless-runtime-failure.sh" _hrff_project_blocked_exit 1
	done
	jq -se '.[0].flags.worker_blocked_exit_verified == "v1-release-persisted" and all(.[1:4][]; .flags == {})' "$BLOCKED_LOG" >/dev/null ||
		fail 'blocked exit provenance did not fail closed'
	jq -c 'select(.flags.worker_blocked_exit_verified) |
		(.caller_function="main" | .flags={}),
		(.delta.title_delta_pct=10), (.delta.body_delta_pct=10),
		(.delta.labels_added += ["extra-label"])' "$BLOCKED_LOG" >"${TEST_ROOT}/blocked-negatives"
	cat "${TEST_ROOT}/blocked-negatives" >>"$BLOCKED_LOG"
)
blocked_output=$(GH_AUDIT_LOG_FILE="$BLOCKED_LOG" GH_ANOMALY_STATE_FILE="${TEST_ROOT}/blocked-state.json" \
	GH_AUDIT_QUIET=true "$HELPER" scan --all --dry-run)
[[ "$blocked_output" == *'**Anomalies found:** 8'* ]] || fail 'blocked exact-shape filter hid a generic or mutated edit'
(
	CLI_SCRIPT_DIR="${SCRIPT_DIR}/.."
	# shellcheck source=../gh-write-helper.sh
	source "${CLI_SCRIPT_DIR}/gh-write-helper.sh" help >/dev/null
	WORKER_ISSUE_NUMBER=80
	gh_issue_edit_safe() { return 0; }
	for label_args in '--add-label=status:blocked' '--remove-label=bug,status:in-progress'; do
		rc=0
		main issue edit 80 --repo example/repo "$label_args" 2>"${TEST_ROOT}/guard-output" || rc=$?
		[[ "$rc" == 2 ]] || fail 'worker status edit was accepted'
	done
	rc=0
	main issue edit 80 --remove-label status:in-progress --add-label status:blocked 2>"${TEST_ROOT}/guard-output" || rc=$?
	[[ "$rc" == 2 ]] || fail 'separate status args were accepted'
	rc=0
	main issue edit --repo example/repo 80 --add-label status:blocked 2>"${TEST_ROOT}/guard-output" || rc=$?
	[[ "$rc" == 2 ]] || fail 'options-first status edit was accepted'
	grep -q 'runtime projects lifecycle state' "${TEST_ROOT}/guard-output" || fail 'guard pointer missing'
	main issue edit 80 --add-label needs-secret:CONFIG_NAME || fail 'non-status label edit blocked'
	main issue edit 81 --add-label status:blocked || fail 'non-worker target changed by guard'
)

printf 'PASS: expected approval and blocked transitions are retained in the log but excluded from alerts\n'
