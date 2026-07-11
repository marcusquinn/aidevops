#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Skills and Plugin Library
# =============================================================================
# Skill and plugin management functions extracted from aidevops.sh to keep
# the orchestrator under the 2000-line file-size threshold.
#
# Covers:
#   1. Skills: _skill_help, _skill_add_usage, cmd_skill, cmd_skills
#   2. Plugins: _plugin_validate_ns, _plugin_field, _plugin_add, _plugin_list,
#      _plugin_update, _plugin_toggle, _plugin_remove, _plugin_scaffold,
#      _plugin_help, cmd_plugin
#
# Usage: source "${SCRIPT_DIR}/aidevops-skills-plugin-lib.sh"
#
# Dependencies:
#   - INSTALL_DIR, AGENTS_DIR, CONFIG_DIR (set by aidevops.sh)
#   - print_* helpers and utility functions (defined in aidevops.sh before sourcing)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AIDEVOPS_SKILLS_PLUGIN_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_SKILLS_PLUGIN_LIB_LOADED=1

_PLUGIN_SOURCE_TRUST_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plugin-source-trust-lib.sh"
if [[ ! -f "$_PLUGIN_SOURCE_TRUST_LIB" ]]; then
	printf 'Plugin source trust library not found: %s\n' "$_PLUGIN_SOURCE_TRUST_LIB" >&2
	return 1
fi
# shellcheck source=../plugin-source-trust-lib.sh
source "$_PLUGIN_SOURCE_TRUST_LIB"

# Skill help text (extracted for complexity reduction)
_skill_help() {
	print_header "Agent Skills Management"
	echo ""
	echo "Import and manage reusable AI agent skills from the community."
	echo "Skills are converted to aidevops format with upstream tracking."
	echo "Telemetry is disabled - no data sent to third parties."
	echo ""
	echo "Usage: aidevops skill <command> [options]"
	echo ""
	echo "Commands:"
	echo "  add <source>     Import a skill from GitHub (saved as *-skill.md)"
	echo "  list             List all imported skills"
	echo "  check            Check for upstream updates"
	echo "  update [name]    Update specific or all skills"
	echo "  remove <name>    Remove an imported skill"
	echo "  scan [name]      Security scan imported skills (Cisco Skill Scanner)"
	echo "  status           Show detailed skill status"
	echo "  generate         Generate SKILL.md stubs for cross-tool discovery"
	echo "  clean            Remove generated SKILL.md stubs"
	echo ""
	echo "Source formats:"
	echo "  owner/repo                    GitHub shorthand"
	echo "  owner/repo/path/to/skill      Specific skill in multi-skill repo"
	echo "  https://github.com/owner/repo Full URL"
	echo ""
	echo "Examples:"
	echo "  aidevops skill add vercel-labs/agent-skills"
	echo "  aidevops skill add anthropics/skills/pdf"
	echo "  aidevops skill add expo/skills --name expo-dev"
	echo "  aidevops skill check"
	echo "  aidevops skill update"
	echo "  aidevops skill scan"
	echo "  aidevops skill scan cloudflare-platform"
	echo "  aidevops skill generate --dry-run"
	echo ""
	echo "Imported skills are saved with a -skill suffix to distinguish"
	echo "from native aidevops subagents (e.g., playwright-skill.md vs playwright.md)."
	echo ""
	echo "Browse community skills: https://skills.sh"
	echo "Agent Skills specification: https://agentskills.io"
	return 0
}

_skill_add_usage() {
	print_error "Source required (owner/repo or URL)"
	echo ""
	echo "Usage: aidevops skill add <source> [options]"
	echo ""
	echo "Examples:"
	echo "  aidevops skill add vercel-labs/agent-skills"
	echo "  aidevops skill add anthropics/skills/pdf"
	echo "  aidevops skill add https://github.com/owner/repo"
	echo ""
	echo "Options:"
	echo "  --name <name>   Override the skill name"
	echo "  --force         Overwrite existing skill"
	echo "  --dry-run       Preview without making changes"
	echo ""
	echo "Browse skills: https://skills.sh"
	return 0
}

