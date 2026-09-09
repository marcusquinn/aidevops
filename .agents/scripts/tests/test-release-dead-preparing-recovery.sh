#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
export AIDEVOPS_WORKTREE_BASE_DIR="$TEST_ROOT/worktrees"
mkdir -p "$HOME" "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42"
printf '1.2.4\n' >"$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42/VERSION"

# shellcheck source=../release-lane-helper.sh
source "$SCRIPT_DIR/release-lane-helper.sh"
# shellcheck source=../full-loop-release-aggregate-recovery.sh
source "$SCRIPT_DIR/full-loop-release-aggregate-recovery.sh"

REPO_ROOT="$TEST_ROOT/repo"
mkdir -p "$REPO_ROOT"
SNAPSHOT=2222222222222222222222222222222222222222
EXPECTED='101@1111111111111111111111111111111111111111'
BASE_STATE='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"expected_sources":"101@1111111111111111111111111111111111111111","phase":"preparing","tag":null,"owner":"process-42","operation_token":"token-old","updated_at":"2020-01-01T00:00:00Z","terminal_receipt":null,"reservation_contract":"fenced-prepublication/v1","executor":{"host_id":"local","pid":42,"started_at":"old"},"snapshot_sha":"2222222222222222222222222222222222222222","snapshot_base":"1111111111111111111111111111111111111111","snapshot_base_tag":"v1.2.3","snapshot_base_object":"3333333333333333333333333333333333333333","snapshot_manifest_bound":true}'
STATE="$BASE_STATE"
AUTHORIZATION="$EXPECTED"
CHANNELS_ABSENT=true
SURVIVING_PROCESS=false
PROTECTED_BRANCH=false
PERMISSION=true
LANE_ABSENT=false
RECOVERY_CALLS=0
CAPTURED_EVIDENCE=""

release_lane_read() {
	[[ "$LANE_ABSENT" == "false" ]] || return 2
	_AIDEVOPS_RELEASE_LANE_JSON="$STATE"
	_AIDEVOPS_RELEASE_LANE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	return 0
}

_full_loop_read_release_authorization() {
	printf '%s\n' "$AUTHORIZATION"
	return 0
}

_full_loop_release_expected_tag_at_commit() {
	[[ "$1" == "$SNAPSHOT" && "$2" == "patch" ]] || return 1
	printf 'v1.2.4\n'
	return 0
}

_full_loop_recovery_verify_channels_absent() {
	[[ "$1" == "test/repo" && "$2" == "v1.2.4" && "$CHANNELS_ABSENT" == "true" ]]
	return $?
}

_full_loop_recovery_process_uses_path() {
	[[ "$SURVIVING_PROCESS" == "false" ]]
	return $?
}

_release_lane_executor_observe() {
	printf '{"state":"%s"}\n' "$EXECUTOR_STATE"
	return 0
}

git() {
	local args="$*"
	case "$args" in
	*"rev-parse HEAD"*) printf '%s\n' "$SNAPSHOT" ;;
	*"symbolic-ref -q HEAD"*) return 1 ;;
	*"show-ref --verify --quiet refs/tags/v1.2.4"*)
		[[ "$LOCAL_TAG" == "false" ]] && return 1
		return 0
		;;
	*"worktree list --porcelain"*)
		[[ "$REGISTRY_ERROR" == "false" ]] || return 128
		[[ "$REGISTERED" == "true" ]] && printf 'worktree %s\n' "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42"
		return 0
		;;
	*"worktree add --detach"*)
		[[ "$6" == "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42" && "$7" == "$SNAPSHOT" ]] || return 1
		mkdir -p "$6"
		printf '1.2.3\n' >"$6/VERSION"
		RECONSTRUCT_CALLS=$((RECONSTRUCT_CALLS + 1))
		;;
	*"ls-remote --heads origin refs/heads/chore/release-v1.2.4-provenance"*)
		[[ "$PROTECTED_BRANCH" == "false" ]] && return 0
		printf '%s\t%s\n' 4444444444444444444444444444444444444444 refs/heads/chore/release-v1.2.4-provenance
		;;
	*) return 1 ;;
	esac
	return 0
}

