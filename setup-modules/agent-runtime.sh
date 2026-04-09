#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Runtime agent conversion: convert and deploy aidevops agents to installed runtimes.
# Extracted from agent-deploy.sh (t1940) — see agent-deploy.sh for core deployment.

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# _convert_agent_frontmatter: strips aidevops-only fields from agent markdown.
# Reads from stdin, writes converted content to stdout.
# Tracks whether we're inside an indented block (subagents list) to correctly
# skip its child lines without stripping other indented YAML fields.
#
# aidevops frontmatter fields stripped (not understood by target runtimes):
#   mode, subagents
#
# Kept/mapped fields (compatible with Claude Code, Cursor, Amp):
#   name, description, tools, model, permissionMode, hooks, mcpServers,
#   maxTurns, initialPrompt, memory, background, isolation
_convert_agent_frontmatter() {
	local in_frontmatter=false
	local frontmatter_started=false
	local in_skip_block=false
	local line_num=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		if [[ $line_num -eq 1 && "$line" == "---" ]]; then
			in_frontmatter=true
			frontmatter_started=true
			echo "$line"
			continue
		fi
		if [[ "$frontmatter_started" == "true" && "$in_frontmatter" == "true" && "$line" == "---" ]]; then
			in_frontmatter=false
			echo "$line"
			continue
		fi
		if [[ "$in_frontmatter" == "true" ]]; then
			# Detect top-level keys (no leading whitespace)
			case "$line" in
			mode:*)
				in_skip_block=false
				continue
				;;
			subagents:*)
				in_skip_block=true
				continue
				;;
			esac
			# If inside a skipped block, consume indented continuation lines
			if [[ "$in_skip_block" == "true" ]]; then
				case "$line" in
				[[:space:]]*)
					# Indented line under a skipped key — skip it
					continue
					;;
				*)
					# Non-indented line — we've left the skip block
					in_skip_block=false
					echo "$line"
					;;
				esac
			else
				echo "$line"
			fi
		else
			echo "$line"
		fi
	done
	return 0
}

# _is_agent_definition: check if a markdown file has agent frontmatter (name: field).
# Returns 0 if the file is an agent definition, 1 otherwise.
_is_agent_definition() {
	local file="$1"
	# Check first 30 lines for name: in YAML frontmatter (fast path)
	head -30 "$file" 2>/dev/null | grep -q '^name:' 2>/dev/null
	return $?
}

