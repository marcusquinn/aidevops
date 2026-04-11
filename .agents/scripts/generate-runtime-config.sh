#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Unified Runtime Config Generator
# =============================================================================
# Single entry point for generating agent, command, and MCP configurations
# for all installed AI coding assistant runtimes.
#
# Replaces:
#   - generate-opencode-agents.sh   (924 lines)
#   - generate-claude-agents.sh     (879 lines)
#   - generate-opencode-commands.sh (1,439 lines)
#   - generate-claude-commands.sh   (860 lines)
#
# Architecture:
#   Phase 1: Load shared content definitions (agents, commands, MCPs)
#   Phase 2: For each installed runtime, generate config using adapters
#   Phase 3: Verify output integrity
#
# Dependencies:
#   - runtime-registry.sh (t1665.1) — runtime detection and properties
#   - mcp-config-adapter.sh (t1665.2) — MCP config transforms
#   - prompt-injection-adapter.sh (t1665.3) — system prompt deployment
#
# Usage:
#   generate-runtime-config.sh [subcommand] [options]
#
# Subcommands:
#   all              Generate everything for all installed runtimes (default)
#   agents           Generate agent configs only
#   commands         Generate slash commands only
#   mcp              Register MCP servers only
#   prompts          Deploy system prompts only
#   --verify-parity  Compare output with old generators (regression test)
#   --runtime <id>   Generate for a specific runtime only
#   --dry-run        Show what would be generated without writing
#
# Part of t1665 (Runtime abstraction layer), subtask t1665.4.
# Bash 3.2 compatible.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source shared constants for print_info/print_warning/print_success/print_error
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Source runtime registry for detection and property lookups
# shellcheck source=runtime-registry.sh
source "${SCRIPT_DIR}/runtime-registry.sh"

# Source MCP config adapter (library mode)
# shellcheck source=mcp-config-adapter.sh
source "${SCRIPT_DIR}/mcp-config-adapter.sh"

# Source prompt injection adapter (library mode)
# shellcheck source=prompt-injection-adapter.sh
source "${SCRIPT_DIR}/prompt-injection-adapter.sh"

# =============================================================================
# Constants
# =============================================================================

AGENTS_DIR="${HOME}/.aidevops/agents"

# =============================================================================
# Shared MCP Definitions — defined once, consumed by all runtimes
# =============================================================================
# Universal JSON format: {"command":"...","args":[...],"env":{...}}
# These are registered via mcp-config-adapter.sh for each runtime.

# MCP loading policy categories
# Eager: start at runtime launch (used by all main agents)
# Lazy: start on-demand via subagents (default)

# Helper: get the package runner (bun x or npx)
_get_pkg_runner() {
	local bun_path
	bun_path=$(command -v bun 2>/dev/null || echo "")
	if [[ -n "$bun_path" ]]; then
		echo "bun"
	else
		echo "npx"
	fi
	return 0
}

# =============================================================================
# Phase 1: Shared Content — Agent Definitions
# =============================================================================
# Agent auto-discovery from ~/.aidevops/agents/*.md is handled by the Python
# code in _generate_agents_opencode() and _generate_agents_claude() since it
# requires frontmatter parsing, JSON manipulation, and complex data structures
# that are better suited to Python than bash 3.2.
#
# The Python code is shared via a heredoc function that both runtimes call
# with runtime-specific parameters.

# Generate the shared Python agent discovery code.
# This is the single source of truth for agent definitions, tool assignments,
# model tiers, and MCP loading policy.
# Arguments:
#   $1 - runtime_id (opencode, claude-code)
#   $2 - output format (opencode-json, claude-settings)
_run_agent_discovery_python() {
	local runtime_id="$1"
	local output_format="$2"
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	python3 "$script_dir/agent-discovery.py" "$runtime_id" "$output_format"
	return $?
}

# =============================================================================
# Phase 2a: Agent Generation — Per-Runtime Adapters
# =============================================================================

