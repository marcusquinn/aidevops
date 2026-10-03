#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# review-evidence-helper.sh — Build immutable evidence bundles for review policies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_ROOT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
REVIEW_BODY_FILE=""
REVIEW_PATHS_FILE=""
REVIEW_AUX_FILE=""
REVIEW_BINARY_PATHS_FILE=""
REVIEW_BINARY_METADATA_FILE=""
REVIEW_LIMITS_FILE=""
REVIEW_PACKET_FILE=""
REVIEW_BLIND=false
BLIND_CONTRACT="aidevops.acceptance-review/v1"
BLIND_SCHEMA="aidevops.review-blind-packet/v1"
BLIND_MAX_FILE_BYTES=200000
BLIND_IDS=" "

_review_cleanup() {
	[[ -z "$REVIEW_LIMITS_FILE" ]] || rm -f "$REVIEW_LIMITS_FILE"
	[[ -z "$REVIEW_PACKET_FILE" ]] || rm -f "$REVIEW_PACKET_FILE"
	[[ -z "$REVIEW_BODY_FILE" ]] || rm -f "$REVIEW_BODY_FILE"
	[[ -z "$REVIEW_PATHS_FILE" ]] || rm -f "$REVIEW_PATHS_FILE"
	[[ -z "$REVIEW_AUX_FILE" ]] || rm -f "$REVIEW_AUX_FILE"
	[[ -z "$REVIEW_BINARY_PATHS_FILE" ]] || rm -f "$REVIEW_BINARY_PATHS_FILE"
	[[ -z "$REVIEW_BINARY_METADATA_FILE" ]] || rm -f "$REVIEW_BINARY_METADATA_FILE"
	return 0
}

_review_usage() {
	cat <<'EOF'
Usage:
  review-evidence-helper.sh bundle local [--output FILE]
  review-evidence-helper.sh bundle branch [--base REF] [--output FILE]
  review-evidence-helper.sh bundle commit --commit REF [--output FILE]
  review-evidence-helper.sh bundle issue NUMBER [--repo OWNER/REPO] [--output FILE]
  review-evidence-helper.sh bundle pr NUMBER [--repo OWNER/REPO] [--output FILE]
  review-evidence-helper.sh blind build local|branch|commit [--base REF] [--commit REF]
      [--requirements FILE --requirements-source LABEL]
      [--amendments FILE --amendments-source LABEL]
      [--verification FILE] [--context PATH]... [--output FILE]
  review-evidence-helper.sh blind validate PACKET
  review-evidence-helper.sh blind check-result PACKET RESULT

The emitted Markdown bundle uses schema aidevops.review-evidence/v1. Git targets
contain complete text patches and SHA-256-bound metadata for binary changes, plus
a prompt-injection scan status and bundle digest. It never fetches, changes refs,
or invokes a reviewer.

Blind mode (opt-in) emits schema aidevops.review-blind-packet/v1 by allowlist:
criteria (one "ID: text" line each) with provenance, pinned identity, the patch,
final contents of changed files, named context files, head-bound verification
evidence and explicit coverage limits. Commit messages, issue/PR discussion,
prior verdicts and rationale are never selected; issue/PR targets are refused.
acceptance_identity binds contract, criteria, artifacts, verification and
coverage, so any change invalidates reuse. check-result validates a reviewer
table (| ID | satisfied/unmet/unverified | evidence | gap |) with exactly one
row per criterion; it exits 3 unless every criterion is satisfied.
EOF
	return 0
}

_review_die() {
	local message="$1"
	printf 'review-evidence: %s\n' "$message" >&2
	return 1
}

_review_require() {
	local command_name="$1"
	command -v "$command_name" >/dev/null 2>&1 || {
		_review_die "required command not found: ${command_name}"
		return 1
	}
	return 0
}

_review_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || {
		_review_die "target requires a Git repository"
		return 1
	}
	return 0
}

_review_validate_ref() {
	local ref="$1"
	git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null || {
		_review_die "Git ref does not resolve locally: ${ref}"
		return 1
	}
	return 0
}

_review_default_base() {
	local remote_head=""
	remote_head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
	if [[ -n "$remote_head" ]]; then
		printf '%s\n' "$remote_head"
		return 0
	fi
	if git show-ref --verify --quiet refs/remotes/origin/main; then
		printf '%s\n' 'origin/main'
		return 0
	fi
	if git show-ref --verify --quiet refs/remotes/origin/master; then
		printf '%s\n' 'origin/master'
		return 0
	fi
	_review_die "cannot resolve a remote default branch; pass --base REF"
	return 1
}

_review_validate_number() {
	local number="$1"
	[[ "$number" =~ ^[1-9][0-9]*$ ]] || {
		_review_die "issue/PR number must be a positive integer"
		return 1
	}
	return 0
}

_review_validate_repo_slug() {
	local repo_slug="$1"
	[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
		_review_die "issue/PR target requires explicit --repo OWNER/REPO"
		return 1
	}
	return 0
}

