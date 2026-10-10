#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-full-loop-release-reconcile.sh; shares its fixtures and state.

# Direct execution must initialize the shared fixtures and preceding fragments.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	exec bash "$(dirname "${BASH_SOURCE[0]}")/test-full-loop-release-reconcile.sh" "$@"
fi

_full_loop_resolve_repo() {
	local requested_repo="$1"
	printf '%s\n' "${requested_repo:-test/repo}"
	return 0
}
_full_loop_release_receipt_path() {
	local repo="$1"
	local pr_number="$2"
	printf '%s/%s-%s.status\n' "${TEST_ROOT}/receipts" "${repo//\//_}" "$pr_number"
	return 0
}
_full_loop_release_find_tag_for_pr() {
	local repo="$1"
	local pr_number="$2"
	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	_FULL_LOOP_RELEASE_FOUND_TAG=v1.2.3
	return 0
}
_full_loop_release_latest_tag() {
	printf 'v1.2.3\n'
	return 0
}
_full_loop_release_inspect_remote() {
	local repo="$1"
	local tag_name="$2"
	[[ -n "$repo" && -n "$tag_name" ]] || return 1
	return "${INSPECT_RC:-3}"
}
_full_loop_release_dispatch_recovery() {
	local repo="$1"
	local tag_name="$2"
	printf '%s %s\n' "$repo" "$tag_name" >"${TEST_ROOT}/dispatch.log"
	return 8
}
_full_loop_release_finalize_reconciliation() {
	local repo="$1"
	local pr_number="$2"
	local tag_name="$3"
	printf '%s %s %s\n' "$repo" "$pr_number" "$tag_name" >"${TEST_ROOT}/finalize.log"
	return 0
}
_version_manager_reconcile_protected_release_tag() {
	local repo="$1"
	local tag_name="$2"
	local mode="$3"
	[[ -n "$repo" && -n "$tag_name" && ("$mode" == "status" || "$mode" == "reconcile") ]] || return 1
	case "${PROTECTED_FIXTURE_MODE:-remote}" in
	open) _VERSION_MANAGER_PROTECTED_RELEASE_RESULT="pr-pending" ;;
	merged)
		if [[ "$mode" == "status" ]]; then
			_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="tag-ready"
		else
			_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="tag-pushed"
		fi
		;;
	mismatch) return 1 ;;
	remote) _VERSION_MANAGER_PROTECTED_RELEASE_RESULT="remote-tag-present" ;;
	*) return 1 ;;
	esac
	return 0
}
_full_loop_release_verify_protected_source_provenance() {
	[[ "$1" == "test/repo" && "$2" == "v1.2.3" ]]
	return $?
}
_full_loop_release_claim_preserved_tag() {
	[[ "$1" == "test/repo" && "$2" == "90" && "$3" == "v1.2.3" ]] || return 1
	[[ "${CLAIM_FIXTURE_RC:-0}" -eq 0 ]] || return "$CLAIM_FIXTURE_RC"
	printf 'claimed\n' >>"${TEST_ROOT}/existing-pr-claim.log"
	lane_patch_json='{"phase":"remote-publication","tag":"v1.2.3","reservation_contract":"fenced-prepublication/v1","snapshot_manifest_bound":true}'
	return 0
}
_full_loop_release_record_stale_deployment() {
	[[ "$1" == "test/repo" && "$2" == "90" && "$3" == "v1.2.3" ]] || return 1
	printf '%s %s %s\n' "$1" "$2" "$3" >>"${TEST_ROOT}/stale-deployment.log"
}
(
	export HOME="${TEST_ROOT}/deployed-home"
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/deployed-receipts"
	git() { /usr/bin/git "$@"; }
	# shellcheck source=../full-loop-helper-state.sh
	source "${SCRIPT_DIR}/full-loop-helper-state.sh"
	_FULL_LOOP_RELEASE_RECONCILE_LOADED=""
	# shellcheck source=../full-loop-release-reconcile.sh
	source "${SCRIPT_DIR}/full-loop-release-reconcile.sh"
	fixture_scripts="${TEST_ROOT}/deployed-scripts"
	fixture_repo="${TEST_ROOT}/deployed-repo"
	mkdir -p "$fixture_scripts" "$fixture_repo" "$HOME/.aidevops/agents"
	git -C "$fixture_repo" init -q
	git -C "$fixture_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m release
	fixture_tag_commit=$(git -C "$fixture_repo" rev-parse HEAD)
	git -C "$fixture_repo" tag v1.2.3
	git -C "$fixture_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m runtime
	fixture_active_sha=$(git -C "$fixture_repo" rev-parse HEAD)
	REPO_ROOT="$fixture_repo"
	SCRIPT_DIR="$fixture_scripts"
	# Literal fixture functions must expand HOME and the SHA when sourced, not here.
	# shellcheck disable=SC2016
	printf '%s\n' '_runtime_bundle_verify_active_link() { _AIDEVOPS_RUNTIME_VERIFY_ACTIVE_ROOT="$HOME/.aidevops/agents"; }' \
		'_runtime_bundle_verify_manifest_value() { printf "%s\\n" "$FIXTURE_ACTIVE_SHA"; }' \
		>"${fixture_scripts}/runtime-bundle-verifier.sh"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${fixture_scripts}/version-manager.sh"
	FIXTURE_ACTIVE_SHA="$fixture_active_sha"
	_full_loop_release_resolve_tag_commit() { printf '%s\n' "$fixture_tag_commit"; }
	_full_loop_release_prepare_tag_worktree() { _FULL_LOOP_RELEASE_PATH="$fixture_repo"; }
	fixture_evidence=$(_full_loop_release_evidence_path test/repo 90 successor)
	mkdir -p "${fixture_evidence%/*}"
	jq -cn --arg source_commit "$fixture_tag_commit" --arg active "$fixture_active_sha" '
		{schema_version:1,evidence_type:"post-publication-supersession",status:"superseded",
		repository:"test/repo",pr_number:90,source_pr:90,
		source_merge:$source_commit,source_release_tag:"v1.2.3",source_release_commit:$source_commit,
		source_workflow_run:10,successor_pr:91,successor_merge:$active,
		release_tag:"v1.2.4",release_commit:$active,release_workflow_run:11,
		recorded_at:"2026-09-27T00:00:00Z"}' >"$fixture_evidence"
	_full_loop_release_record_stale_deployment test/repo 90 v1.2.3 || {
		printf 'FAIL converged superseded release did not record deployment proof\n' >&2
		exit 1
	}
	jq -e --arg sha "$fixture_active_sha" '
		.deployment.status == "deployed" and .deployment.active_sha == $sha
		and .deployment.tag == "v1.2.3"' "$fixture_evidence" >/dev/null
	git -C "$fixture_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m later
	_full_loop_release_record_stale_deployment test/repo 90 v1.2.3 || {
		printf 'FAIL deployed supersession replay rejected a later runtime\n' >&2
		exit 1
	}
	jq -e --arg sha "$fixture_active_sha" '.deployment.active_sha == $sha' "$fixture_evidence" >/dev/null
)
printf 'PASS supersession preserves verified deployed bundle SHA across later main movement\n'