_generate_agents_opencode() {
	print_info "Generating OpenCode agent configuration..."

	local opencode_config_dir="$HOME/.config/opencode"
	local opencode_agent_dir="$opencode_config_dir/agent"
	local opencode_config="$opencode_config_dir/opencode.json"

	mkdir -p "$opencode_agent_dir"

	# Deploy AGENTS.md with version check
	cat >"$opencode_config_dir/AGENTS.md" <<'AGENTSEOF'
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.

## aidevops Framework Status

**On interactive conversation start** (skip this section entirely for headless/command sessions like `/pulse`, `/full-loop`, etc.):
1. If you have Bash tool: Run `bash ~/.aidevops/agents/scripts/aidevops-update-check.sh --interactive`
2. If no Bash tool: Read `~/.aidevops/cache/session-greeting.txt` (cached by agents with Bash) and greet with: "Hi!\n\n{content of file}.\n\nWhat would you like to work on?". If the file doesn't exist, read `~/.aidevops/agents/VERSION` to get the `{version}` and greet with: "Hi!\n\nWe're running https://aidevops.sh v{version}.\n\nWhat would you like to work on?"
3. Then respond to the user's actual message

If you ran the update check script (step 1) and the output starts with `UPDATE_AVAILABLE|` (e.g., `UPDATE_AVAILABLE|2.41.1|2.41.2|OpenCode`), inform user: "Update available (current → latest). Run `aidevops update` in a terminal session to update, or type `!aidevops update` below and hit Enter." If the output also contains a line `AUTO_UPDATE_ENABLED`, replace the manual update instruction with: "Auto-update is enabled and will apply this within ~10 minutes." This check does not apply when falling back to reading the cache or VERSION file (step 2).

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
AGENTSEOF
	print_success "Updated AGENTS.md with version check"

	# Remove legacy agent files
	local legacy_files=(
		"Accounts.md" "Accounting.md" "accounting.md" "AI-DevOps.md" "Build+.md" "Content.md"
		"Health.md" "Legal.md" "Marketing.md" "Research.md" "Sales.md" "SEO.md" "WordPress.md"
		"Plan+.md" "Build-Agent.md" "Build-MCP.md" "build-agent.md" "build-mcp.md"
		"plan-plus.md" "aidevops.md" "Browser-Extension-Dev.md" "Mobile-App-Dev.md" "AGENTS.md"
	)
	local f
	for f in "${legacy_files[@]}"; do
		rm -f "$opencode_agent_dir/$f"
	done

	# Remove loop-state files incorrectly created as agents
	for f in ralph-loop.local.md quality-loop.local.md full-loop.local.md loop-state.md re-anchor.md postflight-loop.md; do
		rm -f "$opencode_agent_dir/$f"
	done

	# Create minimal config if missing
	if [[ ! -f "$opencode_config" ]]; then
		print_warning "$opencode_config not found. Creating minimal config."
		# shellcheck disable=SC2016
		echo '{"$schema": "https://opencode.ai/config.json"}' >"$opencode_config"
	fi

	# Run shared Python agent discovery for OpenCode
	_run_agent_discovery_python "opencode" "opencode-json"

	print_success "Primary agents configured in opencode.json"

	# Generate subagent markdown files
	_generate_subagents_opencode "$opencode_agent_dir"

	# Sync MCP tool index
	local mcp_index_helper="$AGENTS_DIR/scripts/mcp-index-helper.sh"
	if [[ -x "$mcp_index_helper" ]]; then
		if "$mcp_index_helper" sync 2>/dev/null; then
			print_success "MCP tool index updated"
		else
			print_warning "MCP index sync skipped (non-critical)"
		fi
	fi

	return 0
}

# Determine additional MCP tools for a subagent based on its name.
# Arguments: $1 - subagent name (basename without .md)
# Outputs: extra tool lines to stdout (empty if none)
_get_subagent_extra_tools() {
	local name="$1"

	case "$name" in
	outscraper)
		printf '%s\n' '  outscraper_*: true' '  webfetch: true'
		;;
	mainwp | localwp)
		printf '%s\n' '  localwp_*: true'
		;;
	quickfile)
		printf '%s\n' '  quickfile_*: true'
		;;
	google-search-console)
		printf '%s\n' '  gsc_*: true'
		;;
	dataforseo)
		printf '%s\n' '  dataforseo_*: true' '  webfetch: true'
		;;
	claude-code)
		printf '%s\n' '  claude-code-mcp_*: true'
		;;
	openapi-search)
		printf '%s\n' '  openapi-search_*: true' '  webfetch: true'
		;;
	aidevops)
		printf '%s\n' '  openapi-search_*: true'
		;;
	playwriter)
		printf '%s\n' '  playwriter_*: true'
		;;
	shadcn)
		printf '%s\n' '  shadcn_*: true' '  write: true' '  edit: true'
		;;
	macos-automator | mac)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			printf '%s\n' '  macos-automator_*: true' '  webfetch: true'
		fi
		;;
	ios-simulator-mcp)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			printf '%s\n' '  ios-simulator_*: true'
		fi
		;;
	*) ;;
	esac
	return 0
}

# Write a single subagent markdown stub file.
# Arguments: $1 - source .md file path
# Requires: AGENTS_DIR and agent_dir to be set (exported for xargs usage)
# Outputs: "1" to stdout on success (for counting)
_write_subagent_stub() {
	local f="$1"
	local name
	name=$(basename "$f" .md)
	[[ "$name" == "AGENTS" || "$name" == "README" ]] && return 0

	local rel_path="${f#"$AGENTS_DIR"/}"

	# Extract description from source file frontmatter
	local src_desc
	src_desc=$(sed -n '/^---$/,/^---$/{ /^description:/{s/^description: *//p; q} }' "$f" 2>/dev/null)
	if [[ -z "$src_desc" ]]; then
		src_desc="Read ~/.aidevops/agents/${rel_path}"
	fi

	local extra_tools
	extra_tools=$(_get_subagent_extra_tools "$name")

	{
		printf '%s\n' \
			"---" \
			"description: ${src_desc}" \
			"mode: subagent" \
			"temperature: 0.2" \
			"permission:" \
			"  external_directory: allow" \
			"tools:" \
			"  read: true" \
			"  bash: true"
		[[ -n "$extra_tools" ]] && printf '%s\n' "$extra_tools"
		printf '%s\n' \
			"---" \
			"" \
			"**MANDATORY**: Your first action MUST be to read ~/.aidevops/agents/${rel_path} and follow ALL rules within it."
	} >"$agent_dir/$name.md"
	echo 1
	return 0
}

# Remove previously generated subagent files (those with "mode: subagent" frontmatter).
# Arguments: $1 - agent output directory
_clean_generated_subagents() {
	local agent_dir="$1"
	find "$agent_dir" -name "*.md" -type f -exec grep -l "^mode: subagent" {} + 2>/dev/null | while IFS= read -r f; do rm -f "$f"; done
	return 0
}

