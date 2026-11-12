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
# GH#36772: fleet holds are cacheable holds, never unclassified_signal.
assert_reason 'TERMINAL_BLOCKER_FLEET_HOLD task_revision=aaaaaaaaaaaaaaaaaaaaaaaa probe=falsified wake=brief_or_retry' 'terminal_blocker_circuit'
assert_reason 'TERMINAL_BLOCKER_FLEET_HOLD task_revision=aaaaaaaaaaaaaaaaaaaaaaaa wake=capability:bbbbbbbbbbbbbbbbbbbbbbbb' 'terminal_blocker_fleet_hold'
assert_reason '' 'no_recent_log_evidence'
assert_reason 'new blocker shape not yet classified' 'unclassified_signal'

# GH#34526: exercise the production classifier/cache/filter across two cycles.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT"
LOGFILE="$TEST_ROOT/pulse.log"
# shellcheck source=../pulse-dispatch-lib.sh
source "$SCRIPT_DIR/../pulse-dispatch-lib.sh"
# Keep the production fingerprint function; later sections stub the public name.
eval "_prod$(declare -f _dispatch_negative_pr_fingerprint)"
eval "_prod$(declare -f _dispatch_draft_hint_boundary)"
_dispatch_draft_hint_boundary() { printf '0:43200\n'; return 0; }
_dispatch_stats_increment() { return 0; }
_dispatch_stats_increment_candidate_failed() { return 0; }
_dispatch_mark_benign_blocked_candidate() { return 0; }
CHECKPOINT_HEAD=test-head
_dispatch_checkpoint_pr_head() {
	local repo="$1" pr="$2"
	[[ "$repo" == example/repo && "$pr" == 123 && -n "$CHECKPOINT_HEAD" ]] || return 1
	printf '%s\n' "$CHECKPOINT_HEAD"
	return 0
}
# GH#36000: exercise the real LOGFILE reader before the legacy unit stub below.
candidate='{"number":34526,"repo_slug":"example/repo","updatedAt":"2026-10-13T00:00:00Z","assignees":[],"labels":["status:available","auto-dispatch"]}'
cache=$(_dispatch_negative_cache_path 34526 example/repo)
attention_verdict=$(
	# Keep the production emitter and stub only the upstream evidence lookup.
	# shellcheck source=../pr-checkpoint-continuation-helper.sh
	source "$SCRIPT_DIR/../pr-checkpoint-continuation-helper.sh"
	_pcc_completed_release_evidence() { printf '456\tcompleted\ttrue\n'; return 0; }
	_pcc_completed_attention example/repo 34526 123 abc '[]' test-key
)
for verdict in \
	'STALLED_CHECKPOINT_CONTINUATION_SKIPPED: PR #123 in example/repo has no current stall release issue=#34526' \
	"$attention_verdict" \
	'STALLED_CHECKPOINT_CONTINUATION_SKIPPED: PR #123 in example/repo head=abc — runner bot already released it as runner_capability_unmet (release=456) issue=#34526'; do
	printf '%s\n' \
		'DISPATCH_CANDIDATE_ATTEMPT issue=#34526 repo=example/repo' \
		'WORKER_DRAFT_CHECKPOINT: draft PR #123 for issue #34526 in example/repo is a durable checkpoint' \
		"$verdict" \
		'DISPATCH_BLOCK_REASON reason=dedup_active_claim signal=test issue=#34526 repo=example/repo' >"$LOGFILE"
	[[ "$(_dispatch_candidate_recent_lines 34526 example/repo)" == *"$verdict"* ]]
	[[ -z "$(_dispatch_candidate_recent_lines 3452 example/repo)" ]]
	[[ -z "$(_dispatch_candidate_recent_lines 34526 other/repo)" ]]
	_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
	[[ "$(_dispatch_negative_cache_reason "$candidate")" == worker_draft_checkpoint_cooldown ]]
	rm -f "$cache"
	printf '%s\n' 'PR_CHECKPOINT_CONTINUATION_BLOCKED: PR #123 in example/repo launch failed rc=1 issue=#34526' >>"$LOGFILE"
	_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
	_dispatch_cache_confirmed_block "$candidate" 34526 example/repo
	[[ ! -f "$cache" ]]
