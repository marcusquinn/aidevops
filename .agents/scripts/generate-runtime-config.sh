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
# Sub-libraries (sourced below):
#   - generate-runtime-config-agents.sh   -- agent discovery & generation
#   - generate-runtime-config-commands.sh -- slash command deployment
#   - generate-runtime-config-mcp.sh      -- MCP registration, prompts, parity
#
# Dependencies:
#   - runtime-registry.sh (t1665.1) -- runtime detection and properties
#   - mcp-config-adapter.sh (t1665.2) -- MCP config transforms
#   - prompt-injection-adapter.sh (t1665.3) -- system prompt deployment
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

# --- Sub-libraries ---
# shellcheck source=./generate-runtime-config-agents.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-runtime-config-agents.sh"

# shellcheck source=./generate-runtime-config-commands.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-runtime-config-commands.sh"

# shellcheck source=./generate-runtime-config-mcp.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/generate-runtime-config-mcp.sh"

# =============================================================================
# Constants
# =============================================================================

AGENTS_DIR="${HOME}/.aidevops/agents"
# Bypass flag: set to true when --verify-parity is active so the cache is
# skipped and fresh outputs are generated for regression comparison.
# --dry-run is handled by main() before any generation call, so it never
# reaches _generate_for_runtime() and does not need a flag here.
_SKIP_CACHE=false

# =============================================================================
# Cache check -- skip generation if source files haven't changed
# =============================================================================
# One hash file per runtime: ${AGENTS_DIR}/.runtime-config-source-hash-<id>
# Independent caches ensure an opencode-only change doesn't invalidate
# the claude-code cache, and vice versa.

RUNTIME_CACHE_HASH_FILE_PREFIX="${AGENTS_DIR}/.runtime-config-source-hash"

# Compute a stable hash of all files the generator reads.
# Includes: the script itself + all source .md/.toml/.json files under AGENTS_DIR.
# Uses file metadata (name/size/mtime) for speed (~10ms for 1600 files)
# rather than content hashing (~80s per runtime).
# Portable: stat -f is macOS/BSD; stat -c is Linux/GNU. Detected via uname.
# If metadata collection fails entirely, returns a unique no-cache sentinel so
# the cache is safely bypassed rather than producing a stale constant hash.
compute_runtime_source_hash() {
	local metadata
	if [[ "$(uname -s)" == "Darwin" ]]; then
		metadata=$({
			stat -f '%N %z %m' "${BASH_SOURCE[0]}"
			find "$AGENTS_DIR" -type f \( -name "*.md" -o -name "*.toml" -o -name "*.json" \) \
				-exec stat -f '%N %z %m' {} + 2>/dev/null
		})
	else
		# Linux/GNU stat uses -c instead of -f; guarded by uname branch above.
		local script_meta find_meta
		# shell-portability: ignore next
		script_meta=$(stat -c '%n %s %Y' "${BASH_SOURCE[0]}" 2>/dev/null || true)
		# shell-portability: ignore next
		find_meta=$(find "$AGENTS_DIR" -type f \( -name "*.md" -o -name "*.toml" -o -name "*.json" \) \
			-exec stat -c '%n %s %Y' {} + 2>/dev/null || true)
		metadata="${script_meta}"$'\n'"${find_meta}"
	fi

	# If metadata collection failed entirely, return a unique sentinel so the
	# cache is bypassed rather than storing a false constant-hash cache hit.
	[[ -z "$metadata" ]] && { echo "no-cache-${RANDOM}"; return 0; }

	echo "$metadata" | LC_ALL=C sort | shasum -a 256 | cut -d' ' -f1
	return 0
}

# =============================================================================
# Shared MCP Definitions -- defined once, consumed by all runtimes
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
# Main Orchestrator
# =============================================================================

_generate_for_runtime() {
	local runtime_id="$1"
	local subcommand="$2"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	# Cache check -- skip regeneration when source files haven't changed.
	# Bypassed when _SKIP_CACHE=true (set by --verify-parity in main()).
	if [[ "$_SKIP_CACHE" == false ]]; then
		local cache_hash_file="${RUNTIME_CACHE_HASH_FILE_PREFIX}-${runtime_id}"
		local current_hash stored_hash
		current_hash=$(compute_runtime_source_hash)
		if [[ -f "$cache_hash_file" ]]; then
			stored_hash=$(cat "$cache_hash_file" 2>/dev/null || echo "")
			if [[ "$current_hash" == "$stored_hash" ]]; then
				# Paranoia check: verify at least one expected output artefact
				# exists before declaring a cache hit -- handles the edge case
				# where the hash file was written but outputs were later deleted.
				local output_ok=false
				case "$runtime_id" in
				opencode)
					[[ -f "$HOME/.config/opencode/AGENTS.md" ]] && output_ok=true
					;;
				claude-code)
					[[ -f "$HOME/.config/Claude/AGENTS.md" ]] && output_ok=true
					;;
				*)
					# Unknown runtime: optimistically trust the hash
					output_ok=true
					;;
				esac
				if [[ "$output_ok" == true ]]; then
					print_info "$display_name config up to date (source unchanged) -- skipping generation"
					return 0
				fi
			fi
		fi
	fi

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

		# MCP -- always attempt generation. The mcp-config-adapter handles
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

	# Write the source hash after successful generation so the next invocation
	# can skip regeneration when inputs are unchanged.
	# Reuse current_hash computed at the top of this function -- avoids a
	# redundant stat scan across 1600+ files.
	if [[ "$_SKIP_CACHE" == false ]]; then
		echo "$current_hash" >"${RUNTIME_CACHE_HASH_FILE_PREFIX}-${runtime_id}"
	fi

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

	# --verify-parity must generate fresh outputs for a valid regression comparison.
	if [[ "$verify_parity" == "true" ]]; then
		_SKIP_CACHE=true
	fi

	if [[ "$dry_run" == "true" ]]; then
		print_info "[DRY RUN] Would generate: $subcommand"
		if [[ -n "$target_runtime" ]]; then
			print_info "  Target runtime: $target_runtime"
		else
			print_info "  Target runtimes: all installed"
			# rt_detect_installed returns 1 when none found -- guard against set -e
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