# Skill management command
cmd_skill() {
	local action="${1:-help}"
	shift || true
	export DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 SKILLS_NO_TELEMETRY=1
	local add_skill_script="$AGENTS_DIR/scripts/add-skill-helper.sh"
	local update_skill_script="$AGENTS_DIR/scripts/skill-update-helper.sh"
	case "$action" in
	add | a)
		if [[ $# -lt 1 ]]; then
			_skill_add_usage
			return 1
		fi
		[[ ! -f "$add_skill_script" ]] && {
			print_error "add-skill-helper.sh not found"
			print_info "Run 'aidevops update' to get the latest scripts"
			return 1
		}
		bash "$add_skill_script" add "$@"
		;;
	list | ls | l)
		[[ ! -f "$add_skill_script" ]] && {
			print_error "add-skill-helper.sh not found"
			return 1
		}
		bash "$add_skill_script" list
		;;
	check | c)
		[[ ! -f "$update_skill_script" ]] && {
			print_error "skill-update-helper.sh not found"
			return 1
		}
		bash "$update_skill_script" check "$@"
		;;
	update | u)
		[[ ! -f "$update_skill_script" ]] && {
			print_error "skill-update-helper.sh not found"
			return 1
		}
		bash "$update_skill_script" update "$@"
		;;
	remove | rm)
		[[ $# -lt 1 ]] && {
			print_error "Skill name required"
			echo "Usage: aidevops skill remove <name>"
			return 1
		}
		[[ ! -f "$add_skill_script" ]] && {
			print_error "add-skill-helper.sh not found"
			return 1
		}
		bash "$add_skill_script" remove "$@"
		;;
	status | s)
		[[ ! -f "$update_skill_script" ]] && {
			print_error "skill-update-helper.sh not found"
			return 1
		}
		bash "$update_skill_script" status "$@"
		;;
	generate | gen | g)
		local gs="$AGENTS_DIR/scripts/generate-skills.sh"
		[[ ! -f "$gs" ]] && {
			print_error "generate-skills.sh not found"
			print_info "Run 'aidevops update' to get the latest scripts"
			return 1
		}
		print_info "Generating SKILL.md stubs for cross-tool discovery..."
		bash "$gs" "$@"
		;;
	scan)
		local ss="$AGENTS_DIR/scripts/security-helper.sh"
		[[ ! -f "$ss" ]] && {
			print_error "security-helper.sh not found"
			print_info "Run 'aidevops update' to get the latest scripts"
			return 1
		}
		bash "$ss" skill-scan "$@"
		;;
	clean)
		local gs="$AGENTS_DIR/scripts/generate-skills.sh"
		[[ ! -f "$gs" ]] && {
			print_error "generate-skills.sh not found"
			return 1
		}
		bash "$gs" --clean "$@"
		;;
	help | --help | -h) _skill_help ;;
	*)
		print_error "Unknown skill command: $action"
		echo "Run 'aidevops skill help' for usage information."
		return 1
		;;
	esac
	return 0
}

# Plugin management helpers (extracted for complexity reduction)
_PLUGIN_RESERVED="custom draft scripts tools services workflows templates memory plugins seo wordpress aidevops"

_plugin_validate_ns() {
	local ns="$1"
	if [[ ! "$ns" =~ ^[a-z][a-z0-9-]*$ ]]; then
		print_error "Invalid namespace '$ns': must be lowercase alphanumeric with hyphens, starting with a letter"
		return 1
	fi
	case " $_PLUGIN_RESERVED " in
	*" $ns "*)
		print_error "Namespace '$ns' is reserved."
		return 1
		;;
	esac
	return 0
}

_plugin_field() {
	local pf="$1" n="$2" f="$3"
	jq -r --arg n "$n" --arg f "$f" '.plugins[] | select(.name == $n) | .[$f] // empty' "$pf" 2>/dev/null || echo ""
	return 0
}

_plugin_validate_candidate() {
	local pf="$1"
	local ad="$2"
	local plugin_name="$3"
	local stage_dir="$4"
	local loader="$ad/scripts/plugin-loader-helper.sh"

	if [[ ! -f "$loader" ]]; then
		print_error "Plugin validator not found: $loader"
		return 1
	fi
	if ! AIDEVOPS_AGENTS_DIR="$ad" AIDEVOPS_CONFIG_DIR="$(dirname "$pf")" \
		bash "$loader" validate-path "$stage_dir" "$plugin_name"; then
		print_error "Plugin '$plugin_name' failed staged validation"
		return 1
	fi
	return 0
}

