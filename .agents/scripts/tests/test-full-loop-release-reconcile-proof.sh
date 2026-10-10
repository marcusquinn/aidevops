#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-full-loop-release-reconcile.sh; shares its fixtures and state.

# Direct execution must initialize the shared fixtures and preceding fragments.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	exec bash "$(dirname "${BASH_SOURCE[0]}")/test-full-loop-release-reconcile.sh" "$@"
fi

stale_publication_jobs_fixture() {
	local mode="${1:-valid}"
	local jobs_json=""
	jobs_json=$(jq -cn '
		{total_count:1,jobs:[{id:101,name:"Publish GitHub, npm, and Homebrew",
		status:"completed",conclusion:"failure",steps:[
		{name:"Set up job",number:1,status:"completed",conclusion:"success"},
		{name:"Checkout verified tag",number:2,status:"completed",conclusion:"success"},
		{name:"Verify immutable release provenance",number:3,status:"completed",conclusion:"success"},
		{name:"Create or reconcile GitHub release",number:4,status:"completed",conclusion:"success"},
		{name:"Publish to npm",number:5,status:"completed",conclusion:"skipped"},
		{name:"Verify npm publication",number:6,status:"completed",conclusion:"success"},
		{name:"Push to Homebrew tap",number:7,status:"completed",conclusion:"skipped"},
		{name:"Verify Homebrew tap",number:8,status:"completed",conclusion:"success"},
		{name:"Queue exact-tag postflight",number:9,status:"completed",conclusion:"failure"},
		{name:"Publication summary",number:10,status:"completed",conclusion:"skipped"}
		]}]}
	') || return 1
	case "$mode" in
	valid) ;;
	queue-success) jobs_json=$(jq '.jobs[0].steps[8].conclusion = "success"' <<<"$jobs_json") || return 1 ;;
	duplicate-npm) jobs_json=$(jq '.jobs[0].steps += [.jobs[0].steps[5]]' <<<"$jobs_json") || return 1 ;;
	extra-failure) jobs_json=$(jq '.jobs[0].steps[3].conclusion = "failure"' <<<"$jobs_json") || return 1 ;;
	nonterminal) jobs_json=$(jq '.jobs[0].steps[8].status = "in_progress"' <<<"$jobs_json") || return 1 ;;
	reordered-postflight) jobs_json=$(jq '.jobs[0].steps[3].number = 9 | .jobs[0].steps[8].number = 4' <<<"$jobs_json") || return 1 ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$jobs_json"
	return 0
}

valid_stale_jobs=$(stale_publication_jobs_fixture valid)
_full_loop_release_run_jobs_payload_valid "$valid_stale_jobs" || {
	printf 'FAIL valid workflow jobs payload was rejected\n'
	exit 1
}
_full_loop_release_stale_publication_jobs_valid "$valid_stale_jobs" || {
	printf 'FAIL exact post-publication dispatch failure evidence was rejected\n'
	exit 1
}
for invalid_jobs_mode in queue-success duplicate-npm extra-failure nonterminal reordered-postflight; do
	if _full_loop_release_stale_publication_jobs_valid \
		"$(stale_publication_jobs_fixture "$invalid_jobs_mode")"; then
		printf 'FAIL %s stale publication job evidence was accepted\n' "$invalid_jobs_mode"
		exit 1
	fi
done
if _full_loop_release_run_jobs_payload_valid \
	"$(jq '.total_count = 2' <<<"$valid_stale_jobs")"; then
	printf 'FAIL truncated workflow jobs payload was accepted\n'
	exit 1
fi
printf 'PASS stale publication proof requires exact successful channels and sole postflight failure\n'

run_stale_publication_verification_fixture() {
	local mode="$1"
	(
		_full_loop_release_find_workflow_run() {
			local repo="$1"
			local tag_name="$2"
			local tag_commit="$3"
			[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.3" && "$tag_commit" == "$(printf '%040d' 3)" ]] || return 1
			case "$mode" in
			success)
				_FULL_LOOP_RELEASE_RUN_JSON='{"id":101,"status":"completed","conclusion":"success"}'
				;;
			partial-failure | other-failure)
				_FULL_LOOP_RELEASE_RUN_JSON='{"id":101,"status":"completed","conclusion":"failure"}'
				;;
			pending)
				_FULL_LOOP_RELEASE_RUN_JSON='{"id":101,"status":"in_progress","conclusion":"success"}'
				;;
			cancelled)
				_FULL_LOOP_RELEASE_RUN_JSON='{"id":101,"status":"completed","conclusion":"cancelled"}'
				;;
			*) return 1 ;;
			esac
			return 0
		}
		_full_loop_release_fetch_run_jobs() {
			local repo="$1"
			local run_id="$2"
			[[ "$repo" == "test/repo" && "$run_id" == "101" ]] || return 1
			case "$mode" in
			partial-failure) _FULL_LOOP_RELEASE_RUN_JOBS_JSON="$valid_stale_jobs" ;;
			other-failure) _FULL_LOOP_RELEASE_RUN_JOBS_JSON=$(stale_publication_jobs_fixture extra-failure) || return 1 ;;
			*) return 1 ;;
			esac
			return 0
		}
		_full_loop_release_verify_stale_publication_run test/repo v1.2.3 "$(printf '%040d' 3)"
	)
	return $?
}

