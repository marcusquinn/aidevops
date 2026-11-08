#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Runtime bundle staging, validation, pruning and activation functions.
# Sourced by agent-deploy.sh (GH#37253); moved verbatim, no behaviour change.
#
# Part of aidevops setup.sh modularization

# Include guard
[[ -n "${_AGENT_DEPLOY_BUNDLE_LOADED:-}" ]] && return 0
_AGENT_DEPLOY_BUNDLE_LOADED=1

# Runtime bundles keep every executable part of one framework revision under an
# immutable directory. ~/.aidevops/agents is only the atomic activation link.
_AIDEVOPS_STAGED_BUNDLE_DIR=""
_AIDEVOPS_PREVIOUS_BUNDLE_ROOT=""
[[ -z "${_AIDEVOPS_BUNDLE_UNKNOWN+x}" ]] && _AIDEVOPS_BUNDLE_UNKNOWN="unknown"

_runtime_bundle_sha256_file() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | cut -d' ' -f1
	else
		openssl dgst -sha256 "$file" | sed 's/^.*= //'
	fi
	return 0
}

_runtime_bundle_resolve_root() {
	local agents_path="$1"
	[[ -d "$agents_path" ]] || return 1
	(cd "$agents_path" && pwd -P) || return 1
	return 0
}

# Plugin namespaces are copied per bundle. User-owned custom/ and draft/ are
# not: they live in the stable user-state root (GH#34088).
_runtime_bundle_copy_preserved_dirs() {
	local current_root="$1"
	local candidate_root="$2"
	shift 2
	local preserved_dir=""
	local -a preserved_dirs=("$@")

	[[ "${#preserved_dirs[@]}" -gt 0 ]] || return 0
	for preserved_dir in "${preserved_dirs[@]}"; do
		[[ -n "$preserved_dir" && -d "$current_root/$preserved_dir" ]] || continue
		rm -rf "${candidate_root:?}/$preserved_dir"
		cp -a "$current_root/$preserved_dir" "$candidate_root/$preserved_dir" || return 1
	done
	return 0
}

# ----- stable user-owned agent state (GH#34088) ---------------------------
# custom/ and draft/ used to be copied into every immutable bundle, so absolute
# links (package current/previous pointers, entry points) kept targeting the
# older bundle and dangled once it was pruned. They now live once, outside
# runtime-bundles/, and each bundle exposes them through agents/{custom,draft}
# links, so ~/.aidevops/agents/custom/... remains the documented path.
_RUNTIME_BUNDLE_USER_STATE_DIRS=("custom" "draft")

_runtime_bundle_user_state_root() {
	local target_dir="$1"
	printf '%s/user-agents\n' "${target_dir%/*}"
	return 0
}

# _runtime_bundle_rebase_user_link link name stable_dir current_root bundles_dir
# Rewrite one absolute link whose target lies inside a bundle-scoped copy of
# custom/ or draft/ to the equivalent stable path. Other links are untouched.
_runtime_bundle_rebase_user_link() {
	local link_path="$1"
	local name="$2"
	local stable_dir="$3"
	local current_root="$4"
	local bundles_dir="$5"
	local link_target="" suffix="" rest="" bundle_id=""

	link_target=$(readlink "$link_path") || return 1
	[[ "$link_target" == /* ]] || return 0
	if [[ "$link_target" == "$current_root/$name" || "$link_target" == "$current_root/$name/"* ]]; then
		suffix="${link_target#"$current_root/$name"}"
	elif [[ -n "$bundles_dir" && "$link_target" == "$bundles_dir/"* ]]; then
		rest="${link_target#"$bundles_dir/"}"
		bundle_id="${rest%%/*}"
		rest="${rest#*/}"
		[[ -n "$bundle_id" && "$bundle_id" != "$rest" ]] || return 0
		if [[ "$rest" == "agents/$name" ]]; then
			suffix=""
		elif [[ "$rest" == "agents/$name/"* ]]; then
			suffix="${rest#"agents/$name"}"
		else
			return 0
		fi
	else
		return 0
	fi
	rm -f "$link_path" || return 1
	ln -s "${stable_dir}${suffix}" "$link_path" || return 1
	return 0
}

# Report (never edit) Python environments that still embed a runtime-bundle
# path; rewriting shebangs or pyvenv.cfg in place produces broken interpreters.
_runtime_bundle_report_bundle_bound_venvs() {
	local stable_dir="$1"
	local cfg_file="" venv_dir="" count=0

	while IFS= read -r cfg_file; do
		[[ -n "$cfg_file" ]] || continue
		venv_dir="${cfg_file%/pyvenv.cfg}"
		if grep -q '/runtime-bundles/' "$cfg_file" 2>/dev/null ||
			grep -lq '^#!.*/runtime-bundles/' "$venv_dir"/bin/* 2>/dev/null; then
			count=$((count + 1))
			print_warning "  Python environment still bound to a runtime bundle: ${venv_dir#"$stable_dir"/} — re-create it under ~/.aidevops/agents/${stable_dir##*/}/"
		fi
	done < <(find "$stable_dir" -name pyvenv.cfg -type f 2>/dev/null)
	[[ "$count" -eq 0 ]] || print_info "  Re-create the reported environments before the old bundle is pruned; they were not modified"
	return 0
}