_plugin_deploy_registered() {
	local pf="$1"
	local ad="$2"
	local plugin_name="$3"
	local requested_commit="$4"
	local update_trust="$5"
	local enable_plugin="$6"
	local repo=""
	local namespace=""
	local branch=""
	local stage_result=""
	local stage_dir=""
	local resolved_commit=""
	local registry_tmp=""
	local metadata_result=""
	local tree_digest=""
	local metadata_dir=""
	local inventory_json=""
	local marker=""

	repo=$(_plugin_field "$pf" "$plugin_name" "repo")
	namespace=$(_plugin_field "$pf" "$plugin_name" "namespace")
	branch=$(_plugin_field "$pf" "$plugin_name" "branch")
	branch="${branch:-main}"
	if [[ -z "$repo" || -z "$namespace" ]]; then
		print_error "Plugin '$plugin_name' not found"
		return 1
	fi
	_plugin_validate_ns "$namespace" || return 1
	if ! plugin_trust_valid_branch "$branch"; then
		print_error "Invalid branch '$branch' for plugin '$plugin_name'"
		return 1
	fi
	if [[ -n "$requested_commit" ]]; then
		if ! plugin_trust_valid_commit "$requested_commit"; then
			print_error "Commit must be a full 40- or 64-character object ID"
			return 1
		fi
	fi

	stage_result=$(plugin_trust_stage_repository "$ad" "$namespace" "$repo" "$branch" "$requested_commit") || {
		print_error "Failed to stage plugin '$plugin_name'"
		return 1
	}
	IFS=$'\t' read -r stage_dir resolved_commit <<<"$stage_result"
	if ! _plugin_validate_candidate "$pf" "$ad" "$plugin_name" "$stage_dir"; then
		rm -rf "$stage_dir"
		return 1
	fi
	metadata_result=$(plugin_trust_prepare_metadata "$stage_dir" "$ad" "$namespace") || {
		rm -rf "$stage_dir"
		return 1
	}
	IFS=$'\t' read -r tree_digest metadata_dir inventory_json <<<"$metadata_result"

	registry_tmp=$(mktemp "${pf}.tmp.XXXXXX") || {
		rm -rf "$stage_dir" "$metadata_dir"
		return 1
	}
	if ! jq --arg n "$plugin_name" --arg commit "$resolved_commit" --arg digest "$tree_digest" \
		--slurpfile inventory "$inventory_json" \
		--argjson update_trust "$update_trust" --argjson enable_plugin "$enable_plugin" '
		(.plugins[] | select(.name == $n)) |= (
			.deployed_commit = $commit
			| .deployed_tree_digest = $digest
			| .deployed_tree_inventory = $inventory[0]
			| .hooks_enabled = (.hooks_enabled // false)
			| (if $update_trust then .trusted_commit = $commit else . end)
			| (if $enable_plugin then .enabled = true else . end)
		)' "$pf" >"$registry_tmp"; then
		rm -rf "$stage_dir" "$metadata_dir"
		rm -f "$registry_tmp"
		return 1
	fi
	marker=$(plugin_trust_marker_path "$ad" "$namespace")
	if ! plugin_trust_activate_candidate "$stage_dir" "$ad/$namespace" "$registry_tmp" "$pf" "$marker"; then
		rm -rf "$stage_dir"
		rm -rf "$metadata_dir"
		rm -f "$registry_tmp"
		print_error "Failed to activate plugin '$plugin_name'; previous deployment preserved"
		return 1
	fi
	rm -rf "$metadata_dir"
	printf '%s\n' "$resolved_commit"
	return 0
}

_plugin_regenerate_discovery_index() {
	local ad="$1"
	local runtime_generator="$ad/scripts/generate-runtime-config.sh"
	local index_helper="$ad/scripts/subagent-index-helper.sh"

	if [[ -x "$runtime_generator" ]]; then
		if bash "$runtime_generator" all >/dev/null 2>&1; then
			print_success "Runtime config and subagent index regenerated"
			return 0
		fi
		print_warning "Runtime config regeneration encountered issues; trying subagent index only"
	fi

	if [[ -x "$index_helper" ]]; then
		if bash "$index_helper" generate >/dev/null 2>&1; then
			print_success "Subagent index regenerated"
			return 0
		fi
		print_warning "Subagent index regeneration encountered issues"
		return 1
	fi

	print_warning "Subagent index helper not found; run 'aidevops update' to regenerate discovery"
	return 1
}

_plugin_add_usage() {
	print_error "Repository URL required"
	echo ""
	echo "Usage: aidevops plugin add <repo-url> [options]"
	echo ""
	echo "Options:"
	echo "  --namespace <name>   Namespace directory (default: derived from repo name)"
	echo "  --branch <branch>    Branch to track (default: main)"
	echo "  --name <name>        Human-readable name (default: derived from repo)"
	echo ""
	echo "Examples:"
	echo "  aidevops plugin add https://github.com/marcusquinn/aidevops-pro.git --namespace pro"
	echo "  aidevops plugin add https://github.com/marcusquinn/aidevops-anon.git --namespace anon"
	return 0
}

_plugin_add_deploy() {
	local pf="$1" ad="$2" repo_url="$3" branch="$4" namespace="$5" plugin_name="$6"
	local stage_result="" stage_dir="" resolved_commit=""
	local metadata_result="" tree_digest="" metadata_dir="" inventory_json=""
	local registry_tmp="" marker=""

	stage_result=$(plugin_trust_stage_repository "$ad" "$namespace" "$repo_url" "$branch" "") || {
		print_error "Failed to stage repository"
		return 1
	}
	IFS=$'\t' read -r stage_dir resolved_commit <<<"$stage_result"
	if ! _plugin_validate_candidate "$pf" "$ad" "$plugin_name" "$stage_dir"; then
		rm -rf "$stage_dir"
		return 1
	fi
	metadata_result=$(plugin_trust_prepare_metadata "$stage_dir" "$ad" "$namespace") || {
		rm -rf "$stage_dir"
		return 1
	}
	IFS=$'\t' read -r tree_digest metadata_dir inventory_json <<<"$metadata_result"
	registry_tmp=$(mktemp "${pf}.tmp.XXXXXX") || {
		rm -rf "$stage_dir" "$metadata_dir"
		return 1
	}
	if ! jq --arg name "$plugin_name" --arg repo "$repo_url" --arg branch "$branch" \
		--arg ns "$namespace" --arg commit "$resolved_commit" --arg digest "$tree_digest" \
		--slurpfile inventory "$inventory_json" '
		.plugins += [{"name": $name, "repo": $repo, "branch": $branch, "namespace": $ns,
			"enabled": true, "trusted_commit": $commit, "deployed_commit": $commit,
			"deployed_tree_digest": $digest, "deployed_tree_inventory": $inventory[0],
			"hooks_enabled": false}]' "$pf" >"$registry_tmp"; then
		rm -rf "$stage_dir" "$metadata_dir"
		rm -f "$registry_tmp"
		return 1
	fi
	marker=$(plugin_trust_marker_path "$ad" "$namespace")
	if ! plugin_trust_activate_candidate "$stage_dir" "$ad/$namespace" "$registry_tmp" "$pf" "$marker"; then
		rm -rf "$stage_dir" "$metadata_dir"
		rm -f "$registry_tmp"
		print_error "Failed to activate plugin '$plugin_name'"
		return 1
	fi
	rm -rf "$metadata_dir"
	print_success "Plugin '$plugin_name' installed at trusted commit ${resolved_commit:0:12}"
	return 0
}

_plugin_add() {
	local pf="$1" ad="$2"
	shift 2
	if [[ $# -lt 1 ]]; then
		_plugin_add_usage
		return 1
	fi
	local repo_url="$1"
	shift
	local namespace="" branch="main" plugin_name=""
	while [[ $# -gt 0 ]]; do
		local _opt="$1" _val="${2:-}"
		case "$_opt" in
		--namespace | --ns)
			namespace="$_val"
			shift 2
			;;
		--branch | -b)
			branch="$_val"
			shift 2
			;;
		--name | -n)
			plugin_name="$_val"
			shift 2
			;;
		*)
			print_error "Unknown option: $_opt"
			return 1
			;;
		esac
	done
	[[ -z "$namespace" ]] && {
		namespace=$(basename "$repo_url" .git | sed 's/^aidevops-//')
		namespace=$(echo "$namespace" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
	}
	[[ -z "$plugin_name" ]] && plugin_name="$namespace"
	_plugin_validate_ns "$namespace" || return 1
	if ! plugin_trust_valid_branch "$branch"; then
		print_error "Invalid branch '$branch'"
		return 1
	fi
	local existing
	existing=$(jq -r --arg n "$plugin_name" '.plugins[] | select(.name == $n) | .name' "$pf" 2>/dev/null || echo "")
	[[ -n "$existing" ]] && {
		print_error "Plugin '$plugin_name' already exists. Use 'aidevops plugin update $plugin_name' to update."
		return 1
	}
	if [[ -d "$ad/$namespace" ]]; then
		local ns_owner
		ns_owner=$(jq -r --arg ns "$namespace" '.plugins[] | select(.namespace == $ns) | .name' "$pf" 2>/dev/null || echo "")
		[[ -n "$ns_owner" ]] && print_error "Namespace '$namespace' is already used by plugin '$ns_owner'" || {
			print_error "Directory '$ad/$namespace/' already exists"
			echo "  Choose a different namespace with --namespace <name>"
		}
		return 1
	fi
	print_info "Adding plugin '$plugin_name' from $repo_url..."
	print_info "  Namespace: $namespace"
	print_info "  Branch: $branch"
	_plugin_add_deploy "$pf" "$ad" "$repo_url" "$branch" "$namespace" "$plugin_name" || return 1
	_plugin_regenerate_discovery_index "$ad" || true
	echo ""
	echo "  Agents available at: ~/.aidevops/agents/$namespace/"
	echo "  Update: aidevops plugin update $plugin_name"
	echo "  Remove: aidevops plugin remove $plugin_name"
	return 0
}

_plugin_list() {
	local pf="$1"
	local count
	count=$(jq '.plugins | length' "$pf" 2>/dev/null || echo "0")
	if [[ "$count" == "0" ]]; then
		echo "No plugins installed."
		echo ""
		echo "Add a plugin: aidevops plugin add <repo-url> --namespace <name>"
		return 0
	fi
	echo "Installed plugins ($count):"
	echo ""
	printf "  %-15s %-10s %-8s %-8s %-12s %s\n" "NAME" "NAMESPACE" "ENABLED" "HOOKS" "COMMIT" "REPO"
	printf "  %-15s %-10s %-8s %-8s %-12s %s\n" "----" "---------" "-------" "-----" "------" "----"
	jq -r '.plugins[] | [.name, .namespace, (.enabled // true | tostring), (.hooks_enabled // false | tostring), (.trusted_commit // "untrusted"), .repo] | @tsv' "$pf" 2>/dev/null |
		while IFS=$'\t' read -r name ns enabled hooks commit repo; do
			local si="yes"
			local hi="no"
			[[ "$enabled" == "false" ]] && si="no"
			[[ "$hooks" == "true" ]] && hi="yes"
			[[ "$commit" != "untrusted" ]] && commit="${commit:0:12}"
			printf "  %-15s %-10s %-8s %-8s %-12s %s\n" "$name" "$ns" "$si" "$hi" "$commit" "$repo"
		done
	return 0
}

_plugin_update() {
	local pf="$1" ad="$2" target="${3:-}"
	if [[ -n "$target" ]]; then
		print_info "Updating plugin '$target'..."
		local commit=""
		commit=$(_plugin_deploy_registered "$pf" "$ad" "$target" "" true false) || return 1
		print_success "Plugin '$target' trusted and updated to ${commit:0:12}"
		_plugin_regenerate_discovery_index "$ad" || true
	else
		local names
		names=$(jq -r '.plugins[] | select(.enabled != false) | .name' "$pf" 2>/dev/null || echo "")
		[[ -z "$names" ]] && {
			echo "No enabled plugins to update."
			return 0
		}
		local failed=0
		while IFS= read -r pn; do
			[[ -z "$pn" ]] && continue
			print_info "Updating '$pn'..."
			if _plugin_deploy_registered "$pf" "$ad" "$pn" "" true false >/dev/null; then
				print_success "  '$pn' updated"
			else
				print_error "  '$pn' failed to update"
				failed=$((failed + 1))
			fi
		done <<<"$names"
		[[ "$failed" -gt 0 ]] && {
			print_warning "$failed plugin(s) failed to update"
			return 1
		}
		print_success "All plugins updated"
		_plugin_regenerate_discovery_index "$ad" || true
	fi
	return 0
}

_plugin_trust() {
	local pf="$1"
	local ad="$2"
	local plugin_name="${3:-}"
	shift 3 || true
	local commit=""

	if [[ -z "$plugin_name" ]]; then
		print_error "Plugin name required"
		echo "Usage: aidevops plugin trust <name> [--commit <full-object-id>]"
		return 1
	fi
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--commit)
			commit="${2:-}"
			shift 2
			;;
		*)
			print_error "Unknown option: $option"
			return 1
			;;
		esac
	done
	print_info "Staging and validating plugin '$plugin_name'..."
	local deployed_commit=""
	deployed_commit=$(_plugin_deploy_registered "$pf" "$ad" "$plugin_name" "$commit" true false) || return 1
	_plugin_regenerate_discovery_index "$ad" || true
	print_success "Plugin '$plugin_name' trusted at commit $deployed_commit"
	return 0
}

