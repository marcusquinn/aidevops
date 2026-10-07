#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-full-loop-release-reconcile.sh; shares its fixtures and state.

# Direct execution must initialize the shared fixtures and preceding fragments.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	exec bash "$(dirname "${BASH_SOURCE[0]}")/test-full-loop-release-reconcile.sh" "$@"
fi

mkdir -p "${TEST_ROOT}/worktrees" "${TEST_ROOT}/tag-checkout" \
	"${TEST_ROOT}/runtime" "${TEST_ROOT}/tag-checkout/.agents/scripts"
export AIDEVOPS_WORKTREE_BASE_DIR="${TEST_ROOT}/worktrees"
PREPARE_GIT_LOG="${TEST_ROOT}/prepare-git.log"
export PREPARE_GIT_LOG
_FULL_LOOP_RELEASE_PATH="${TEST_ROOT}/tag-checkout"
git() {
	local args="$*"
	case "$args" in
	*" rev-parse refs/tags/v1.2.3^{commit}" | *" rev-parse HEAD")
		printf '%s\n' '3333333333333333333333333333333333333333'
		return 0
		;;
	*" worktree add "*)
		printf '%s\n' "$args" >>"$PREPARE_GIT_LOG"
		return 1
		;;
	esac
	return 1
}
if ! _full_loop_release_prepare_tag_worktree v1.2.3 || [[ -e "$PREPARE_GIT_LOG" ]]; then
	printf 'FAIL exact detached tag checkout was not reused safely\n'
	exit 1
fi
unset -f git
printf 'PASS exact detached tag checkout is reused across discovery and finalization\n'

FAKE_VERIFY_LOG="${TEST_ROOT}/verify.log"
FAKE_POST_RELEASE_LOG="${TEST_ROOT}/post-release.log"
FAKE_PERSIST_LOG="${TEST_ROOT}/persist.log"
FAKE_OLD_RUNTIME_LOG="${TEST_ROOT}/old-runtime.log"
export FAKE_VERIFY_LOG FAKE_POST_RELEASE_LOG FAKE_PERSIST_LOG FAKE_OLD_RUNTIME_LOG
cat >"${TEST_ROOT}/runtime/release-provenance-helper.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'cwd=%s\nargs=%s\n' "$PWD" "$*" >>"${FAKE_VERIFY_LOG:?}"
STUB
cat >"${TEST_ROOT}/runtime/version-manager.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'cwd=%s\naction=%s\nsync_root=%s\ndeploy_helper=%s\nsquash_recovery=%s\nlane_pr=%s\nlane_tag=%s\n' \
	"$PWD" "$*" "${AIDEVOPS_SYNC_REPO_ROOT:-}" \
	"${AIDEVOPS_SYNC_DEPLOY_SCRIPT:-}" "${AIDEVOPS_RELEASE_SQUASH_RECOVERY:-}" \
	"${AIDEVOPS_RELEASE_LANE_SOURCE_PR:-}" "${AIDEVOPS_RELEASE_LANE_TAG:-}" \
	>"${FAKE_POST_RELEASE_LOG:?}"
STUB
cat >"${TEST_ROOT}/tag-checkout/.agents/scripts/version-manager.sh" <<'STUB'
#!/usr/bin/env bash
printf 'obsolete tag runtime invoked\n' >"${FAKE_OLD_RUNTIME_LOG:?}"
exit 1
STUB
printf '#!/usr/bin/env bash\nexit 0\n' \
	>"${TEST_ROOT}/runtime/deploy-agents-on-merge.sh"
chmod +x "${TEST_ROOT}/runtime/release-provenance-helper.sh" \
	"${TEST_ROOT}/runtime/version-manager.sh" \
	"${TEST_ROOT}/runtime/deploy-agents-on-merge.sh" \
	"${TEST_ROOT}/tag-checkout/.agents/scripts/version-manager.sh"

saved_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="${TEST_ROOT}/runtime"
: >"$FAKE_VERIFY_LOG"
_full_loop_release_prepare_tag_worktree() {
	local tag_name="$1"
	[[ "$tag_name" == "v1.2.3" ]] || return 1
	_FULL_LOOP_RELEASE_PATH="${TEST_ROOT}/tag-checkout"
	return 0
}
if ! _full_loop_release_verify_tag_provenance test/repo v1.2.3 ||
	! _full_loop_release_verify_protected_source_provenance test/repo v1.2.3 ||
	! grep -qx "cwd=${TEST_ROOT}/tag-checkout" "$FAKE_VERIFY_LOG" ||
	! grep -qx 'args=verify --tag v1.2.3 --repo test/repo' "$FAKE_VERIFY_LOG" ||
	! grep -qx 'args=verify-local-source --tag v1.2.3 --repo test/repo' "$FAKE_VERIFY_LOG"; then
	printf 'FAIL release provenance was not verified from the detached tag checkout\n'
	exit 1