# _runtime_bundle_migrate_user_state current_root user_root bundles_dir
# Idempotent, no-clobber migration of the active bundle's real custom/ and
# draft/ into the stable root. The legacy in-bundle copy is left in place until
# that bundle is pruned, so rollback to a pre-migration bundle still works.
_runtime_bundle_migrate_user_state() {
	local current_root="$1"
	local user_root="$2"
	local bundles_dir="$3"
	local name="" legacy_dir="" stable_dir="" stage_dir="" link_path=""

	mkdir -p "$user_root" || return 1
	for name in "${_RUNTIME_BUNDLE_USER_STATE_DIRS[@]}"; do
		legacy_dir="$current_root/$name"
		stable_dir="$user_root/$name"
		if [[ -e "$stable_dir" || -L "$stable_dir" ]]; then
			[[ -d "$stable_dir" && ! -L "$stable_dir" ]] || {
				print_error "Stable user agent state is not a real directory: $stable_dir"
				return 1
			}
			continue
		fi
		if [[ -n "$current_root" && -d "$legacy_dir" && ! -L "$legacy_dir" ]]; then
			stage_dir=$(mktemp -d "$user_root/.${name}.migrate.XXXXXX") || return 1
			rmdir "$stage_dir" || return 1
			if ! cp -a "$legacy_dir" "$stage_dir"; then
				rm -rf "$stage_dir"
				return 1
			fi
			while IFS= read -r link_path; do
				[[ -n "$link_path" ]] || continue
				_runtime_bundle_rebase_user_link "$link_path" "$name" "$stable_dir" \
					"$current_root" "$bundles_dir" || {
					rm -rf "$stage_dir"
					return 1
				}
			done < <(find "$stage_dir" -type l 2>/dev/null)
			# No clobber: a setup that migrated first wins. If one appears between
			# the check and the rename, mv nests this copy inside it; remove that.
			if [[ -e "$stable_dir" || -L "$stable_dir" ]]; then
				rm -rf "$stage_dir"
				continue
			fi
			mv "$stage_dir" "$stable_dir" || {
				rm -rf "$stage_dir"
				return 1
			}
			if [[ -e "$stable_dir/${stage_dir##*/}" ]]; then
				rm -rf "${stable_dir:?}/${stage_dir##*/}"
				continue
			fi
			print_info "  Migrated agents/$name to stable user state (~/.aidevops/${user_root##*/}/$name)"
			_runtime_bundle_report_bundle_bound_venvs "$stable_dir"
		else
			mkdir -p "$stable_dir" || return 1
		fi
	done
	return 0
}