_plugin_hooks_authorize() {
	local pf="$1"
	local ad="$2"
	local plugin_name="$3"
	local action="$4"
	local enabled=""
	local registry_tmp=""
	local namespace=""
	local marker=""

	if [[ -z "$(_plugin_field "$pf" "$plugin_name" "repo")" ]]; then
		print_error "Plugin '$plugin_name' not found"
		return 1
	fi
	case "$action" in
	enable) enabled=true ;;
	disable) enabled=false ;;
	*)
		print_error "Hook action must be 'enable' or 'disable'"
		return 1
		;;
	esac
	namespace=$(_plugin_field "$pf" "$plugin_name" "namespace")
	marker=$(plugin_trust_marker_path "$ad" "$namespace")
	registry_tmp=$(mktemp "${pf}.tmp.XXXXXX") || return 1
	if ! jq --arg n "$plugin_name" --argjson enabled "$enabled" \
		'(.plugins[] | select(.name == $n)).hooks_enabled = $enabled' "$pf" >"$registry_tmp"; then
		rm -f "$registry_tmp"
		return 1
	fi
	if ! plugin_trust_acquire_write_locks "$pf" "$marker"; then
		rm -f "$registry_tmp"
		return 1
	fi
	if ! mv "$registry_tmp" "$pf"; then
		rm -f "$registry_tmp"
		plugin_trust_release_write_locks "$pf" "$marker" || true
		return 1
	fi
	plugin_trust_release_write_locks "$pf" "$marker" || return 1
	if [[ "$enabled" == "true" ]]; then
		print_success "Hooks authorized for '$plugin_name'; hooks still run only when explicitly invoked"
	else
		print_success "Hooks disabled for '$plugin_name'"
	fi
	return 0
}

