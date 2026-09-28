#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-full-loop-release-reconcile.sh; shares its fixtures and state.

run_stale_supersession_fixture() {
	local mode="$1"
	local write_log="$2"
	(
		_full_loop_release_source_json_from_tag() {
			local tag_name="$1"
			case "$tag_name" in
			v1.2.3)
				printf '%s\n' '{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'
				;;
			v1.2.4)
				printf '%s\n' '{"source_pr":91,"source_merge":"2222222222222222222222222222222222222222","aggregated_sources":[]}'
				;;
			*) return 1 ;;
			esac
			return 0
		}
		_full_loop_release_resolve_tag_commit() {
			local tag_name="$1"
			case "$tag_name" in
			v1.2.3) printf '%040d\n' 3 ;;
			v1.2.4) printf '%040d\n' 4 ;;
			*) return 1 ;;
			esac
			return 0
		}
		_full_loop_release_verify_stale_publication_run() {
			local repo="$1"
			local tag_name="$2"
			local tag_commit="$3"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.3" && "$tag_commit" == "$(printf '%040d' 3)" ]] || return 1
			[[ "$mode" != "source-run" ]] || return 1
			_FULL_LOOP_RELEASE_RUN_JSON='{"id":101}'
			return 0
		}
		_full_loop_release_reset_tag_worktree() {
			return 0
		}
		_full_loop_release_verify_tag_provenance() {
			local repo="$1"
			local tag_name="$2"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.4" ]]
			return $?
		}
		_full_loop_release_inspect_remote() {
			local repo="$1"
			local tag_name="$2"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.4" ]] || return 1
			[[ "$mode" != "latest-remote" ]] || return 1
			_FULL_LOOP_RELEASE_RUN_JSON='{"id":202}'
			return 0
		}
		_full_loop_release_receipt_path() {
			local repo="$1"
			local pr_number="$2"
			[[ "$repo" == "test/repo" ]] || return 1
			if [[ "$mode" == "receipt" ]]; then
				printf '%s/missing-%s.status\n' "$TEST_ROOT" "$pr_number"
			else
				printf '%s/receipts/test_repo-%s.status\n' "$TEST_ROOT" "$pr_number"
			fi
			return 0
		}
		_full_loop_write_successor_release_receipt() {
			local args="$*"
			printf '%s\n' "$args" >"$write_log"
			return 0
		}
		git() {
			local args="$*"
			[[ "$args" == *" merge-base --is-ancestor "* && "$mode" != "ancestry" ]]
			return $?
		}
		_full_loop_release_finalize_stale_supersession test/repo 90 v1.2.3 v1.2.4
	)
	return $?
}

printf 'published\n' >"${TEST_ROOT}/receipts/test_repo-91.status"
stale_write_log="${TEST_ROOT}/stale-successor-write.log"
run_stale_supersession_fixture valid "$stale_write_log" || {
	printf 'FAIL verified stale publication and terminal successor did not reconcile\n'
	exit 1
}
if ! grep -qx "test/repo 90 1111111111111111111111111111111111111111 v1.2.3 $(printf '%040d' 3) 101 91 2222222222222222222222222222222222222222 v1.2.4 $(printf '%040d' 4) 202" \
	"$stale_write_log"; then
	printf 'FAIL post-publication supersession omitted immutable source or successor evidence\n'
	exit 1
fi
for stale_failure_mode in source-run ancestry latest-remote receipt; do
	rm -f "$stale_write_log"
	if run_stale_supersession_fixture "$stale_failure_mode" "$stale_write_log"; then
		printf 'FAIL %s uncertainty allowed stale release supersession\n' "$stale_failure_mode"
		exit 1
	fi
	[[ ! -e "$stale_write_log" ]] || {
		printf 'FAIL %s uncertainty wrote terminal supersession evidence\n' "$stale_failure_mode"
		exit 1
	}
done
printf 'PASS stale receipt supersession binds both releases and fails closed on uncertain evidence\n'