release_lane_recover_dead_preparing() {
	[[ "$1" == "test/repo" && "$2" == "101" && "$3" == "$EXPECTED" && "$4" == "v1.2.4" ]] || return 1
	RECOVERY_CALLS=$((RECOVERY_CALLS + 1))
	CAPTURED_EVIDENCE="$5"
	return 0
}

gh() {
	[[ "$*" == 'api repos/test/repo --jq '* ]] || return 1
	printf '%s\n' "$PERMISSION"
	return 0
}

reset_fixture() {
	STATE="$BASE_STATE"
	AUTHORIZATION="$EXPECTED"
	CHANNELS_ABSENT=true
	SURVIVING_PROCESS=false
	PROTECTED_BRANCH=false
	PERMISSION=true
	LANE_ABSENT=false
	RECOVERY_CALLS=0
	CAPTURED_EVIDENCE=""
	EXECUTOR_STATE=dead
	LOCAL_TAG=false
	REGISTERED=false
	REGISTRY_ERROR=false
	RECONSTRUCT_CALLS=0
	mkdir -p "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42"
	printf '1.2.4\n' >"$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42/VERSION"
	return 0
}

reset_fixture
_full_loop_recovery_dead_preparing test/repo 101 "$EXPECTED" patch >/dev/null
[[ "$RECOVERY_CALLS" -eq 1 ]] || exit 1
jq -e '.attempted_tag == "v1.2.4" and .worktree_state == "isolated"
	and .remote_tag == "absent" and .github_release == "absent"
	and .npm == "absent" and .homebrew == "absent" and .protected_branch == "absent"' \
	<<<"$CAPTURED_EVIDENCE" >/dev/null
printf 'PASS dead preparing recovery proves isolated worktree and absent channels before one CAS\n'

reset_fixture
LANE_ABSENT=true
absent_rc=0
_full_loop_recovery_dead_preparing test/repo 101 "$EXPECTED" patch >/dev/null 2>&1 || absent_rc=$?
[[ "$absent_rc" -eq 2 && "$RECOVERY_CALLS" -eq 0 ]] || exit 1
printf 'PASS absent lane falls through to the ordinary release path\n'

for refusal in authorization channels process permission branch version; do
	reset_fixture
	case "$refusal" in
	authorization) AUTHORIZATION='101@9999999999999999999999999999999999999999' ;;
	channels) CHANNELS_ABSENT=false ;;
	process) SURVIVING_PROCESS=true ;;
	permission) PERMISSION=false ;;
	branch) PROTECTED_BRANCH=true ;;
	version) printf '1.2.5\n' >"$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42/VERSION" ;;
	esac
	if _full_loop_recovery_dead_preparing test/repo 101 "$EXPECTED" patch >/dev/null 2>&1; then
		printf 'FAIL unsafe %s state was recovered\n' "$refusal" >&2
		exit 1
	fi
	[[ "$RECOVERY_CALLS" -eq 0 ]] || exit 1
done
printf 'PASS preparing recovery refuses authorization, channel, process, branch, and worktree uncertainty\n'

reset_fixture
rm -rf "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42"
_full_loop_recovery_dead_preparing test/repo 101 "$EXPECTED" patch >/dev/null
[[ "$RECOVERY_CALLS" -eq 1 && "$RECONSTRUCT_CALLS" -eq 1 ]] || exit 1
jq -e '.worktree_reconstructed == true and .worktree_head == "2222222222222222222222222222222222222222"' <<<"$CAPTURED_EVIDENCE" >/dev/null
printf 'PASS missing preparation reconstructed from exact snapshot with explicit evidence\n'

