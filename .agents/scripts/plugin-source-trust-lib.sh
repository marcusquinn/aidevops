#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared runtime-neutral plugin provenance, inventory, and activation primitives.

[[ -n "${_AIDEVOPS_PLUGIN_SOURCE_TRUST_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_PLUGIN_SOURCE_TRUST_LIB_LOADED=1

plugin_trust_valid_commit() {
	local commit="$1"
	[[ "$commit" =~ ^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$ ]]
	return $?
}

plugin_trust_valid_branch() {
	local branch="$1"
	git check-ref-format --branch "$branch" >/dev/null 2>&1
	return $?
}

plugin_trust_canonical_path() {
	local path="$1"
	local resolved=""
	if command -v realpath >/dev/null 2>&1; then
		resolved=$(realpath "$path" 2>/dev/null || true)
	elif command -v python3 >/dev/null 2>&1; then
		resolved=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || true)
	fi
	if [[ -z "$resolved" || ! -e "$resolved" ]]; then
		return 1
	fi
	printf '%s\n' "$resolved"
	return 0
}

plugin_trust_path_is_within() {
	local root="$1"
	local candidate="$2"
	case "$candidate" in
	"$root" | "$root"/*) return 0 ;;
	*) return 1 ;;
	esac
}

plugin_trust_sha256_file() {
	local path="$1"
	local result=""
	if command -v sha256sum >/dev/null 2>&1; then
		result=$(sha256sum "$path") || return 1
		printf '%s\n' "${result%% *}"
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		result=$(shasum -a 256 "$path") || return 1
		printf '%s\n' "${result%% *}"
		return 0
	fi
	if command -v openssl >/dev/null 2>&1; then
		result=$(openssl dgst -sha256 -r "$path") || return 1
		printf '%s\n' "${result%% *}"
		return 0
	fi
	return 1
}

plugin_trust_file_mode() {
	local path="$1"
	local mode=""
	mode=$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || true)
	if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
		return 1
	fi
	printf '%s\n' "$mode"
	return 0
}

plugin_trust_safe_inventory_text() {
	local value="$1"
	[[ "$value" != *$'\n'* && "$value" != *$'\t'* && "$value" != *$'\r'* ]]
	return $?
}

plugin_trust_inventory_entry() {
	local root="$1"
	local root_real="$2"
	local path="$3"
	local output="$4"
	local relative_path="${path#"$root"/}"
	local mode=""
	local value="-"

	plugin_trust_safe_inventory_text "$relative_path" || return 1
	if [[ -L "$path" ]]; then
		local link_lines=""
		local link_target=""
		local resolved_target=""
		link_lines=$(readlink "$path" | wc -l | tr -d ' ')
		[[ "$link_lines" == "1" ]] || return 1
		link_target=$(readlink "$path") || return 1
		plugin_trust_safe_inventory_text "$link_target" || return 1
		[[ -n "$link_target" && "$link_target" != /* && -e "$path" ]] || return 1
		resolved_target=$(plugin_trust_canonical_path "$path") || return 1
		plugin_trust_path_is_within "$root_real" "$resolved_target" || return 1
		mode="120000"
		value="$link_target"
		printf 'l\t%s\t%s\t%s\n' "$mode" "$value" "$relative_path" >>"$output"
		return $?
	fi
	mode=$(plugin_trust_file_mode "$path") || return 1
	if [[ -d "$path" ]]; then
		printf 'd\t%s\t%s\t%s\n' "$mode" "$value" "$relative_path" >>"$output"
		return $?
	fi
	if [[ -f "$path" ]]; then
		value=$(plugin_trust_sha256_file "$path") || return 1
		printf 'f\t%s\t%s\t%s\n' "$mode" "$value" "$relative_path" >>"$output"
		return $?
	fi
	return 1
}

plugin_trust_build_inventory() {
	local root="$1"
	local output="$2"
	local root_real=""
	local paths_file=""
	local unsorted_file=""
	local failed=0

	[[ -d "$root" && ! -L "$root" ]] || return 1
	root_real=$(plugin_trust_canonical_path "$root") || return 1
	paths_file=$(mktemp "${output}.paths.XXXXXX") || return 1
	unsorted_file=$(mktemp "${output}.unsorted.XXXXXX") || {
		rm -f "$paths_file"
		return 1
	}
	if ! find "$root" -mindepth 1 -print0 >"$paths_file"; then
		failed=1
	else
		while IFS= read -r -d '' path; do
			plugin_trust_inventory_entry "$root" "$root_real" "$path" "$unsorted_file" || {
				failed=1
				break
			}
		done <"$paths_file"
	fi
	rm -f "$paths_file"
	if [[ "$failed" -ne 0 ]] || ! LC_ALL=C sort "$unsorted_file" >"$output"; then
		rm -f "$unsorted_file" "$output"
		return 1
	fi
	rm -f "$unsorted_file"
	return 0
}

plugin_trust_inventory_json() {
	local inventory_file="$1"
	local json_file="$2"
	jq -Rn '[inputs | split("\t") | {type: .[0], mode: .[1], value: .[2], path: .[3]}]' \
		<"$inventory_file" >"$json_file"
	return $?
}

plugin_trust_tree_metadata() {
	local root="$1"
	local inventory_file="$2"
	local inventory_json="$3"
	local digest=""

	plugin_trust_build_inventory "$root" "$inventory_file" || return 1
	plugin_trust_inventory_json "$inventory_file" "$inventory_json" || return 1
	digest=$(plugin_trust_sha256_file "$inventory_file") || return 1
	printf '%s\n' "$digest"
	return 0
}

plugin_trust_prepare_metadata() {
	local root="$1"
	local parent_dir="$2"
	local namespace="$3"
	local work_dir=""
	local inventory_file=""
	local inventory_json=""
	local digest=""

	work_dir=$(mktemp -d "$parent_dir/.plugin-${namespace}.metadata.XXXXXX") || return 1
	inventory_file="$work_dir/inventory.tsv"
	inventory_json="$work_dir/inventory.json"
	digest=$(plugin_trust_tree_metadata "$root" "$inventory_file" "$inventory_json") || {
		rm -rf "$work_dir"
		return 1
	}
	printf '%s\t%s\t%s\n' "$digest" "$work_dir" "$inventory_json"
	return 0
}

plugin_trust_verify_tree() {
	local root="$1"
	local expected_digest="$2"
	local expected_inventory="$3"
	local work_dir=""
	local inventory_file=""
	local inventory_json=""
	local actual_digest=""
	local actual_canonical=""
	local expected_canonical=""

	[[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-plugin-verify.XXXXXX") || return 1
	inventory_file="$work_dir/inventory.tsv"
	inventory_json="$work_dir/inventory.json"
	actual_digest=$(plugin_trust_tree_metadata "$root" "$inventory_file" "$inventory_json") || {
		rm -rf "$work_dir"
		return 1
	}
	actual_canonical=$(jq -cS . "$inventory_json" 2>/dev/null || true)
	expected_canonical=$(printf '%s\n' "$expected_inventory" | jq -cS . 2>/dev/null || true)
	rm -rf "$work_dir"
	[[ "$actual_digest" == "$expected_digest" && -n "$expected_canonical" && "$actual_canonical" == "$expected_canonical" ]]
	return $?
}

plugin_trust_normalize_directories() {
	local root="$1"
	local paths_file=""
	local failed=0

	paths_file=$(mktemp "${root}.directories.XXXXXX") || return 1
	find "$root" -type d -print0 >"$paths_file" || failed=1
	while [[ "$failed" -eq 0 ]] && IFS= read -r -d '' directory; do
		chmod 755 "$directory" || failed=1
	done <"$paths_file"
	rm -f "$paths_file"
	[[ "$failed" -eq 0 ]]
	return $?
}

plugin_trust_materialize_commit() {
	local repository_dir="$1"
	local commit="$2"
	local output_dir="$3"
	local tree_list=""
	local failed=0

	tree_list=$(mktemp "${output_dir}.tree.XXXXXX") || return 1
	git -C "$repository_dir" ls-tree -rz --full-tree "$commit" >"$tree_list" || failed=1
	while [[ "$failed" -eq 0 ]] && IFS= read -r -d '' entry; do
		local metadata="${entry%%$'\t'*}"
		local relative_path="${entry#*$'\t'}"
		local mode="" object_type="" object_id="" destination=""
		IFS=' ' read -r mode object_type object_id <<<"$metadata"
		plugin_trust_safe_inventory_text "$relative_path" || failed=1
		[[ "$object_type" == "blob" && "$relative_path" != /* && "$relative_path" != ../* &&
			"$relative_path" != */../* && "$relative_path" != *"/.." ]] || failed=1
		case "$mode" in
		100644 | 100755 | 120000) ;;
		*) failed=1 ;;
		esac
		[[ "$failed" -eq 0 ]] || break
		destination="$output_dir/$relative_path"
		mkdir -p "$(dirname "$destination")"
		if [[ "$mode" == "120000" ]]; then
			local link_target=""
			local link_file=""
			link_file=$(mktemp "${output_dir}.link.XXXXXX") || failed=1
			[[ "$failed" -eq 0 ]] && git -C "$repository_dir" cat-file blob "$object_id" >"$link_file" || failed=1
			[[ "$failed" -eq 0 && "$(wc -l <"$link_file" | tr -d ' ')" == "0" ]] || failed=1
			[[ "$failed" -eq 0 ]] && link_target=$(cat "$link_file") || failed=1
			rm -f "$link_file"
			plugin_trust_safe_inventory_text "$link_target" || failed=1
			[[ -n "$link_target" && "$link_target" != /* ]] || failed=1
			[[ "$failed" -eq 0 ]] && ln -s "$link_target" "$destination" || failed=1
		elif git -C "$repository_dir" cat-file blob "$object_id" >"$destination"; then
			if [[ "$mode" == "100755" ]]; then
				chmod 755 "$destination" || failed=1
			else
				chmod 644 "$destination" || failed=1
			fi
		else
			failed=1
		fi
	done <"$tree_list"
	rm -f "$tree_list"
	[[ "$failed" -eq 0 ]] || return 1
	plugin_trust_normalize_directories "$output_dir" || return 1
	plugin_trust_build_inventory "$output_dir" "${output_dir}.inventory-check" || return 1
	rm -f "${output_dir}.inventory-check"
	return 0
}

plugin_trust_stage_repository() {
	local agents_dir="$1"
	local namespace="$2"
	local repo="$3"
	local branch="$4"
	local expected_commit="$5"
	local stage_dir="" source_dir="" resolved_commit="" expected_normalized=""

	stage_dir=$(mktemp -d "$agents_dir/.plugin-${namespace}.stage.XXXXXX") || return 1
	source_dir="${stage_dir}.source"
	git clone --quiet --no-checkout --no-tags --branch "$branch" -- "$repo" "$source_dir" || {
		rm -rf "$stage_dir" "$source_dir"
		return 1
	}
	if [[ -n "$expected_commit" ]]; then
		resolved_commit=$(git -C "$source_dir" rev-parse --verify "${expected_commit}^{commit}" 2>/dev/null || true)
	else
		resolved_commit=$(git -C "$source_dir" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
	fi
	resolved_commit=$(printf '%s' "$resolved_commit" | tr '[:upper:]' '[:lower:]')
	expected_normalized=$(printf '%s' "$expected_commit" | tr '[:upper:]' '[:lower:]')
	if ! plugin_trust_valid_commit "$resolved_commit" ||
		[[ -n "$expected_commit" && "$resolved_commit" != "$expected_normalized" ]] ||
		! plugin_trust_materialize_commit "$source_dir" "$resolved_commit" "$stage_dir"; then
		rm -rf "$stage_dir" "$source_dir"
		return 1
	fi
	rm -rf "$source_dir"
	printf '%s\t%s\n' "$stage_dir" "$resolved_commit"
	return 0
}

plugin_trust_marker_path() {
	local agents_dir="$1"
	local namespace="$2"
	printf '%s/.plugin-%s.deploying\n' "$agents_dir" "$namespace"
	return 0
}

plugin_trust_acquire_lock() {
	local marker="$1"
	mkdir "$marker" 2>/dev/null
	return $?
}

plugin_trust_release_lock() {
	local marker="$1"
	rmdir "$marker" 2>/dev/null
	return $?
}

plugin_trust_registry_lock_path() {
	local plugins_file="$1"
	printf '%s.lock\n' "$plugins_file"
	return 0
}

plugin_trust_acquire_write_locks() {
	local plugins_file="$1"
	local marker="$2"
	local registry_lock=""
	registry_lock=$(plugin_trust_registry_lock_path "$plugins_file")
	plugin_trust_acquire_lock "$registry_lock" || return 1
	if ! plugin_trust_acquire_lock "$marker"; then
		plugin_trust_release_lock "$registry_lock" || true
		return 1
	fi
	return 0
}

plugin_trust_release_write_locks() {
	local plugins_file="$1"
	local marker="$2"
	local registry_lock=""
	registry_lock=$(plugin_trust_registry_lock_path "$plugins_file")
	plugin_trust_release_lock "$marker" || return 1
	plugin_trust_release_lock "$registry_lock" || return 1
	return 0
}

plugin_trust_activate_candidate() {
	local stage_dir="$1"
	local target_dir="$2"
	local registry_tmp="$3"
	local plugins_file="$4"
	local marker="$5"
	local backup_dir="${target_dir}.previous.$$"
	local had_previous=false
	local activated=false

	[[ ! -e "$backup_dir" ]] || return 1
	plugin_trust_acquire_write_locks "$plugins_file" "$marker" || return 1
	if [[ -e "$target_dir" ]]; then
		mv "$target_dir" "$backup_dir" || {
			plugin_trust_release_write_locks "$plugins_file" "$marker" || true
			return 1
		}
		had_previous=true
	fi
	if mv "$stage_dir" "$target_dir"; then
		activated=true
	else
		[[ "$had_previous" == "true" ]] && mv "$backup_dir" "$target_dir" 2>/dev/null || true
		plugin_trust_release_write_locks "$plugins_file" "$marker" || true
		return 1
	fi
	if mv "$registry_tmp" "$plugins_file"; then
		[[ "$had_previous" == "true" ]] && rm -rf "$backup_dir"
		plugin_trust_release_write_locks "$plugins_file" "$marker"
		return $?
	fi
	[[ "$activated" == "true" ]] && rm -rf "$target_dir"
	if [[ "$had_previous" == "true" ]] && ! mv "$backup_dir" "$target_dir" 2>/dev/null; then
		return 1
	fi
	plugin_trust_release_write_locks "$plugins_file" "$marker" || return 1
	return 1
}