_full_loop_release_finalize_stale_supersession() {
	local repo="$1"
	local pr_number="$2"
	local source_tag="$3"
	local release_tag="$4"
	printf '%s %s %s %s\n' "$repo" "$pr_number" "$source_tag" "$release_tag" \
		>"${TEST_ROOT}/stale-finalize.log"
	return "${STALE_FINALIZE_RC:-0}"
}
_full_loop_verify_superseded_release_receipt() {
	local repo="$1"
	local pr_number="$2"
	[[ "$repo" == "test/repo" && "$pr_number" == "90" ]]
	return $?
}
_full_loop_update_superseded_cleanup_receipt() {
	local repo="$1"
	local pr_number="$2"
	printf '%s %s\n' "$repo" "$pr_number" >"${TEST_ROOT}/cleanup-update.log"
	return 0
}

printf 'not-requested\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
lane_patch_json='{"phase":"preparing","tag":null,"reservation_contract":"fenced-prepublication/v1","snapshot_manifest_bound":true}'
PROTECTED_FIXTURE_MODE=open
export PROTECTED_FIXTURE_MODE
authorization_expected_sources='91@2222222222222222222222222222222222222222'
protected_intent_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || protected_intent_rc=$?
if [[ "$protected_intent_rc" -ne 1 || -e "${TEST_ROOT}/existing-pr-claim.log" ]] ||
	[[ "$(jq -r '.phase' <<<"$lane_patch_json")" != "preparing" ]]; then
	printf 'FAIL mismatched explicit intent mutated the dead preparing lane\n'
	exit 1
fi
printf 'PASS explicit intent is verified before the dead preparing lane is claimed\n'
authorization_expected_sources=''
protected_open_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>"${TEST_ROOT}/protected-open.err" || protected_open_rc=$?
if [[ "$protected_open_rc" -ne 8 ]] ||
	[[ "$(grep -c '^claimed$' "${TEST_ROOT}/existing-pr-claim.log")" -ne 1 ]] ||
	[[ "$(jq -r '.phase' <<<"$lane_patch_json")" != "remote-publication" ]]; then
	printf 'FAIL exact open protected PR did not claim and resume the dead preparing lane (rc=%s claim=%s lane=%s)\n' \
		"$protected_open_rc" "$(test -f "${TEST_ROOT}/existing-pr-claim.log" && grep -c '^claimed$' "${TEST_ROOT}/existing-pr-claim.log" || true)" \
		"$lane_patch_json stderr=$(<"${TEST_ROOT}/protected-open.err")"
	exit 1