protected_write_log="${TEST_ROOT}/protected-successor-write.log"
for mode in valid unrelated protected-ancestry unmerged malformed-merge receipt; do
	rm -f "$protected_write_log"
	protected_fixture_rc=0
	write_log="$protected_write_log"
	(
		_full_loop_release_source_json_from_tag() {
			local tag_name="$1"
			case "$tag_name" in
			v1.2.3)
				printf '%s\n' '{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'
				;;
			v1.2.4)
				printf '%s\n' '{"source_pr":91,"source_merge":"2222222222222222222222222222222222222222","aggregated_sources":[]}'
				;;
			*) return 1 ;;
			esac
			return 0
		}
		_full_loop_release_resolve_tag_commit() {
			local tag_name="$1"
			case "$tag_name" in
			v1.2.3) printf '%040d\n' 3 ;;
			v1.2.4) printf '%040d\n' 4 ;;
			*) return 1 ;;
			esac
			return 0
		}
		_full_loop_release_verify_stale_publication_run() {
			return 1
		}
		_full_loop_release_find_workflow_run() {
			local repo="$1"
			local tag_name="$2"
			local tag_commit="$3"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.3" &&
				"$tag_commit" == "$(printf '%040d' 3)" ]] || return 1
			return 3
		}
		_full_loop_release_verify_protected_source_provenance() {
			local repo="$1"
			local tag_name="$2"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.3" ]]
			return $?
		}
		_full_loop_release_reset_tag_worktree() {
			return 0
		}
		_full_loop_release_verify_tag_provenance() {
			local repo="$1"
			local tag_name="$2"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.4" ]]
			return $?
		}
		_version_manager_reconcile_protected_release_tag() {
			local repo="$1"
			local tag_name="$2"
			local reconcile_mode="$3"
			local merged_at="2026-08-04T00:00:00Z"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.3" &&
				"$reconcile_mode" == "status" ]] || return 1
			[[ "$mode" != "malformed-merge" ]] || merged_at="not-a-timestamp"
			_VERSION_MANAGER_LOCAL_TAG_OBJECT="$(printf '%040d' 2)"
			_VERSION_MANAGER_LOCAL_TAG_COMMIT="$(printf '%040d' 3)"
			_VERSION_MANAGER_PROTECTED_PR_NUMBER=77
			_VERSION_MANAGER_PROTECTED_PR_JSON=$(jq -cn \
				--arg head "$(printf '%040d' 33)" --arg merged_at "$merged_at" \
				'{head:{sha:$head},merged_at:$merged_at}') || return 1
			if [[ "$mode" == "unmerged" ]]; then
				_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="pr-pending"
			else
				_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="tag-ready"
			fi
			return 0
		}
		_full_loop_release_inspect_remote() {
			local repo="$1"
			local tag_name="$2"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.4" ]] || return 1
			_FULL_LOOP_RELEASE_RUN_JSON='{"id":202}'
			return 0
		}
		_full_loop_release_receipt_path() {
			local repo="$1"
			local pr_number="$2"
			[[ "$repo" == "test/repo" ]] || return 1
			if [[ "$mode" == "receipt" ]]; then
				printf '%s/missing-protected-%s.status\n' "$TEST_ROOT" "$pr_number"
			else
				printf '%s/receipts/test_repo-%s.status\n' "$TEST_ROOT" "$pr_number"
			fi
			return 0
		}
		_full_loop_release_write_protected_successor_receipt() {
			local args="$*"
			printf '%s\n' "$args" >"$write_log"
			return 0
		}
		git() {
			local args="$*"
			case "$args" in
			*" merge-base --is-ancestor "*)
				[[ "$mode" != "unrelated" ]] || return 1
				if [[ "$mode" == "protected-ancestry" &&
					"$args" == *"$(printf '%040d' 33) $(printf '%040d' 4)"* ]]; then
					return 1
				fi
				return 0
				;;
			esac
			return 1
		}
		_full_loop_release_finalize_stale_supersession test/repo 90 v1.2.3 v1.2.4
	) || protected_fixture_rc=$?
	if [[ "$mode" == "valid" ]]; then
		if [[ "$protected_fixture_rc" -ne 0 ]]; then
			printf 'FAIL unpublished protected predecessor did not reconcile through a published descendant\n'
			exit 1
		fi
		if ! grep -q '"protected_pr":77' "$protected_write_log" ||
			! grep -q '"protected_head":"0000000000000000000000000000000000000033"' "$protected_write_log"; then
			printf 'FAIL protected predecessor supersession omitted immutable PR evidence\n'
			exit 1
		fi
		continue
	fi
	if [[ "$protected_fixture_rc" -eq 0 ]]; then
		printf 'FAIL %s protected predecessor evidence allowed supersession\n' "$mode"
		exit 1
	fi
	[[ ! -e "$protected_write_log" ]] || {
		printf 'FAIL %s protected predecessor uncertainty wrote terminal evidence\n' \
			"$mode"
		exit 1
	}