_review_sensitive_path() {
	local path="$1"
	case "/${path}" in
	*/.env | */.env.* | */credentials.json | */auth.json | *.pem | *.p12 | *.pfx | *.key | *.keystore)
		return 0
		;;
	esac
	return 1
}

_review_check_paths() {
	local paths_file="$1"
	local path=""
	while IFS= read -r -d '' path; do
		[[ -z "$path" ]] && continue
		if _review_sensitive_path "$path"; then
			_review_die "refusing security-sensitive path in review bundle: ${path}"
			return 1
		fi
	done <"$paths_file"
	return 0
}

_review_sha256() {
	local file="$1"
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 <"$file" | cut -d' ' -f1
		return 0
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum <"$file" | cut -d' ' -f1
		return 0
	fi
	_review_die "neither shasum nor sha256sum is available"
	return 1
}

_review_scan_status() {
	local file="$1"
	local scanner="${SCRIPT_DIR}/prompt-guard-helper.sh"
	local scan_output=""
	if [[ ! -x "$scanner" ]]; then
		printf '%s\n' 'unavailable'
		return 0
	fi
	scan_output=$("$scanner" scan-file "$file" 2>&1 || true)
	case "$scan_output" in
	*CLEAN*) printf '%s\n' 'clean' ;;
	*) printf '%s\n' 'flagged-untrusted-data' ;;
	esac
	return 0
}

_review_git_diff() {
	local repo_root="$1" range="$2"
	shift 2
	if [[ "$range" == commit:* ]]; then
		# One first-parent policy binds sensitive-path inventory, binary metadata
		# and text patches to the same tree comparison, including merge commits.
		git -C "$repo_root" show --format= --root --diff-merges=first-parent "${range#commit:}" "$@"
	else
		git -C "$repo_root" diff "$range" "$@"
	fi
	return $?
}

_review_is_binary_diff() {
	local repo_root="$1"
	local range="$2"
	local path="$3"
	local numstat=""
	numstat=$(_review_git_diff "$repo_root" "$range" --numstat --no-renames -- ":(literal)$path") || return 1
	[[ "$numstat" == $'-\t-\t'* ]]
}

_review_is_binary_untracked() {
	local repo_root="$1"
	local path="$2"
	local numstat=""
	numstat=$(git -C "$repo_root" diff --no-index --numstat -- /dev/null "$path" 2>/dev/null || true)
	[[ "$numstat" == $'-\t-\t'* ]]
}

_review_diff_status() {
	local repo_root="$1"
	local range="$2"
	local path="$3"
	_review_git_diff "$repo_root" "$range" --name-status --no-renames -- ":(literal)$path" | cut -f1
	return 0
}

_review_binary_metadata() {
	local repo_root="$1"
	local path="$2"
	local status="$3"
	local current_file="$4"
	local preferred_ref="$5"
	local fallback_ref="$6"
	local artifact_file="$current_file"
	local ref=""
	local byte_size=""
	local mime_type=""
	local digest=""
	if [[ ! -f "$artifact_file" ]]; then
		for ref in "$preferred_ref" "$fallback_ref"; do
			[[ -n "$ref" ]] || continue
			if git -C "$repo_root" cat-file -e "${ref}:${path}" 2>/dev/null; then
				[[ -n "$REVIEW_AUX_FILE" ]] || REVIEW_AUX_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-binary.XXXXXX")
				git -C "$repo_root" show "${ref}:${path}" >"$REVIEW_AUX_FILE" || return 1
				artifact_file="$REVIEW_AUX_FILE"
				break
			fi
		done
	fi
	[[ -f "$artifact_file" ]] || {
		_review_die "cannot materialize binary artifact for review: ${path}"
		return 1
	}
	byte_size=$(wc -c <"$artifact_file" | tr -d '[:space:]') || return 1
	mime_type=$(file --brief --mime-type -- "$artifact_file") || return 1
	digest=$(_review_sha256 "$artifact_file") || return 1
	printf '%s\t%q\t%s\t%s\t%s\n' "$status" "$path" "$byte_size" "$mime_type" "$digest"
	return 0
}

_review_collect_diff_binaries() {
	local repo_root="$1"
	local range="$2"
	local preferred_ref="$3"
	local fallback_ref="$4"
	local use_worktree="${5:-false}" current_file=""
	local path=""
	local status=""
	while IFS= read -r -d '' path; do
		[[ -z "$path" ]] && continue
		if _review_is_binary_diff "$repo_root" "$range" "$path"; then
			status=$(_review_diff_status "$repo_root" "$range" "$path") || return 1
			printf '%s\0' "$path" >>"$REVIEW_BINARY_PATHS_FILE"
			current_file=""
			[[ "$use_worktree" != true ]] || current_file="$repo_root/$path"
			_review_binary_metadata "$repo_root" "$path" "$status" "$current_file" "$preferred_ref" "$fallback_ref" >>"$REVIEW_BINARY_METADATA_FILE" || return 1
		fi
	done < <(_review_git_diff "$repo_root" "$range" --name-only --no-renames -z)
	return 0
}