fi
printf 'PASS exact open protected PR claims the lane and remains queued\n'

rm -f "${TEST_ROOT}/existing-pr-claim.log" "${TEST_ROOT}/finalize.log"
lane_patch_json='{"phase":"preparing","tag":null,"reservation_contract":"fenced-prepublication/v1","snapshot_manifest_bound":true}'
PROTECTED_FIXTURE_MODE=merged
protected_merged_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || protected_merged_rc=$?
if [[ "$protected_merged_rc" -ne 8 ]] ||
	! grep -qx claimed "${TEST_ROOT}/existing-pr-claim.log"; then
	printf 'FAIL exact merged protected PR did not resume its preserved tag\n'
	exit 1
fi
PROTECTED_FIXTURE_MODE=remote
INSPECT_RC=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if ! grep -qx 'test/repo 90 v1.2.3' "${TEST_ROOT}/finalize.log"; then
	printf 'FAIL merged protected PR recovery did not reach terminal reconciliation\n'
	exit 1
fi
printf 'PASS exact merged protected PR resumes and reaches terminal reconciliation\n'

rm -f "${TEST_ROOT}/existing-pr-claim.log" "${TEST_ROOT}/finalize.log"
lane_patch_json='{"phase":"preparing","tag":null,"reservation_contract":"fenced-prepublication/v1","snapshot_manifest_bound":true}'
PROTECTED_FIXTURE_MODE=mismatch
protected_mismatch_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || protected_mismatch_rc=$?
if [[ "$protected_mismatch_rc" -ne 1 || -e "${TEST_ROOT}/existing-pr-claim.log" ]] ||
	[[ "$(jq -r '.phase' <<<"$lane_patch_json")" != "preparing" ]]; then
	printf 'FAIL mismatched protected PR mutated the dead preparing lane\n'
	exit 1
fi
printf 'PASS protected PR mismatch leaves the dead preparing lane unchanged\n'

rm -f "${TEST_ROOT}/receipts/test_repo-90.status"
lane_patch_json='{}'
PROTECTED_FIXTURE_MODE=remote
INSPECT_RC=3

reconcile_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || reconcile_rc=$?
if [[ "$reconcile_rc" -ne 8 ]] ||
	! grep -qx 'test/repo v1.2.3' "${TEST_ROOT}/dispatch.log"; then
	printf 'FAIL absent publication did not queue idempotent recovery\n'
	exit 1
fi
printf 'PASS absent publication queues idempotent recovery\n'

INSPECT_RC=1
rm -f "${TEST_ROOT}/dispatch.log"
uncertain_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || uncertain_rc=$?
if [[ "$uncertain_rc" -ne 1 || -e "${TEST_ROOT}/dispatch.log" ]]; then
	printf 'FAIL remote-state uncertainty allowed a recovery dispatch\n'
	exit 1
fi
printf 'PASS remote-state uncertainty blocks recovery dispatch\n'

INSPECT_RC=8
rm -f "${TEST_ROOT}/dispatch.log"
pending_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || pending_rc=$?
if [[ "$pending_rc" -ne 8 || -e "${TEST_ROOT}/dispatch.log" ]]; then
	printf 'FAIL pending publication was redundantly redispatched\n'
	exit 1
fi
printf 'PASS pending publication is not redundantly redispatched\n'

INSPECT_RC=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if ! grep -qx 'test/repo 90 v1.2.3' "${TEST_ROOT}/finalize.log"; then
	printf 'FAIL completed publication did not finalize durable release state\n'
	exit 1
fi
printf 'PASS completed publication finalizes durable release state\n'

printf 'published\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
rm -f "${TEST_ROOT}/finalize.log"
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if [[ -e "${TEST_ROOT}/finalize.log" ]]; then
	printf 'FAIL terminal published receipt was finalized twice\n'
	exit 1
fi
printf 'PASS published reconciliation is idempotent\n'

printf 'not-requested\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
lane_expected_sources='91'
terminal_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || terminal_rc=$?
if [[ "$terminal_rc" -ne 1 ]]; then
	printf 'FAIL reconciliation inferred fresh publication intent from not-requested evidence\n'
	exit 1
fi
printf 'PASS reconciliation cannot replace the explicit release command as publication intent\n'
lane_expected_sources='90@1111111111111111111111111111111111111111'
rm -f "${TEST_ROOT}/finalize.log"
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if ! grep -qx 'test/repo 90 v1.2.3' "${TEST_ROOT}/finalize.log"; then
	printf 'FAIL matching explicit publication intent did not transition not-requested evidence\n'
	exit 1