for accepted_publication_mode in success partial-failure; do
	if ! run_stale_publication_verification_fixture "$accepted_publication_mode"; then
		printf 'FAIL %s publication run was rejected as stale-release evidence\n' "$accepted_publication_mode"
		exit 1
	fi
done
for rejected_publication_mode in pending cancelled other-failure; do
	if run_stale_publication_verification_fixture "$rejected_publication_mode"; then
		printf 'FAIL %s publication run was accepted as stale-release evidence\n' "$rejected_publication_mode"
		exit 1
	fi
done
printf 'PASS stale release evidence accepts successful publication and fails closed otherwise\n'

_full_loop_release_tag_body() {
	local tag_name="$1"
	[[ "$tag_name" == "v1.2.3" ]] || return 1
	cat <<'BODY'
Release v1.2.3

Aidevops-Version: 1.2.3
Aidevops-Source-PR: 90
Aidevops-Source-Merge: 1111111111111111111111111111111111111111
Aidevops-Aggregated-Source: 89@2222222222222222222222222222222222222222
BODY
	return 0
}

source_json=$(_full_loop_release_source_json_from_tag v1.2.3)
if ! jq -e '.source_pr == 90
	and .source_merge == "1111111111111111111111111111111111111111"
	and .aggregated_sources == [{"pr":89,"merge":"2222222222222222222222222222222222222222"}]' \
	<<<"$source_json" >/dev/null; then
	printf 'FAIL signed tag trailers did not reconstruct release provenance\n'
	exit 1
fi
printf 'PASS signed tag trailers reconstruct release provenance\n'

(
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/gap-receipts"
	# shellcheck source=../full-loop-helper-state.sh
	source "${SCRIPT_DIR}/full-loop-helper-state.sh"
	gap_expected='28993@23667f1e351981e4e6ecfeb03dd4c7a52ecfd100,29006@da5fec68b034be737bbf1f8d7ccf05a8dbf64a10,29010@4745adde8faa4a92aa4e27763c52e2c1a02a5e76,29013@de9e0b1b76f8dbeb97ccb8d2c3d57020b41adbd0'
	gap_observed='29010@4745adde8faa4a92aa4e27763c52e2c1a02a5e76'
	gap_tag_object='1901024bf5b675e4c6b680a801ea402b75f1f355'
	gap_release_commit='0050022840d6ab7df25608a8a16e50b54e12efec'
	gap_reason='published tag omitted explicitly authorized sources'
	_full_loop_release_verify_tag_provenance() {
		local repo="$1"
		local tag_name="$2"
		[[ "$repo" == "test/repo" && "$tag_name" == "v3.32.200" ]]
		return $?
	}
	_full_loop_release_resolve_tag_expected_sources() {
		local repo="$1"
		local requested_pr="$2"
		local tag_name="$3"
		local expected_sources="$4"
		[[ "$repo" == "test/repo" && "$requested_pr" == "29010" && "$tag_name" == "v3.32.200" ]] || return 1
		[[ "$expected_sources" == "$gap_expected" ]] || return 1
		printf '%s\n' "$gap_expected"
		return 0
	}
	_full_loop_release_observed_sources_for_expected() {
		local tag_name="$1"
		local expected_sources="$2"
		[[ "$tag_name" == "v3.32.200" && "$expected_sources" == "$gap_expected" ]] || return 1
		printf '%s\n' "$gap_observed"
		return 0
	}
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet") return 0 ;;
		*" rev-parse refs/tags/v3.32.200^{commit}") printf '%s\n' "$gap_release_commit" ;;
		*" rev-parse refs/tags/v3.32.200") printf '%s\n' "$gap_tag_object" ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_record_authorization_gap test/repo 29010 v3.32.200 "$gap_expected" "$gap_reason" >/dev/null
	gap_path=$(_full_loop_release_evidence_path test/repo 29010 authorization-gap)
	jq -e --arg tag_object "$gap_tag_object" --arg release_commit "$gap_release_commit" '
		.status == "authorization-gap"
		and (.expected_sources | length) == 4
		and (.observed_sources | length) == 1
		and .tag_object == $tag_object
		and .release_commit == $release_commit
		and .terminal_cleanup_evidence == false
	' "$gap_path" >/dev/null
	cp "$gap_path" "${TEST_ROOT}/gap-evidence-original.json"
	_full_loop_release_record_authorization_gap test/repo 29010 v3.32.200 "$gap_expected" "$gap_reason" >/dev/null
	cmp -s "$gap_path" "${TEST_ROOT}/gap-evidence-original.json"
	if _full_loop_release_record_authorization_gap test/repo 29010 v3.32.200 "$gap_expected" \
		'conflicting incident classification' >/dev/null 2>&1; then
		printf 'FAIL conflicting authorization-gap replay replaced immutable incident evidence\n'
		exit 1
	fi
	cmp -s "$gap_path" "${TEST_ROOT}/gap-evidence-original.json"
	gap_observed="$gap_expected"
	if _full_loop_release_record_authorization_gap test/repo 29010 v3.32.200 "$gap_expected" \
		'no authorization mismatch' >/dev/null 2>&1; then
		printf 'FAIL matching authorization manifests wrote gap evidence\n'
		exit 1
	fi
	cmp -s "$gap_path" "${TEST_ROOT}/gap-evidence-original.json"
	[[ ! -f "${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-29010.status" ]]
)
printf 'PASS historical authorization gaps use idempotent detached production evidence\n'