# _agent_source_dirs: list directories under agents_source that contain subagents.
# Excludes framework infrastructure directories that are not agent definitions.
# Prints directory paths, one per line.
_agent_source_dirs() {
	local agents_source="$1"
	local dir
	for dir in "$agents_source"/*/; do
		[[ -d "$dir" ]] || continue
		local dirname
		dirname=$(basename "$dir")
		# Skip framework infrastructure directories
		case "$dirname" in
		scripts | reference | prompts | templates | configs | hooks | \
			plugins | bundles | loop-state | advisories | aidevops | \
			custom | draft | tests | rules)
			continue
			;;
		*)
			echo "$dir"
			;;
		esac
	done
	return 0
}

# _collect_agent_files: print "abspath|relpath" lines for all deployable agent files
# under agents_source. Excludes AGENTS.md, SKILL.md stubs, and non-agent markdown.
# Output is consumed by deploy_agents_to_runtimes via a process substitution.
_collect_agent_files() {
	local agents_source="$1"
	local f bn

	# Top-level agents
	for f in "$agents_source"/*.md; do
		[[ -f "$f" ]] || continue
		bn=$(basename "$f")
		[[ "$bn" == "AGENTS.md" ]] && continue
		if _is_agent_definition "$f"; then
			printf '%s|%s\n' "$f" "$bn"
		fi
	done

	# Subagent directories (recursive)
	local subdir
	while IFS= read -r subdir; do
		while IFS= read -r f; do
			[[ -f "$f" ]] || continue
			bn=$(basename "$f")
			# Skip SKILL.md stubs — they're directory indexes, not real agents
			[[ "$bn" == "SKILL.md" ]] && continue
			if _is_agent_definition "$f"; then
				local relpath="${f#"$agents_source"/}"
				printf '%s|%s\n' "$f" "$relpath"
			fi
		done < <(find "$subdir" -name '*.md' -type f 2>/dev/null)
	done < <(_agent_source_dirs "$agents_source")
	return 0
}

# _deploy_agents_to_single_runtime: convert and copy all agent files to one runtime.
# Arguments: runtime_id agent_dir agent_list_file
# agent_list_file contains "abspath|relpath" lines produced by _collect_agent_files.
# Prints the count of successfully deployed agents to stdout.
_deploy_agents_to_single_runtime() {
	local runtime_id="$1"
	local agent_dir="$2"
	local agent_list_file="$3"

	# Only deploy if the runtime is actually installed
	local binary config_path config_dir
	binary=$(rt_binary "$runtime_id")
	config_path=$(rt_config_path "$runtime_id")
	config_dir="$(dirname "$config_path" 2>/dev/null)"

	if ! type -P "$binary" >/dev/null 2>&1 && [[ ! -d "$config_dir" ]]; then
		echo "0"
		return 0
	fi

	mkdir -p "$agent_dir"
	local agent_count=0
	local src rel target target_parent

	while IFS='|' read -r src rel; do
		[[ -n "$src" && -n "$rel" ]] || continue
		target="$agent_dir/$rel"
		target_parent=$(dirname "$target")
		[[ -d "$target_parent" ]] || mkdir -p "$target_parent"
		if _convert_agent_frontmatter <"$src" >"$target"; then
			agent_count=$((agent_count + 1))
		fi
	done <"$agent_list_file"

	echo "$agent_count"
	return 0
}

# deploy_agents_to_runtimes: main entry point called by setup.sh.
# Iterates all installed runtimes with agent directory support, converts and
# deploys aidevops agents (top-level and subagent directories) to each runtime's
# native agent directory. Only files with name: frontmatter are deployed.
# SKILL.md stubs (directory indexes) are excluded.
deploy_agents_to_runtimes() {
	# Source runtime registry if not already loaded
	local registry_script="${INSTALL_DIR:-.}/.agents/scripts/runtime-registry.sh"
	if [[ -z "${_RUNTIME_REGISTRY_LOADED:-}" ]]; then
		if [[ -f "$registry_script" ]]; then
			# shellcheck source=/dev/null
			source "$registry_script"
		else
			print_warning "Runtime registry not found — skipping agent deployment to runtimes"
			return 0
		fi
	fi

	local agents_source="${HOME}/.aidevops/agents"
	if [[ ! -d "$agents_source" ]]; then
		print_warning "No deployed agents found at $agents_source — skipping"
		return 0
	fi

	# Build the agent file list once (shared across all runtimes) into a temp file.
	# Each line: "abspath|relpath"
	local agent_list_file
	agent_list_file=$(mktemp)
	trap 'rm -f "${agent_list_file:-}"' RETURN
	_collect_agent_files "$agents_source" >"$agent_list_file"

	local total_agents
	total_agents=$(wc -l <"$agent_list_file" | tr -d ' ')
	if [[ "$total_agents" -eq 0 ]]; then
		print_warning "No agent definitions found in $agents_source"
		return 0
	fi

	local deployed_count=0
	local runtime_count=0

	# Deploy to each installed runtime
	local runtime_id agent_dir agent_count display_name
	while IFS= read -r runtime_id; do
		agent_dir=$(rt_agent_dir "$runtime_id")
		[[ -z "$agent_dir" ]] && continue

		agent_count=$(_deploy_agents_to_single_runtime "$runtime_id" "$agent_dir" "$agent_list_file")
		# A count of 0 means runtime not installed (skipped) — don't increment runtime_count
		if [[ "$agent_count" -gt 0 ]]; then
			display_name=$(rt_display_name "$runtime_id")
			print_info "Deployed $agent_count agents to $display_name ($agent_dir)"
			deployed_count=$((deployed_count + agent_count))
			runtime_count=$((runtime_count + 1))
		fi
	done < <(rt_list_with_agents)

	if [[ $runtime_count -eq 0 ]]; then
		print_info "No runtimes with agent directory support detected — skipping"
	else
		print_success "Deployed $deployed_count agent(s) across $runtime_count runtime(s)"
	fi

	return 0
}
