#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Canonical Recovery Rebase -- rebase state preservation and release tag fetch
# =============================================================================
# Rebase state fingerprinting, preservation/restoration of rebase refs and
# objects, release tag fetch, bootstrap identity audit and ffl_block.
#
# Usage: source "${SCRIPT_DIR}/canonical-recovery-rebase.sh"
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_CANONICAL_RECOVERY_REBASE_LIB_LOADED:-}" ]] && return 0
_CANONICAL_RECOVERY_REBASE_LIB_LOADED=1

rebase_state_fingerprint() {
	local state_dir="$1"
	local fingerprint=""
	fingerprint=$(
		python3 - "$state_dir" <<'PY'
import hashlib
import os
import stat
import sys

state_dir = sys.argv[1]
root_stat = os.lstat(state_dir)
if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
    raise RuntimeError("rebase state root is not a plain directory")

digest = hashlib.sha256()


def add_field(value):
    data = value.encode("utf-8", "surrogateescape")
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)


def walk(path, relative):
    for entry in sorted(os.scandir(path), key=lambda item: item.name):
        entry_relative = os.path.join(relative, entry.name) if relative else entry.name
        entry_stat = entry.stat(follow_symlinks=False)
        if stat.S_ISDIR(entry_stat.st_mode) and not stat.S_ISLNK(entry_stat.st_mode):
            digest.update(b"D")
            add_field(entry_relative)
            walk(entry.path, entry_relative)
        elif stat.S_ISREG(entry_stat.st_mode):
            digest.update(b"F")
            add_field(entry_relative)
            digest.update(entry_stat.st_size.to_bytes(8, "big"))
            with open(entry.path, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
        else:
            raise RuntimeError("rebase state contains a non-regular entry")


walk(state_dir, "")
print(digest.hexdigest())
PY
	) || return 1
	printf '%s\n' "$fingerprint"
	return 0
}

rebase_marker_fingerprint() {
	local state_dir="$1"
	local rebase_head_path="$2"
	local state_hash=""
	local rebase_head_hash="absent"
	state_hash=$(rebase_state_fingerprint "$state_dir") || return 1
	if [[ -f "$rebase_head_path" ]]; then
		rebase_head_hash=$("$REAL_GIT" hash-object "$rebase_head_path") || return 1
	elif [[ -e "$rebase_head_path" ]]; then
		return 1
	fi
	printf '%s\n%s\n' "$state_hash" "$rebase_head_hash" | "$REAL_GIT" hash-object --stdin
	return 0
}

rebase_state_latest_mtime() {
	local state_dir="$1"
	local rebase_head_path="$2"
	local latest_mtime=""
	latest_mtime=$(
		python3 - "$state_dir" "$rebase_head_path" <<'PY'
import os
import sys

state_dir, rebase_head_path = sys.argv[1:]
paths = [state_dir]
for root, dirs, files in os.walk(state_dir):
    paths.extend(os.path.join(root, name) for name in dirs)
    paths.extend(os.path.join(root, name) for name in files)
if os.path.exists(rebase_head_path):
    paths.append(rebase_head_path)
print(int(max(os.lstat(path).st_mtime for path in paths)))
PY
	) || return 1
	printf '%s\n' "$latest_mtime"
	return 0
}