done
printf 'PASS production checkpoint verdict log attribution and transient launch exclusion\n'
_dispatch_candidate_recent_lines() {
	printf '%s\nDISPATCH_BLOCK_REASON reason=%s signal=test\n' "$ATTEMPT_LINES" "$ATTEMPT_REASON"
	return 0
}
# A cooled checkpoint must never require the old expensive network PR lookup.
_dispatch_negative_pr_fingerprint() { return 1; }
candidate='{"number":34526,"repo_slug":"example/repo","updatedAt":"2026-10-13T00:00:00Z","assignees":[],"labels":["status:available","auto-dispatch"]}'
ATTEMPT_REASON=dedup_active_claim
ATTEMPT_LINES='WORKER_DRAFT_CHECKPOINT: draft PR #123 is a durable checkpoint
STALLED_CHECKPOINT_CONTINUATION_SKIPPED'
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
_dispatch_cache_confirmed_block "$candidate" 34526 example/repo
[[ "$(_dispatch_negative_cache_reason "$candidate")" == worker_draft_checkpoint_cooldown ]]
rm -f "$cache"
ATTEMPT_REASON=worker_draft_checkpoint_blocked
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
[[ "$(_dispatch_negative_cache_reason "$candidate")" == worker_draft_checkpoint_cooldown ]]
ATTEMPT_REASON=dedup_active_claim
for cycle in 1 2; do
	[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" == '[]' ]]
done
changed=$(jq -c '.updatedAt = "2026-10-13T00:00:01Z"' <<<"$candidate")
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$changed]")" != '[]' ]]
changed=$(jq -c '.labels += ["retry"]' <<<"$candidate")
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$changed]")" != '[]' ]]
changed=$(jq -c '.labels |= reverse' <<<"$candidate")
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$changed]")" == '[]' ]]
CHECKPOINT_HEAD=new-head
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" != '[]' ]]
CHECKPOINT_HEAD=''
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" != '[]' ]]
CHECKPOINT_HEAD=test-head
cache=$(_dispatch_negative_cache_path 34526 example/repo)
fingerprint=$(_dispatch_checkpoint_fingerprint "$candidate")
printf '%s\t%s\t%s\t123\t%s\ttest-head\t0:43200\n' "$(($(date +%s) - 21600))" \
	'2026-10-13T00:00:00Z' worker_draft_checkpoint_cooldown "$fingerprint" >"$cache"
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" != '[]' ]]
# Record age and issue age are independent: quiet eligibility is fixed at write time.
now=$(date +%s)
stamp=$((now - 3600))
printf '%s\t%s\t%s\t123\t%s\ttest-head\t0:43200\n' "$stamp" \
	'2026-10-13T00:00:00Z' worker_draft_checkpoint_cooldown "$fingerprint" >"$cache"
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" == '[]' ]]
assigned=$(jq -c '.assignees = [{login:"runner"}]' <<<"$candidate")
[[ "$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$assigned]")" != '[]' ]]
[[ "$(AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_COOLDOWN_SECONDS=0 _dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" != '[]' ]]
[[ "$(AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_COOLDOWN_SECONDS=invalid _dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" == '[]' ]]
[[ "$(AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_COOLDOWN_SECONDS=08 _dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" != '[]' ]]
[[ "$(AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_COOLDOWN_SECONDS=00021600 _dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" == '[]' ]]
for value in invalid 999999999999999999999999999999999999 2147483648; do
	[[ "$(_dispatch_checkpoint_decimal "$value" 14400)" == 14400 ]]
done
[[ "$(_dispatch_checkpoint_decimal 00008 14400)" == 8 ]]
[[ "$(_dispatch_checkpoint_decimal 0000 14400)" == 0 ]]
[[ "$(_dispatch_checkpoint_decimal 2147483647 14400)" == 2147483647 ]]
for age in 14399 14400; do
	revision=$(jq -nr --argjson epoch "$((stamp - age))" '$epoch | todateiso8601')
	recent=$(jq -c --arg revision "$revision" '.updatedAt = $revision' <<<"$candidate")
	printf '%s\t%s\t%s\t123\t%s\ttest-head\t0:43200\n' "$stamp" "$revision" worker_draft_checkpoint_cooldown "$fingerprint" >"$cache"
	filtered=$(_dispatch_filter_capability_cooled_candidates example/repo '' "[$recent]")
	if ((age < 14400)); then [[ "$filtered" != '[]' ]]; else [[ "$filtered" == '[]' ]]; fi
	[[ "$(AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_AFTER_SECONDS=08 _dispatch_filter_capability_cooled_candidates example/repo '' "[$recent]")" == '[]' ]]
done
# The quiet duration cap remains one day even with an oversized setting.
printf '%s\t%s\t%s\t123\t%s\ttest-head\t0:43200\n' "$((now - 86400))" \
	'2026-10-13T00:00:00Z' worker_draft_checkpoint_cooldown "$fingerprint" >"$cache"
[[ "$(AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_COOLDOWN_SECONDS=999999 _dispatch_filter_capability_cooled_candidates example/repo '' "[$candidate]")" != '[]' ]]
rm -f "$cache"
# A successful old PR-cache lookup must not mask routed-continuation safety.
PR_FINGERPRINT=test-pr-fingerprint
_dispatch_negative_pr_fingerprint() { printf '%s\n' "$PR_FINGERPRINT"; return 0; }
timeout_sec() { shift; "$@"; return $?; }
gh() { printf '%s\n' "$BOUNDARY_COMMENTS"; return 0; }
BOUNDARY_COMMENTS='[[]]'
boundary_function=$(declare -f _prod_dispatch_draft_hint_boundary)
eval "${boundary_function/_prod_dispatch_draft_hint_boundary/_dispatch_draft_hint_boundary}"
[[ "$(_dispatch_draft_hint_boundary "$candidate" example/repo 34526)" == 0:43200 ]]
now=$(date +%s)
attention_date=$(jq -nr --argjson epoch "$((now - 43100))" '$epoch | todateiso8601')
BOUNDARY_COMMENTS=$(jq -nc --arg date "$attention_date" --arg expiry "$((now + 200))" \
	'[[{body:("DISPATCH_LEASE expires_at=" + $expiry)},
	{body:"<!-- aidevops:stalled-checkpoint-attention -->",created_at:$date}]]')
