#!/usr/bin/env bash
# shellcheck disable=SC2034

# =============================================================================
# Runtime Registry — Central data source for all supported AI CLI runtimes
# =============================================================================
# Single source of truth for runtime properties: binary names, config paths,
# config formats, MCP root keys, command directories, prompt mechanisms,
# session databases, and process patterns.
#
# Bash 3.2 compatible: uses parallel indexed arrays (no associative arrays).
#
# Usage:
#   source runtime-registry.sh
#   # Look up a property by runtime ID:
#   local config_path
#   config_path=$(rt_config_path "claude-code")
#   # List all runtime IDs:
#   rt_list_ids
#   # Detect which runtimes are installed:
#   rt_detect_installed
#
# Sourced from shared-constants.sh so all scripts inherit it.
#
# Design: t1665.1 — registry data source only, no adapters or migration.
# =============================================================================

# Include guard
[[ -n "${_RUNTIME_REGISTRY_LOADED:-}" ]] && return 0
_RUNTIME_REGISTRY_LOADED=1

# =============================================================================
# Runtime ID Index
# =============================================================================
# Each runtime has a stable string ID used as the lookup key.
# The index position in _RT_IDS corresponds to the same index in all
# parallel property arrays below.
#
# To add a new runtime: append to _RT_IDS and to every _RT_* array below,
# keeping the same index position. Run tests/test-runtime-registry.sh to
# verify alignment.

_RT_IDS=(
	"opencode"    # 0
	"claude-code" # 1
	"codex"       # 2
	"cursor"      # 3
	"droid"       # 4
	"gemini-cli"  # 5
	"windsurf"    # 6
	"continue"    # 7
	"kilo"        # 8
	"kiro"        # 9
	"aider"       # 10
	"amp"         # 11
)