_plugin_toggle() {
	local pf="$1" ad="$2" tn="$3" action="$4"
	if [[ "$action" == "enable" ]]; then
		local tr
		tr=$(_plugin_field "$pf" "$tn" "repo")
		[[ -z "$tr" ]] && {
			print_error "Plugin '$tn' not found"
			return 1
		}
		local tns
		tns=$(_plugin_field "$pf" "$tn" "namespace")
		local trusted_commit=""
		trusted_commit=$(_plugin_field "$pf" "$tn" "trusted_commit")
		if ! plugin_trust_valid_commit "$trusted_commit"; then
			print_error "Plugin '$tn' has no trusted commit. Run: aidevops plugin trust $tn"
			return 1
		fi
		print_info "Deploying plugin '$tn' at trusted commit ${trusted_commit:0:12}..."
		_plugin_deploy_registered "$pf" "$ad" "$tn" "$trusted_commit" false true >/dev/null || return 1
		_plugin_regenerate_discovery_index "$ad" || true
		print_success "Plugin '$tn' enabled"
	else
		local tns
		tns=$(_plugin_field "$pf" "$tn" "namespace")
		[[ -z "$tns" ]] && {
			print_error "Plugin '$tn' not found"
			return 1
		}
		local tmp=""
		local marker=""
		tmp=$(mktemp "${pf}.tmp.XXXXXX") || return 1
		if ! jq --arg n "$tn" '(.plugins[] | select(.name == $n)).enabled = false' "$pf" >"$tmp"; then
			rm -f "$tmp"
			return 1
		fi
		marker=$(plugin_trust_marker_path "$ad" "$tns")
		if ! plugin_trust_acquire_write_locks "$pf" "$marker"; then
			rm -f "$tmp"
			return 1
		fi
		if ! mv "$tmp" "$pf"; then
			rm -f "$tmp"
			plugin_trust_release_write_locks "$pf" "$marker" || true
			return 1
		fi
		if [[ -d "$ad/${tns:?}" ]] && ! rm -rf "$ad/${tns:?}"; then
			return 1
		fi
		plugin_trust_release_write_locks "$pf" "$marker" || return 1
		_plugin_regenerate_discovery_index "$ad" || true
		print_success "Plugin '$tn' disabled (config preserved)"
	fi
	return 0
}