(
	unset -f git
	REPO_ROOT="$TEST_ROOT/real-repo"
	AIDEVOPS_WORKTREE_BASE_DIR="$TEST_ROOT/real-worktrees"
	mkdir -p "$REPO_ROOT" "$AIDEVOPS_WORKTREE_BASE_DIR"
	git init -q "$REPO_ROOT"
	printf '1.2.3\n' >"$REPO_ROOT/VERSION"
	git -C "$REPO_ROOT" add VERSION
	git -C "$REPO_ROOT" -c user.name=Fixture -c user.email=fixture@example.invalid \
		-c commit.gpgsign=false commit -qm snapshot
	SNAPSHOT=$(git -C "$REPO_ROOT" rev-parse HEAD)
	_full_loop_recovery_restore_preparation 101 42 \
		"$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42" "$SNAPSHOT" v1.2.4
	[[ "$(git -C "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42" rev-parse HEAD)" == "$SNAPSHOT" ]]
	if git -C "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42" symbolic-ref -q HEAD; then
		exit 1
	fi
	[[ "$_FULL_LOOP_RECOVERY_WORKTREE_RECONSTRUCTED" == "true" ]]
)
printf 'PASS real Git reconstruction creates a detached exact-snapshot worktree\n'

for refusal in authorization channels process permission branch executor registration local_tag registry_error directory_symlink symlink; do
	reset_fixture
	rm -rf "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42"
	case "$refusal" in
	authorization) AUTHORIZATION='101@9999999999999999999999999999999999999999' ;;
	channels) CHANNELS_ABSENT=false ;;
	process) SURVIVING_PROCESS=true ;;
	permission) PERMISSION=false ;;
	branch) PROTECTED_BRANCH=true ;;
	executor) EXECUTOR_STATE=unknown ;;
	registration) REGISTERED=true ;;
	local_tag) LOCAL_TAG=true ;;
	registry_error) REGISTRY_ERROR=true ;;
	directory_symlink)
		mkdir -p "$TEST_ROOT/symlink-target"
		printf '1.2.3\n' >"$TEST_ROOT/symlink-target/VERSION"
		ln -s "$TEST_ROOT/symlink-target" "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42"
		;;
	symlink) ln -s "$TEST_ROOT/missing" "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42" ;;
	esac
	if _full_loop_recovery_dead_preparing test/repo 101 "$EXPECTED" patch >/dev/null 2>&1; then
		printf 'FAIL unsafe missing-worktree %s state was recovered\n' "$refusal" >&2
		exit 1
	fi
	[[ "$RECOVERY_CALLS" -eq 0 && "$RECONSTRUCT_CALLS" -eq 0 ]] || exit 1
done
printf 'PASS missing preparation refuses uncertain ownership, publication, registration, and paths\n'