[[ "$(_dispatch_draft_hint_boundary "$candidate" example/repo 34526)" == "$((now + 100)):43200" ]]
BOUNDARY_COMMENTS='invalid'
if _dispatch_draft_hint_boundary "$candidate" example/repo 34526; then exit 1; fi
BOUNDARY_COMMENTS='{"state":"open","draft":true,"updated_at":"2026-10-13T00:00:00Z","head":{"sha":"test-head"}}'
[[ "$(_dispatch_negative_pr_rest_fingerprint example/repo 123)" == 2026-10-13T00:00:00Z_test-head ]]
BOUNDARY_COMMENTS=$(jq -c '.draft = false' <<<"$BOUNDARY_COMMENTS")
if _dispatch_negative_pr_rest_fingerprint example/repo 123; then exit 1; fi
BOUNDARY_COMMENTS='[[]]'
# An eligible refusal is not a write receipt: head lookup failure (or a disabled
# cooldown) must fall through to the older boundary-aware draft record.
ATTEMPT_LINES='WORKER_DRAFT_CHECKPOINT: draft PR #123 STALLED_CHECKPOINT_CONTINUATION_SKIPPED'
ATTEMPT_REASON=worker_draft_checkpoint_blocked
for unavailable in head disabled; do
	CHECKPOINT_HEAD=test-head
	_DISPATCH_CHECKPOINT_COOLDOWN_SECONDS=1800
	if [[ "$unavailable" == head ]]; then CHECKPOINT_HEAD=''; else _DISPATCH_CHECKPOINT_COOLDOWN_SECONDS=0; fi
	_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
	[[ "$_DISPATCH_CHECKPOINT_COOLDOWN_RECORDED" == 0 ]]
	_dispatch_cache_confirmed_block "$candidate" 34526 example/repo
	[[ "$(_dispatch_negative_cache_reason "$candidate")" == worker_draft_checkpoint_blocked ]]
	rm -f "$cache"