# Generate subagent markdown stubs for OpenCode
_generate_subagents_opencode() {
	local agent_dir="$1"

	print_info "Generating subagent markdown files..."

	_clean_generated_subagents "$agent_dir"

	export -f _get_subagent_extra_tools 2>/dev/null || true
	export -f _write_subagent_stub 2>/dev/null || true
	export AGENTS_DIR
	export agent_dir

	local _ncpu
	_ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
	local _parallel_jobs=$((_ncpu > 4 ? _ncpu : 4))
	local subagent_count
	subagent_count=$(find "$AGENTS_DIR" -mindepth 2 -name "*.md" -type f -not -path "*/loop-state/*" -not -name "*-skill.md" -print0 |
		xargs -0 -P "$_parallel_jobs" -I {} bash -c '_write_subagent_stub "$@"' _ {} |
		awk '{sum+=$1} END {print sum+0}')

	print_success "Generated $subagent_count subagent files"
	return 0
}

_generate_agents_claude() {
	print_info "Generating Claude Code agent configuration..."

	local claude_settings="$HOME/.claude/settings.json"

	# Ensure directory exists
	mkdir -p "$(dirname "$claude_settings")"

	# Create minimal settings if missing
	if [[ ! -f "$claude_settings" ]]; then
		echo '{}' >"$claude_settings"
		chmod 600 "$claude_settings"
		print_success "Created $claude_settings"
	fi

	# Run shared Python agent discovery for Claude Code
	_run_agent_discovery_python "claude-code" "claude-settings"

	print_success "Claude Code settings updated"
	return 0
}

# =============================================================================
# Phase 2b: Command Generation — Per-Runtime Adapters
# =============================================================================

# Shared command definitions — the body content is defined once here.
# Each runtime adapter writes these to its command directory with the
# appropriate frontmatter format.

# Helper: write a command file for OpenCode format
_write_opencode_command() {
	local cmd_dir="$1"
	local name="$2"
	local description="$3"
	local agent="$4"
	local subtask="$5"
	local body="$6"

	{
		echo "---"
		echo "description: ${description}"
		[[ -n "$agent" ]] && echo "agent: ${agent}"
		[[ "$subtask" == "true" ]] && echo "subtask: true"
		echo "---"
		echo ""
		echo "$body"
	} >"${cmd_dir}/${name}.md"
	return 0
}

# Helper: write a command file for Claude Code format
_write_claude_command() {
	local cmd_dir="$1"
	local name="$2"
	local description="$3"
	# Claude Code doesn't use agent/subtask fields
	local body="$4"

	cat >"${cmd_dir}/${name}.md" <<EOF
---
description: $description
---

$body
EOF
	return 0
}

# Helper: copy a source command file to a destination, stripping only
# OpenCode-specific frontmatter fields that confuse other runtimes.
# Safe default for clients that accept YAML frontmatter + markdown body
# (codex, droid, qwen, kimi, amp, windsurf).
_copy_cmd_strip_opencode_fields() {
	local src="$1"
	local dest="$2"
	sed -E '/^---$/,/^---$/{/^(agent|subtask|mode):/d;}' "$src" >"$dest"
}

# Helper: Cursor command files — Cursor Commands (1.6+) do not support
# YAML frontmatter at all. Strip the entire leading frontmatter block
# and emit only the markdown body.
_copy_cmd_strip_all_frontmatter() {
	local src="$1"
	local dest="$2"
	awk '
		BEGIN { in_fm = 0; past_fm = 0 }
		NR == 1 && /^---$/ { in_fm = 1; next }
		in_fm && /^---$/ { in_fm = 0; past_fm = 1; next }
		in_fm { next }
		{ print }
	' "$src" >"$dest"
}

# Helper: Kiro steering files — copy as-is but ensure the frontmatter
# contains `inclusion: manual` so the file appears as a user-invocable
# slash command rather than an always-on steering document.
_copy_cmd_kiro_steering() {
	local src="$1"
	local dest="$2"
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"
	if grep -q '^inclusion:' "$tmp"; then
		cp "$tmp" "$dest"
	else
		awk '
			NR == 1 && /^---$/ { print; print "inclusion: manual"; next }
			{ print }
		' "$tmp" >"$dest"
	fi
	rm -f "$tmp"
}

# Helper: Continue .prompt files — Continue wants `.prompt` extension
# plus `invokable: true` in the frontmatter for the prompt to appear
# as a slash command in Chat/Plan/Agent modes.
_copy_cmd_continue_prompt() {
	local src="$1"
	local dest="$2" # caller already switched extension to .prompt
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"
	if grep -q '^invokable:' "$tmp"; then
		cp "$tmp" "$dest"
	else
		awk '
			NR == 1 && /^---$/ { print; print "invokable: true"; next }
			{ print }
		' "$tmp" >"$dest"
	fi
	rm -f "$tmp"
}