# Total count — used for alignment validation
_RT_COUNT=${#_RT_IDS[@]}

# =============================================================================
# Property Arrays (parallel to _RT_IDS)
# =============================================================================
# IMPORTANT: Every array MUST have exactly _RT_COUNT elements. Use "" for
# unknown/not-applicable values. The test suite validates alignment.

# --- Binary names (what to pass to `command -v`) ---
_RT_BINARY=(
	"opencode" # opencode
	"claude"   # claude-code
	"codex"    # codex
	"cursor"   # cursor
	"droid"    # droid
	"gemini"   # gemini-cli
	"windsurf" # windsurf
	"continue" # continue
	"kilo"     # kilo
	"kiro"     # kiro
	"aider"    # aider
	"amp"      # amp
)

# --- Display names (human-readable) ---
_RT_DISPLAY_NAME=(
	"OpenCode"    # opencode
	"Claude Code" # claude-code
	"Codex CLI"   # codex
	"Cursor"      # cursor
	"Droid"       # droid
	"Gemini CLI"  # gemini-cli
	"Windsurf"    # windsurf
	"Continue"    # continue
	"Kilo Code"   # kilo
	"Kiro"        # kiro
	"Aider"       # aider
	"Amp"         # amp
)

# --- MCP config file paths (~ expanded at lookup time) ---
# Use $HOME explicitly; ~ is not expanded inside double quotes.
_RT_CONFIG_PATH=(
	"\$HOME/.config/opencode/opencode.json"            # opencode
	"\$HOME/.config/Claude/claude_desktop_config.json" # claude-code
	"\$HOME/.codex/config.json"                        # codex
	"\$HOME/.cursor/mcp.json"                          # cursor
	"\$HOME/.config/droid/mcp.json"                    # droid
	"\$HOME/.gemini/settings.json"                     # gemini-cli
	"\$HOME/.codeium/windsurf/mcp_config.json"         # windsurf
	"\$HOME/.continue/config.json"                     # continue
	"\$HOME/.kilo/mcp.json"                            # kilo
	"\$HOME/.kiro/settings/mcp.json"                   # kiro
	""                                                 # aider (no MCP config)
	"\$HOME/.amp/settings.json"                        # amp
)

# --- Config file formats ---
_RT_CONFIG_FORMAT=(
	"json" # opencode
	"json" # claude-code
	"json" # codex
	"json" # cursor
	"json" # droid
	"json" # gemini-cli
	"json" # windsurf
	"json" # continue
	"json" # kilo
	"json" # kiro
	""     # aider
	"json" # amp
)

# --- MCP root key (the JSON key under which MCP servers are defined) ---
_RT_MCP_ROOT_KEY=(
	"mcp"        # opencode — inside opencode.json
	"mcpServers" # claude-code
	"mcpServers" # codex
	"mcpServers" # cursor
	"mcpServers" # droid
	"mcpServers" # gemini-cli
	"mcpServers" # windsurf
	"mcpServers" # continue
	"mcpServers" # kilo
	"mcpServers" # kiro
	""           # aider
	"mcpServers" # amp
)

# --- Slash command directories (where /command files live) ---
_RT_COMMAND_DIR=(
	"\$HOME/.config/opencode/command" # opencode
	"\$HOME/.claude/commands"         # claude-code
	""                                # codex
	""                                # cursor
	""                                # droid
	""                                # gemini-cli
	""                                # windsurf
	""                                # continue
	""                                # kilo
	""                                # kiro
	""                                # aider
	""                                # amp
)

# --- Prompt mechanism (how the runtime loads system instructions) ---
# Values: "AGENTS.md" (file-based), "system-prompt" (API param),
#         "config" (in config file), "" (unknown/none)
_RT_PROMPT_MECHANISM=(
	"AGENTS.md"     # opencode
	"AGENTS.md"     # claude-code
	"system-prompt" # codex
	"config"        # cursor (.cursorrules)
	"AGENTS.md"     # droid
	"system-prompt" # gemini-cli
	"config"        # windsurf (.windsurfrules)
	"config"        # continue (.continuerules)
	"system-prompt" # kilo
	"AGENTS.md"     # kiro
	"config"        # aider (.aider.conf.yml)
	"AGENTS.md"     # amp
)

# --- Session database paths ---
# Where the runtime stores session/conversation history.
# Use $HOME; expanded at lookup time.
_RT_SESSION_DB=(
	"\$HOME/.local/share/opencode/opencode.db" # opencode (SQLite)
	"\$HOME/.claude/projects"                  # claude-code (JSONL dir)
	""                                         # codex
	"\$HOME/.cursor/state.vscdb"               # cursor (SQLite)
	""                                         # droid
	""                                         # gemini-cli
	""                                         # windsurf
	""                                         # continue
	""                                         # kilo
	""                                         # kiro
	""                                         # aider
	""                                         # amp
)

# --- Session DB format ---
_RT_SESSION_DB_FORMAT=(
	"sqlite"    # opencode
	"jsonl-dir" # claude-code
	""          # codex
	"sqlite"    # cursor
	""          # droid
	""          # gemini-cli
	""          # windsurf
	""          # continue
	""          # kilo
	""          # kiro
	""          # aider
	""          # amp
)

# --- Process patterns (for pgrep/ps detection of running instances) ---
_RT_PROCESS_PATTERN=(
	"opencode" # opencode
	"claude"   # claude-code
	"codex"    # codex
	"cursor"   # cursor (Electron app name)
	"droid"    # droid
	"gemini"   # gemini-cli
	"windsurf" # windsurf (Electron app name)
	"continue" # continue
	"kilo"     # kilo
	"kiro"     # kiro
	"aider"    # aider (Python process)
	"amp"      # amp
)

# --- Headless support (can the runtime run without a UI?) ---
# "yes" = has a headless/CLI mode, "no" = GUI/editor only, "" = unknown
_RT_HEADLESS_SUPPORT=(
	"yes" # opencode
	"yes" # claude-code
	"yes" # codex
	"no"  # cursor (editor-only)
	"yes" # droid
	"yes" # gemini-cli
	"no"  # windsurf (editor-only)
	"no"  # continue (editor extension)
	"yes" # kilo
	"no"  # kiro (editor-only)
	"yes" # aider
	"yes" # amp
)

# =============================================================================
# Internal: Index Lookup
# =============================================================================
# Returns the array index for a given runtime ID, or 1 if not found.
# This is the core lookup used by all rt_* functions.

_rt_index() {
	local id="$1"
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ "${_RT_IDS[$i]}" == "$id" ]]; then
			echo "$i"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# Expand $HOME in a path string.
