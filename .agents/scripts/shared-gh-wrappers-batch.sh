#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

[[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] && set -euo pipefail
[[ -n "${_SHARED_GH_WRAPPERS_BATCH_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_BATCH_LOADED=1

_gh_write_batch_private_temp() {
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	[[ -d "$temp_root" ]] || {
		printf '[aidevops][gh-batch][BLOCK] AIDEVOPS_TEMP_DIR is unavailable\n' >&2
		return 1
	}
	local previous_umask path
	previous_umask=$(umask)
	umask 077
	path=$(mktemp "${temp_root%/}/gh-write-batch.${1}.XXXXXX") || {
		umask "$previous_umask"
		return 1
	}
	umask "$previous_umask"
	printf '%s\n' "$path"
	return 0
}

_gh_write_batch_execute() {
	local prepared="$1" receipt="$2"
	python3 "${_SHARED_GH_WRAPPERS_DIR}/gh-write-batch.py" execute \
		--prepared "$prepared" --receipt "$receipt"
	return $?
}

gh_write_batch() {
	_gh_wrapper_enter_cleanup_scope
	local manifest="${1:-}"
	[[ -n "$manifest" && $# -eq 1 ]] || {
		printf 'Usage: gh-write-helper.sh batch MANIFEST.json\n' >&2
		return 2
	}
	command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
		printf '[aidevops][gh-batch][BLOCK] python3 and jq are required\n' >&2
		return 2
	}
	# This local, no-network gate must precede privacy probes and every other
	# possible GitHub call. The PATH shim rechecks immediately before each call.
	_gh_secondary_cooldown_preflight write || return $?

	local prepared receipt cleanup_cmd temp_root
	temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	prepared=$(_gh_write_batch_private_temp prepared) || return 1
	receipt=$(_gh_write_batch_private_temp receipt) || {
		rm -f -- "$prepared"
		return 1
	}
	printf -v cleanup_cmd 'rm -f -- %q' "$prepared"
	push_cleanup "$cleanup_cmd"
	if ! python3 "${_SHARED_GH_WRAPPERS_DIR}/gh-write-batch.py" prepare \
		--manifest "$manifest" --temp-root "$temp_root" \
		--signature-helper "${_SHARED_GH_WRAPPERS_DIR}/gh-signature-helper.sh" \
		--output "$prepared"; then
		rm -f -- "$receipt"
		return 1
	fi

	local repo body_file body_sha actual_sha title
	local -a privacy_args
	repo=$(jq -r '.repository' "$prepared") || return 1
	privacy_args=(--repo "$repo")
	while IFS=$'\t' read -r body_file body_sha; do
		[[ -n "$body_file" ]] || continue
		printf -v cleanup_cmd 'rm -f -- %q' "$body_file"
		push_cleanup "$cleanup_cmd"
		actual_sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$body_file") || return 1
		if [[ "$actual_sha" != "$body_sha" ]]; then
			python3 "${_SHARED_GH_WRAPPERS_DIR}/gh-write-batch.py" reject \
				--prepared "$prepared" --receipt "$receipt" --reason body_integrity_failed >/dev/null 2>&1 || true
			printf '[aidevops][gh-batch][BLOCK] body integrity validation failed; receipt=%s\n' "$receipt" >&2
			return 1
		fi
		privacy_args+=(--body-file "$body_file")
	done < <(jq -r '.operations[] | select(.body_file != null) | [.body_file,.body_sha256] | @tsv' "$prepared")
	while IFS= read -r title; do
		[[ -n "$title" ]] && privacy_args+=(--title "$title")
	done < <(jq -r '.operations[] | select(.title != null) | .title' "$prepared")
	if ! _gh_guard_public_write_args "${privacy_args[@]}"; then
		python3 "${_SHARED_GH_WRAPPERS_DIR}/gh-write-batch.py" reject \
			--prepared "$prepared" --receipt "$receipt" --reason privacy_validation_failed >/dev/null 2>&1 || true
		printf '[aidevops][gh-batch][BLOCK] privacy validation failed; receipt=%s\n' "$receipt" >&2
		return 1
	fi

	gh_record_call graphql gh_write_batch 2>/dev/null || true
	local rc=0
	_gh_with_timeout write _gh_write_batch_execute "$prepared" "$receipt" || rc=$?
	printf '[aidevops][gh-batch] receipt=%s\n' "$receipt" >&2
	return "$rc"
}
