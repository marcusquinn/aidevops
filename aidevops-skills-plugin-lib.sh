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
}

# Plugin management helpers (extracted for complexity reduction)
_PLUGIN_RESERVED="custom draft scripts tools services workflows templates memory plugins seo wordpress aidevops"

_plugin_validate_ns() {
	local ns="$1"
	if [[ ! "$ns" =~ ^[a-z][a-z0-9-]*$ ]]; then
		print_error "Invalid namespace '$ns': must be lowercase alphanumeric with hyphens, starting with a letter"
		return 1
	fi
	local r
	for r in $_PLUGIN_RESERVED; do [[ "$ns" == "$r" ]] && {
		print_error "Namespace '$ns' is reserved."
		return 1
	}; done
	return 0
}

_plugin_field() {
	local pf="$1" n="$2" f="$3"
	jq -r --arg n "$n" --arg f "$f" '.plugins[] | select(.name == $n) | .[$f] // empty' "$pf" 2>/dev/null || echo ""
}

_plugin_add() {
	local pf="$1" ad="$2"
	shift 2
	if [[ $# -lt 1 ]]; then
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
	local clone_dir="$ad/$namespace"
	if ! git clone --branch "$branch" --depth 1 "$repo_url" "$clone_dir" 2>&1; then
		print_error "Failed to clone repository"
		rm -rf "$clone_dir" 2>/dev/null || true
		return 1
	fi
	rm -rf "$clone_dir/.git"
	local tmp="${pf}.tmp"
	jq --arg name "$plugin_name" --arg repo "$repo_url" --arg branch "$branch" --arg ns "$namespace" \
		'.plugins += [{"name": $name, "repo": $repo, "branch": $branch, "namespace": $ns, "enabled": true}]' "$pf" >"$tmp" && mv "$tmp" "$pf"
	local loader="$ad/scripts/plugin-loader-helper.sh"
	[[ -f "$loader" ]] && bash "$loader" hooks "$namespace" init 2>/dev/null || true
	print_success "Plugin '$plugin_name' installed to $clone_dir"
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
	printf "  %-15s %-10s %-8s %s\n" "NAME" "NAMESPACE" "ENABLED" "REPO"
	printf "  %-15s %-10s %-8s %s\n" "----" "---------" "-------" "----"
	jq -r '.plugins[] | "  \(.name)\t\(.namespace)\t\(.enabled // true)\t\(.repo)"' "$pf" 2>/dev/null |
		while IFS=$'\t' read -r name ns enabled repo; do
			local si="yes"
			[[ "$enabled" == "false" ]] && si="no"
			printf "  %-15s %-10s %-8s %s\n" "$name" "$ns" "$si" "$repo"
		done
	return 0
}

_plugin_update() {
	local pf="$1" ad="$2" target="${3:-}"
	if [[ -n "$target" ]]; then
		local repo ns bn
		repo=$(_plugin_field "$pf" "$target" "repo")
		ns=$(_plugin_field "$pf" "$target" "namespace")
		bn=$(_plugin_field "$pf" "$target" "branch")
		bn="${bn:-main}"
		[[ -z "$repo" ]] && {
			print_error "Plugin '$target' not found"
			return 1
		}
		print_info "Updating plugin '$target'..."
		local cd2="$ad/$ns"
		rm -rf "$cd2"
		if git clone --branch "$bn" --depth 1 "$repo" "$cd2" 2>&1; then
			rm -rf "$cd2/.git"
			print_success "Plugin '$target' updated"
		else
			print_error "Failed to update plugin '$target'"
			return 1
		fi
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
			local pr pns pb
			pr=$(_plugin_field "$pf" "$pn" "repo")
			pns=$(_plugin_field "$pf" "$pn" "namespace")
			pb=$(_plugin_field "$pf" "$pn" "branch")
			pb="${pb:-main}"
			print_info "Updating '$pn'..."
			local pd="$ad/$pns"
			rm -rf "$pd"
			if git clone --branch "$pb" --depth 1 "$pr" "$pd" 2>/dev/null; then
				rm -rf "$pd/.git"
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
		local tb
		tb=$(_plugin_field "$pf" "$tn" "branch")
		tb="${tb:-main}"
		local tmp="${pf}.tmp"
		jq --arg n "$tn" '(.plugins[] | select(.name == $n)).enabled = true' "$pf" >"$tmp" && mv "$tmp" "$pf"
		[[ ! -d "$ad/$tns" ]] && {
			print_info "Deploying plugin '$tn'..."
			git clone --branch "$tb" --depth 1 "$tr" "$ad/$tns" 2>/dev/null && rm -rf "$ad/$tns/.git"
		}
		local loader="$ad/scripts/plugin-loader-helper.sh"
		[[ -f "$loader" ]] && bash "$loader" hooks "$tns" init 2>/dev/null || true
		print_success "Plugin '$tn' enabled"
	else
		local tns
		tns=$(_plugin_field "$pf" "$tn" "namespace")
		[[ -z "$tns" ]] && {
			print_error "Plugin '$tn' not found"
			return 1
		}
		local loader="$ad/scripts/plugin-loader-helper.sh"
		[[ -f "$loader" && -d "$ad/$tns" ]] && bash "$loader" hooks "$tns" unload 2>/dev/null || true
		local tmp="${pf}.tmp"
		jq --arg n "$tn" '(.plugins[] | select(.name == $n)).enabled = false' "$pf" >"$tmp" && mv "$tmp" "$pf"
		[[ -d "$ad/${tns:?}" ]] && rm -rf "$ad/${tns:?}"
		print_success "Plugin '$tn' disabled (config preserved)"
	fi
	return 0
}

_plugin_remove() {
	local pf="$1" ad="$2" tn="$3"
	local tns
	tns=$(_plugin_field "$pf" "$tn" "namespace")
	[[ -z "$tns" ]] && {
		print_error "Plugin '$tn' not found"
		return 1
	}
	local loader="$ad/scripts/plugin-loader-helper.sh"
	[[ -f "$loader" && -d "$ad/$tns" ]] && bash "$loader" hooks "$tns" unload 2>/dev/null || true
	[[ -d "$ad/${tns:?}" ]] && {
		rm -rf "$ad/${tns:?}"
		print_info "Removed $ad/$tns/"
	}
	local tmp="${pf}.tmp"
	jq --arg n "$tn" '.plugins = [.plugins[] | select(.name != $n)]' "$pf" >"$tmp" && mv "$tmp" "$pf"
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
	echo "  update [name]      Update specific or all plugins"
	echo "  enable <name>      Enable a disabled plugin (redeploys files)"
	echo "  disable <name>     Disable a plugin (removes files, keeps config)"
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
	mkdir -p "$CONFIG_DIR"
	[[ ! -f "$pf" ]] && echo '{"plugins":[]}' >"$pf"
	case "$action" in
	add | a) _plugin_add "$pf" "$ad" "$@" ;;
	list | ls | l) _plugin_list "$pf" ;;
	update | u) _plugin_update "$pf" "$ad" "$@" ;;
	enable)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin enable <name>"
			return 1
		}
		local _enable_name="$1"
		_plugin_toggle "$pf" "$ad" "$_enable_name" enable
		;;
	disable)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin disable <name>"
			return 1
		}
		local _disable_name="$1"
		_plugin_toggle "$pf" "$ad" "$_disable_name" disable
		;;
	remove | rm)
		[[ $# -lt 1 ]] && {
			print_error "Plugin name required"
			echo "Usage: aidevops plugin remove <name>"
			return 1
		}
		local _remove_name="$1"
		_plugin_remove "$pf" "$ad" "$_remove_name"
		;;
	init) _plugin_scaffold "$ad" "$@" ;;
	help | --help | -h) _plugin_help ;;
	*)
		print_error "Unknown plugin command: $action"
		echo "Run 'aidevops plugin help' for usage information."
		return 1
		;;
	esac
	return 0
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
}