(
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/receipt-conflict-receipts"
	# shellcheck source=../full-loop-helper-state.sh
	source "${SCRIPT_DIR}/full-loop-helper-state.sh"
	conflict_release_path="${TEST_ROOT}/receipt-conflict-release"
	mkdir -p "$conflict_release_path"
	printf '1.2.5\n' >"${conflict_release_path}/VERSION"
	conflict_tag_commit="4444444444444444444444444444444444444444"
	conflict_source_json=$(jq -cn '
		{source_pr:90,source_merge:"1111111111111111111111111111111111111111",
		 aggregated_sources:[
		  {pr:89,merge:"2222222222222222222222222222222222222222"},
		  {pr:88,merge:"3333333333333333333333333333333333333333"}
		 ]}
	')
	conflict_receipt=$(_full_loop_release_receipt_path test/repo 89)
	mkdir -p "${conflict_receipt%/*}"
	git() {
		local args="$*"
		case "$args" in
		*"rev-parse refs/tags/v1.2.5^{commit}"*) printf '%s\n' "$conflict_tag_commit" ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_update_superseded_cleanup_receipt() {
		return 0
	}
	: >"$conflict_receipt"
	if _full_loop_validate_release_candidates test/repo "$conflict_source_json" \
		"$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" v1.2.5 "$conflict_tag_commit" >/dev/null 2>&1; then
		printf 'FAIL published reconciliation accepted an empty receipt\n'
		exit 1
	fi
	if _full_loop_persist_release_success test/repo "$conflict_release_path" "$conflict_source_json" \
		90 1111111111111111111111111111111111111111 "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" \
		>/dev/null 2>&1; then
		printf 'FAIL published reconciliation replaced an empty receipt\n'
		exit 1
	fi
	[[ ! -s "$conflict_receipt" ]]
	printf '%s\n' "$_FULL_LOOP_RELEASE_NOT_REQUESTED" >"$conflict_receipt"
	cp "$conflict_receipt" "${TEST_ROOT}/receipt-conflict-original.status"
	_full_loop_validate_release_candidates test/repo "$conflict_source_json"
	_full_loop_validate_release_candidates test/repo "$conflict_source_json" \
		"$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" v1.2.5 "$conflict_tag_commit"
	_full_loop_persist_release_success test/repo "$conflict_release_path" "$conflict_source_json" \
		90 1111111111111111111111111111111111111111 "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED"
	cmp -s "$conflict_receipt" "${TEST_ROOT}/receipt-conflict-original.status"
	grep -qx "$_FULL_LOOP_RELEASE_NOT_REQUESTED" "$conflict_receipt"
	grep -qx "$_FULL_LOOP_RELEASE_SUPERSEDED" \
		"${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-88.status"
	grep -qx "$_FULL_LOOP_RELEASE_PUBLISHED" \
		"${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-90.status"
	conflict_evidence=$(_full_loop_release_evidence_path test/repo 89 receipt-conflict)
	jq -e --arg tag_commit "$conflict_tag_commit" '
		.evidence_type == "published-aggregate-terminal-receipt-conflict"
		and .status == "receipt-conflict" and .pr_number == 89 and .aggregate_pr == 90
		and .preserved_receipt_status == "not-requested" and .release_commit == $tag_commit
		and (.terminal_cleanup_evidence | not)
	' "$conflict_evidence" >/dev/null
	cp "$conflict_evidence" "${TEST_ROOT}/receipt-conflict-original.json"
	_full_loop_validate_release_candidates test/repo "$conflict_source_json" \
		"$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" v1.2.5 "$conflict_tag_commit"
	_full_loop_persist_release_success test/repo "$conflict_release_path" "$conflict_source_json" \
		90 1111111111111111111111111111111111111111 "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED"
	cmp -s "$conflict_receipt" "${TEST_ROOT}/receipt-conflict-original.status"
	cmp -s "$conflict_evidence" "${TEST_ROOT}/receipt-conflict-original.json"
	_full_loop_validate_release_candidates test/repo "$conflict_source_json" \
		"$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" v1.2.5 "$conflict_tag_commit"
	_full_loop_persist_release_success test/repo "$conflict_release_path" "$conflict_source_json" \
		90 1111111111111111111111111111111111111111 "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED"
	grep -qx "$_FULL_LOOP_RELEASE_SUPERSEDED" "$conflict_receipt"
	jq -e --arg tag_commit "$conflict_tag_commit" '
		.status == "superseded" and .pr_number == 89 and .aggregate_pr == 90
		and .release_commit == $tag_commit
	' "${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-89.aggregate.json" >/dev/null
	_full_loop_persist_release_success test/repo "$conflict_release_path" "$conflict_source_json" \
		90 1111111111111111111111111111111111111111 "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED"
	grep -qx "$_FULL_LOOP_RELEASE_SUPERSEDED" "$conflict_receipt"
	conflicting_source_json=$(jq '.aggregated_sources[0].merge = "5555555555555555555555555555555555555555"' \
		<<<"$conflict_source_json")
	if _full_loop_validate_release_candidates test/repo "$conflicting_source_json" \
		"$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" v1.2.5 "$conflict_tag_commit" >/dev/null 2>&1; then
		printf 'FAIL conflicting receipt-conflict replay replaced immutable evidence\n'
		exit 1
	fi
)
printf 'PASS published aggregate reconciliation repairs only authorization-bound terminal no-release receipts\n'

(
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/future-release-receipts"
	# shellcheck source=../full-loop-helper-state.sh
	source "${SCRIPT_DIR}/full-loop-helper-state.sh"
	future_release_path="${TEST_ROOT}/future-release"
	mkdir -p "$future_release_path"
	printf '1.2.6\n' >"${future_release_path}/VERSION"
	future_tag_commit="6666666666666666666666666666666666666666"
	future_source_json=$(jq -cn '
		{source_pr:92,source_merge:"7777777777777777777777777777777777777777",
		 aggregated_sources:[{pr:91,merge:"8888888888888888888888888888888888888888"}]}
	')
	git() {
		local args="$*"
		case "$args" in
		*"rev-parse refs/tags/v1.2.6^{commit}"*) printf '%s\n' "$future_tag_commit" ;;
		*) return 1 ;;
		esac
		return 0
	}
	full_loop_update_cleanup_release_status() {
		return 0
	}
	_full_loop_write_release_receipt test/repo 91 "$_FULL_LOOP_RELEASE_NOT_REQUESTED"
	_full_loop_write_release_receipt test/repo 92 "$_FULL_LOOP_RELEASE_NOT_REQUESTED"
	_full_loop_validate_release_candidates test/repo "$future_source_json"
	_full_loop_persist_release_success test/repo "$future_release_path" "$future_source_json" \
		92 7777777777777777777777777777777777777777
	grep -qx "$_FULL_LOOP_RELEASE_SUPERSEDED" \
		"${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-91.status"
	grep -qx "$_FULL_LOOP_RELEASE_PUBLISHED" \
		"${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-92.status"
	jq -e --arg tag_commit "$future_tag_commit" '
		.status == "superseded" and .pr_number == 91 and .aggregate_pr == 92
		and .release_commit == $tag_commit
	' "${AIDEVOPS_FULL_LOOP_RECEIPT_DIR}/test_repo-91.aggregate.json" >/dev/null
)
printf 'PASS a later authorized release includes merged no-release PRs without renewed consent\n'