# Helper: Gemini CLI TOML files — convert markdown with YAML frontmatter
# into Gemini's documented TOML format (geminicli.com/docs/cli/custom-commands).
# Output schema:
#   description = "<extracted from frontmatter>"
#   prompt = """
#   <body after frontmatter>
#   """
# Uses basic multi-line strings (`"""`) by default; falls back to literal
# multi-line strings (`'''`) if the body contains the triple-quote sequence.
_copy_cmd_gemini_toml() {
	local src="$1"
	local dest="$2" # caller already switched extension to .toml
	local description body delim
	local warning_line=""

	# Extract `description:` value from the YAML frontmatter block (first
	# fenced `---` region). Stop at the closing marker.
	description=$(awk '
		/^---$/ {
			if (in_fm) exit
			in_fm = 1
			next
		}
		in_fm && /^description:[[:space:]]*/ {
			sub(/^description:[[:space:]]*/, "")
			sub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$src")

	# Extract the body (everything after the closing frontmatter marker).
	# If the file has no frontmatter, the whole file is the body.
	body=$(awk '
		BEGIN { in_fm = 0; past_fm = 0; has_fm = 0 }
		NR == 1 && /^---$/ { in_fm = 1; has_fm = 1; next }
		in_fm && /^---$/ { in_fm = 0; past_fm = 1; next }
		in_fm { next }
		{ print }
	' "$src")

	# Pick a multi-line string delimiter the body will not collide with.
	delim='"""'
	if printf '%s' "$body" | grep -qF '"""'; then
		delim="'''"
		if printf '%s' "$body" | grep -qF "'''"; then
			warning_line="# WARNING: body contains both \"\"\" and ''' — prompt string may need manual fix-up"
		fi
	fi

	# Escape double quotes in the description (TOML basic string rules).
	local escaped_desc
	escaped_desc=$(printf '%s' "$description" | sed 's/\\/\\\\/g; s/"/\\"/g')

	{
		[[ -n "$warning_line" ]] && echo "$warning_line"
		if [[ -n "$description" ]]; then
			printf 'description = "%s"\n' "$escaped_desc"
		fi
		printf 'prompt = %s\n' "$delim"
		printf '%s\n' "$body"
		printf '%s\n' "$delim"
	} >"$dest"
	return 0
}

# Helper: Kimi CLI Skills — Kimi expects a directory-per-skill layout:
#   ~/.kimi/skills/<name>/SKILL.md
# where the parent directory name MUST match the `name:` frontmatter field.
# This helper creates the subdirectory, writes SKILL.md inside it, and
# injects/corrects the required `name:` and `description:` fields.
#
# Arguments:
#   $1 - source file
#   $2 - skills root dir (e.g. ~/.kimi/skills)
#   $3 - skill name (what the directory is called)
_copy_cmd_kimi_skill() {
	local src="$1"
	local skills_root="$2"
	local name="$3"
	local skill_dir="${skills_root}/${name}"
	local dest="${skill_dir}/SKILL.md"

	mkdir -p "$skill_dir"

	# Strip OpenCode-only fields first so other clients' frontmatter doesn't
	# confuse Kimi's skill loader.
	local tmp
	tmp=$(mktemp)
	_copy_cmd_strip_opencode_fields "$src" "$tmp"

	# Ensure `name:` matches the directory name. If present, replace its
	# value; if absent, inject it right after the opening `---` marker.
	local tmp2
	tmp2=$(mktemp)
	if grep -q '^name:' "$tmp"; then
		sed "s|^name:.*|name: ${name}|" "$tmp" >"$tmp2"
	else
		awk -v n="$name" '
			NR == 1 && /^---$/ { print; print "name: " n; next }
			{ print }
		' "$tmp" >"$tmp2"
	fi

	# Ensure `description:` is present. Kimi requires it for auto-invocation;
	# inject a sensible fallback derived from the skill name if the source
	# file doesn't carry one.
	if grep -q '^description:' "$tmp2"; then
		cp "$tmp2" "$dest"
	else
		awk -v n="$name" '
			NR == 1 && /^---$/ { print; print "description: aidevops primary agent routing command: " n; next }
			{ print }
		' "$tmp2" >"$dest"
	fi

	rm -f "$tmp" "$tmp2"
	return 0
}

# Namespace prefix applied to every slash command deployed to clients.
# Differentiates aidevops commands from native client slash commands and
# groups them alphabetically in the client's command picker.
_AIDEVOPS_CMD_PREFIX="aidevops-"

# Deploy one source command file to a runtime's command directory,
# applying the correct per-runtime format transform.
# Arguments:
#   $1 - runtime_id
#   $2 - source file (full path)
#   $3 - deployed name (WITHOUT extension — format-specific extension added here)
#   $4 - destination command dir
# Returns: 0 on success, 1 on failure.
_deploy_one_command() {
	local runtime_id="$1"
	local src="$2"
	local name="$3"
	local cmd_dir="$4"
	local dest

	case "$runtime_id" in
	opencode)
		# OpenCode is the source format — copy as-is.
		dest="${cmd_dir}/${name}.md"
		cp "$src" "$dest" || return 1
		;;
	claude-code | codex | droid | amp | qwen)
		# Markdown + YAML frontmatter clients: strip opencode-only fields
		# (agent, subtask, mode) that other clients don't recognise.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_strip_opencode_fields "$src" "$dest" || return 1
		;;
	cursor)
		# Cursor Commands (1.6+) do not support YAML frontmatter. Strip it.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_strip_all_frontmatter "$src" "$dest" || return 1
		;;
	kiro)
		# Kiro steering files: add `inclusion: manual` so they appear as
		# user-invocable slash commands rather than always-on steering docs.
		dest="${cmd_dir}/${name}.md"
		_copy_cmd_kiro_steering "$src" "$dest" || return 1
		;;
	continue)
		# Continue: rename extension to .prompt and add `invokable: true`
		# so the file appears as a slash command in Chat/Plan/Agent modes.
		dest="${cmd_dir}/${name}.prompt"
		_copy_cmd_continue_prompt "$src" "$dest" || return 1
		;;
	gemini-cli)
		# Convert markdown + YAML frontmatter to Gemini CLI's documented TOML
		# format: `description = "..."` + `prompt = """..."""`. The helper
		# handles triple-quote collisions by falling back to literal strings.
		dest="${cmd_dir}/${name}.toml"
		_copy_cmd_gemini_toml "$src" "$dest" || return 1
		;;
	kimi)
		# Kimi Skills: directory-per-skill layout. The skill name (= directory
		# name) must match the `name:` frontmatter field. `cmd_dir` here is
		# the parent ~/.kimi/skills dir; the helper creates the subdirectory
		# and writes SKILL.md inside it.
		_copy_cmd_kimi_skill "$src" "$cmd_dir" "$name" || return 1
		;;
	kilo | windsurf | aider)
		# Kilo uses custom modes (different mechanism); Windsurf uses a
		# repo-local dir created by `aidevops init`; Aider has no native
		# slash commands. These are handled elsewhere — skip here.
		return 0
		;;
	*)
		# Unknown runtime: conservative fall-through — copy as-is.
		dest="${cmd_dir}/${name}.md"
		cp "$src" "$dest" || return 1
		;;
	esac
	return 0
}

