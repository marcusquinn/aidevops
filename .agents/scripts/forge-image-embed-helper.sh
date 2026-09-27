#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Publish GitHub image embeds on an asset-only branch, without web upload.
#
# Images are committed through the Git Data API (blobs -> tree -> commit -> ref)
# to a dedicated branch that is never the default branch or an open PR head.
# Each embed URL is pinned to the asset commit SHA and verified to serve an
# image before it is printed. Refusals exit non-zero with nothing on stdout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

_FIE_MAX_BYTES=10485760
_FIE_REPO=''
_FIE_BRANCH='aidevops-assets'
_FIE_MESSAGE='Add image embeds'
_FIE_ALLOW_PRIVATE=0
_FIE_FILES=()
_FIE_NAMES=()

cmd_help() {
	printf '%s\n' 'Usage: forge-image-embed-helper.sh publish --repo OWNER/REPO [--branch NAME] [--message MSG] [--allow-private] FILE [FILE...]' \
		'Publish only inspected, non-sensitive images (PNG, JPEG, GIF, WebP; up to 10 MiB each).' \
		'Prints one Markdown embed per image, pinned to the asset commit SHA.' \
		'Private repository embeds render only for readers of that repository.' \
		'Keep the asset branch while embeds matter. Cleanup (breaks embeds): gh api -X DELETE repos/OWNER/REPO/git/refs/heads/BRANCH'
	return 0
}

# Parse publish options into _FIE_* globals; remaining args are image paths.
_fie_parse_args() {
	while (($#)); do
		local option="$1" value="${2:-}"
		case "$option" in
		--repo | --branch | --message)
			if (($# < 2)) || [[ -z "$value" ]]; then
				log_error "Missing value for $option"
				return 1
			fi
			case "$option" in
			--repo) _FIE_REPO="$value" ;;
			--branch) _FIE_BRANCH="$value" ;;
			--message) _FIE_MESSAGE="$value" ;;
			esac
			shift 2
			;;
		--allow-private)
			_FIE_ALLOW_PRIVATE=1
			shift
			;;
		--)
			shift
			break
			;;
		-*)
			log_error "Unknown option: $option"
			return 1
			;;
		*) break ;;
		esac
	done
	_FIE_FILES=("$@")
	if [[ ! "$_FIE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ "$_FIE_REPO" == *'..'* ]] || ((${#_FIE_FILES[@]} == 0)); then
		log_error 'Expected --repo OWNER/REPO and at least one image'
		return 1
	fi
	if [[ ! "$_FIE_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || [[ "$_FIE_BRANCH" == *'..'* || "$_FIE_BRANCH" == */ || "$_FIE_BRANCH" == *'//'* ]]; then
		log_error 'Invalid asset branch name'
		return 1
	fi
	return 0
}

# Refuse private repos (unless allowed), the default branch and open PR heads.
_fie_check_target() {
	local repo="$1" branch="$2" allow_private="$3"
	local metadata default_branch private head_pr
	gh auth status >/dev/null 2>&1 || {
		log_error 'gh authentication required'
		return 1
	}
	metadata=$(gh api "repos/${repo}" --jq '[.default_branch, .private] | @tsv') || return 1
	IFS=$'\t' read -r default_branch private <<<"$metadata"
	if [[ "$private" == true && "$allow_private" -ne 1 ]]; then
		log_error 'Private repo requires --allow-private'
		return 1
	fi
	if [[ "$branch" == "$default_branch" ]]; then
		log_error 'Asset branch cannot be the default branch'
		return 1
	fi
	head_pr=$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq 'length') || return 1
	if [[ "$head_pr" != 0 ]]; then
		log_error 'Asset branch is an open PR head'
		return 1
	fi
	return 0
}

# Validate every file before any remote write; fills _FIE_NAMES.
_fie_check_images() {
	local file name mime size other
	_FIE_NAMES=()
	for file in "$@"; do
		if [[ ! -f "$file" || ! -r "$file" ]]; then
			log_error "Unreadable image: $file"
			return 1
		fi
		name="${file##*/}"
		if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
			log_error "Unsafe image basename: $name"
			return 1
		fi
		for other in "${_FIE_NAMES[@]+"${_FIE_NAMES[@]}"}"; do
			if [[ "$other" == "$name" ]]; then
				log_error "Duplicate basename: $name"
				return 1
			fi
		done
		mime=$(file --mime-type -b "$file") || return 1
		case "$mime" in
		image/png | image/jpeg | image/gif | image/webp) ;;
		*)
			log_error "Unsupported image type: $file ($mime)"
			return 1
			;;
		esac
		size=$(wc -c <"$file" | tr -d '[:space:]') || return 1
		if ((size == 0 || size > _FIE_MAX_BYTES)); then
			log_error "Image must be 1 byte to 10 MiB: $file"
			return 1
		fi
		_FIE_NAMES+=("$name")
	done
	return 0
}