(
	# shellcheck source=../full-loop-release-reconcile.sh
	source "$SCRIPT_DIR/full-loop-release-reconcile.sh"
	# shellcheck source=../release-authorization-manifest-helper.sh
	source "$SCRIPT_DIR/release-authorization-manifest-helper.sh"
	_full_loop_release_source_json_from_tag() {
		printf '{"source_pr":101,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}\n'
		return 0
	}
	_version_manager_local_tag_identity() {
		[[ "$1" == "v1.2.4" ]] || return 1
		_VERSION_MANAGER_LOCAL_TAG_OBJECT=4444444444444444444444444444444444444444
		_VERSION_MANAGER_LOCAL_TAG_COMMIT=5555555555555555555555555555555555555555
		return 0
	}
	git() {
		[[ "$*" == *'rev-parse 5555555555555555555555555555555555555555^' ]] || return 1
		printf '%s\n' "$SNAPSHOT"
		return 0
	}
	_full_loop_release_verify_protected_source_provenance() {
		_FULL_LOOP_RELEASE_PATH="${TEST_ROOT}/tag-checkout"
		[[ "$VALID_SOURCE" == "true" ]]
		return $?
	}
	_release_lane_executor_capture() {
		printf '{"host_id":"local","pid":43,"started_at":"new"}\n'
		return 0
	}
	_release_lane_write() {
		[[ "$1" == "test/repo" && "$3" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || return 1
		[[ "$CAS_FAIL" == "false" ]] || return 75
		STATE="$2"
		RECOVERY_CALLS=$((RECOVERY_CALLS + 1))
		return 0
	}
	_version_manager_queue_protected_main_release() {
		[[ "$1" == "1.2.4" && "$REPO_ROOT" == "${TEST_ROOT}/tag-checkout" ]] || return 1
		[[ "$AIDEVOPS_VERSION_MANAGER_REPO_SLUG" == "test/repo" ]] || return 1
		if [[ "$FENCE_RACE" == "true" ]]; then
			STATE=$(jq '.operation_token = "competing-fixture"' <<<"$STATE") || return 1
		fi
		_version_manager_require_aggregate_fence || return 1
		printf 'queued\n' >>"${TEST_ROOT}/preserved-queue.log"
		return 0
	}
	reset_preserved_fixture() {
		# Do not follow the dangling path deliberately left by the preceding fixture.
		STATE="$BASE_STATE"
		AUTHORIZATION="$EXPECTED"
		CHANNELS_ABSENT=true
		SURVIVING_PROCESS=false
		PERMISSION=true
		LANE_ABSENT=false
		EXECUTOR_STATE=dead
		RECOVERY_CALLS=0
		VALID_SOURCE=true
		CAS_FAIL=false
		FENCE_RACE=false
		rm -f "${TEST_ROOT}/preserved-queue.log"
		return 0
	}
	reset_preserved_fixture
	queue_rc=0
	_full_loop_release_queue_preserved_tag test/repo 101 v1.2.4 >/dev/null || queue_rc=$?
	[[ "$queue_rc" -eq 8 && "$RECOVERY_CALLS" -eq 1 && -e "${TEST_ROOT}/preserved-queue.log" ]]
	jq -e '.phase == "remote-publication" and .tag == "v1.2.4"
		and .operation_token != "token-old"
		and .preserved_tag_recovery.tag_object == "4444444444444444444444444444444444444444"
		and .preserved_tag_recovery.release_commit == "5555555555555555555555555555555555555555"
		and .expected_sources == "101@1111111111111111111111111111111111111111"' <<<"$STATE" >/dev/null
	# An interruption after the claim but before PR creation retains the same tag.
	queue_rc=0
	_full_loop_release_queue_preserved_tag test/repo 101 v1.2.4 >/dev/null || queue_rc=$?
	[[ "$queue_rc" -eq 8 && "$RECOVERY_CALLS" -eq 2 ]]
	printf 'PASS preserved signed candidate resumes after either preparation interruption without a bump\n'
	for refusal in provenance authorization manifest channels process permission alive unknown competing phase snapshot contract cas; do
		reset_preserved_fixture
		case "$refusal" in
		provenance) VALID_SOURCE=false ;;
		authorization) AUTHORIZATION='101@9999999999999999999999999999999999999999' ;;
		manifest)
			STATE=$(jq '.expected_sources="101@9999999999999999999999999999999999999999"' <<<"$STATE")
			AUTHORIZATION='101@9999999999999999999999999999999999999999'
			;;
		channels) CHANNELS_ABSENT=false ;;
		process) SURVIVING_PROCESS=true ;;
		permission) PERMISSION=false ;;
		alive | unknown) EXECUTOR_STATE="$refusal" ;;
		competing) STATE=$(jq '.source_pr=102' <<<"$STATE") ;;
		phase) STATE=$(jq '.phase="reserved"' <<<"$STATE") ;;
		snapshot) STATE=$(jq '.snapshot_sha="9999999999999999999999999999999999999999"' <<<"$STATE") ;;
		contract) STATE=$(jq 'del(.reservation_contract)' <<<"$STATE") ;;
		cas) CAS_FAIL=true ;;
		esac
		queue_rc=0
		_full_loop_release_queue_preserved_tag test/repo 101 v1.2.4 >/dev/null 2>&1 || queue_rc=$?
		[[ "$queue_rc" -ne 8 && "$queue_rc" -ne 0 && "$RECOVERY_CALLS" -eq 0 && ! -e "${TEST_ROOT}/preserved-queue.log" ]] || {
			printf 'FAIL unsafe preserved-tag %s state queued publication\n' "$refusal" >&2
			exit 1
		}
	done
	reset_preserved_fixture
	FENCE_RACE=true
	queue_rc=0
	_full_loop_release_queue_preserved_tag test/repo 101 v1.2.4 >/dev/null 2>&1 || queue_rc=$?
	[[ "$queue_rc" -eq 1 && "$RECOVERY_CALLS" -eq 1 && ! -e "${TEST_ROOT}/preserved-queue.log" ]]
	printf 'PASS preserved-tag recovery fails closed before CAS and at the publication fence\n'
)