done
CHECKPOINT_HEAD=test-head
_DISPATCH_CHECKPOINT_COOLDOWN_SECONDS=1800
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
[[ "$_DISPATCH_CHECKPOINT_COOLDOWN_RECORDED" == 1 ]]
if _dispatch_negative_cache_reason "$assigned"; then exit 1; fi
if AIDEVOPS_PCC_ATTENTION_REARM_SECONDS=60 _dispatch_negative_cache_reason "$candidate"; then exit 1; fi
printf '%s\t%s\t%s\t123\t%s\ttest-head\t%s:43200\n' "$now" \
	'2026-10-13T00:00:00Z' worker_draft_checkpoint_cooldown "$fingerprint" "$now" >"$cache"
if _dispatch_negative_cache_reason "$candidate"; then exit 1; fi
rm -f "$cache"
_DISPATCH_CHECKPOINT_COOLDOWN_RECORDED=0
printf 'PASS cooldown write failure falls back; owner and re-arm boundaries wake cooldowns\n'
for draft_reason in worker_draft_checkpoint_blocked stale_draft_checkpoint; do
	ATTEMPT_LINES="WORKER_DRAFT_CHECKPOINT: draft PR #123 DISPATCH_BLOCK_REASON reason=$draft_reason"
	_dispatch_cache_confirmed_block "$candidate" 34526 example/repo
	[[ "$(_dispatch_negative_cache_reason "$candidate")" == "$draft_reason" ]]
	# Unchanged hints survive the old 30-minute TTL across repeated cycles.
	printf '%s\t%s\t%s\t123\t%s\t%s:43200\n' "$((now - 3600))" \
		'2026-10-13T00:00:00Z' "$draft_reason" "$PR_FINGERPRINT" "$((now + 100))" >"$cache"
	for cycle in 1 2; do
		[[ "$(_dispatch_negative_cache_reason "$candidate")" == "$draft_reason" ]]
		_dispatch_max_prefilter_cached_block "$candidate" "$TEST_ROOT/outcomes"
	done
	grep -q "cross-cycle block:$draft_reason" "$LOGFILE"
	grep -q 'eligibility=ineligible' "$TEST_ROOT/outcomes"
	assigned=$(jq -c '.assignees = [{login:"runner"}]' <<<"$candidate")
	if _dispatch_negative_cache_reason "$assigned"; then exit 1; fi
	changed=$(jq -c '.updatedAt = "2026-10-13T00:00:01Z"' <<<"$candidate")
	if _dispatch_negative_cache_reason "$changed"; then exit 1; fi
	PR_FINGERPRINT=new-head
	if _dispatch_negative_cache_reason "$candidate"; then exit 1; fi
	PR_FINGERPRINT=test-pr-fingerprint
	if AIDEVOPS_PCC_ATTENTION_REARM_SECONDS=60 _dispatch_negative_cache_reason "$candidate"; then exit 1; fi
	# Crossing the recorded boundary wakes even with the same PR and issue.
	printf '%s\t%s\t%s\t123\t%s\t%s:43200\n' "$now" \
		'2026-10-13T00:00:00Z' "$draft_reason" "$PR_FINGERPRINT" "$now" >"$cache"
	if _dispatch_negative_cache_reason "$candidate"; then exit 1; fi
	printf '%s\t%s\t%s\t123\t%s\t0:43200\n' "$((now - 21600))" \
		'2026-10-13T00:00:00Z' "$draft_reason" "$PR_FINGERPRINT" >"$cache"
	if AIDEVOPS_DISPATCH_CHECKPOINT_QUIET_COOLDOWN_SECONDS=999999 _dispatch_negative_cache_reason "$candidate"; then exit 1; fi
	rm -f "$cache"
done
printf 'PASS draft hints: stale recording, extended ceiling, revision/head/config wake and age boundary\n'
for signal in 'checkpoint_routed' 'CONTINUATION_ROUTED'; do
	ATTEMPT_LINES="WORKER_DRAFT_CHECKPOINT: draft PR #123 BLOCKED_CHECKPOINT_ATTENTION_EXISTS $signal"
	_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
	_dispatch_cache_confirmed_block "$candidate" 34526 example/repo
	[[ ! -f "$cache" ]]
