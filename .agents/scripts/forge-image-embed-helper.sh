#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Publish GitHub image embeds on an asset-only branch.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
set -euo pipefail

cmd_help() {
	printf '%s\n' 'Usage: forge-image-embed-helper.sh publish --repo OWNER/REPO [--branch NAME] [--message MSG] [--allow-private] FILE [FILE...]' \
		'Publish only inspected, non-sensitive images. Private repository embeds require reader access.' \
		'Keep the asset branch while embeds matter. Cleanup (breaks embeds): gh api -X DELETE repos/OWNER/REPO/git/refs/heads/BRANCH'
	return 0
}

cmd_publish() {
	local repo='' branch='aidevops-assets' message='Add image embeds' allow_private=0
	while (($#)); do
		local option="$1" value="${2:-}"
		case "$option" in
		--repo | --branch | --message)
			if (($# < 2)) || [[ -z "$value" ]]; then
				log_error "Missing value for $option"
				return 1
			fi
			case "$option" in
			--repo) repo="$value" ;; --branch) branch="$value" ;; --message) message="$value" ;;
			esac
			shift 2
			;;
		--allow-private)
			allow_private=1
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
	if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ "$repo" == *'..'* ]] || (($# == 0)); then
		log_error 'Expected --repo OWNER/REPO and at least one image'
		return 1
	fi
	if [[ ! "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || [[ "$branch" == *'..'* || "$branch" == */ || "$branch" == *'//'* ]]; then
		log_error 'Invalid asset branch name'
		return 1
	fi
	gh auth status >/dev/null 2>&1 || {
		log_error 'gh authentication required'
		return 1
	}
	local metadata default_branch private head_pr
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
	local file name mime size other
	local -a files=("$@") names=()
	for file in "${files[@]}"; do
		if [[ ! -f "$file" || ! -r "$file" ]]; then
			log_error "Unreadable image: $file"
			return 1
		fi
		name="${file##*/}"
		if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
			log_error "Unsafe image basename: $name"
			return 1
		fi
		for other in "${names[@]+"${names[@]}"}"; do
			if [[ "$other" == "$name" ]]; then
				log_error "Duplicate basename: $name"
				return 1
			fi
		done
		mime=$(file --mime-type -b "$file") || return 1
		case "$mime" in image/png | image/jpeg | image/gif | image/webp) ;; *)
			log_error "Unsupported image type: $file ($mime)"
			return 1
			;;
		esac
		size=$(wc -c <"$file") || return 1
		if ((size == 0 || size > 10485760)); then
			log_error "Image must be 1 byte to 10 MiB: $file"
			return 1
		fi
		names+=("$name")
	done
	local ref tip='' base_tree='' tree commit sha response url status content_type
	if ref=$(gh api "repos/${repo}/git/ref/heads/${branch}" --jq '.object.sha' 2>/dev/null); then
		tip="$ref"
		base_tree=$(gh api "repos/${repo}/git/commits/${tip}" --jq '.tree.sha') || return 1
	else
		# Only 404 means a new branch; other API failures must not be treated as absence.
		response=$(gh api -i "repos/${repo}/git/ref/heads/${branch}" 2>&1) || {
			if [[ "$response" != *'404 Not Found'* ]]; then
				log_error "Cannot inspect asset ref: $response"
				return 1
			fi
		}
	fi
	local temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_root" || return 1
	local temp_dir
	temp_dir=$(mktemp -d "${temp_root}/forge-embed.XXXXXX") || return 1
	trap 'rm -rf -- "$temp_dir"' RETURN
	local -a tree_args=() commit_args=()
	local index=0
	for file in "${files[@]}"; do
		if base64 --help 2>&1 | grep -q -- '-w'; then
			base64 -w 0 "$file" >"${temp_dir}/blob.b64" || return 1
		else
			base64 -i "$file" -o "${temp_dir}/blob.b64" || return 1
		fi
		sha=$(gh api "repos/${repo}/git/blobs" -f encoding=base64 -F "content=@${temp_dir}/blob.b64" --jq '.sha') || return 1
		tree_args+=(-f "tree[${index}][path]=${names[$index]}" -f "tree[${index}][mode]=100644" -f "tree[${index}][type]=blob" -f "tree[${index}][sha]=$sha")
		index=$((index + 1))
	done
	if [[ -n "$tip" ]]; then
		tree_args+=(-f "base_tree=$base_tree")
		commit_args+=(-f "parents[]=$tip")
	fi
	tree=$(gh api "repos/${repo}/git/trees" "${tree_args[@]}" --jq '.sha') || return 1
	commit=$(gh api "repos/${repo}/git/commits" -f "message=$message" -f "tree=$tree" "${commit_args[@]}" --jq '.sha') || return 1
	if [[ -n "$tip" ]]; then
		gh api -X PATCH "repos/${repo}/git/refs/heads/${branch}" -f "sha=$commit" -F force=false >/dev/null || {
			log_error 'Ref update failed; rerun after checking concurrent publishes'
			return 1
		}
	else
		gh api "repos/${repo}/git/refs" -f "ref=refs/heads/${branch}" -f "sha=$commit" >/dev/null || return 1
	fi
	for name in "${names[@]}"; do
		url="https://github.com/${repo}/raw/${commit}/${name}"
		response=$(curl -sIL --retry 4 --retry-delay 2 -o /dev/null -w '%{http_code} %{content_type}' "$url") || return 1
		read -r status content_type <<<"$response"
		if [[ "$status" != 200 || "$content_type" != image/* ]]; then
			log_error "Embed URL did not serve an image: $url ($response)"
			return 1
		fi
	done
	for name in "${names[@]}"; do printf '![%s](https://github.com/%s/raw/%s/%s)\n' "$name" "$repo" "$commit" "$name"; done
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