# Handles the "\$HOME" literal stored in arrays (to avoid premature expansion).
_rt_expand_path() {
	local path="$1"
	# Replace literal $HOME or \$HOME with actual HOME value
	path="${path//\\\$HOME/$HOME}"
	path="${path//\$HOME/$HOME}"
	echo "$path"
	return 0
}

# =============================================================================
# Public API: Property Lookups
# =============================================================================
# All functions take a runtime ID as $1 and print the value to stdout.
# Return 0 on success, 1 if the runtime ID is unknown.
# Empty string output means "not applicable" for that runtime.

rt_binary() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_BINARY[$idx]}"
	return 0
}

rt_display_name() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_DISPLAY_NAME[$idx]}"
	return 0
}

rt_config_path() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	_rt_expand_path "${_RT_CONFIG_PATH[$idx]}"
	return 0
}

rt_config_format() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_CONFIG_FORMAT[$idx]}"
	return 0
}

rt_mcp_root_key() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_MCP_ROOT_KEY[$idx]}"
	return 0
}

rt_command_dir() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	_rt_expand_path "${_RT_COMMAND_DIR[$idx]}"
	return 0
}

rt_prompt_mechanism() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_PROMPT_MECHANISM[$idx]}"
	return 0
}

rt_session_db() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	_rt_expand_path "${_RT_SESSION_DB[$idx]}"
	return 0
}

rt_session_db_format() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_SESSION_DB_FORMAT[$idx]}"
	return 0
}

rt_process_pattern() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_PROCESS_PATTERN[$idx]}"
	return 0
}

rt_headless_support() {
	local id="$1"
	local idx
	idx=$(_rt_index "$id") || return 1
	echo "${_RT_HEADLESS_SUPPORT[$idx]}"
	return 0
}

# =============================================================================
# Public API: Enumeration and Detection
# =============================================================================

# Print all runtime IDs, one per line.
rt_list_ids() {
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		echo "${_RT_IDS[$i]}"
		i=$((i + 1))
	done
	return 0
}

# Print the total number of registered runtimes.
rt_count() {
	echo "$_RT_COUNT"
	return 0
}

# Detect which runtimes are installed (binary in PATH or config dir exists).
# Prints installed runtime IDs, one per line.
# Returns 0 if at least one found, 1 if none.
# Note: GUI/editor runtimes (cursor, windsurf, kiro, continue) may not ship
# a PATH binary — fall back to checking their config directory.
rt_detect_installed() {
	local found=0
	local i=0
	local bin config_path config_dir
	while [[ $i -lt $_RT_COUNT ]]; do
		bin="${_RT_BINARY[$i]}"
		# Use type -P to find only filesystem executables — command -v matches
		# shell builtins (e.g., "continue") causing false positives.
		if [[ -n "$bin" ]] && type -P "$bin" >/dev/null 2>&1; then
			echo "${_RT_IDS[$i]}"
			found=1
		else
			# Fallback: check if the runtime's config directory exists.
			# Editor-only runtimes (cursor, windsurf, kiro, continue) often
			# don't have a PATH binary but do have a config directory.
			config_path="${_RT_CONFIG_PATH[$i]}"
			if [[ -n "$config_path" ]]; then
				config_path=$(_rt_expand_path "$config_path")
				config_dir="$(dirname "$config_path")"
				if [[ -d "$config_dir" ]]; then
					echo "${_RT_IDS[$i]}"
					found=1
				fi
			fi
		fi
		i=$((i + 1))
	done
	if [[ $found -eq 1 ]]; then
		return 0
	fi
	return 1
}