_plugin_remove() {
	local pf="$1" ad="$2" tn="$3"
	local tns=""
	local marker=""
	tns=$(_plugin_field "$pf" "$tn" "namespace")
	[[ -z "$tns" ]] && {
		print_error "Plugin '$tn' not found"
		return 1
	}
	local tmp=""
	tmp=$(mktemp "${pf}.tmp.XXXXXX") || return 1
	if ! jq --arg n "$tn" '.plugins = [.plugins[] | select(.name != $n)]' "$pf" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	marker=$(plugin_trust_marker_path "$ad" "$tns")
	if ! plugin_trust_acquire_write_locks "$pf" "$marker"; then
		rm -f "$tmp"
		return 1
	fi
	if ! mv "$tmp" "$pf"; then
		rm -f "$tmp"
		plugin_trust_release_write_locks "$pf" "$marker" || true
		return 1
	fi
	if [[ -d "$ad/${tns:?}" ]]; then
		rm -rf "$ad/${tns:?}" || return 1
		print_info "Removed $ad/$tns/"
	fi
	plugin_trust_release_write_locks "$pf" "$marker" || return 1
	print_success "Plugin '$tn' removed"
	return 0
}

_plugin_scaffold() {
	local ad="$1" td="${2:-.}" pn="${3:-my-plugin}"
	local ns="${4:-$pn}"
	if [[ "$td" != "." && -d "$td" ]]; then
		local ec
		ec=$(find "$td" -maxdepth 1 -type f | wc -l | tr -d ' ')
		[[ "$ec" -gt 0 ]] && {
			print_error "Directory '$td' already has files. Use an empty directory."
			return 1
		}
	fi
	mkdir -p "$td"
	local tpl="$ad/templates/plugin-template"
	[[ ! -d "$tpl" ]] && {
		print_error "Plugin template not found at $tpl"
		print_info "Run 'aidevops update' to get the latest templates."
		return 1
	}
	local pnu
	pnu=$(echo "$pn" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
	sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{PLUGIN_NAME_UPPER}}|$pnu|g" -e "s|{{NAMESPACE}}|$ns|g" -e "s|{{REPO_URL}}|https://github.com/user/aidevops-$ns.git|g" "$tpl/AGENTS.md" >"$td/AGENTS.md"
	sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{PLUGIN_DESCRIPTION}}|$pn plugin for aidevops|g" -e "s|{{NAMESPACE}}|$ns|g" "$tpl/main-agent.md" >"$td/$ns.md"
	mkdir -p "$td/$ns"
	sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{NAMESPACE}}|$ns|g" "$tpl/example-subagent.md" >"$td/$ns/example.md"
	mkdir -p "$td/scripts"
	if [[ -d "$tpl/scripts" ]]; then
		for hf in "$tpl/scripts"/on-*.sh; do
			[[ -f "$hf" ]] || continue
			local hb
			hb=$(basename "$hf")
			sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{NAMESPACE}}|$ns|g" "$hf" >"$td/scripts/$hb"
			chmod +x "$td/scripts/$hb"
		done
	fi
	[[ -f "$tpl/plugin.json" ]] && sed -e "s|{{PLUGIN_NAME}}|$pn|g" -e "s|{{PLUGIN_DESCRIPTION}}|$pn plugin for aidevops|g" -e "s|{{NAMESPACE}}|$ns|g" "$tpl/plugin.json" >"$td/plugin.json"
	print_success "Plugin scaffolded in $td/"
	echo ""
	echo "Structure:"
	echo "  $td/"
	echo "  ├── AGENTS.md              # Plugin documentation"
	echo "  ├── plugin.json            # Plugin manifest"
	echo "  ├── $ns.md           # Main agent"
	echo "  ├── $ns/"
	echo "  │   └── example.md          # Example subagent"
	echo "  └── scripts/"
	echo "      ├── on-init.sh          # Init lifecycle hook"
	echo "      ├── on-load.sh          # Load lifecycle hook"
	echo "      └── on-unload.sh        # Unload lifecycle hook"
	echo ""
	echo "Next steps:"
	echo "  1. Edit plugin.json with your plugin metadata"
	echo "  2. Edit $ns.md with your agent instructions"
	echo "  3. Add subagents to $ns/"
	echo "  4. Push to a git repo"
	echo "  5. Install: aidevops plugin add <repo-url> --namespace $ns"
	return 0
}