done
unset mode write_log protected_fixture_rc
printf 'PASS unpublished protected predecessors require merged ancestry and a published successor receipt\n'

(
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/protected-evidence-receipts"
	# shellcheck source=../full-loop-helper-state.sh
	source "${SCRIPT_DIR}/full-loop-helper-state.sh"
	_full_loop_update_superseded_cleanup_receipt() {
		local repo="$1"
		local pr_number="$2"
		[[ "$repo" == "test/repo" && "$pr_number" == "90" ]]
		return $?
	}
	protected_json=$(jq -cn \
		--arg source_tag v1.2.3 --arg source_tag_object "$(printf '%040d' 2)" \
		--arg source_commit "$(printf '%040d' 3)" --argjson protected_pr 77 \
		--arg protected_head "$(printf '%040d' 33)" \
		--arg protected_merged_at '2026-08-04T00:00:00Z' \
		'{source_tag:$source_tag,source_tag_object:$source_tag_object,
		  source_commit:$source_commit,protected_pr:$protected_pr,
		  protected_head:$protected_head,protected_merged_at:$protected_merged_at}') || exit 1
	malformed_protected_json=$(jq -c '.protected_merged_at = "invalid"' \
		<<<"$protected_json") || exit 1
	if _full_loop_release_write_protected_successor_receipt test/repo 92 \
		1111111111111111111111111111111111111111 "$malformed_protected_json" 93 \
		2222222222222222222222222222222222222222 v1.2.4 \
		"$(printf '%040d' 4)" 202; then
		exit 1
	fi
	malformed_evidence=$(_full_loop_release_evidence_path test/repo 92 successor) || exit 1
	[[ ! -e "$malformed_evidence" &&
		! -e "${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-92.status" ]] || exit 1
	_full_loop_release_write_protected_successor_receipt test/repo 90 \
		1111111111111111111111111111111111111111 "$protected_json" 91 \
		2222222222222222222222222222222222222222 v1.2.4 \
		"$(printf '%040d' 4)" 202 || exit 1
	evidence_path=$(_full_loop_release_evidence_path test/repo 90 successor) || exit 1
	_full_loop_verify_successor_superseded_release_evidence \
		"$evidence_path" test/repo 90 || exit 1
	jq -e '.schema_version == 2
		and .evidence_type == "protected-predecessor-supersession"
		and .source_release_tag_object == "0000000000000000000000000000000000000002"
		and .source_protected_pr == 77
		and .source_protected_pr_head == "0000000000000000000000000000000000000033"
		and .release_workflow_run == 202' "$evidence_path" >/dev/null || exit 1
	grep -qx superseded "${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-90.status" || exit 1
)
printf 'PASS protected predecessor supersession writes independently verifiable audit evidence\n'

