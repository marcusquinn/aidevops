#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by test-full-loop-release-reconcile.sh; shares its fixtures and state.

# Direct execution must initialize the shared fixtures and preceding fragments.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	exec bash "$(dirname "${BASH_SOURCE[0]}")/test-full-loop-release-reconcile.sh" "$@"
fi

legacy_found_tag_file="${TEST_ROOT}/legacy-found-tag.txt"
(
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet"*) return 0 ;;
		*" for-each-ref "*)
			printf 'v1.2.4\x1f90\x1f1111111111111111111111111111111111111111\x1f\n'
			;;
		*" log --all --fixed-strings "*)
			printf '1111111111111111111111111111111111111111\n'
			;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.4" ]] || return 1
		printf '%s\n' \
			'Release v1.2.4' \
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
	_full_loop_release_verify_tag_provenance() {
		local repo="$1"
		local tag_name="$2"
		[[ "$repo" == "test/repo" && "$tag_name" == "v1.2.4" ]]
		return $?
	}
	_version_manager_classify_remote_tag() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.4" ]] || return 1
		_VERSION_MANAGER_REMOTE_TAG_STATE="$_VERSION_MANAGER_TAG_STATE_MATCHING"
		return 0
	}
	_full_loop_release_find_tag_for_pr test/repo 89 || exit 1
	printf '%s\n' "$_FULL_LOOP_RELEASE_FOUND_TAG"
) >"$legacy_found_tag_file"
legacy_found_tag=$(<"$legacy_found_tag_file")
if [[ "$legacy_found_tag" != "v1.2.4" ]]; then
	printf 'FAIL included source PR could not discover its transitively bound tag\n'
	exit 1
fi
printf 'PASS included source PR discovers its transitively bound release tag\n'

candidate_tags_file="${TEST_ROOT}/candidate-tags.txt"
(
	git() {
		local args="$*"
		case "$args" in
		*" for-each-ref "*)
			printf '%b\n' \
				'v2.0.0\x1f890\x1faaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x1f' \
				'v1.9.0\x1f89\x1fbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\x1f' \
				'v1.8.0\x1f90\x1fcccccccccccccccccccccccccccccccccccccccc\x1f890@dddddddddddddddddddddddddddddddddddddddd' \
				'v1.7.0\x1f90\x1feeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\x1f89@ffffffffffffffffffffffffffffffffffffffff'
			;;
		*" log --all --fixed-strings "*) return 0 ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_candidate_tags_for_pr 89
) >"$candidate_tags_file"
candidate_tags=$(<"$candidate_tags_file")
if [[ "$candidate_tags" != $'v1.9.0\nv1.7.0' ]]; then
	printf 'FAIL one-pass trailer index did not preserve exact newest-first candidates\n'
	exit 1
fi
printf 'PASS one-pass trailer index preserves exact newest-first candidates\n'

fallback_candidate_tags_file="${TEST_ROOT}/candidate-tags-fallback.txt"
(
	git() {
		local args="$*"
		case "$args" in
		*"%(refname:short)%00%(contents)%00"*)
			printf 'v2.0.0\0Aidevops-Source-PR: 89\0\n'
			printf 'v1.9.0\0Aidevops-Aggregated-Source: 89@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\0\n'
			printf 'v1.8.0\0Aidevops-Source-PR: 90\nAidevops-Source-Merge: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\0\n'
			;;
		*" for-each-ref "*)
			printf '%b\n' \
				'v2.0.0\x1f\x1f\x1f' \
				'v1.9.0\x1f\x1f\x1f' \
				'v1.8.0\x1f\x1f\x1f'
			;;
		*" log --all --fixed-strings "*)
			printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
			;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_candidate_tags_for_pr 89
) >"$fallback_candidate_tags_file"
fallback_candidate_tags=$(<"$fallback_candidate_tags_file")
if [[ "$fallback_candidate_tags" != $'v2.0.0\nv1.9.0\nv1.8.0' ]]; then
	printf 'FAIL empty trailer index did not build an exact raw-body candidate index\n'
	exit 1
fi
printf 'PASS empty trailer index covers direct, aggregate, and legacy raw-body candidates\n'

fallback_find_tag_file="${TEST_ROOT}/find-tag-fallback.txt"
(
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet"*) return 0 ;;
		*"%(refname:short)%00%(contents)%00"*)
			printf 'v2.0.0\0Aidevops-Source-PR: 89\0\n'
			;;
		*" for-each-ref "*)
			printf '%b\n' 'v2.0.0\x1f\x1f\x1f'
			;;
		*" log --all --fixed-strings "*) return 0 ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v2.0.0" ]] || return 1
		printf '%s\n' 'Aidevops-Source-PR: 89'
		return 0
	}
	_full_loop_release_source_json_from_tag() {
		local tag_name="$1"
		[[ "$tag_name" == "v2.0.0" ]] || return 1
		printf '%s\n' '{"source_pr":89,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'
		return 0
	}
	_full_loop_release_verify_candidate_tag_provenance() { return 0; }
	_full_loop_release_find_tag_for_pr test/repo 89 || exit 1
	printf '%s\n' "$_FULL_LOOP_RELEASE_FOUND_TAG"
) >"$fallback_find_tag_file"
fallback_find_tag=$(<"$fallback_find_tag_file")
if [[ "$fallback_find_tag" != "v2.0.0" ]]; then
	printf 'FAIL full tag fallback did not recover a body-parseable signed tag\n'
	exit 1
fi
printf 'PASS full tag fallback recovers a body-parseable signed tag\n'