_plugin_help() {
	print_header "Plugin Management"
	echo ""
	echo "Manage third-party agent plugins that extend aidevops."
	echo "Plugins deploy to ~/.aidevops/agents/<namespace>/ (isolated from core)."
	echo ""
	echo "Usage: aidevops plugin <command> [options]"
	echo ""
	echo "Commands:"
	echo "  add <repo-url>     Install a plugin from a git repository"
	echo "  list               List installed plugins"
	echo "  update [name]      Trust and deploy the latest tracked commit"
	echo "  trust <name>       Migrate or pin a plugin to an exact commit"
	echo "  enable <name>      Enable a disabled plugin (redeploys files)"
	echo "  disable <name>     Disable a plugin (removes files, keeps config)"
	echo "  hooks <name> <enable|disable>  Authorize explicit lifecycle hooks"
	echo "  remove <name>      Remove a plugin entirely"
	echo "  init [dir] [name] [namespace]  Scaffold a new plugin from template"
	echo ""
	echo "Options for 'add':"
	echo "  --namespace <name>   Directory name under ~/.aidevops/agents/"
	echo "  --branch <branch>    Branch to track (default: main)"
	echo "  --name <name>        Human-readable plugin name"
	echo ""
	echo "Examples:"
	echo "  aidevops plugin add https://github.com/marcusquinn/aidevops-pro.git --namespace pro"
	echo "  aidevops plugin add https://github.com/marcusquinn/aidevops-anon.git --namespace anon"
	echo "  aidevops plugin list"
	echo "  aidevops plugin update"
	echo "  aidevops plugin update pro"
	echo "  aidevops plugin trust pro --commit <full-object-id>"
	echo "  aidevops plugin hooks pro enable"
	echo "  aidevops plugin disable pro"
	echo "  aidevops plugin enable pro"
	echo "  aidevops plugin remove pro"
	echo "  aidevops plugin init ./my-plugin my-plugin my-plugin"
	echo ""
	echo "Plugin docs: ~/.aidevops/agents/aidevops/plugins.md"
	return 0
}