(
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="${TEST_ROOT}/direct-authorized-reconcile-receipts"
	# shellcheck source=../full-loop-helper-state.sh
	source "${SCRIPT_DIR}/full-loop-helper-state.sh"
	direct_release_path="${TEST_ROOT}/direct-authorized-reconcile-release"
	direct_cleanup_log="${TEST_ROOT}/direct-authorized-reconcile-cleanup.log"
	direct_source_merge="9999999999999999999999999999999999999999"
	direct_tag_commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	mkdir -p "$direct_release_path"
	printf '1.2.7\n' >"${direct_release_path}/VERSION"
	direct_source_json=$(jq -cn --arg source_merge "$direct_source_merge" \
		'{source_pr:93,source_merge:$source_merge,aggregated_sources:[]}')
	git() {
		local args="$*"
		case "$args" in
		*"rev-parse refs/tags/v1.2.7^{commit}"*) printf '%s\n' "$direct_tag_commit" ;;
		*) return 1 ;;
		esac
		return 0
	}
	full_loop_update_cleanup_release_status() {
		local repo="$1"
		local pr_number="$2"
		local release_status="$3"
		printf '%s %s %s\n' "$repo" "$pr_number" "$release_status" >"$direct_cleanup_log"
		return 0
	}
	direct_receipt=$(_full_loop_release_receipt_path test/repo 93)
	_full_loop_write_release_receipt test/repo 93 "$_FULL_LOOP_RELEASE_NOT_REQUESTED"
	cp "$direct_receipt" "${TEST_ROOT}/direct-authorized-reconcile-original.status"
	if _full_loop_validate_release_candidates test/repo "$direct_source_json" \
		"$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" v1.2.7 "$direct_tag_commit" >/dev/null 2>&1; then
		printf 'FAIL unbound published reconciliation accepted a direct no-release source\n'
		exit 1
	fi
	if _full_loop_persist_release_success test/repo "$direct_release_path" "$direct_source_json" \
		93 "$direct_source_merge" "$_FULL_LOOP_RELEASE_RECONCILE_PUBLISHED" >/dev/null 2>&1; then
		printf 'FAIL unbound published reconciliation replaced a direct no-release receipt\n'
		exit 1
	fi
	cmp -s "$direct_receipt" "${TEST_ROOT}/direct-authorized-reconcile-original.status"
	_full_loop_validate_release_candidates test/repo "$direct_source_json" \
		"$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" v1.2.7 "$direct_tag_commit"
	_full_loop_persist_release_success test/repo "$direct_release_path" "$direct_source_json" \
		93 "$direct_source_merge" "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED"
	grep -qx "$_FULL_LOOP_RELEASE_PUBLISHED" "$direct_receipt"
	grep -qx "test/repo 93 ${_FULL_LOOP_RELEASE_PUBLISHED}" "$direct_cleanup_log"
	_full_loop_validate_release_candidates test/repo "$direct_source_json" \
		"$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED" v1.2.7 "$direct_tag_commit"
	_full_loop_persist_release_success test/repo "$direct_release_path" "$direct_source_json" \
		93 "$direct_source_merge" "$_FULL_LOOP_RELEASE_RECONCILE_AUTHORIZED"
)
printf 'PASS explicit publication intent reconciles a direct no-release source exactly once\n'

