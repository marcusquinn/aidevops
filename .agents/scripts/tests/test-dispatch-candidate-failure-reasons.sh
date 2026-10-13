#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../dispatch-dedup-helper.sh"

assert_reason() {
	local signal="$1"
	local expected="$2"
	local actual
	actual=$("$HELPER" classify-blocker "$signal")
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL signal=%s expected=%s actual=%s\n' "$signal" "$expected" "$actual" >&2
		return 1
	fi
	return 0
}

assert_reason 'COST_BUDGET_EXCEEDED (spent=123 budget=100)' 'cost_budget_exceeded'
assert_reason 'DISPATCH_BLOCK_REASON reason=dedup_active_claim signal=assigned to runner' 'dedup_active_claim_unverified'
assert_reason 'DISPATCH_BLOCK_REASON reason=interactive_review_hold signal=interactive review hold label present' 'interactive_review_hold'
assert_reason 'Dispatch blocked for #4849 in exampleorg/examplerepo: target is a pull request, not a dispatchable issue (GH#22948)' 'pr_target_not_dispatchable'
assert_reason 'DISPATCH_BLOCK_REASON reason=renovate_dependency_dashboard signal=renovate_dependency_dashboard issue=#24975 repo=marcusquinn/aidevops' 'renovate_dependency_dashboard'
assert_reason 'GraphQL budget below circuit-breaker threshold' 'graphql_circuit_breaker'
assert_reason 'DISPATCH_COOLDOWN_ACTIVE until=2026-05-02T23:00:00Z reason=no_worker_process' 'cooldown_no_worker_process'
assert_reason 'dispatch_with_dedup: BLOCKED #3638 in exampleorg/examplerepo — requires cryptographic approval (ever-NMR)' 'ever_nmr_without_approval'
assert_reason 'DISPATCH_BLOCK_REASON reason=ever_nmr_without_approval signal=ever-NMR issue requires approval' 'ever_nmr_without_approval'
assert_reason 'dispatch_with_dedup: BLOCKED #3638 in exampleorg/examplerepo — ever-NMR issue lacks approval' 'ever_nmr_without_approval'
assert_reason 'blocked by local capacity gate (ever-nmr check not run)' 'local_capacity_gate'
assert_reason 'review-followup exemption: skipping historical ever-NMR check (GH#18648)' 'unclassified_signal'
assert_reason 'skipping historical ever-NMR check for bot-generated cleanup issue (GH#18648)' 'unclassified_signal'
assert_reason 'DISPATCH_BLOCK_REASON reason=blocked_by_native_lookup_unavailable signal=native blockedBy lookup unavailable and no body blocked-by markers found' 'blocked_by_native_lookup_unavailable'
assert_reason 'PR_LOOKUP_RESULT=uncertain reason=timeout scope=open_siblings' 'pr_lookup_uncertain'
# GH#33524: metadata fetch failures are classified, not unclassified_signal.
assert_reason 'DISPATCH_BLOCK_REASON reason=issue_metadata_unavailable signal=transient issue=#33524 repo=marcusquinn/aidevops' 'issue_metadata_unavailable'
assert_reason 'Dispatch blocked for #33524 in marcusquinn/aidevops: unable to load issue metadata' 'issue_metadata_unavailable'
assert_reason 'pre-dispatch validator failed: missing worker context; needs-brief label present' 'missing_worker_context'
assert_reason 'dedup.worktree_cap blocked by max worktree count' 'local_capacity_gate'
assert_reason 'dedup guard blocked #303 in some-org/infrastructure' 'dedup_active_claim_unverified'
assert_reason 'PARENT_TASK_BLOCKED (label=parent-task)' 'parent_task'
assert_reason 'PUBLICATION_PENDING_BLOCKED (label=publication:pending)' 'publication_pending'
assert_reason 'NO_AUTO_DISPATCH_BLOCKED (label=no-auto-dispatch)' 'no_auto_dispatch'
assert_reason 'FOOTPRINT_OVERLAP path=.agents/scripts/pulse-dispatch-engine.sh issue=#25229' 'footprint_overlap'
assert_reason '[dispatch_with_dedup] Hard-stop before worker bootstrap for #25233 in marcusquinn/aidevops: unresolved blocked-by dependency (GH#23932)' 'blocked_by_unresolved'
assert_reason 'dispatch candidate skipped: issue #25275 state=CLOSED' 'issue_closed'
assert_reason 'dispatch candidate skipped: consolidated into #25279' 'consolidated'
assert_reason 'INFRASTRUCTURE_BLOCKED (label=infrastructure)' 'policy_gate'
assert_reason 'HOLD_FOR_REVIEW_BLOCKED (label=hold-for-review)' 'policy_gate'
assert_reason 'external_author_gate blocked no-auto-dispatch policy' 'policy_gate'
# GH#32979: Dependabot-target and pre-claim brief-scope blocks.
assert_reason 'Dispatch blocked for #181 in owner/repo: another issue owns the same Dependabot PR target' 'dependabot_target_owned'
assert_reason '[pulse-wrapper] Dedup: Dependabot PR #30038 intake #43 blocked by target owner #42' 'dependabot_target_owned'
assert_reason 'DISPATCH_BLOCK_REASON reason=dependabot_target_unverified signal=dependabot_target_lookup_unavailable' 'dependabot_target_unverified'
assert_reason '[pulse-wrapper] Dedup: authoritative Dependabot intake lookup unavailable for #43; blocking dispatch' 'dependabot_target_unverified'
assert_reason 'DISPATCH_BLOCK_REASON reason=brief_scope_hold signal=brief_scope_hold_recorded' 'brief_scope_hold'
assert_reason 'DISPATCH_BLOCK_REASON reason=missing_worker_context signal=brief_scope_untrusted_author' 'missing_worker_context'
# GH#33332: terminal-blocker backoff is its own cacheable hold, not an active claim.
assert_reason 'TERMINAL_BLOCKER_BACKOFF failures=2 retry_after=1788696900' 'terminal_blocker_backoff'
assert_reason 'TERMINAL_BLOCKER_CIRCUIT task_revision=aaaaaaaaaaaaaaaaaaaaaaaa' 'terminal_blocker_circuit'
assert_reason '' 'no_recent_log_evidence'
assert_reason 'new blocker shape not yet classified' 'unclassified_signal'