fi
printf 'PASS remote and protected-source provenance verification run from the detached tag checkout\n'

_full_loop_validate_release_candidates() {
	local repo="$1"
	local source_json="$2"
	local mode="$3"
	local tag_name="$4"
	local tag_commit="$5"
	[[ -n "$repo" && -n "$source_json" && "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]] || return 1
	[[ "$tag_name" == "v1.2.3" && "$tag_commit" == "3333333333333333333333333333333333333333" ]]
	return $?
}
_full_loop_read_release_authorization() {
	local repo="$1"
	local requested_pr="$2"
	[[ "$repo" == "test/repo" && "$requested_pr" == "90" ]] || return 1
	printf '%s\n' "${authorization_expected_sources:-90@1111111111111111111111111111111111111111}"
	return 0
}
lane_expected_sources='90@1111111111111111111111111111111111111111'
lane_patch_json='{}'
release_lane_read() {
	local repo="$1"
	[[ "$repo" == "test/repo" ]] || return 1
	_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg expected "$lane_expected_sources" --argjson patch "$lane_patch_json" \
		'{active:true,source_pr:90,expected_sources:$expected,phase:"remote-publication",tag:"v1.2.3",terminal_receipt:null} + $patch') || return 1
	return 0
}
_full_loop_release_resolve_tag_commit() {
	local tag_name="$1"
	[[ "$tag_name" == "v1.2.3" ]] || return 1
	printf '%s\n' '3333333333333333333333333333333333333333'
	return 0
}
_full_loop_persist_release_success() {
	local repo="$1"
	local release_path="$2"
	local source_json="$3"
	local source_pr="$4"
	local source_merge="$5"
	local mode="$6"
	[[ "$mode" == "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" ]] || return 1
	printf '%s|%s|%s|%s|%s|%s\n' \
		"$repo" "$release_path" "$source_json" "$source_pr" "$source_merge" "$mode" \
		>"$FAKE_PERSIST_LOG"
	return 0
}
if ! _full_loop_release_finalize_reconciliation test/repo 90 v1.2.3 ||
	! grep -qx "cwd=${TEST_ROOT}/tag-checkout" "$FAKE_POST_RELEASE_LOG" ||
	! grep -qx 'action=post-release' "$FAKE_POST_RELEASE_LOG" ||
	! grep -qx "sync_root=${TEST_ROOT}/tag-checkout" "$FAKE_POST_RELEASE_LOG" ||
	! grep -qx "deploy_helper=${TEST_ROOT}/runtime/deploy-agents-on-merge.sh" \
		"$FAKE_POST_RELEASE_LOG" ||
	! grep -qx 'squash_recovery=1' "$FAKE_POST_RELEASE_LOG" ||
	! grep -qx 'lane_pr=90' "$FAKE_POST_RELEASE_LOG" ||
	! grep -qx 'lane_tag=v1.2.3' "$FAKE_POST_RELEASE_LOG" ||
	[[ -e "$FAKE_OLD_RUNTIME_LOG" || ! -s "$FAKE_PERSIST_LOG" ]]; then
	printf 'FAIL reconciliation did not finalize with current hardened runtime against the tag checkout\n'
	exit 1
fi
lane_expected_sources='90'
if ! _full_loop_release_finalize_reconciliation test/repo 90 v1.2.3; then
	printf 'FAIL published reconciliation rejected equivalent legacy PR-only lane intent\n'
	exit 1
fi
lane_state_before="$_AIDEVOPS_RELEASE_LANE_JSON"
if ! _full_loop_release_validate_published_reconciliation_intent test/repo 90 v1.2.3 \
	'{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}' ||
	[[ "$_AIDEVOPS_RELEASE_LANE_JSON" != "$lane_state_before" ]]; then
	printf 'FAIL published validation mutated equivalent legacy lane intent\n'
	exit 1
fi
lane_patch_json='{"phase":"reconcile-required","stale_runtime_recovery":{"type":"stale-runtime/v1","attempt_head":"2222222222222222222222222222222222222222","failed_phase":"exact-tag-deployment","deferred_at":"2026-09-20T20:58:52Z"}}'
if ! _full_loop_release_validate_published_reconciliation_intent test/repo 90 v1.2.3 \
	'{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'; then
	printf 'FAIL published reconciliation rejected a validated stale-runtime deferral\n'
	exit 1
fi
for lane_patch_json in \
	'{"phase":"reconcile-required"}' \
	'{"phase":"reconcile-required","stale_runtime_recovery":{}}' \
	'{"phase":"reconcile-required","stale_runtime_recovery":{"type":"other","attempt_head":"2222222222222222222222222222222222222222","failed_phase":"exact-tag-deployment","deferred_at":"2026-09-20T20:58:52Z"}}' \
	'{"phase":"reconcile-required","stale_runtime_recovery":{"type":"stale-runtime/v1","attempt_head":"invalid","failed_phase":"exact-tag-deployment","deferred_at":"2026-09-20T20:58:52Z"}}' \
	'{"phase":"reconcile-required","stale_runtime_recovery":{"type":"stale-runtime/v1","attempt_head":"2222222222222222222222222222222222222222","failed_phase":"remote-publication","deferred_at":"2026-09-20T20:58:52Z"}}' \
	'{"phase":"reconcile-required","stale_runtime_recovery":{"type":"stale-runtime/v1","attempt_head":"2222222222222222222222222222222222222222","failed_phase":"exact-tag-deployment","deferred_at":"not-a-timestamp"}}'; do
	if _full_loop_release_validate_published_reconciliation_intent test/repo 90 v1.2.3 \
		'{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'; then
		printf 'FAIL published reconciliation accepted invalid stale-runtime recovery: %s\n' "$lane_patch_json"
		exit 1
	fi
done
lane_patch_json='{}'
printf 'PASS published reconciliation resumes only validated stale-runtime deferrals\n'
for lane_expected_sources in \
	'91' \
	'90,91' \
	'90,90' \
	'90@2222222222222222222222222222222222222222'; do
	if _full_loop_release_finalize_reconciliation test/repo 90 v1.2.3; then
		printf 'FAIL published reconciliation accepted mismatched lane intent: %s\n' "$lane_expected_sources"
		exit 1
	fi
done
lane_expected_sources='90@1111111111111111111111111111111111111111'
lane_patch_json='{"tag":null,"snapshot_manifest_bound":true,"snapshot_sha":"1111111111111111111111111111111111111111"}'
if ! (
	tag_bound=0
	release_lane_update_if_owned() {
		[[ "$1" == "test/repo" && "$2" == "90" && "$3" == "exact-tag-deployment" && "$4" == "v1.2.3" ]] || return 1
		tag_bound=1
		return 0
	}
	_full_loop_release_finalize_reconciliation test/repo 90 v1.2.3 || exit 1
	[[ "$tag_bound" -eq 1 ]]
); then
	printf 'FAIL published null-tag lane with exact bound snapshot could not resume\n'
	exit 1
fi
for lane_patch_json in \
	'{"tag":"v9.9.9","snapshot_manifest_bound":true,"snapshot_sha":"1111111111111111111111111111111111111111"}' \
	'{"tag":null,"snapshot_manifest_bound":true,"snapshot_sha":"2222222222222222222222222222222222222222"}' \
	'{"tag":null,"snapshot_manifest_bound":false,"snapshot_sha":"1111111111111111111111111111111111111111"}' \
	'{"tag":null}' \
	'{"tag":null,"snapshot_manifest_bound":true,"snapshot_sha":"1111111111111111111111111111111111111111","source_pr":91}' \
	'{"tag":null,"snapshot_manifest_bound":true,"snapshot_sha":"1111111111111111111111111111111111111111","terminal_receipt":{}}'; do
	if _full_loop_release_finalize_reconciliation test/repo 90 v1.2.3; then
		printf 'FAIL unsafe null-tag lane accepted: %s\n' "$lane_patch_json"
		exit 1
	fi
done
lane_patch_json='{}'
printf 'PASS null-tag reconciliation requires exact modern snapshot and retains mismatch refusals\n'
SCRIPT_DIR="$saved_script_dir"
_FULL_LOOP_RELEASE_PATH=""
printf 'PASS reconciliation uses hardened tag runtime and accepts only equivalent legacy lane intent\n'