preserve_rebase_commit_ref() {
	local repo="$1"
	local issue="$2"
	local namespace="$3"
	local commitish="$4"
	local commit=""
	local existing_commit=""
	local preservation_ref=""
	[[ "$commitish" =~ ^[0-9a-fA-F]{4,40}$ ]] || return 1
	commit=$("$REAL_GIT" -C "$repo" rev-parse --verify "${commitish}^{commit}" 2>/dev/null) || return 1
	[[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
	preservation_ref="refs/aidevops/canonical-recovery/issue-${issue}/${namespace}/${commit}"
	existing_commit=$("$REAL_GIT" -C "$repo" rev-parse --verify "${preservation_ref}^{commit}" 2>/dev/null || true)
	[[ -z "$existing_commit" || "$existing_commit" == "$commit" ]] || return 1
	if [[ -z "$existing_commit" ]]; then
		"$REAL_GIT" -C "$repo" update-ref "$preservation_ref" "$commit" \
			"0000000000000000000000000000000000000000" || return 1
	fi
	[[ "$("$REAL_GIT" -C "$repo" rev-parse --verify "${preservation_ref}^{commit}")" == "$commit" ]] || return 1
	return 0
}

preserve_rebase_sequence_refs() {
	local repo="$1"
	local issue="$2"
	local namespace="$3"
	local sequence_file="$4"
	local sequence_action=""
	local sequence_commit=""
	local sequence_rest=""
	[[ -f "$sequence_file" ]] || return 1
	while read -r sequence_action sequence_commit sequence_rest ||
		[[ -n "$sequence_action" || -n "$sequence_commit" || -n "$sequence_rest" ]]; do
		case "$sequence_action" in
		"" | \#* | exec | x | break | b | label | l | reset | t | update-ref | u | noop)
			continue
			;;
		pick | p | reword | r | edit | e | squash | s | drop | d)
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$sequence_commit" || return 1
			;;
		fixup | f)
			if [[ "$sequence_commit" == "-C" || "$sequence_commit" == "-c" ]]; then
				read -r sequence_commit _ <<<"$sequence_rest"
			fi
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$sequence_commit" || return 1
			;;
		merge | m)
			if [[ "$sequence_commit" == "-C" || "$sequence_commit" == "-c" ]]; then
				read -r sequence_commit _ <<<"$sequence_rest"
				preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$sequence_commit" || return 1
			fi
			;;
		*)
			return 1
			;;
		esac
	done <"$sequence_file"
	return 0
}

preserve_rewritten_rebase_refs() {
	local repo="$1"
	local issue="$2"
	local namespace="$3"
	local state_dir="$4"
	local extra=""
	local new_commit=""
	local old_commit=""
	local pending_commit=""
	if [[ -f "${state_dir}/rewritten-list" ]]; then
		while read -r old_commit new_commit extra ||
			[[ -n "$old_commit" || -n "$new_commit" || -n "$extra" ]]; do
			[[ -n "$old_commit" && -n "$new_commit" && -z "$extra" ]] || return 1
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$old_commit" || return 1
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$new_commit" || return 1
		done <"${state_dir}/rewritten-list"
	fi
	if [[ -f "${state_dir}/rewritten-pending" ]]; then
		while read -r pending_commit extra || [[ -n "$pending_commit" || -n "$extra" ]]; do
			[[ -n "$pending_commit" && -z "$extra" ]] || return 1
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$pending_commit" || return 1
		done <"${state_dir}/rewritten-pending"
	fi
	return 0
}

preserve_rebase_object_file_refs() {
	local repo="$1"
	local issue="$2"
	local namespace="$3"
	local object_file="$4"
	local object_line=""
	local object_token=""
	local -a object_tokens=()
	[[ -f "$object_file" ]] || return 0
	while IFS= read -r object_line || [[ -n "$object_line" ]]; do
		object_tokens=()
		read -r -a object_tokens <<<"$object_line"
		for object_token in "${object_tokens[@]}"; do
			[[ "$object_token" =~ ^[0-9a-fA-F]{4,40}$ ]] || continue
			[[ "$object_token" =~ ^0+$ ]] && continue
			preserve_rebase_commit_ref "$repo" "$issue" "$namespace" "$object_token" || return 1
		done
	done <"$object_file"
	return 0
}