malformed_tag_log="${TEST_ROOT}/malformed-tag-timing.log"
if (
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet"*) return 0 ;;
		*"%(refname:short)%00%(contents)%00"*)
			printf 'v2.0.1\0Aidevops-Source-PR: 89\0\n'
			;;
		*" for-each-ref "*) printf '%b\n' 'v2.0.1\x1f\x1f\x1f' ;;
		*" log --all --fixed-strings "*) return 0 ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v2.0.1" ]] || return 1
		printf '%s\n' 'Aidevops-Source-PR: 89'
		return 0
	}
	_full_loop_release_source_json_from_tag() {
		local tag_name="$1"
		[[ "$tag_name" == "v2.0.1" ]] || return 1
		return 1
	}
	_full_loop_release_find_tag_for_pr test/repo 89 2>"$malformed_tag_log"
); then
	printf 'FAIL malformed matching tag was treated as a safe no-match\n'
	exit 1
fi
if ! grep -q 'phase=release-tag-provenance-reconstruction .*result=invalid' "$malformed_tag_log"; then
	printf 'FAIL malformed tag diagnostics did not identify provenance reconstruction\n'
	exit 1
fi
printf 'PASS malformed matching tags fail closed with phase diagnostics\n'

large_scan_log="${TEST_ROOT}/large-scan.log"
large_body_log="${TEST_ROOT}/large-body.log"
large_reconstruction_log="${TEST_ROOT}/large-reconstruction.log"
large_timing_log="${TEST_ROOT}/large-timing.log"
stale_receipt="${TEST_ROOT}/receipts/test_repo-89.status"
printf '%s\n' "$_FULL_LOOP_PHASE_FAILED" >"$stale_receipt"
(
	_full_loop_resolve_repo() {
		local requested_repo="$1"
		printf '%s\n' "${requested_repo:-test/repo}"
		return 0
	}
	_full_loop_release_receipt_path() {
		local repo="$1"
		local pr_number="$2"
		printf '%s/receipts/%s-%s.status\n' "$TEST_ROOT" "${repo//\//_}" "$pr_number"
		return 0
	}
	git() {
		local args="$*"
		local tag_number=0
		case "$args" in
		*" fetch origin --tags --quiet"*) return 0 ;;
		*"%(refname:short)%00%(contents)%00"*)
			printf 'raw-index\n' >>"$large_scan_log"
			for ((tag_number = 500; tag_number >= 1; tag_number--)); do
				printf 'v9.%s.0\0Release without requested provenance\0\n' "$tag_number"
			done
			;;
		*" for-each-ref "*)
			for ((tag_number = 500; tag_number >= 1; tag_number--)); do
				printf 'v9.%s.0\x1f\x1f\x1f\n' "$tag_number"
			done
			;;
		*" log --all --fixed-strings "*) return 0 ;;
		*" tag --list "*)
			printf 'unexpected-full-list\n' >>"$large_scan_log"
			return 1
			;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_tag_body() {
		local tag_name="$1"
		printf '%s\n' "$tag_name" >>"$large_body_log"
		return 1
	}
	_full_loop_release_source_json_from_tag() {
		local tag_name="$1"
		printf '%s\n' "$tag_name" >>"$large_reconstruction_log"
		return 1
	}
	for lookup_mode in status reconcile status; do
		lookup_rc=0
		AIDEVOPS_FULL_LOOP_REPO=test/repo \
			_full_loop_release_existing_command "$lookup_mode" 89 >/dev/null 2>>"$large_timing_log" || lookup_rc=$?
		[[ "$lookup_rc" -eq 2 ]] || exit 1
	done
)
if [[ "$(grep -c '^raw-index$' "$large_scan_log")" -ne 3 ]] ||
	grep -q '^unexpected-full-list$' "$large_scan_log" ||
	[[ -e "$large_body_log" || -e "$large_reconstruction_log" ]]; then
	printf 'FAIL repeated large no-match lookups reconstructed historical tag provenance\n'
	exit 1
fi
if [[ "$(grep -c 'phase=release-tag-candidate-index state=finish .*items=0$' "$large_timing_log")" -ne 3 ]]; then
	printf 'FAIL repeated status/reconcile lookups did not report bounded zero-candidate scans\n'
	exit 1
fi
printf 'PASS repeated status/reconcile no-match lookups use one raw index and zero reconstructions across 500 tags\n'

if (
	git() {
		local args="$*"
		case "$args" in
		*" for-each-ref "*) return 1 ;;
		*" log --all --fixed-strings "*) return 0 ;;
		esac
		return 1
	}
	_full_loop_release_candidate_tags_for_pr 89
); then
	printf 'FAIL tag enumeration failure was treated as an empty candidate set\n'
	exit 1
fi
printf 'PASS tag enumeration failure remains fail closed\n'

if (
	git() {
		local args="$*"
		case "$args" in
		*" fetch origin --tags --quiet"*) return 0 ;;
		*" for-each-ref "*)
			printf 'v1.2.5\x1f90\x1f1111111111111111111111111111111111111111\x1f89@2222222222222222222222222222222222222222\n'
			;;
		*" log --all --fixed-strings "*) return 0 ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_release_tag_body() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.5" ]] || return 1
		printf '%s\n' 'Aidevops-Aggregated-Source: 89@2222222222222222222222222222222222222222'
		return 0
	}
	_full_loop_release_source_json_from_tag() {
		local tag_name="$1"
		[[ "$tag_name" == "v1.2.5" ]] || return 1
		printf '%s\n' '{"source_pr":90,"source_merge":"1111111111111111111111111111111111111111","aggregated_sources":[]}'
		return 0
	}
	_full_loop_release_find_tag_for_pr test/repo 89
); then
	printf 'FAIL textual and reconstructed provenance disagreement was accepted\n'
	exit 1
fi
printf 'PASS textual and reconstructed provenance disagreement remains fail closed\n'