legacy_source_json_file="${TEST_ROOT}/legacy-source.json"
(
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.4" ]] || return 1
		printf '%s\n' \
			'Release v1.2.4' \
			'' \
			'Aidevops-Version: 1.2.4' \
			'Aidevops-Source-PR: 90' \
			'Aidevops-Source-Merge: 1111111111111111111111111111111111111111'
		return 0
	}
	_full_loop_release_source_merge_trailer_values() {
		local source_merge="$1"
		local trailer_key="$2"
		[[ "$source_merge" == "1111111111111111111111111111111111111111" ]] || return 1
		case "$trailer_key" in
		Aidevops-Release-Aggregator-PR) printf '90\n' ;;
		Aidevops-Release-Aggregates) printf '89@2222222222222222222222222222222222222222\n' ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_source_json_from_tag v1.2.4
) >"$legacy_source_json_file"
legacy_source_json=$(<"$legacy_source_json_file")
if ! jq -e '.source_pr == 90
	and .source_merge == "1111111111111111111111111111111111111111"
	and .aggregated_sources == [{"pr":89,"merge":"2222222222222222222222222222222222222222"}]' \
	<<<"$legacy_source_json" >/dev/null; then
	printf 'FAIL signed source merge did not reconstruct an omitted aggregate list\n'
	exit 1
fi
printf 'PASS signed source merge reconstructs an omitted redundant tag manifest\n'