_review_collect_untracked_binaries() {
	local repo_root="$1"
	local path=""
	while IFS= read -r -d '' path; do
		[[ -z "$path" ]] && continue
		if _review_is_binary_untracked "$repo_root" "$path"; then
			printf '%s\0' "$path" >>"$REVIEW_BINARY_PATHS_FILE"
			_review_binary_metadata "$repo_root" "$path" 'A' "$repo_root/$path" '' '' >>"$REVIEW_BINARY_METADATA_FILE" || return 1
		fi
	done < <(git -C "$repo_root" ls-files --others --exclude-standard -z)
	return 0
}

_review_binary_path_recorded() {
	local wanted="$1" path=""
	while IFS= read -r -d '' path; do
		[[ "$path" != "$wanted" ]] || return 0
	done <"$REVIEW_BINARY_PATHS_FILE"
	return 1
}

_review_write_text_diff() {
	local repo_root="$1"
	local range="$2"
	local -a diff_args=(--no-ext-diff -- .)
	local path=""
	while IFS= read -r -d '' path; do
		[[ -z "$path" ]] && continue
		diff_args+=(":(top,literal,exclude)$path")
	done <"$REVIEW_BINARY_PATHS_FILE"
	_review_git_diff "$repo_root" "$range" "${diff_args[@]}"
	return 0
}

_review_write_binary_metadata() {
	[[ -s "$REVIEW_BINARY_METADATA_FILE" ]] || return 0
	printf '\n## Binary artifacts\n\nThe following binary changes are represented by status, repository-relative path, byte size, MIME type, and SHA-256.\n\n```text\n'
	printf 'status\tpath\tbytes\tmime_type\tsha256\n'
	cat "$REVIEW_BINARY_METADATA_FILE"
	printf '```\n'
	return 0
}

_review_write_local() {
	local body_file="$1"
	local paths_file="$2"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	_review_require file || return 1
	git -C "$repo_root" diff --name-only -z HEAD >"$paths_file"
	git -C "$repo_root" ls-files --others --exclude-standard -z >>"$paths_file"
	_review_check_paths "$paths_file" || return 1
	_review_collect_diff_binaries "$repo_root" 'HEAD' 'HEAD' 'HEAD' true || return 1
	_review_collect_untracked_binaries "$repo_root" || return 1
	{
		printf 'target: local\n'
		printf 'head: %s\n' "$(git -C "$repo_root" rev-parse HEAD)"
		printf '\n## Changed files\n\n```text\n'
		git -C "$repo_root" status --short
		printf '%s\n\n## Patch\n\n%s\n' '```' '```diff'
		_review_write_text_diff "$repo_root" 'HEAD'
		local untracked_file=""
		while IFS= read -r -d '' untracked_file; do
			[[ -z "$untracked_file" ]] && continue
			if ! _review_binary_path_recorded "$untracked_file"; then
				git -C "$repo_root" diff --no-index --no-ext-diff -- /dev/null "$untracked_file" || true
			fi
		done < <(git -C "$repo_root" ls-files --others --exclude-standard -z)
		printf '```\n'
		_review_write_binary_metadata
	} >"$body_file"
	return 0
}

_review_write_branch() {
	local body_file="$1"
	local paths_file="$2"
	local base="$3"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	_review_require file || return 1
	[[ -n "$base" ]] || base=$(_review_default_base) || return 1
	_review_validate_ref "$base" || return 1
	local merge_base=""
	merge_base=$(git -C "$repo_root" merge-base "$base" HEAD) || return 1
	git -C "$repo_root" diff --name-only -z "${base}...HEAD" >"$paths_file"
	_review_check_paths "$paths_file" || return 1
	_review_collect_diff_binaries "$repo_root" "${base}...HEAD" 'HEAD' "$merge_base" || return 1
	{
		printf 'target: branch\n'
		printf 'base: %s\n' "$base"
		printf 'head: %s\n' "$(git -C "$repo_root" rev-parse HEAD)"
		printf '\n## Changed files\n\n```text\n'
		git -C "$repo_root" diff --name-status "${base}...HEAD"
		printf '%s\n\n## Patch\n\n%s\n' '```' '```diff'
		_review_write_text_diff "$repo_root" "${base}...HEAD"
		printf '```\n'
		_review_write_binary_metadata
	} >"$body_file"
	return 0
}