# Generate all shared commands for a given runtime.
# Reads from two source directories:
#   1. ~/.aidevops/agents/commands/        — main-agent symlinks (already
#                                            prefixed with `aidevops-`)
#   2. ~/.aidevops/agents/scripts/commands/ — skills/workflows/utilities
#                                            (prefix is applied at deploy time)
# Gated on the per-runtime `commands` feature flag.
#
# Arguments: $1=runtime_id
_generate_commands_for_runtime() {
	local runtime_id="$1"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	# Feature flag gate — user can disable commands installation per runtime
	# via AIDEVOPS_FEATURE_COMMANDS_<SUFFIX>=no.
	local feature_enabled
	feature_enabled=$(rt_feature_commands "$runtime_id" 2>/dev/null || echo "yes")
	if [[ "$feature_enabled" != "yes" ]]; then
		print_info "Commands installation disabled for $display_name (feature flag)"
		return 0
	fi

	local cmd_dir
	cmd_dir=$(rt_command_dir "$runtime_id") || cmd_dir=""

	if [[ -z "$cmd_dir" ]]; then
		print_info "No command directory for $display_name — skipping commands"
		return 0
	fi

	mkdir -p "$cmd_dir"

	local command_count=0
	local skipped_count=0

	print_info "Generating $display_name commands..."

	# --- Source 1: .agents/commands/ (main-agent symlinks — already prefixed) ---
	local main_src_dir="$HOME/.aidevops/agents/commands"
	if [[ -d "$main_src_dir" ]]; then
		local cmd_file cmd_name
		for cmd_file in "$main_src_dir"/*.md; do
			[[ -e "$cmd_file" ]] || continue
			cmd_name=$(basename "$cmd_file" .md)

			# Deploy with name as-is (already carries `aidevops-` prefix).
			if ! _deploy_one_command "$runtime_id" "$cmd_file" "$cmd_name" "$cmd_dir"; then
				if [[ ! -e "$cmd_file" ]]; then
					print_warning "Skipping main-agent command $cmd_name: source disappeared"
					skipped_count=$((skipped_count + 1))
					continue
				fi
				print_warning "Failed to deploy main-agent command $cmd_name for $display_name"
				return 1
			fi
			command_count=$((command_count + 1))
		done
	fi

	# --- Source 2: .agents/scripts/commands/ (skills + workflows) ---
	# These files are NOT prefixed at the source — prepend `aidevops-` at deploy.
	local skills_src_dir="$HOME/.aidevops/agents/scripts/commands"
	if [[ -d "$skills_src_dir" ]]; then
		local cmd_file cmd_name deployed_name
		for cmd_file in "$skills_src_dir"/*.md; do
			[[ -f "$cmd_file" ]] || continue
			cmd_name=$(basename "$cmd_file" .md)

			# Skip non-commands
			[[ "$cmd_name" == "SKILL" ]] && continue

			# Apply namespace prefix.
			deployed_name="${_AIDEVOPS_CMD_PREFIX}${cmd_name}"

			if ! _deploy_one_command "$runtime_id" "$cmd_file" "$deployed_name" "$cmd_dir"; then
				if [[ ! -f "$cmd_file" ]]; then
					print_warning "Skipping command $cmd_name: source disappeared"
					skipped_count=$((skipped_count + 1))
					continue
				fi
				print_warning "Failed to deploy command $cmd_name for $display_name"
				return 1
			fi
			command_count=$((command_count + 1))
		done
	fi

	# Generate hardcoded commands that aren't in scripts/commands/
	# These are runtime-specific commands that have inline body content
	_generate_hardcoded_commands "$runtime_id" "$cmd_dir"
	local hc_count=$?
	command_count=$((command_count + hc_count))

	if [[ "$skipped_count" -gt 0 ]]; then
		print_warning "$display_name: skipped $skipped_count command file(s) that disappeared during generation"
	fi
	print_success "$display_name: $command_count commands in $cmd_dir"
	return 0
}

# Write a hardcoded command if not already present from auto-discovery.
# Writes using the appropriate format for the given runtime.
# Arguments:
#   $1 - runtime_id
#   $2 - cmd_dir
#   $3 - command name
#   $4 - description
#   $5 - body content
# Returns: 0 if written, 1 if skipped (already exists)
_maybe_write_hardcoded_command() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local name="$3"
	local description="$4"
	local body="$5"

	# Skip if already exists from auto-discovery
	[[ -f "${cmd_dir}/${name}.md" ]] && return 1

	case "$runtime_id" in
	opencode)
		_write_opencode_command "$cmd_dir" "$name" "$description" "Build+" "true" "$body"
		;;
	*)
		_write_claude_command "$cmd_dir" "$name" "$description" "$body"
		;;
	esac
	return 0
}

# Generate quality/review hardcoded commands (agent-review, preflight, postflight).
# Arguments: $1 - runtime_id, $2 - cmd_dir
# Returns: count of generated commands via exit code
_generate_hardcoded_quality_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	# --- Agent Review ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "agent-review" \
		"Systematic review and improvement of agent instructions" \
		'Read ~/.aidevops/agents/tools/build-agent/agent-review.md and follow its instructions.

Review the agent file(s) specified: $ARGUMENTS

If no specific file is provided, review the agents used in this session and propose improvements based on:
1. Any corrections the user made
2. Any commands or paths that failed
3. Instruction count (target <50 for main, <100 for subagents)
4. Universal applicability (>80% of tasks)
5. Duplicate detection across agents

Follow the improvement proposal format from the agent-review instructions.'; then
		count=$((count + 1))
	fi

	# --- Preflight ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "preflight" \
		"Run quality checks before version bump and release" \
		'Read ~/.aidevops/agents/workflows/preflight.md and follow its instructions.

Run preflight checks for: $ARGUMENTS

This includes:
1. Code quality checks (ShellCheck, SonarCloud, secrets scan)
2. Markdown formatting validation
3. Version consistency verification
4. Git status check (clean working tree)'; then
		count=$((count + 1))
	fi

	# --- Postflight ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "postflight" \
		"Check code audit feedback on latest push (branch or PR)" \
		'Check code audit tool feedback on the latest push.

Target: $ARGUMENTS

**Auto-detection:**
1. If on a feature branch with open PR -> check that PR'\''s feedback
2. If on a feature branch without PR -> check branch CI status
3. If on main -> check latest commit'\''s CI/audit status

**Checks performed:**
1. GitHub Actions workflow status (pass/fail/pending)
2. CodeRabbit comments and suggestions
3. Codacy analysis results
4. SonarCloud quality gate status

Report findings and recommend next actions (fix issues, merge, etc.)'; then
		count=$((count + 1))
	fi

	return "$count"
}

# Generate lifecycle hardcoded commands (release, onboarding, setup-aidevops).
# Arguments: $1 - runtime_id, $2 - cmd_dir
# Returns: count of generated commands via exit code
_generate_hardcoded_lifecycle_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	# --- Release ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "release" \
		"Full release workflow with version bump, tag, and GitHub release" \
		'Execute a release for the current repository.

Release type: $ARGUMENTS (valid: major, minor, patch)

**Steps:**
1. Run `git log v$(cat VERSION 2>/dev/null || echo "0.0.0")..HEAD --oneline` to see commits since last release
2. If no release type provided, determine it from commits
3. Run the single release command:
   ```bash
   .agents/scripts/version-manager.sh release [type] --skip-preflight --force
   ```
4. Report the result with the GitHub release URL'; then
		count=$((count + 1))
	fi

	# --- Onboarding ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "onboarding" \
		"Interactive onboarding wizard - discover services, configure integrations" \
		'Read ${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/onboarding.md and follow its Welcome Flow instructions to guide the user through setup. Do NOT repeat these instructions — go straight to the Welcome Flow conversation.

Arguments: $ARGUMENTS'; then
		count=$((count + 1))
	fi

	# --- Setup ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "setup-aidevops" \
		"Deploy latest aidevops agent changes locally" \
		'Run the aidevops setup script to deploy the latest changes.

```bash
AIDEVOPS_REPO="${AIDEVOPS_REPO:-$(jq -r ".initialized_repos[]?.path | select(test(\"/aidevops$\"))" ~/.config/aidevops/repos.json 2>/dev/null | head -n 1)}"
if [[ -z "$AIDEVOPS_REPO" ]]; then
  AIDEVOPS_REPO="$HOME/Git/aidevops"
fi
[[ -f "$AIDEVOPS_REPO/setup.sh" ]] || {
  echo "Unable to find setup.sh. Set AIDEVOPS_REPO to your aidevops clone path." >&2
  exit 1
}
cd "$AIDEVOPS_REPO" && ./setup.sh || exit
```

This deploys agents, updates commands, regenerates configs.
Arguments: $ARGUMENTS'; then
		count=$((count + 1))
	fi

	return "$count"
}

# Generate hardcoded commands not in scripts/commands/
# Returns the count of generated commands via exit code (max 255)
_generate_hardcoded_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	_generate_hardcoded_quality_commands "$runtime_id" "$cmd_dir"
	count=$((count + $?))

	_generate_hardcoded_lifecycle_commands "$runtime_id" "$cmd_dir"
	count=$((count + $?))

	return "$count"
}

# =============================================================================
# Phase 2c: MCP Registration — Per-Runtime
# =============================================================================

_generate_mcp_for_runtime() {
	local runtime_id="$1"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	print_info "Registering MCP servers for $display_name..."

	local mcp_count=0

	# Shared MCP definitions — defined once, registered for each runtime
	# Format: register_mcp_for_runtime <runtime_id> <name> '<json>'

	# Augment Context Engine (requires auggie binary AND active auth session)
	local auggie_path
	auggie_path=$(command -v auggie 2>/dev/null || echo "")
	if [[ -n "$auggie_path" && -f "$HOME/.augment/session.json" ]]; then
		register_mcp_for_runtime "$runtime_id" "auggie-mcp" \
			"{\"command\":\"$auggie_path\",\"args\":[\"--mcp\"]}"
		mcp_count=$((mcp_count + 1))
	elif [[ -n "$auggie_path" ]]; then
		print_warning "Skipping auggie-mcp: binary found but not logged in (run: auggie login)"
	fi

	# context7 (library docs — remote endpoint, zero install)
	register_mcp_for_runtime "$runtime_id" "context7" \
		'{"url":"https://mcp.context7.com/mcp"}'
	mcp_count=$((mcp_count + 1))

	# Playwright MCP (correct package: @playwright/mcp, not @anthropic-ai/mcp-server-playwright)
	register_mcp_for_runtime "$runtime_id" "playwright" \
		'{"command":"npx","args":["-y","@playwright/mcp@latest"]}'
	mcp_count=$((mcp_count + 1))

	# shadcn UI
	register_mcp_for_runtime "$runtime_id" "shadcn" \
		'{"command":"npx","args":["shadcn@latest","mcp"]}'
	mcp_count=$((mcp_count + 1))

	# OpenAPI Search (remote, zero install)
	# Skip for OpenCode — it uses a remote URL setup in _generate_agents_opencode
	if [[ "$runtime_id" != "opencode" ]]; then
		register_mcp_for_runtime "$runtime_id" "openapi-search" \
			'{"command":"npx","args":["-y","openapi-mcp-server"]}'
		mcp_count=$((mcp_count + 1))
	fi

	# macOS Automator (macOS only)
	if [[ "$(uname -s)" == "Darwin" ]]; then
		register_mcp_for_runtime "$runtime_id" "macos-automator" \
			'{"command":"npx","args":["-y","@steipete/macos-automator-mcp@latest"]}'
		mcp_count=$((mcp_count + 1))
	fi

	# Cloudflare API (remote MCP endpoint — no local install needed)
	register_mcp_for_runtime "$runtime_id" "cloudflare-api" \
		'{"url":"https://mcp.cloudflare.com/mcp"}'
	mcp_count=$((mcp_count + 1))

	# Shopify Dev MCP (disabled by default; enabled per-agent via @shopify)
	# Requires: Node 18+, Shopify CLI 3.93.0+ (npm install -g @shopify/cli@latest)
	# TODO(permission-migration): when anomalyco/opencode#6892 is resolved, the
	# per-agent tools: entry can be replaced with permission: shopify-dev-mcp: allow
	register_mcp_for_runtime "$runtime_id" "shopify-dev-mcp" \
		'{"command":"npx","args":["-y","@shopify/dev-mcp@latest"]}'
	mcp_count=$((mcp_count + 1))

	print_success "$display_name: $mcp_count MCP servers processed"
	return 0
}

# =============================================================================
# Phase 2d: System Prompt Deployment
# =============================================================================

_generate_prompts_for_runtime() {
	local runtime_id="$1"
	deploy_prompts_for_runtime "$runtime_id"
	return $?
}

# =============================================================================
# Phase 3: Verification
# =============================================================================

_verify_parity() {
	print_info "Verifying output parity with old generators..."

	local errors=0

	# Check OpenCode config exists and has agents
	local opencode_config="$HOME/.config/opencode/opencode.json"
	if [[ -f "$opencode_config" ]]; then
		local agent_count
		agent_count=$(python3 -c "
import json
with open('$opencode_config') as f:
    config = json.load(f)
agents = config.get('agent', {})
print(len([k for k, v in agents.items() if not v.get('disable', False)]))
" 2>/dev/null || echo "0")
		if [[ "$agent_count" -gt 0 ]]; then
			print_success "OpenCode: $agent_count active agents configured"
		else
			print_warning "OpenCode: no active agents found"
			errors=$((errors + 1))
		fi

		# Check instructions field
		local has_instructions
		has_instructions=$(python3 -c "
import json
with open('$opencode_config') as f:
    config = json.load(f)
print('yes' if config.get('instructions') else 'no')
" 2>/dev/null || echo "no")
		if [[ "$has_instructions" == "yes" ]]; then
			print_success "OpenCode: instructions field set"
		else
			print_warning "OpenCode: instructions field missing"
			errors=$((errors + 1))
		fi
	else
		print_warning "OpenCode config not found at $opencode_config"
	fi

	# Check Claude Code settings
	local claude_settings="$HOME/.claude/settings.json"
	if [[ -f "$claude_settings" ]]; then
		local has_hooks
		has_hooks=$(python3 -c "
import json
with open('$claude_settings') as f:
    settings = json.load(f)
hooks = settings.get('hooks', {}).get('PreToolUse', [])
print('yes' if hooks else 'no')
" 2>/dev/null || echo "no")
		if [[ "$has_hooks" == "yes" ]]; then
			print_success "Claude Code: PreToolUse hooks configured"
		else
			print_warning "Claude Code: PreToolUse hooks missing"
			errors=$((errors + 1))
		fi
	fi

	# Check command directories
	local opencode_cmd_dir
	opencode_cmd_dir=$(rt_command_dir "opencode") || opencode_cmd_dir=""
	if [[ -n "$opencode_cmd_dir" && -d "$opencode_cmd_dir" ]]; then
		local oc_cmd_count
		oc_cmd_count=$(find "$opencode_cmd_dir" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		print_success "OpenCode: $oc_cmd_count commands in $opencode_cmd_dir"
	fi

	local claude_cmd_dir
	claude_cmd_dir=$(rt_command_dir "claude-code") || claude_cmd_dir=""
	if [[ -n "$claude_cmd_dir" && -d "$claude_cmd_dir" ]]; then
		local cc_cmd_count
		cc_cmd_count=$(find "$claude_cmd_dir" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		print_success "Claude Code: $cc_cmd_count commands in $claude_cmd_dir"
	fi

	if [[ $errors -gt 0 ]]; then
		print_warning "Parity check: $errors issue(s) found"
		return 1
	fi

	print_success "Parity check passed"
	return 0
}

# =============================================================================
# Main Orchestrator
# =============================================================================

_generate_for_runtime() {
	local runtime_id="$1"
	local subcommand="$2"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	print_info "Generating config for $display_name..."

	case "$subcommand" in
	all)
		# Agents
		case "$runtime_id" in
		opencode) _generate_agents_opencode ;;
		claude-code) _generate_agents_claude ;;
		*) print_info "No agent generation for $runtime_id" ;;
		esac

		# Commands
		_generate_commands_for_runtime "$runtime_id"

		# MCP — always attempt generation. The mcp-config-adapter handles
		# per-runtime support detection internally (some runtimes like aider
		# use YAML config instead of a JSON config path).
		_generate_mcp_for_runtime "$runtime_id"

		# System prompts
		_generate_prompts_for_runtime "$runtime_id"
		;;
	agents)
		case "$runtime_id" in
		opencode) _generate_agents_opencode ;;
		claude-code) _generate_agents_claude ;;
		*) print_info "No agent generation for $runtime_id" ;;
		esac
		;;
	commands)
		_generate_commands_for_runtime "$runtime_id"
		;;
	mcp)
		_generate_mcp_for_runtime "$runtime_id"
		;;
	prompts)
		_generate_prompts_for_runtime "$runtime_id"
		;;
	esac

	return 0
}

usage() {
	local script_name
	script_name="$(basename "$0")"
	cat <<EOF
Usage: ${script_name} [subcommand] [options]

Unified runtime config generator for all AI coding assistant runtimes.

Subcommands:
  all              Generate everything for all installed runtimes (default)
  agents           Generate agent configs only
  commands         Generate slash commands only
  mcp              Register MCP servers only
  prompts          Deploy system prompts only

Options:
  --runtime <id>   Generate for a specific runtime only
  --verify-parity  Compare output with old generators (regression test)
  --dry-run        Show what would be generated without writing
  --help           Show this help

Supported runtimes: opencode, claude-code, codex, cursor, droid, gemini-cli,
                    windsurf, continue, kilo, kiro, aider, amp, kimi, qwen

Examples:
  ${script_name}                          # Generate all for all installed runtimes
  ${script_name} agents                   # Generate agent configs only
  ${script_name} commands --runtime opencode  # Generate OpenCode commands only
  ${script_name} --verify-parity          # Run regression test
EOF
	return 0
}

main() {
	local subcommand="all"
	local target_runtime=""
	local verify_parity=false
	local dry_run=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		all | agents | commands | mcp | prompts)
			subcommand="$1"
			;;
		--runtime)
			shift
			target_runtime="${1:-}"
			if [[ -z "$target_runtime" ]]; then
				print_error "Missing runtime ID after --runtime"
				return 1
			fi
			;;
		--verify-parity)
			verify_parity=true
			;;
		--dry-run)
			dry_run=true
			;;
		--help | -h)
			usage
			return 0
			;;
		*)
			print_error "Unknown argument: $1"
			usage
			return 1
			;;
		esac
		shift
	done

	if [[ "$dry_run" == "true" ]]; then
		print_info "[DRY RUN] Would generate: $subcommand"
		if [[ -n "$target_runtime" ]]; then
			print_info "  Target runtime: $target_runtime"
		else
			print_info "  Target runtimes: all installed"
			# rt_detect_installed returns 1 when none found — guard against set -e
			if ! rt_detect_installed; then
				print_info "  (none detected)"
			fi
		fi
		return 0
	fi

	# Generate for target runtime(s)
	if [[ -n "$target_runtime" ]]; then
		# Validate runtime ID
		if ! rt_binary "$target_runtime" >/dev/null 2>&1; then
			print_error "Unknown runtime: $target_runtime"
			return 1
		fi
		_generate_for_runtime "$target_runtime" "$subcommand"
	else
		# Generate for all installed runtimes that we support config generation for
		# Currently: opencode and claude-code have full support
		local runtime_id
		while IFS= read -r runtime_id; do
			[[ -z "$runtime_id" ]] && continue
			_generate_for_runtime "$runtime_id" "$subcommand"
		done < <(rt_detect_installed)
	fi

	# Regenerate subagent index (shared between runtimes)
	local subagent_index_helper="$AGENTS_DIR/scripts/subagent-index-helper.sh"
	if [[ -x "$subagent_index_helper" ]]; then
		print_info "Regenerating subagent index..."
		if "$subagent_index_helper" generate 2>/dev/null; then
			print_success "Subagent index regenerated"
		else
			print_warning "Subagent index generation encountered issues"
		fi
	fi

	# Verify parity if requested
	if [[ "$verify_parity" == "true" ]]; then
		_verify_parity
	fi

	print_success "Runtime config generation complete"
	return 0
}

# Allow sourcing without executing main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