# Print the current asset branch tip SHA, or nothing when the branch is absent.
# Only a 404 means absence; any other API failure aborts.
_fie_branch_tip() {
	local repo="$1" branch="$2" tip response
	if tip=$(gh api "repos/${repo}/git/ref/heads/${branch}" --jq '.object.sha' 2>/dev/null); then
		printf '%s\n' "$tip"
		return 0
	fi
	response=$(gh api -i "repos/${repo}/git/ref/heads/${branch}" 2>&1) && return 1
	if [[ "$response" != *'404 Not Found'* ]]; then
		log_error "Cannot inspect asset ref: $response"
		return 1
	fi
	return 0
}

# Upload one file as a base64 blob and print its SHA.
_fie_upload_blob() {
	local repo="$1" file="$2" temp_dir="$3"
	if base64 --help 2>&1 | grep -q -- '-w'; then
		base64 -w 0 "$file" >"${temp_dir}/blob.b64" || return 1
	else
		base64 -i "$file" -o "${temp_dir}/blob.b64" || return 1
	fi
	gh api "repos/${repo}/git/blobs" -f encoding=base64 -F "content=@${temp_dir}/blob.b64" --jq '.sha'
	return $?
}

# Create blobs, tree and commit, then advance or create the ref (no force).
# Prints the new commit SHA.
_fie_commit_images() {
	local repo="$1" branch="$2" message="$3" tip="$4" temp_dir="$5"
	local base_tree='' sha tree commit index=0
	local -a tree_args=() commit_args=()
	if [[ -n "$tip" ]]; then
		base_tree=$(gh api "repos/${repo}/git/commits/${tip}" --jq '.tree.sha') || return 1
		tree_args+=(-f "base_tree=$base_tree")
		commit_args+=(-f "parents[]=$tip")
	fi
	for index in "${!_FIE_FILES[@]}"; do
		sha=$(_fie_upload_blob "$repo" "${_FIE_FILES[$index]}" "$temp_dir") || return 1
		# gh starts a new array object whenever an object key repeats.
		tree_args+=(-f "tree[][path]=${_FIE_NAMES[$index]}" -f 'tree[][mode]=100644'
			-f 'tree[][type]=blob' -f "tree[][sha]=$sha")
	done
	tree=$(gh api "repos/${repo}/git/trees" "${tree_args[@]}" --jq '.sha') || return 1
	commit=$(gh api "repos/${repo}/git/commits" -f "message=$message" -f "tree=$tree" \
		"${commit_args[@]+"${commit_args[@]}"}" --jq '.sha') || return 1
	if [[ -n "$tip" ]]; then
		gh api -X PATCH "repos/${repo}/git/refs/heads/${branch}" -f "sha=$commit" -F force=false >/dev/null || {
			log_error 'Ref update failed; rerun after checking concurrent publishes'
			return 1
		}
	else
		gh api "repos/${repo}/git/refs" -f "ref=refs/heads/${branch}" -f "sha=$commit" >/dev/null || return 1
	fi
	printf '%s\n' "$commit"
	return 0
}

# Verify each pinned URL serves an image, then print the Markdown embeds.
_fie_verify_and_print() {
	local repo="$1" commit="$2" name url response status content_type
	for name in "${_FIE_NAMES[@]}"; do
		url="https://github.com/${repo}/raw/${commit}/${name}"
		response=$(curl -sIL --retry 4 --retry-delay 2 -o /dev/null -w '%{http_code} %{content_type}' "$url") || return 1
		read -r status content_type <<<"$response"
		if [[ "$status" != 200 || "$content_type" != image/* ]]; then
			log_error "Embed URL did not serve an image: $url ($response)"
			return 1
		fi
	done
	for name in "${_FIE_NAMES[@]}"; do
		printf '![%s](https://github.com/%s/raw/%s/%s)\n' "$name" "$repo" "$commit" "$name"
	done
	return 0
}

cmd_publish() {
	local tip commit temp_root temp_dir
	_fie_parse_args "$@" || return 1
	_fie_check_target "$_FIE_REPO" "$_FIE_BRANCH" "$_FIE_ALLOW_PRIVATE" || return 1
	_fie_check_images "${_FIE_FILES[@]}" || return 1
	tip=$(_fie_branch_tip "$_FIE_REPO" "$_FIE_BRANCH") || return 1
	temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_root" || return 1
	temp_dir=$(mktemp -d "${temp_root}/forge-embed.XXXXXX") || return 1
	# shellcheck disable=SC2064 # expand temp_dir now; the local is gone at RETURN
	trap "rm -rf -- '${temp_dir}'" RETURN
	commit=$(_fie_commit_images "$_FIE_REPO" "$_FIE_BRANCH" "$_FIE_MESSAGE" "$tip" "$temp_dir") || return 1
	_fie_verify_and_print "$_FIE_REPO" "$commit" || return 1
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	publish) cmd_publish "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		return 1
		;;
	esac
	return $?
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