_review_write_commit() {
	local body_file="$1"
	local paths_file="$2"
	local commit_ref="$3"
	local repo_root=""
	repo_root=$(_review_repo_root) || return 1
	_review_require file || return 1
	[[ -n "$commit_ref" ]] || {
		_review_die "commit target requires --commit REF"
		return 1
	}
	_review_validate_ref "$commit_ref" || return 1
	_review_git_diff "$repo_root" "commit:${commit_ref}" --name-only --no-renames -z >"$paths_file" || return 1
	_review_check_paths "$paths_file" || return 1
	_review_collect_diff_binaries "$repo_root" "commit:${commit_ref}" "$commit_ref" "${commit_ref}^" || return 1
	{
		printf 'target: commit\n'
		printf 'commit: %s\n' "$(git -C "$repo_root" rev-parse "$commit_ref")"
		if [[ "$REVIEW_BLIND" == true ]]; then
			# Commit messages carry author rationale; blind packets select the patch only.
			printf '\n## Patch\n\n```diff\n'
		else
			printf '\n## Commit metadata and patch\n\n```text\n'
			git -C "$repo_root" show --format=fuller --no-patch "$commit_ref"
			printf '%s\n\n%s\n' '```' '```diff'
		fi
		_review_write_text_diff "$repo_root" "commit:${commit_ref}"
		printf '```\n'
		_review_write_binary_metadata
	} >"$body_file"
	return 0
}

_review_write_issue() {
	local body_file="$1"
	local number="$2"
	local repo_slug="$3"
	_review_require gh || return 1
	_review_validate_number "$number" || return 1
	_review_validate_repo_slug "$repo_slug" || return 1
	local -a repo_args=(--repo "$repo_slug")
	{
		printf 'target: issue\n'
		printf 'number: %s\n' "$number"
		printf '\n## Issue evidence\n\n```json\n'
		gh issue view "$number" "${repo_args[@]}" \
			--json number,title,body,author,createdAt,state,labels,comments
		printf '```\n'
	} >"$body_file"
	return 0
}

_review_write_pr() {
	local body_file="$1"
	local paths_file="$2"
	local number="$3"
	local repo_slug="$4"
	_review_require gh || return 1
	_review_require jq || return 1
	_review_validate_number "$number" || return 1
	_review_validate_repo_slug "$repo_slug" || return 1
	local -a repo_args=(--repo "$repo_slug")
	REVIEW_AUX_FILE=$(mktemp "${TEMP_ROOT}/review-pr-metadata.XXXXXX")
	gh pr view "$number" "${repo_args[@]}" \
		--json number,title,body,author,createdAt,state,baseRefName,headRefName,files,comments \
		>"$REVIEW_AUX_FILE"
	jq -j '.files[]?.path // empty | ., "\u0000"' "$REVIEW_AUX_FILE" >"$paths_file"
	_review_check_paths "$paths_file" || {
		rm -f "$REVIEW_AUX_FILE"
		REVIEW_AUX_FILE=""
		return 1
	}
	{
		printf 'target: pr\n'
		printf 'number: %s\n' "$number"
		printf '\n## PR evidence\n\n```json\n'
		cat "$REVIEW_AUX_FILE"
		printf '%s\n\n## Patch\n\n%s\n' '```' '```diff'
		if ! gh pr diff "$number" "${repo_args[@]}" --patch; then
			rm -f "$REVIEW_AUX_FILE"
			REVIEW_AUX_FILE=""
			return 1
		fi
		printf '```\n'
	} >"$body_file"
	rm -f "$REVIEW_AUX_FILE"
	REVIEW_AUX_FILE=""
	return 0
}

_review_emit_bundle() {
	local body_file="$1"
	local output_file="$2"
	local repository_identity="${3:-}"
	local digest=""
	local scan_status=""
	local identity_line="repository_identity: omitted"
	[[ -z "$repository_identity" ]] || identity_line="repository_identity: ${repository_identity}"
	digest=$(_review_sha256 "$body_file") || return 1
	scan_status=$(_review_scan_status "$body_file") || return 1
	if [[ -n "$output_file" ]]; then
		{
			printf '%s\n' '---'
			printf '%s\n' 'schema: aidevops.review-evidence/v1'
			printf 'bundle_sha256: %s\n' "$digest"
			printf 'prompt_injection_scan: %s\n' "$scan_status"
			printf '%s\n\n' "$identity_line"
			cat "$body_file"
		} >"$output_file"
		printf '%s\n' "$output_file"
		return 0
	fi
	printf '%s\n' '---'
	printf '%s\n' 'schema: aidevops.review-evidence/v1'
	printf 'bundle_sha256: %s\n' "$digest"
	printf 'prompt_injection_scan: %s\n' "$scan_status"
	printf '%s\n\n' "$identity_line"
	cat "$body_file"
	return 0
}

_blind_stdin_sha256() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | cut -d' ' -f1
		return 0
	fi
	sha256sum | cut -d' ' -f1
	return 0
}

_blind_trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
	return 0
}

_blind_has_id() {
	local list="$1"
	local id="$2"
	[[ "$list" == *" ${id} "* ]]
	return $?
}

_blind_note_limit() {
	local message="$1"
	printf -- '- %s\n' "$message" >>"$REVIEW_LIMITS_FILE"
	return 0
}