fi
printf 'PASS matching explicit publication intent may transition not-requested evidence\n'
rm -f "${TEST_ROOT}/receipts/test_repo-90.status" "${TEST_ROOT}/finalize.log"

_full_loop_release_latest_tag() {
	printf 'v1.2.4\n'
	return 0
}
printf 'failed\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
stale_status_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command status 90 \
	>/dev/null 2>&1 || stale_status_rc=$?
if [[ "$stale_status_rc" -ne 1 || -e "${TEST_ROOT}/stale-finalize.log" ]]; then
	printf 'FAIL read-only stale release status mutated terminal evidence\n'
	exit 1
fi
stale_reconcile_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || stale_reconcile_rc=$?
if [[ "$stale_reconcile_rc" -ne 0 ]] ||
	! grep -qx 'test/repo 90 v1.2.3 v1.2.4' "${TEST_ROOT}/stale-finalize.log" ||
	! grep -qx 'test/repo 90 v1.2.3' "${TEST_ROOT}/stale-deployment.log" ||
	[[ -e "${TEST_ROOT}/dispatch.log" || -e "${TEST_ROOT}/finalize.log" ]]; then
	printf 'FAIL stale release receipt did not use the no-publication supersession path\n'
	exit 1
fi

rm -f "${TEST_ROOT}/stale-finalize.log"
STALE_FINALIZE_RC=1
export STALE_FINALIZE_RC
stale_uncertain_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || stale_uncertain_rc=$?
if [[ "$stale_uncertain_rc" -ne 1 ]] || ! grep -qx 'failed' "${TEST_ROOT}/receipts/test_repo-90.status"; then
	printf 'FAIL uncertain stale supersession replaced the failed receipt\n'
	exit 1
fi
unset STALE_FINALIZE_RC

printf 'superseded\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
rm -f "${TEST_ROOT}/stale-finalize.log" "${TEST_ROOT}/cleanup-update.log"
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command status 90 >/dev/null
if [[ -e "${TEST_ROOT}/cleanup-update.log" ]]; then
	printf 'FAIL read-only terminal stale status updated cleanup evidence\n'
	exit 1
fi
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if [[ -e "${TEST_ROOT}/stale-finalize.log" ]] ||
	! grep -qx 'test/repo 90' "${TEST_ROOT}/cleanup-update.log"; then
	printf 'FAIL terminal stale supersession evidence was finalized twice\n'
	exit 1
fi
printf 'PASS stale release tags cannot downgrade channels and reconcile only through verified supersession\n'

# Deferred postflight: status stays read-only; reconcile queues only the exact tag.
_full_loop_release_latest_tag() {
	printf 'v1.2.3\n'
	return 0
}
_full_loop_release_dispatch_postflight() {
	[[ "$1" == "test/repo" && "$2" == "v1.2.3" ]] || return 1
	printf '%s %s\n' "$1" "$2" >"${TEST_ROOT}/postflight-dispatch.log"
	return 8
}
rm -f "${TEST_ROOT}/receipts/test_repo-90.status" "${TEST_ROOT}/dispatch.log" \
	"${TEST_ROOT}/finalize.log" "${TEST_ROOT}/postflight-dispatch.log"
INSPECT_RC=6
postflight_status_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command status 90 \
	>/dev/null 2>&1 || postflight_status_rc=$?
postflight_reconcile_rc=0
if [[ "$postflight_status_rc" -ne 8 || -e "${TEST_ROOT}/postflight-dispatch.log" ]]; then
	printf 'FAIL status dispatched or misreported absent postflight\n'
	exit 1
fi
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || postflight_reconcile_rc=$?
if [[ "$postflight_reconcile_rc" -ne 8 ]] ||
	! grep -qx 'test/repo v1.2.3' "${TEST_ROOT}/postflight-dispatch.log" ||
	[[ -e "${TEST_ROOT}/dispatch.log" || -e "${TEST_ROOT}/finalize.log" ]]; then
	printf 'FAIL reconcile did not queue only exact-tag postflight without publication or receipt\n'
	exit 1
fi
rm -f "${TEST_ROOT}/postflight-dispatch.log"
INSPECT_RC=9
postflight_failed_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || postflight_failed_rc=$?
if [[ "$postflight_failed_rc" -ne 1 || -e "${TEST_ROOT}/finalize.log" || -e "${TEST_ROOT}/postflight-dispatch.log" ]]; then
	printf 'FAIL failed postflight became success or was redispatched\n'
	exit 1
fi
unset INSPECT_RC
printf 'PASS deferred postflight is queued by reconcile only and failed postflight never finalizes\n'