# Detect which runtimes have MCP config files present.
# Prints runtime IDs with existing config files, one per line.
rt_detect_configured() {
	local found=0
	local i=0
	local path
	while [[ $i -lt $_RT_COUNT ]]; do
		path="${_RT_CONFIG_PATH[$i]}"
		if [[ -n "$path" ]]; then
			path=$(_rt_expand_path "$path")
			if [[ -f "$path" ]]; then
				echo "${_RT_IDS[$i]}"
				found=1
			fi
		fi
		i=$((i + 1))
	done
	if [[ $found -eq 1 ]]; then
		return 0
	fi
	return 1
}

# Detect which runtimes have running processes.
# Prints runtime IDs with detected processes, one per line.
rt_detect_running() {
	local found=0
	local i=0
	local pattern
	while [[ $i -lt $_RT_COUNT ]]; do
		pattern="${_RT_PROCESS_PATTERN[$i]}"
		if [[ -n "$pattern" ]] && pgrep -x "$pattern" >/dev/null 2>&1; then
			echo "${_RT_IDS[$i]}"
			found=1
		fi
		i=$((i + 1))
	done
	if [[ $found -eq 1 ]]; then
		return 0
	fi
	return 1
}

# Look up a runtime ID by its binary name.
# Useful for reverse lookups (e.g., "which runtime is 'claude'?").
# Returns 0 and prints the ID, or 1 if not found.
rt_id_from_binary() {
	local bin="$1"
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ "${_RT_BINARY[$i]}" == "$bin" ]]; then
			echo "${_RT_IDS[$i]}"
			return 0
		fi
		i=$((i + 1))
	done
	return 1
}

# List runtimes that support headless operation.
# Prints runtime IDs, one per line.
rt_list_headless() {
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ "${_RT_HEADLESS_SUPPORT[$i]}" == "yes" ]]; then
			echo "${_RT_IDS[$i]}"
		fi
		i=$((i + 1))
	done
	return 0
}

# List runtimes that have slash command directories.
# Prints runtime IDs, one per line.
rt_list_with_commands() {
	local i=0
	while [[ $i -lt $_RT_COUNT ]]; do
		if [[ -n "${_RT_COMMAND_DIR[$i]}" ]]; then
			echo "${_RT_IDS[$i]}"
		fi
		i=$((i + 1))
	done
	return 0
}

# =============================================================================
# Validation (called by test suite, safe to call at source time)
# =============================================================================
# Verifies all parallel arrays have the same length as _RT_IDS.
# Returns 0 if valid, 1 if misaligned (prints which array is wrong).

rt_validate_registry() {
	local errors=0
	local arrays=(
		"_RT_BINARY"
		"_RT_DISPLAY_NAME"
		"_RT_CONFIG_PATH"
		"_RT_CONFIG_FORMAT"
		"_RT_MCP_ROOT_KEY"
		"_RT_COMMAND_DIR"
		"_RT_PROMPT_MECHANISM"
		"_RT_SESSION_DB"
		"_RT_SESSION_DB_FORMAT"
		"_RT_PROCESS_PATTERN"
		"_RT_HEADLESS_SUPPORT"
	)

	local arr_name
	for arr_name in "${arrays[@]}"; do
		local count_cmd="${arr_name}[@]"
		local arr_vals=("${!count_cmd}")
		local arr_len=${#arr_vals[@]}
		if [[ $arr_len -ne $_RT_COUNT ]]; then
			echo "MISALIGNED: $arr_name has $arr_len elements, expected $_RT_COUNT" >&2
			errors=$((errors + 1))
		fi
	done

	if [[ $errors -gt 0 ]]; then
		return 1
	fi
	return 0
}