_blind_check_label() {
	local label="$1"
	[[ "$label" =~ ^[A-Za-z0-9_.#/:@\ -]{1,80}$ ]] || {
		_review_die "provenance label must be 1-80 safe characters"
		return 1
	}
	return 0
}

# Emit "- ID: text" per criterion; IDs are unique across requirements and amendments.
_blind_write_criteria_file() {
	local file="$1"
	local kind="$2"
	local source_label="$3"
	local line=""
	local id=""
	local text=""
	[[ -f "$file" ]] || {
		_review_die "${kind} file not found"
		return 1
	}
	_blind_check_label "$source_label" || return 1
	printf '%s_source: %s\n' "$kind" "$source_label"
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$(_blind_trim "$line")" || "$line" == '#'* ]] && continue
		if [[ ! "$line" =~ ^([A-Za-z0-9][A-Za-z0-9._-]*):[[:space:]]+(.+)$ ]]; then
			_review_die "${kind} line must be 'ID: text'"
			return 1
		fi
		id="${BASH_REMATCH[1]}"
		text="${BASH_REMATCH[2]}"
		if _blind_has_id "$BLIND_IDS" "$id"; then
			_review_die "duplicate criterion ID: ${id}"
			return 1
		fi
		BLIND_IDS="${BLIND_IDS}${id} "
		printf -- '- %s: %s\n' "$id" "$text"
	done <"$file"
	return 0
}

_blind_write_criteria() {
	local req_file="$1"
	local req_source="$2"
	local amend_file="$3"
	local amend_source="$4"
	if [[ -z "$req_file" ]]; then
		printf 'unavailable: no requirements source supplied; acceptance is unverified\n'
		_blind_note_limit 'no requirements source supplied; acceptance cannot be satisfied'
		return 0
	fi
	[[ -n "$req_source" ]] || {
		_review_die "--requirements requires --requirements-source"
		return 1
	}
	_blind_write_criteria_file "$req_file" requirements "$req_source" || return 1
	if [[ -n "$amend_file" ]]; then
		[[ -n "$amend_source" ]] || {
			_review_die "--amendments requires --amendments-source"
			return 1
		}
		_blind_write_criteria_file "$amend_file" amendments "$amend_source" || return 1
	fi
	return 0
}

_blind_emit_file() {
	local repo_root="$1"
	local head="$2"
	local use_worktree="$3"
	local path="$4"
	local tmp=""
	local size=""
	local digest=""
	tmp=$(mktemp "${TEMP_ROOT}/review-blind-file.XXXXXX") || return 1
	if [[ "$use_worktree" == true ]]; then
		[[ -f "${repo_root}/${path}" ]] || {
			rm -f "$tmp"
			return 0
		}
		cp -- "${repo_root}/${path}" "$tmp"
	else
		git -C "$repo_root" cat-file -e "${head}:${path}" 2>/dev/null || {
			rm -f "$tmp"
			return 0
		}
		git -C "$repo_root" show "${head}:${path}" >"$tmp"
	fi
	size=$(wc -c <"$tmp" | tr -d '[:space:]')
	digest=$(_review_sha256 "$tmp")
	if [[ "$size" -gt "$BLIND_MAX_FILE_BYTES" ]]; then
		printf -- '--- file: %q bytes=%s sha256=%s omitted: exceeds %s bytes ---\n' "$path" "$size" "$digest" "$BLIND_MAX_FILE_BYTES"
		_blind_note_limit "final content omitted for oversized file: $(printf '%q' "$path")"
	else
		printf -- '--- file: %q bytes=%s sha256=%s ---\n' "$path" "$size" "$digest"
		cat "$tmp"
		printf -- '\n--- end file ---\n'
	fi
	rm -f "$tmp"
	return 0
}

_blind_write_files() {
	local repo_root="$1"
	local head="$2"
	local use_worktree="$3"
	local paths_file="$4"
	local path=""
	printf '\n## Final files\n\n'
	while IFS= read -r -d '' path; do
		[[ -z "$path" ]] && continue
		if _review_binary_path_recorded "$path"; then
			_blind_note_limit "binary file represented by metadata only: $(printf '%q' "$path")"
			continue
		fi
		_blind_emit_file "$repo_root" "$head" "$use_worktree" "$path" || return 1
	done <"$paths_file"
	return 0
}

_blind_write_context() {
	local repo_root="$1"
	local head="$2"
	local use_worktree="$3"
	shift 3
	local path=""
	printf '\n## Context files\n\n'
	[[ $# -gt 0 ]] || {
		printf 'none supplied\n'
		_blind_note_limit 'no adjacent-contract context files supplied'
		return 0
	}
	for path in "$@"; do
		if [[ "$path" == /* || "$path" == ../* || "$path" == */../* || "$path" == .. ]]; then
			_review_die "context path must be repository-relative: ${path}"
			return 1
		fi
		if _review_sensitive_path "$path"; then
			_review_die "refusing security-sensitive context path: ${path}"
			return 1
		fi
		_blind_emit_file "$repo_root" "$head" "$use_worktree" "$path" || return 1
	done
	return 0
}

_blind_write_verification() {
	local file="$1"
	local head="$2"
	if [[ -z "$file" ]]; then
		printf 'none supplied\n'
		_blind_note_limit 'no verification evidence supplied'
		return 0
	fi
	[[ -f "$file" ]] || {
		_review_die "verification file not found"
		return 1
	}
	if grep -Fxq "head: ${head}" "$file"; then
		cat "$file"
		printf '\n'
	else
		printf 'excluded: evidence is not bound to the packet head\n'
		_blind_note_limit 'verification evidence excluded: missing exact "head: <sha>" binding line'
	fi
	return 0
}

_blind_section() {
	local file="$1"
	local name="$2"
	awk -v want="$name" '
		/^=== aidevops-section: [a-z]+ ===$/ { cur = $(NF - 1); next }
		cur == want { print }
	' "$file"
	return 0
}

_blind_section_digest() {
	local file="$1"
	local name="$2"
	_blind_section "$file" "$name" | _blind_stdin_sha256
	return 0
}

_blind_identity() {
	local criteria="$1"
	local artifact="$2"
	local verification="$3"
	local coverage="$4"
	printf '%s\n%s\n%s\n%s\n%s\n' "$BLIND_CONTRACT" "$criteria" "$artifact" "$verification" "$coverage" | _blind_stdin_sha256
	return 0
}

_blind_body_of() {
	local packet="$1"
	awk 'c >= 2 { if (skip) { skip = 0; next } print; next } /^---$/ { c++; if (c == 2) skip = 1; next }' "$packet"
	return 0
}

_blind_header_value() {
	local packet="$1"
	local key="$2"
	awk -v key="$key" 'c < 2 && /^---$/ { c++; next } c == 1 && index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }' "$packet"
	return 0
}

_blind_assemble_body() {
	local repo_root="$1"
	local target="$2"
	local head="$3"
	local use_worktree="$4"
	local req_file="$5"
	local req_source="$6"
	local amend_file="$7"
	local amend_source="$8"
	local verification_file="$9"
	shift 9
	{
		printf '=== aidevops-section: criteria ===\n'
		_blind_write_criteria "$req_file" "$req_source" "$amend_file" "$amend_source" || return 1
		printf '=== aidevops-section: artifact ===\n'
		cat "$REVIEW_BODY_FILE"
		_blind_write_files "$repo_root" "$head" "$use_worktree" "$REVIEW_PATHS_FILE" || return 1
		_blind_write_context "$repo_root" "$head" "$use_worktree" "$@" || return 1
		printf '=== aidevops-section: verification ===\n'
		_blind_write_verification "$verification_file" "$head" || return 1
		printf '=== aidevops-section: coverage ===\n'
		if [[ -s "$REVIEW_LIMITS_FILE" ]]; then
			printf 'status: partial\n'
			cat "$REVIEW_LIMITS_FILE"
		else
			printf 'status: complete\n'
		fi
		printf '=== aidevops-section: end ===\n'
	} >"$REVIEW_PACKET_FILE"
	return 0
}

_blind_emit_packet() {
	local target="$1"
	local head="$2"
	local output_file="$3"
	local criteria=""
	local artifact=""
	local verification=""
	local coverage=""
	local status=""
	local identity=""
	local scan=""
	criteria=$(_blind_section_digest "$REVIEW_PACKET_FILE" criteria)
	artifact=$(_blind_section_digest "$REVIEW_PACKET_FILE" artifact)
	verification=$(_blind_section_digest "$REVIEW_PACKET_FILE" verification)
	coverage=$(_blind_section_digest "$REVIEW_PACKET_FILE" coverage)
	status=$(_blind_section "$REVIEW_PACKET_FILE" coverage | sed -n 's/^status: //p')
	identity=$(_blind_identity "$criteria" "$artifact" "$verification" "$coverage")
	scan=$(_review_scan_status "$REVIEW_PACKET_FILE")
	{
		printf '%s\n' '---'
		printf 'schema: %s\n' "$BLIND_SCHEMA"
		printf 'contract: %s\n' "$BLIND_CONTRACT"
		printf 'target: %s\n' "$target"
		printf 'head: %s\n' "$head"
		printf 'packet_sha256: %s\n' "$(_review_sha256 "$REVIEW_PACKET_FILE")"
		printf 'criteria_sha256: %s\n' "$criteria"
		printf 'artifact_sha256: %s\n' "$artifact"
		printf 'verification_sha256: %s\n' "$verification"
		printf 'coverage_sha256: %s\n' "$coverage"
		printf 'coverage: %s\n' "$status"
		printf 'acceptance_identity: %s\n' "$identity"
		printf 'prompt_injection_scan: %s\n' "$scan"
		printf '%s\n\n' '---'
		cat "$REVIEW_PACKET_FILE"
	} >"${output_file:-/dev/stdout}"
	[[ -z "$output_file" ]] || printf '%s\n' "$output_file"
	return 0
}

_blind_build() {
	local target="${1:-}"
	[[ -n "$target" ]] && shift
	case "$target" in
	local | branch | commit) ;;
	issue | pr)
		_review_die "blind packets exclude issue/PR discussion; select local, branch or commit"
		return 1
		;;
	*)
		_review_die "blind build requires local, branch or commit"
		return 1
		;;
	esac
	local base_ref=""
	local commit_ref=""
	local req_file=""
	local req_source=""
	local amend_file=""
	local amend_source=""
	local verification_file=""
	local output_file=""
	local -a contexts=()
	while [[ $# -gt 0 ]]; do
		local option="$1"
		[[ $# -ge 2 ]] || {
			_review_die "option requires a value: ${option}"
			return 1
		}
		local value="${2}"
		case "$option" in
		--base) base_ref="$value" ;;
		--commit) commit_ref="$value" ;;
		--requirements) req_file="$value" ;;
		--requirements-source) req_source="$value" ;;
		--amendments) amend_file="$value" ;;
		--amendments-source) amend_source="$value" ;;
		--verification) verification_file="$value" ;;
		--context) contexts+=("$value") ;;
		--output) output_file="$value" ;;
		*)
			_review_die "unknown option: ${option}"
			return 1
			;;
		esac
		shift 2
	done
	mkdir -p "$TEMP_ROOT"
	REVIEW_BODY_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-body.XXXXXX")
	REVIEW_PATHS_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-paths.XXXXXX")
	REVIEW_BINARY_PATHS_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-binary-paths.XXXXXX")
	REVIEW_BINARY_METADATA_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-binary-metadata.XXXXXX")
	REVIEW_LIMITS_FILE=$(mktemp "${TEMP_ROOT}/review-blind-limits.XXXXXX")
	REVIEW_PACKET_FILE=$(mktemp "${TEMP_ROOT}/review-blind-packet.XXXXXX")
	trap _review_cleanup EXIT
	REVIEW_BLIND=true
	local repo_root=""
	local head=""
	local use_worktree=false
	repo_root=$(_review_repo_root) || return 1
	case "$target" in
	local)
		_review_write_local "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" || return 1
		use_worktree=true
		head=$(git -C "$repo_root" rev-parse HEAD)
		;;
	branch)
		_review_write_branch "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" "$base_ref" || return 1
		head=$(git -C "$repo_root" rev-parse HEAD)
		;;
	commit)
		_review_write_commit "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" "$commit_ref" || return 1
		head=$(git -C "$repo_root" rev-parse "$commit_ref")
		;;
	esac
	_blind_assemble_body "$repo_root" "$target" "$head" "$use_worktree" "$req_file" "$req_source" "$amend_file" "$amend_source" "$verification_file" ${contexts[@]+"${contexts[@]}"} || return 1
	_blind_emit_packet "$target" "$head" "$output_file"
	return $?
}

_blind_validate() {
	local packet="${1:-}"
	[[ -f "$packet" ]] || {
		_review_die "packet file not found"
		return 1
	}
	[[ "$(_blind_header_value "$packet" schema)" == "$BLIND_SCHEMA" ]] || {
		_review_die "unsupported or malformed blind packet schema"
		return 1
	}
	[[ "$(_blind_header_value "$packet" contract)" == "$BLIND_CONTRACT" ]] || {
		_review_die "unsupported acceptance contract"
		return 1
	}
	local body=""
	local name=""
	local expected=""
	local actual=""
	local criteria=""
	local artifact=""
	local verification=""
	local coverage=""
	local identity=""
	body=$(mktemp "${TEMP_ROOT}/review-blind-validate.XXXXXX") || return 1
	_blind_body_of "$packet" >"$body"
	expected=$(_blind_header_value "$packet" packet_sha256)
	actual=$(_review_sha256 "$body")
	[[ "$expected" == "$actual" ]] || {
		rm -f "$body"
		_review_die "packet digest mismatch"
		return 1
	}
	for name in criteria artifact verification coverage; do
		expected=$(_blind_header_value "$packet" "${name}_sha256")
		actual=$(_blind_section_digest "$body" "$name")
		if [[ "$expected" != "$actual" ]]; then
			rm -f "$body"
			_review_die "${name} section digest mismatch"
			return 1
		fi
	done
	criteria=$(_blind_header_value "$packet" criteria_sha256)
	artifact=$(_blind_header_value "$packet" artifact_sha256)
	verification=$(_blind_header_value "$packet" verification_sha256)
	coverage=$(_blind_header_value "$packet" coverage_sha256)
	identity=$(_blind_identity "$criteria" "$artifact" "$verification" "$coverage")
	rm -f "$body"
	[[ "$identity" == "$(_blind_header_value "$packet" acceptance_identity)" ]] || {
		_review_die "acceptance identity mismatch"
		return 1
	}
	printf 'valid acceptance_identity=%s\n' "$identity"
	return 0
}

_blind_check_result() {
	local packet="${1:-}"
	local result="${2:-}"
	[[ -f "$result" ]] || {
		_review_die "result file not found"
		return 1
	}
	_blind_validate "$packet" >/dev/null || return 1
	local body=""
	local ids=""
	local line=""
	local id=""
	local status=""
	local evidence=""
	local gap=""
	local seen=" "
	local unsatisfied=0
	local rows=0
	body=$(mktemp "${TEMP_ROOT}/review-blind-validate.XXXXXX") || return 1
	_blind_body_of "$packet" >"$body"
	ids=$(_blind_section "$body" criteria | sed -n 's/^- \([A-Za-z0-9][A-Za-z0-9._-]*\): .*/\1/p')
	rm -f "$body"
	if [[ -z "$ids" ]]; then
		printf 'acceptance: unverified (packet has no criteria)\n'
		return 3
	fi
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" == '|'* ]] || continue
		IFS='|' read -r _ id status evidence gap _ <<<"$line"
		id=$(_blind_trim "$id")
		status=$(_blind_trim "$status")
		evidence=$(_blind_trim "$evidence")
		gap=$(_blind_trim "$gap")
		[[ "$id" == ID || "$id" =~ ^:?-+:?$ ]] && continue
		if ! printf '%s\n' "$ids" | grep -Fxq -- "$id"; then
			_review_die "result row names unknown criterion: ${id}"
			return 1
		fi
		if _blind_has_id "$seen" "$id"; then
			_review_die "duplicate result row for criterion: ${id}"
			return 1
		fi
		seen="${seen}${id} "
		rows=$((rows + 1))
		case "$status" in
		satisfied)
			[[ -n "$evidence" ]] || {
				_review_die "satisfied criterion ${id} cites no evidence"
				return 1
			}
			;;
		unmet | unverified) unsatisfied=$((unsatisfied + 1)) ;;
		*)
			_review_die "criterion ${id} has invalid status: ${status}"
			return 1
			;;
		esac
	done <"$result"
	while IFS= read -r id; do
		_blind_has_id "$seen" "$id" || {
			_review_die "missing result row for criterion: ${id}"
			return 1
		}
	done <<<"$ids"
	if [[ "$(_blind_header_value "$packet" coverage)" != complete ]]; then
		printf 'acceptance: blocked (packet coverage is partial; satisfied rows cannot establish delivery)\n'
		return 3
	fi
	if [[ "$unsatisfied" -gt 0 ]]; then
		printf 'acceptance: blocked (%s of %s criteria not satisfied)\n' "$unsatisfied" "$rows"
		return 3
	fi
	printf 'acceptance: satisfied (%s of %s criteria)\n' "$rows" "$rows"
	return 0
}

_blind_main() {
	local sub="${1:-}"
	[[ -n "$sub" ]] && shift
	mkdir -p "$TEMP_ROOT"
	case "$sub" in
	build) _blind_build "$@" ;;
	validate) _blind_validate "$@" ;;
	check-result) _blind_check_result "$@" ;;
	*)
		_review_usage >&2
		return 1
		;;
	esac
	return $?
}