# Expose the stable user-state directories inside a staged bundle.
_runtime_bundle_link_user_state() {
	local candidate_root="$1"
	local user_root="$2"
	local name=""

	for name in "${_RUNTIME_BUNDLE_USER_STATE_DIRS[@]}"; do
		[[ -d "$user_root/$name" ]] || return 1
		rm -rf "${candidate_root:?}/$name"
		ln -s "$user_root/$name" "$candidate_root/$name" || return 1
	done
	return 0
}

# Move the user-owned plist override out of the replaceable runtime bundle.
# The no-clobber hard link makes concurrent setup runs converge without
# overwriting an existing stable config. No file contents are logged.
_runtime_bundle_migrate_plist_env_overrides() {
	local current_root="$1"
	local legacy_file="$current_root/configs/plist-env-overrides.json"
	local config_dir="$HOME/.config/aidevops"
	local stable_file="$config_dir/plist-env-overrides.json"
	local migration_tmp=""

	[[ -f "$stable_file" || ! -f "$legacy_file" ]] && return 0
	mkdir -p "$config_dir" || return 1
	migration_tmp=$(mktemp "$config_dir/.plist-env-overrides.json.XXXXXX") || return 1
	if ! cp "$legacy_file" "$migration_tmp" || ! chmod 600 "$migration_tmp"; then
		rm -f "$migration_tmp"
		return 1
	fi
	if ! ln "$migration_tmp" "$stable_file" 2>/dev/null && [[ ! -f "$stable_file" ]]; then
		rm -f "$migration_tmp"
		return 1
	fi
	rm -f "$migration_tmp"
	print_info "  Migrated plist environment overrides to ~/.config/aidevops/plist-env-overrides.json"
	return 0
}

_runtime_bundle_write_manifest() {
	local bundle_dir="$1"
	local repo_dir="$2"
	local plugins_file="$3"
	local agents_root="$bundle_dir/agents"
	local manifest_tmp="$bundle_dir/manifest.tmp"
	local framework_version="$_AIDEVOPS_BUNDLE_UNKNOWN"
	local git_sha="$_AIDEVOPS_BUNDLE_UNKNOWN"
	local file_count="0"
	local missing_sha="missing"
	local cli_sha="$missing_sha"
	local plugin_entry_sha="$missing_sha"
	local plugin_v2_entry_sha="$missing_sha"
	local plugin_v2_loader_sha="$missing_sha"
	local plugin_v2_loader_package_sha="$missing_sha"
	local manifest_bundle_id="${bundle_dir##*/}"
	manifest_bundle_id="${manifest_bundle_id#.staging.}"

	[[ -r "$agents_root/VERSION" ]] && IFS= read -r framework_version <"$agents_root/VERSION"
	git_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || printf '%s' "$_AIDEVOPS_BUNDLE_UNKNOWN")
	file_count=$(_count_deployed_agent_files "$agents_root")
	[[ -f "$agents_root/aidevops.sh" ]] && cli_sha=$(_runtime_bundle_sha256_file "$agents_root/aidevops.sh")
	if [[ -f "$agents_root/plugins/opencode-aidevops/index.mjs" ]]; then
		plugin_entry_sha=$(_runtime_bundle_sha256_file "$agents_root/plugins/opencode-aidevops/index.mjs")
	fi
	if [[ -f "$agents_root/plugins/opencode-aidevops/v2.mjs" ]]; then
		plugin_v2_entry_sha=$(_runtime_bundle_sha256_file "$agents_root/plugins/opencode-aidevops/v2.mjs")
	fi
	if [[ -f "$agents_root/plugins/opencode-aidevops/v2-plugin/index.mjs" ]]; then
		plugin_v2_loader_sha=$(_runtime_bundle_sha256_file "$agents_root/plugins/opencode-aidevops/v2-plugin/index.mjs")
	fi
	if [[ -f "$agents_root/plugins/opencode-aidevops/v2-plugin/package.json" ]]; then
		plugin_v2_loader_package_sha=$(_runtime_bundle_sha256_file "$agents_root/plugins/opencode-aidevops/v2-plugin/package.json")
	fi

	{
		printf 'schema=1\n'
		printf 'status=validated\n'
		printf 'bundle_id=%s\n' "$manifest_bundle_id"
		printf 'framework_version=%s\n' "$framework_version"
		printf 'cli_compatibility=%s\n' "$framework_version"
		printf 'git_sha=%s\n' "$git_sha"
		printf 'agents_file_count=%s\n' "$file_count"
		printf 'cli_sha256=%s\n' "$cli_sha"
		printf 'plugin_entry_sha256=%s\n' "$plugin_entry_sha"
		printf 'plugin_v2_entry_sha256=%s\n' "$plugin_v2_entry_sha"
		printf 'plugin_v2_loader_sha256=%s\n' "$plugin_v2_loader_sha"
		printf 'plugin_v2_loader_package_sha256=%s\n' "$plugin_v2_loader_package_sha"
		if declare -F runtime_bundle_plugin_manifest_fields >/dev/null 2>&1; then
			runtime_bundle_plugin_manifest_fields "$agents_root" "$plugins_file"
		else
			printf 'plugin_registry_sha256=unavailable\n'
		fi
	} >"$manifest_tmp" || return 1
	mv "$manifest_tmp" "$bundle_dir/manifest" || return 1
	cp "$bundle_dir/manifest" "$agents_root/.bundle-manifest" || return 1
	return 0
}