protected_state_log="${TEST_ROOT}/protected-state.log"
protected_source_log="${TEST_ROOT}/protected-source.log"
protected_push_log="${TEST_ROOT}/protected-push.log"
protected_remote_verify_log="${TEST_ROOT}/protected-remote-verify.log"
export protected_state_log protected_source_log protected_push_log protected_remote_verify_log
(
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet"*) return 0 ;;
		*" for-each-ref "*)
			printf 'v1.2.3\x1f90\x1f1111111111111111111111111111111111111111\x1f\n'
			;;
		*" log --all --fixed-strings "*) return 0 ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_resolve_repo() {
		local requested_repo="$1"
		printf '%s\n' "${requested_repo:-test/repo}"
		return 0
	}
	_full_loop_release_receipt_path() {
		local repo="$1"
		local pr_number="$2"
		printf '%s/protected-%s-%s.status\n' "$TEST_ROOT" "${repo//\//_}" "$pr_number"
		return 0
	}
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.3" ]] || return 1
		printf '%s\n' \
			'Aidevops-Source-PR: 90' \
			'Aidevops-Source-Merge: 1111111111111111111111111111111111111111'
		return 0
	}
	_full_loop_release_source_json_from_tag() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.3" ]] || return 1
		printf '%s\n' '{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'
		return 0
	}
	_version_manager_classify_remote_tag() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.3" ]] || return 1
		_VERSION_MANAGER_REMOTE_TAG_STATE="$_VERSION_MANAGER_TAG_STATE_ABSENT"
		return 0
	}
	_full_loop_release_verify_tag_provenance() {
		local repo="$1"
		local tag_name="$2"
		printf '%s %s\n' "$repo" "$tag_name" >"$protected_remote_verify_log"
		return 1
	}
	_full_loop_release_verify_protected_source_provenance() {
		local repo="$1"
		local tag_name="$2"
		printf '%s %s\n' "$repo" "$tag_name" >>"$protected_source_log"
		[[ "${invalid_local_source:-false}" == "false" ]]
		return $?
	}
	_version_manager_reconcile_protected_release_tag() {
		local repo="$1"
		local tag_name="$2"
		local mode="$3"
		printf '%s %s %s\n' "$repo" "$tag_name" "$mode" >>"$protected_state_log"
		if [[ "${missing_protected_pr:-false}" == "true" ]]; then
			_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="$_VERSION_MANAGER_RELEASE_PR_MISSING"
			return 0
		fi
		if [[ "$mode" == "reconcile" ]]; then
			printf '%s %s\n' "$repo" "$tag_name" >"$protected_push_log"
			_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="tag-pushed"
		else
			_VERSION_MANAGER_PROTECTED_RELEASE_RESULT="tag-ready"
		fi
		return 0
	}
	_full_loop_release_latest_tag() {
		printf 'v1.2.3\n'
		return 0
	}
	_full_loop_release_queue_preserved_tag() {
		[[ "$1" == "test/repo" && "$2" == "90" && "$3" == "v1.2.3" ]] || return 1
		printf 'queued\n' >"${TEST_ROOT}/preserved-queue.log"
		return 8
	}
	missing_protected_pr=true
	status_rc=0
	AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command status 90 \
		>/dev/null 2>&1 || status_rc=$?
	[[ "$status_rc" -eq 8 && ! -e "${TEST_ROOT}/preserved-queue.log" ]] || exit 1
	reconcile_rc=0
	AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
		>/dev/null 2>&1 || reconcile_rc=$?
	[[ "$reconcile_rc" -eq 8 && -e "${TEST_ROOT}/preserved-queue.log" ]] || exit 1
	rm -f "${TEST_ROOT}/preserved-queue.log"
	invalid_local_source=true
	reconcile_rc=0
	AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
		>/dev/null 2>&1 || reconcile_rc=$?
	[[ "$reconcile_rc" -eq 1 && ! -e "${TEST_ROOT}/preserved-queue.log" ]] || exit 1
	printf 'PASS missing-PR discovery reaches only authorized reconcile and still verifies provenance\n'
	missing_protected_pr=false
	invalid_local_source=false
	rm -f "$protected_state_log" "$protected_source_log"
	status_rc=0
	AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command status 90 \
		>/dev/null 2>&1 || status_rc=$?
	[[ "$status_rc" -eq 8 && ! -e "$protected_push_log" ]] || exit 1
	reconcile_rc=0
	AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
		>/dev/null 2>&1 || reconcile_rc=$?
	[[ "$reconcile_rc" -eq 8 ]] || exit 1
)
if [[ -e "$protected_remote_verify_log" ]] ||
	! grep -qx 'test/repo v1.2.3' "$protected_push_log" ||
	[[ "$(grep -c '^test/repo v1.2.3 status$' "$protected_state_log")" -ne 3 ]] ||
	[[ "$(grep -c '^test/repo v1.2.3 reconcile$' "$protected_state_log")" -ne 1 ]] ||
	[[ "$(grep -c '^test/repo v1.2.3$' "$protected_source_log")" -ne 2 ]]; then
	printf 'FAIL public reconciliation did not preserve the read-only protected-tag discovery boundary\n'
	exit 1
fi
printf 'PASS public status is read-only and reconcile reaches exact protected-tag publication\n'