# GH#34526: exercise the production classifier/cache/filter across two cycles.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT"
LOGFILE="$TEST_ROOT/pulse.log"
# shellcheck source=../pulse-dispatch-lib.sh
source "$SCRIPT_DIR/../pulse-dispatch-lib.sh"
_dispatch_stats_increment() { return 0; }
_dispatch_stats_increment_candidate_failed() { return 0; }
_dispatch_mark_benign_blocked_candidate() { return 0; }
_dispatch_candidate_recent_lines() {
	printf '%s\nDISPATCH_BLOCK_REASON reason=%s signal=test\n' "$ATTEMPT_LINES" "$ATTEMPT_REASON"
	return 0
}
# A cooled checkpoint must never require the old expensive PR lookup.
_dispatch_negative_pr_fingerprint() { return 1; }
candidate='{"number":34526,"repo_slug":"example/repo","updatedAt":"2026-10-13T00:00:00Z","assignees":[],"labels":["status:available","auto-dispatch"]}'
ATTEMPT_REASON=dedup_active_claim
ATTEMPT_LINES='WORKER_DRAFT_CHECKPOINT: draft PR #123 is a durable checkpoint
STALLED_CHECKPOINT_CONTINUATION_SKIPPED'
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
_dispatch_cache_confirmed_block "$candidate" 34526 example/repo
[[ "$(_dispatch_negative_cache_reason "$candidate")" == worker_draft_checkpoint_cooldown ]]
for cycle in 1 2; do
	[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" == '[]' ]]
done
changed=$(jq -c '.updatedAt = "2026-10-13T00:00:01Z"' <<<"$candidate")
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$changed]")" != '[]' ]]
changed=$(jq -c '.labels += ["retry"]' <<<"$candidate")
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$changed]")" != '[]' ]]
changed=$(jq -c '.labels |= reverse' <<<"$candidate")
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$changed]")" == '[]' ]]
cache=$(_dispatch_negative_cache_path 34526 example/repo)
fingerprint=$(_dispatch_checkpoint_fingerprint "$candidate")
printf '%s\t%s\t%s\t-\t%s\t\n' "$(($(date +%s) - _DISPATCH_CHECKPOINT_COOLDOWN_SECONDS))" \
	'2026-10-13T00:00:00Z' worker_draft_checkpoint_cooldown "$fingerprint" >"$cache"
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" != '[]' ]]
rm -f "$cache"
# A successful old PR-cache lookup must not mask routed-continuation safety.
_dispatch_negative_pr_fingerprint() { printf 'test-pr-fingerprint\n'; return 0; }
for signal in 'checkpoint_routed' 'CONTINUATION_ROUTED'; do
	ATTEMPT_LINES="WORKER_DRAFT_CHECKPOINT: draft PR #123 BLOCKED_CHECKPOINT_ATTENTION_EXISTS $signal"
	_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
	_dispatch_cache_confirmed_block "$candidate" 34526 example/repo
	[[ ! -f "$cache" ]]
done
ATTEMPT_LINES='WORKER_DRAFT_CHECKPOINT: draft PR #123'
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
[[ ! -f "$cache" ]]
ATTEMPT_LINES='WORKER_DRAFT_CHECKPOINT: draft PR #123 BLOCKED_CHECKPOINT_ATTENTION_EXISTS'
ATTEMPT_REASON=unclassified_signal
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
[[ ! -f "$cache" ]]
ATTEMPT_REASON=dedup_active_claim
_DISPATCH_CHECKPOINT_COOLDOWN_SECONDS=0
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
[[ ! -f "$cache" ]]
_DISPATCH_CHECKPOINT_COOLDOWN_SECONDS=1800
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
_DISPATCH_CHECKPOINT_COOLDOWN_SECONDS=0
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" != '[]' ]]
printf 'PASS draft-checkpoint cooldown: two cycles, revision/label wake, TTL, disable and negative outcomes\n'

# GH#33743: the existing capability cooldown still filters independently.
capability_candidate=$(jq -c '.number = 33743 | .labels = ["dispatch-class:gpu"]' <<<"$candidate")
_dispatch_capability_cooldown_record "$capability_candidate" 'DISPATCH_BLOCK_REASON reason=runner_capability_unmet signal=missing_secret cooldown=eligible'
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$capability_candidate]")" == '[]' ]]
changed=$(jq -c '.updatedAt = "2026-10-13T00:00:01Z"' <<<"$capability_candidate")
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$changed]")" != '[]' ]]
printf 'PASS existing runner-capability cooldown remains independent\n'

printf 'PASS dispatch-candidate-failure-reasons\n'