restore_deleted_rebase_head() {
	local repo="$1"
	local rebase_head_path="$2"
	local stopped_sha="$3"
	local current_rebase_head=""
	if [[ -e "$rebase_head_path" ]]; then
		[[ -f "$rebase_head_path" ]] || return 1
		current_rebase_head=$("$REAL_GIT" -C "$repo" rev-parse --verify 'REBASE_HEAD^{commit}' 2>/dev/null || true)
		[[ -n "$current_rebase_head" ]] || return 1
		return 0
	fi
	"$REAL_GIT" -C "$repo" update-ref REBASE_HEAD "$stopped_sha" "$NULL_SHA1" || return 1
	[[ "$("$REAL_GIT" -C "$repo" rev-parse --verify 'REBASE_HEAD^{commit}')" == "$stopped_sha" ]] || return 1
	return 0
}

restore_deleted_rebase_head_copy() {
	local repo="$1"
	local rebase_head_path="$2"
	local stopped_sha="$3"
	local quarantine_head_path="$4"
	restore_deleted_rebase_head "$repo" "$rebase_head_path" "$stopped_sha" || return 1
	rm -f "$quarantine_head_path" || return 1
	return 0
}

restore_quarantined_rebase_state() {
	local repo="$1"
	local state_dir="$2"
	local rebase_head_path="$3"
	local quarantine_dir="$4"
	local quarantine_head_path="$5"
	local cleanup_kind="$6"
	local stopped_sha="$7"
	[[ -d "$quarantine_dir" && ! -e "$state_dir" ]] || return 1
	if [[ "$cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		[[ -f "$quarantine_head_path" ]] || return 1
	fi
	mv "$quarantine_dir" "$state_dir" || return 1
	if [[ "$cleanup_kind" == "$ABANDONED_REBASE_KIND" ]]; then
		if ! restore_deleted_rebase_head "$repo" "$rebase_head_path" "$stopped_sha"; then
			mv "$state_dir" "$quarantine_dir" >/dev/null 2>&1 || true
			return 1
		fi
		rm -f "$quarantine_head_path" || return 1
	fi
	return 0
}

# Fetch only the release tag required by the post-update source-access stage.
# The caller has already pinned and validated the canonical remote. Existing
# refs are never rewritten; source-access owns signature and ancestry checks.
fetch_aidevops_release_tag() {
	local repo="$1"
	local remote="$2"
	local version=""
	local tag_ref=""

	[[ -r "$repo/VERSION" ]] || return 1
	IFS= read -r version <"$repo/VERSION" || return 1
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	tag_ref="refs/tags/v${version}"
	if "$REAL_GIT" -C "$repo" show-ref --verify --quiet "$tag_ref"; then
		return 0
	fi
	if ! "$REAL_GIT" -C "$repo" fetch --no-tags "$remote" \
		"${tag_ref}:${tag_ref}" >/dev/null 2>&1; then
		return 1
	fi
	"$REAL_GIT" -C "$repo" show-ref --verify --quiet "$tag_ref"
	return $?
}

audit_bootstrap_identity() {
	local repo="$1"
	local expected_slug="$2"
	local canonical_remote="$3"
	local audit_helper="${SCRIPT_DIR}/audit-log-helper.sh"
	local recovery_audit_file="${HOME}/.aidevops/logs/canonical-recovery-audit.jsonl"

	[[ -x "$audit_helper" ]] || {
		printf 'BLOCKED: tamper-evident audit helper is unavailable\n' >&2
		return 1
	}
	AUDIT_LOG_FILE="$recovery_audit_file" "$audit_helper" verify --quiet || {
		printf 'BLOCKED: audit chain verification failed\n' >&2
		return 1
	}
	AUDIT_LOG_FILE="$recovery_audit_file" AUDIT_QUIET=true "$audit_helper" log \
		operation.verify "Canonical bootstrap registration identity verified" \
		--detail "repo=${repo}" --detail "operation=${VERIFY_BOOTSTRAP_CMD}" \
		--detail "remote=${canonical_remote}" --detail "expected_slug=${expected_slug}" >/dev/null || {
		printf 'BLOCKED: bootstrap verification audit record could not be written\n' >&2
		return 1
	}
	return 0
}