_runtime_bundle_manifest_value() {
	local manifest_file="$1"
	local key="$2"
	local line=""

	[[ -r "$manifest_file" ]] || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		"${key}="*)
			printf '%s' "${line#*=}"
			return 0
			;;
		esac
	done <"$manifest_file"
	return 1
}

_runtime_bundle_compare_versions() {
	local left="$1"
	local right="$2"
	local left_major="" left_minor="" left_patch=""
	local right_major="" right_minor="" right_patch=""

	left="${left#v}"
	right="${right#v}"
	[[ "$left" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	[[ "$right" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	IFS='.' read -r left_major left_minor left_patch <<<"$left"
	IFS='.' read -r right_major right_minor right_patch <<<"$right"

	if ((10#$left_major < 10#$right_major)); then
		printf '%s' '-1'
		return 0
	fi
	if ((10#$left_major > 10#$right_major)); then
		printf '%s' '1'
		return 0
	fi
	if ((10#$left_minor < 10#$right_minor)); then
		printf '%s' '-1'
		return 0
	fi
	if ((10#$left_minor > 10#$right_minor)); then
		printf '%s' '1'
		return 0
	fi
	if ((10#$left_patch < 10#$right_patch)); then
		printf '%s' '-1'
		return 0
	fi
	if ((10#$left_patch > 10#$right_patch)); then
		printf '%s' '1'
		return 0
	fi
	printf '%s' '0'
	return 0
}

# Print a reason when setup is attempting to activate a candidate that is older
# than the active global runtime. Missing comparison evidence intentionally
# prints nothing. Explicit rollback tooling uses its own audited link transition
# and does not route through setup activation.
_runtime_bundle_stale_candidate_reason() {
	local bundle_dir="$1"
	local active_root="$2"
	local candidate_manifest="$bundle_dir/manifest"
	local active_manifest="$active_root/.bundle-manifest"
	local candidate_version="" active_version="" version_relation=""
	local candidate_sha="" active_sha=""
	local repo_dir="${INSTALL_DIR:-}"

	candidate_version=$(_runtime_bundle_manifest_value "$candidate_manifest" framework_version 2>/dev/null || :)
	active_version=$(_runtime_bundle_manifest_value "$active_manifest" framework_version 2>/dev/null || :)
	if [[ -n "$candidate_version" && -n "$active_version" ]]; then
		version_relation=$(_runtime_bundle_compare_versions "$candidate_version" "$active_version" 2>/dev/null || :)
		if [[ "$version_relation" == "-1" ]]; then
			printf 'candidate version %s is older than active version %s' "$candidate_version" "$active_version"
			return 0
		fi
	fi

	candidate_sha=$(_runtime_bundle_manifest_value "$candidate_manifest" git_sha 2>/dev/null || :)
	active_sha=$(_runtime_bundle_manifest_value "$active_manifest" git_sha 2>/dev/null || :)
	[[ -n "$repo_dir" && "$candidate_sha" != "$active_sha" ]] || return 0
	[[ "$candidate_sha" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 0
	[[ "$active_sha" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 0
	git -C "$repo_dir" cat-file -e "${candidate_sha}^{commit}" 2>/dev/null || return 0
	git -C "$repo_dir" cat-file -e "${active_sha}^{commit}" 2>/dev/null || return 0
	if git -C "$repo_dir" merge-base --is-ancestor "$candidate_sha" "$active_sha" 2>/dev/null; then
		printf 'candidate source %.12s is an ancestor of active source %.12s' "$candidate_sha" "$active_sha"
	fi
	return 0
}

_runtime_bundle_validate() {
	local bundle_dir="$1"
	local source_dir="$2"
	local agents_root="$bundle_dir/agents"
	local repo_version=""
	local bundle_version=""

	_verify_deployed_agents_tree "$agents_root" || return 1
	_verify_deployed_core_plugin_freshness "$source_dir" "$agents_root" || return 1
	[[ -x "$agents_root/aidevops.sh" && -r "$bundle_dir/manifest" ]] || return 1
	grep -q '^status=validated$' "$bundle_dir/manifest" || return 1
	if [[ -r "${INSTALL_DIR:-}/VERSION" ]]; then
		IFS= read -r repo_version <"${INSTALL_DIR}/VERSION" || repo_version=""
		IFS= read -r bundle_version <"$agents_root/VERSION" || bundle_version=""
		[[ -n "$repo_version" && "$repo_version" == "$bundle_version" ]] || return 1
	fi
	return 0
}

_runtime_bundle_stage() {
	local repo_dir="$1"
	local source_dir="$2"
	local target_dir="$3"
	local plugins_file="$4"
	shift 4
	local bundles_dir="${target_dir%/*}/runtime-bundles"
	local bundle_dir=""
	local current_root=""
	local version="$_AIDEVOPS_BUNDLE_UNKNOWN"
	local git_sha="$_AIDEVOPS_BUNDLE_UNKNOWN"
	local bundle_id=""

	mkdir -p "$bundles_dir" || return 1
	[[ -r "$repo_dir/VERSION" ]] && IFS= read -r version <"$repo_dir/VERSION"
	git_sha=$(git -C "$repo_dir" rev-parse --short=12 HEAD 2>/dev/null || printf '%s' "$_AIDEVOPS_BUNDLE_UNKNOWN")
	bundle_id="${version//[^A-Za-z0-9._-]/_}-${git_sha}-$(date +%s)-$$"
	bundle_dir=$(mktemp -d "$bundles_dir/.staging.${bundle_id}.XXXXXX") || return 1
	mkdir -p "$bundle_dir/agents" || return 1
	if current_root=$(_runtime_bundle_resolve_root "$target_dir" 2>/dev/null); then
		_runtime_bundle_migrate_plist_env_overrides "$current_root" || {
			rm -rf "$bundle_dir"
			return 1
		}
	fi

	if ! _deploy_agents_copy "$source_dir" "$bundle_dir/agents" "$@"; then
		rm -rf "$bundle_dir"
		return 1
	fi
	if [[ -n "$current_root" ]]; then
		_runtime_bundle_copy_preserved_dirs "$current_root" "$bundle_dir/agents" "$@" || {
			rm -rf "$bundle_dir"
			return 1
		}
	fi
	local user_root="" physical_bundles_dir=""
	user_root=$(_runtime_bundle_user_state_root "$target_dir")
	physical_bundles_dir=$(cd "$bundles_dir" && pwd -P) || physical_bundles_dir=""
	if ! _runtime_bundle_migrate_user_state "$current_root" "$user_root" "$physical_bundles_dir" ||
		! _runtime_bundle_link_user_state "$bundle_dir/agents" "$user_root"; then
		print_error "Failed to prepare stable custom/draft agent state at $user_root"
		rm -rf "$bundle_dir"
		return 1
	fi
	if [[ "${AIDEVOPS_BUNDLE_FAIL_AT:-}" == "after-stage-copy" ]]; then
		rm -rf "$bundle_dir"
		return 1
	fi

	_deploy_agents_post_copy "$bundle_dir/agents" "$repo_dir" "$source_dir" "$plugins_file" || {
		rm -rf "$bundle_dir"
		return 1
	}
	install -m 0755 "$repo_dir/aidevops.sh" "$bundle_dir/agents/aidevops.sh" || {
		rm -rf "$bundle_dir"
		return 1
	}
	if [[ "${AIDEVOPS_BUNDLE_FAIL_AT:-}" == "after-plugin-generation" ]]; then
		rm -rf "$bundle_dir"
		return 1
	fi

	_runtime_bundle_write_manifest "$bundle_dir" "$repo_dir" "$plugins_file" || {
		rm -rf "$bundle_dir"
		return 1
	}
	_runtime_bundle_validate "$bundle_dir" "$source_dir" || {
		rm -rf "$bundle_dir"
		return 1
	}
	if [[ "${AIDEVOPS_BUNDLE_FAIL_AT:-}" == "before-activation" ]]; then
		rm -rf "$bundle_dir"
		return 1
	fi

	bundle_id="${bundle_dir##*/}"
	bundle_id="${bundle_id#.staging.}"
	local final_dir="$bundles_dir/${bundle_id}"
	mv "$bundle_dir" "$final_dir" || {
		rm -rf "$bundle_dir"
		return 1
	}
	_AIDEVOPS_STAGED_BUNDLE_DIR="$final_dir"
	return 0
}

_runtime_bundle_replace_link() {
	local link_tmp="$1"
	local link_path="$2"
	aidevops_runtime_replace_link "$link_tmp" "$link_path"
	return $?
}

_runtime_bundle_switch_link() {
	local target_dir="$1"
	local agents_root="$2"
	aidevops_runtime_switch_link "$target_dir" "$agents_root" || return 1
	return 0
}

_runtime_bundle_size_bytes() {
	local bundle_dir="$1"
	local size_kib=""
	size_kib=$(LC_ALL=C du -sk "$bundle_dir" 2>/dev/null | cut -f1) || return 1
	case "$size_kib" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s' "$((size_kib * 1024))"
	return 0
}

_runtime_bundle_has_live_lease() {
	local lease_dir="$1"
	local lease_file=""
	local lease_pid=""
	local has_live_lease=false
	[[ -d "$lease_dir" ]] || return 1
	for lease_file in "$lease_dir"/*; do
		[[ -f "$lease_file" ]] || continue
		lease_pid="${lease_file##*/}"
		case "$lease_pid" in
		'' | *[!0-9]*) rm -f "$lease_file" ;;
		*)
			# kill -0 can report EPERM for a live process owned by another user.
			if kill -0 "$lease_pid" 2>/dev/null || [[ -d "/proc/$lease_pid" ]] || ps -p "$lease_pid" >/dev/null 2>&1; then
				has_live_lease=true
			else
				rm -f "$lease_file"
			fi
			;;
		esac
	done
	rmdir "$lease_dir" 2>/dev/null || true
	[[ "$has_live_lease" == "true" ]]
}

_runtime_bundle_numeric_limit() {
	local value="$1"
	local fallback="$2"
	case "$value" in
	'' | *[!0-9]*) printf '%s' "$fallback" ;;
	*) printf '%s' "$value" ;;
	esac
	return 0
}

_runtime_bundle_prune() {
	local bundles_dir="$1"
	local active_root="$2"
	local previous_root="$3"
	local candidate_dir=""
	local candidate_agents_root=""
	local bundle_id=""
	local retention_seconds=""
	local max_count=""
	local max_bytes=""
	local now=""
	local modified=""
	local bundle_bytes=""
	local candidate_rows=""
	local pinned_root=""
	local pin_rc=0
	local total_count=0
	local total_bytes=0
	local bytes_known=1
	local should_remove=0

	retention_seconds=$(_runtime_bundle_numeric_limit "${AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS:-2592000}" 2592000)
	max_count=$(_runtime_bundle_numeric_limit "${AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT:-30}" 30)
	max_bytes=$(_runtime_bundle_numeric_limit "${AIDEVOPS_RUNTIME_BUNDLE_MAX_BYTES:-8589934592}" 8589934592)
	now=$(date +%s) || return 1
	if declare -F pulse_runtime_pin_resolve >/dev/null 2>&1; then
		pinned_root=$(pulse_runtime_pin_resolve 2>/dev/null) || pin_rc=$?
		case "$pin_rc" in
		0 | 1 | 3) ;;
		*)
			print_warning "Skipping runtime bundle pruning because the Pulse runtime pin is invalid"
			return 0
			;;
		esac
	fi

	for candidate_dir in "$bundles_dir"/*; do
		[[ -d "$candidate_dir/agents" ]] || continue
		candidate_agents_root=$(cd "$candidate_dir/agents" 2>/dev/null && pwd -P) || continue
		total_count=$((total_count + 1))
		if bundle_bytes=$(_runtime_bundle_size_bytes "$candidate_dir"); then
			total_bytes=$((total_bytes + bundle_bytes))
		else
			bundle_bytes=0
			bytes_known=0
		fi
		[[ "$candidate_agents_root" == "$active_root" || "$candidate_agents_root" == "$previous_root" || "$candidate_agents_root" == "$pinned_root" ]] && continue
		bundle_id="${candidate_dir##*/}"
		if _runtime_bundle_has_live_lease "$bundles_dir/.leases/$bundle_id"; then
			continue
		fi
		modified=$(_file_mtime_epoch "$candidate_dir")
		candidate_rows+="${modified}"$'\t'"${bundle_bytes}"$'\t'"${candidate_dir}"$'\n'
	done

	while IFS=$'\t' read -r modified bundle_bytes candidate_dir; do
		[[ -n "$candidate_dir" ]] || continue
		should_remove=0
		if [[ $((now - modified)) -ge "$retention_seconds" ]] || [[ "$total_count" -gt "$max_count" ]]; then
			should_remove=1
		elif [[ "$bytes_known" -eq 1 && "$total_bytes" -gt "$max_bytes" ]]; then
			should_remove=1
		fi
		[[ "$should_remove" -eq 1 ]] || continue
		rm -rf "$candidate_dir" || return 1
		total_count=$((total_count - 1))
		total_bytes=$((total_bytes - bundle_bytes))
	done < <(printf '%s' "$candidate_rows" | LC_ALL=C sort -n -k1,1)
	rmdir "$bundles_dir/.leases" 2>/dev/null || true
	return 0
}

_runtime_bundle_activate_locked() {
	local target_dir="$1"
	local bundle_dir="$2"
	local agents_root=""
	local bundles_dir=""
	local parent_dir="${target_dir%/*}"
	local previous_link="$parent_dir/previous-runtime-bundle"
	local previous_root=""
	local legacy_dir=""
	local stale_reason=""
	agents_root=$(_runtime_bundle_resolve_root "$bundle_dir/agents") || return 1
	bundles_dir=$(cd "${bundle_dir%/*}" && pwd -P) || return 1

	if previous_root=$(_runtime_bundle_resolve_root "$target_dir" 2>/dev/null); then
		stale_reason=$(_runtime_bundle_stale_candidate_reason "$bundle_dir" "$previous_root")
		if [[ -n "$stale_reason" ]]; then
			print_error "Refusing stale runtime bundle activation: ${stale_reason}. Use 'aidevops runtime-bundle rollback --help' for the dedicated audited rollback operation instead of setup."
			return 1
		fi
		_AIDEVOPS_PREVIOUS_BUNDLE_ROOT="$previous_root"
	fi
	if [[ -d "$target_dir" && ! -L "$target_dir" ]]; then
		legacy_dir="${bundle_dir%/*}/legacy-$(date +%s)-$$"
		mkdir -p "$legacy_dir" || return 1
		mv "$target_dir" "$legacy_dir/agents" || return 1
		previous_root=$(_runtime_bundle_resolve_root "$legacy_dir/agents") || return 1
		_AIDEVOPS_PREVIOUS_BUNDLE_ROOT="$previous_root"
	fi

	if ! _runtime_bundle_switch_link "$target_dir" "$agents_root"; then
		if [[ -n "$previous_root" ]]; then
			_runtime_bundle_switch_link "$target_dir" "$previous_root" || true
		fi
		return 1
	fi
	if [[ "${AIDEVOPS_BUNDLE_FAIL_AT:-}" == "after-activation" ]] ||
		[[ "$(_runtime_bundle_resolve_root "$target_dir" 2>/dev/null || true)" != "$agents_root" ]]; then
		if [[ -n "$previous_root" ]]; then
			_runtime_bundle_switch_link "$target_dir" "$previous_root" || return 1
		else
			rm -f "$target_dir"
		fi
		return 1
	fi

	# Commit the stamp while the activation lock is still held. Later setup
	# stages may fail or be interrupted; they must not leave a stale stamp.
	if ! _runtime_bundle_write_active_sha "$target_dir"; then
		if [[ -n "$previous_root" ]]; then
			_runtime_bundle_switch_link "$target_dir" "$previous_root" || return 1
		else
			rm -f "$target_dir"
		fi
		return 1
	fi
	# Do not destroy the previous rollback target on an aborted activation.
	if [[ -n "$previous_root" ]]; then
		local previous_tmp="${previous_link}.tmp.$$"
		rm -f "$previous_tmp"
		ln -s "$previous_root" "$previous_tmp" && _runtime_bundle_replace_link "$previous_tmp" "$previous_link" || rm -f "$previous_tmp"
	fi
	_AIDEVOPS_ACTIVE_BUNDLE_ROOT="$agents_root"
	_runtime_bundle_prune "$bundles_dir" "$agents_root" "$previous_root"
	return 0
}

_runtime_bundle_activate() {
	local target_dir="$1"
	local bundle_dir="$2"
	local activate_rc=0
	_AIDEVOPS_ACTIVE_BUNDLE_ROOT=""
	_AIDEVOPS_PREVIOUS_BUNDLE_ROOT=""
	_AIDEVOPS_PREVIOUS_DEPLOYED_SHA=""

	if ! aidevops_runtime_transition_lock_acquire; then
		print_error "Unable to acquire the runtime activation lock"
		return 1
	fi
	if [[ -f "${target_dir%/*}/.deployed-sha" ]]; then
		IFS= read -r _AIDEVOPS_PREVIOUS_DEPLOYED_SHA <"${target_dir%/*}/.deployed-sha" || true
	fi
	_runtime_bundle_activate_locked "$target_dir" "$bundle_dir" || activate_rc=$?
	# Carry exact activation ownership across the CLI's setup subprocess. Never
	# infer the candidate from the active link after setup returns: it may have
	# been replaced by a concurrent deployment by then.
	if [[ "$activate_rc" -eq 0 && -n "${AIDEVOPS_UPDATE_ROLLBACK_RECEIPT:-}" ]]; then
		if ! printf '%s\n' "$_AIDEVOPS_ACTIVE_BUNDLE_ROOT" "${_AIDEVOPS_PREVIOUS_BUNDLE_ROOT:-}" \
			"${_AIDEVOPS_PREVIOUS_DEPLOYED_SHA:-}" >"$AIDEVOPS_UPDATE_ROLLBACK_RECEIPT"; then
			_runtime_bundle_rollback_locked "$target_dir" || true
			activate_rc=1
		fi
	fi
	aidevops_runtime_transition_lock_release
	[[ "$activate_rc" -eq 0 ]] || return "$activate_rc"
	return 0
}