done
# Transient launch failures may retain the existing PR-fingerprinted block,
# but must never become a quiet checkpoint cooldown (GH#36000).
ATTEMPT_LINES='WORKER_DRAFT_CHECKPOINT: draft PR #123 BLOCKED_CHECKPOINT_ATTENTION_EXISTS PR_CHECKPOINT_CONTINUATION_BLOCKED: launch failed rc=1'
_dispatch_record_nonzero_dispatch_result 34526 example/repo 1 "$candidate"
_dispatch_cache_confirmed_block "$candidate" 34526 example/repo
[[ "$(_dispatch_negative_cache_reason "$candidate")" == worker_draft_checkpoint_blocked ]]
rm -f "$cache"
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

# Production snapshots omit isDraft: fall back to the exact-PR REST fingerprint.
(
	STUB_DIR="$TEST_ROOT/prefetch-stub"
	mkdir -p "$STUB_DIR"
	# shellcheck disable=SC2016  # expanded by the generated stub, not here
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$SNAPSHOT_JSON"\nexit 0\n' >"$STUB_DIR/pulse-batch-prefetch-helper.sh"
	chmod +x "$STUB_DIR/pulse-batch-prefetch-helper.sh"
	_PULSE_DISPATCH_LIB_DIR="$STUB_DIR"
	timeout_sec() { shift; "$@"; return $?; }
	gh() { printf '%s\n' "$REST_JSON"; return 0; }
	fresh=$(jq -nr 'now | todateiso8601')
	SNAPSHOT_JSON=$(jq -nc --arg ts "$fresh" '{complete:true,timestamp:$ts,items:[{number:123,updatedAt:"2026-10-13T00:00:00Z",headRefOid:"snap-head"}]}')
	export SNAPSHOT_JSON
	REST_JSON='{"state":"open","draft":true,"updated_at":"2026-10-13T00:00:00Z","head":{"sha":"rest-head"}}'
	[[ "$(_prod_dispatch_negative_pr_fingerprint example/repo 123)" == 2026-10-13T00:00:00Z_rest-head ]]
	# A changed REST fingerprint yields a different hint, so the cached one is rejected.
	REST_JSON='{"state":"open","draft":true,"updated_at":"2026-10-13T00:00:01Z","head":{"sha":"new-head"}}'
	[[ "$(_prod_dispatch_negative_pr_fingerprint example/repo 123)" == 2026-10-13T00:00:01Z_new-head ]]
	# A ready PR is rejected.
	REST_JSON='{"state":"open","draft":false,"updated_at":"2026-10-13T00:00:00Z","head":{"sha":"rest-head"}}'
	if _prod_dispatch_negative_pr_fingerprint example/repo 123; then exit 1; fi
) || exit 1
printf 'PASS missing-isDraft snapshot falls back to REST fingerprint\n'

# GH#37780: an empty local pool rechecks only claims this runner could own.
(
	claimed=$(jq -c '.labels = ["status:in-progress"]' <<<"$candidate")
	foreign=$(jq -c '.assignees = [{login:"Other-Runner"}]' <<<"$claimed")
	printf '%s\t%s\t%s\t\t\t\t\n' "$(date +%s)" '2026-10-13T00:00:00Z' dedup_active_claim >"$cache"
	_DISPATCH_ACTIVE_WORKERS=0
	_DISPATCH_SELF_LOGIN='self-runner'
	[[ "$(_dispatch_negative_cache_reason "$foreign")" == dedup_active_claim ]]
	for owners in '[{"login":"Self-Runner"}]' '[{"login":"other-runner"},{"login":"self-runner"}]' '[]'; do
		owned=$(jq -c --argjson owners "$owners" '.assignees = $owners' <<<"$claimed")
		if _dispatch_negative_cache_reason "$owned"; then exit 1; fi
	done
	for self in '' 'bad login'; do
		_DISPATCH_SELF_LOGIN="$self"
		if _dispatch_negative_cache_reason "$foreign"; then exit 1; fi
	done
	_DISPATCH_ACTIVE_WORKERS=2
	[[ "$(_dispatch_negative_cache_reason "$foreign")" == dedup_active_claim ]]
	rm -f "$cache"
) || exit 1
printf 'PASS empty-pool active-claim hints: foreign owners cached, own/mixed/unknown rechecked\n'

printf 'PASS dispatch-candidate-failure-reasons\n'