main() {
	local command_name="${1:-help}"
	if [[ "$command_name" == "blind" ]]; then
		shift
		_blind_main "$@"
		return $?
	fi
	[[ "$command_name" == "bundle" ]] && shift
	if [[ "$command_name" == "help" || "$command_name" == "--help" || "$command_name" == "-h" ]]; then
		_review_usage
		return 0
	fi
	local target="${1:-}"
	[[ -n "$target" ]] || {
		_review_usage >&2
		return 1
	}
	shift
	local target_arg=""
	case "$target" in issue | pr)
		target_arg="${1:-}"
		[[ -n "$target_arg" ]] && shift
		;;
	esac
	local base_ref=""
	local commit_ref=""
	local repo_slug=""
	local output_file=""
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--base)
			[[ $# -ge 2 ]] || return 1
			base_ref="$2"
			shift 2
			;;
		--commit)
			[[ $# -ge 2 ]] || return 1
			commit_ref="$2"
			shift 2
			;;
		--repo)
			[[ $# -ge 2 ]] || return 1
			repo_slug="$2"
			shift 2
			;;
		--output)
			[[ $# -ge 2 ]] || return 1
			output_file="$2"
			shift 2
			;;
		*)
			_review_die "unknown option: ${option}"
			return 1
			;;
		esac
	done
	mkdir -p "$TEMP_ROOT"
	REVIEW_BODY_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-body.XXXXXX")
	REVIEW_PATHS_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-paths.XXXXXX")
	REVIEW_BINARY_PATHS_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-binary-paths.XXXXXX")
	REVIEW_BINARY_METADATA_FILE=$(mktemp "${TEMP_ROOT}/review-evidence-binary-metadata.XXXXXX")
	trap _review_cleanup EXIT
	case "$target" in
	local) _review_write_local "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" ;;
	branch) _review_write_branch "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" "$base_ref" ;;
	commit) _review_write_commit "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" "$commit_ref" ;;
	issue) _review_write_issue "$REVIEW_BODY_FILE" "$target_arg" "$repo_slug" ;;
	pr) _review_write_pr "$REVIEW_BODY_FILE" "$REVIEW_PATHS_FILE" "$target_arg" "$repo_slug" ;;
	*)
		_review_die "unknown target: ${target}"
		return 1
		;;
	esac
	_review_emit_bundle "$REVIEW_BODY_FILE" "$output_file" "$repo_slug"
	return $?
}

main "$@"