# Plugin management command
cmd_plugin() {
	local action="${1:-help}"
	shift || true
	local pf="$CONFIG_DIR/plugins.json" ad="$AGENTS_DIR"
	local rc=0
	mkdir -p "$CONFIG_DIR"
	[[ ! -f "$pf" ]] && echo '{"plugins":[]}' >"$pf"
	case "$action" in
	add | a) _plugin_add "$pf" "$ad" "$@" || rc=$? ;;
	list | ls | l) _plugin_list "$pf" || rc=$? ;;
	update | u) _plugin_update "$pf" "$ad" "$@" || rc=$? ;;
	trust) _plugin_trust "$pf" "$ad" "$@" || rc=$? ;;
	hooks)
		if [[ $# -lt 2 ]]; then
			print_error "Plugin name and hook authorization action required"
			echo "Usage: aidevops plugin hooks <name> <enable|disable>"
			return 1
		fi
		local _hooks_name="$1"
		local _hooks_action="$2"
		_plugin_hooks_authorize "$pf" "$ad" "$_hooks_name" "$_hooks_action" || rc=$?
		;;
	enable)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin enable <name>"
			return 1
		}
		local _enable_name="$1"
		_plugin_toggle "$pf" "$ad" "$_enable_name" enable || rc=$?
		;;
	disable)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin disable <name>"
			return 1
		}
		local _disable_name="$1"
		_plugin_toggle "$pf" "$ad" "$_disable_name" disable || rc=$?
		;;
	remove | rm)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin remove <name>"
			return 1
		}
		local _remove_name="$1"
		_plugin_remove "$pf" "$ad" "$_remove_name" || rc=$?
		;;
	init) _plugin_scaffold "$ad" "$@" || rc=$? ;;
	help | --help | -h) _plugin_help || rc=$? ;;
	*)
		print_error "Unknown plugin command: $action"
		echo "Run 'aidevops plugin help' for usage information."
		return 1
		;;
	esac
	return "$rc"
}

# Skills discovery command - search, browse, describe installed skills
cmd_skills() {
	local action="${1:-help}"
	shift || true

	local skills_helper="$AGENTS_DIR/scripts/skills-helper.sh"

	if [[ ! -f "$skills_helper" ]]; then
		print_error "skills-helper.sh not found"
		print_info "Run 'aidevops update' to get the latest scripts"
		return 1
	fi

	case "$action" in
	search | s | find | f)
		bash "$skills_helper" search "$@"
		;;
	browse | b)
		bash "$skills_helper" browse "$@"
		;;
	describe | desc | d | show)
		bash "$skills_helper" describe "$@"
		;;
	info | i | meta)
		bash "$skills_helper" info "$@"
		;;
	list | ls | l)
		bash "$skills_helper" list "$@"
		;;
	categories | cats | cat)
		bash "$skills_helper" categories "$@"
		;;
	recommend | rec | suggest)
		bash "$skills_helper" recommend "$@"
		;;
	install | add)
		bash "$skills_helper" install "$@"
		;;
	registry | online)
		bash "$skills_helper" registry "$@"
		;;
	help | --help | -h)
		print_header "Skill Discovery & Exploration"
		echo ""
		echo "Discover, explore, and get recommendations for installed skills."
		echo "For importing/managing skills, use: aidevops skill <cmd>"
		echo ""
		echo "Usage: aidevops skills <command> [options]"
		echo ""
		echo "Commands:"
		echo "  search <query>          Search installed skills by keyword"
		echo "  search --registry <q>   Search the public skills.sh registry (online)"
		echo "  browse [category]       Browse skills by category"
		echo "  describe <name>         Show detailed skill description"
		echo "  info <name>             Show skill metadata (path, source, model tier)"
		echo "  list [filter]           List skills (--imported, --native, --all)"
		echo "  categories              List all categories with skill counts"
		echo "  recommend <task>        Suggest skills for a task description"
		echo "  install <owner/repo@s>  Install a skill from the public registry"
		echo ""
		echo "Options:"
		echo "  --json                  Output in JSON format (for scripting)"
		echo "  --registry, --online    Search the public skills.sh registry"
		echo ""
		echo "Examples:"
		echo "  aidevops skills search \"browser automation\""
		echo "  aidevops skills search --registry \"seo\""
		echo "  aidevops skills browse tools"
		echo "  aidevops skills browse tools/browser"
		echo "  aidevops skills describe playwright"
		echo "  aidevops skills info seo-audit-skill"
		echo "  aidevops skills list --imported"
		echo "  aidevops skills categories"
		echo "  aidevops skills recommend \"deploy a Next.js app\""
		echo "  aidevops skills install vercel-labs/agent-browser@agent-browser"
		echo ""
		echo "See also: aidevops skill help  (import/manage skills)"
		;;
	*)
		# Treat unknown action as a search query
		bash "$skills_helper" search "$action $*"
		;;
	esac
	return 0
}
