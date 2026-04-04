#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-sandbox-helper.sh — Create isolated HOME directories for headless workers (t1412.1)
#
# Workers dispatched by the supervisor/pulse inherit the user's full HOME directory,
# giving them access to ~/.ssh/, gopass, credentials.sh, cloud provider tokens, and
# publish tokens. If a worker is compromised via prompt injection, the attacker gets
# everything.
#
# This script creates a minimal temporary HOME with only:
#   - .gitconfig (user.name + user.email — no credential helpers)
#   - gh CLI auth (scoped GH_TOKEN via environment, not filesystem)
#   - .aidevops/agents/ symlink (read-only access to agent prompts)
#   - XDG dirs for tool configs that workers need
#
# Interactive sessions are NEVER sandboxed — the human is the enforcement layer.
#
# Usage:
#   source worker-sandbox-helper.sh
#   sandbox_home=$(create_worker_sandbox "t1234")
#   # ... set HOME=$sandbox_home in worker environment ...
#   cleanup_worker_sandbox "$sandbox_home"
#
# Or as a standalone:
#   worker-sandbox-helper.sh create <task_id>    # prints sandbox path
#   worker-sandbox-helper.sh cleanup <path>      # removes sandbox
#   worker-sandbox-helper.sh env <task_id>       # prints env vars to export

set -euo pipefail

# Resolve real HOME before anything else — workers may already have HOME overridden
readonly REAL_HOME="${REAL_HOME:-$HOME}"
readonly SANDBOX_BASE="${WORKER_SANDBOX_BASE:-/tmp/aidevops-worker}"
WORKER_SANDBOX_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKER_SANDBOX_HELPER_DIR

#######################################
# Best-effort sandbox audit logging
#
# Emits tamper-evident security.event records when worker sandboxes are
# created or cleaned up. This is best-effort: worker sandboxing must still
# function when audit logging is unavailable.
#
# Args:
#   $1 = action (created|cleaned)
#   $2 = task_id
#   $3 = sandbox_dir
#
# Returns: 0 always
#######################################
log_worker_sandbox_event() {
	local action="$1"
	local task_id="$2"
	local sandbox_dir="$3"
	local audit_helper="${WORKER_SANDBOX_HELPER_DIR}/audit-log-helper.sh"

	if [[ ! -x "$audit_helper" ]]; then
		return 0
	fi

	"$audit_helper" log security.event "worker_sandbox_${action}" \
		--detail task_id="$task_id" \
		--detail sandbox_dir="$sandbox_dir" \
		>/dev/null 2>&1 || true

	return 0
}

#######################################
# Set up git config (identity only, no credential helpers)
#
# Args:
#   $1 = sandbox_dir
#
# Returns: 0 on success
#######################################
setup_sandbox_git_config() {
	local sandbox_dir="$1"
	local git_name git_email

	git_name=$(git config --global user.name 2>/dev/null || echo "aidevops-worker")
	git_email=$(git config --global user.email 2>/dev/null || echo "worker@aidevops.sh")

	mkdir -p "$sandbox_dir" || return 1
	cat >"$sandbox_dir/.gitconfig" <<-GITCONFIG || return 1
		[user]
		    name = ${git_name}
		    email = ${git_email}
		[init]
		    defaultBranch = main
		[core]
		    autocrlf = input
		[safe]
		    directory = *
	GITCONFIG

	return 0
}

#######################################
# Set up gh CLI config and agent prompts symlink
#
# Workers use GH_TOKEN env var (set by the dispatch script), not filesystem auth.
# Creates a minimal gh config so gh doesn't complain about missing config.
# Also symlinks agent prompts for /full-loop, /define, etc.
#
# Args:
#   $1 = sandbox_dir
#
# Returns: 0 on success
#######################################
setup_sandbox_gh_config() {
	local sandbox_dir="$1"
	local gh_config_dir="$sandbox_dir/.config/gh"

	mkdir -p "$gh_config_dir" || return 1
	cat >"$gh_config_dir/config.yml" <<-GHCONFIG || return 1
		version: 1
		git_protocol: https
		editor: ""
		prompt: disabled
	GHCONFIG

	# Agent prompts (read-only symlink)
	local agents_source="${REAL_HOME}/.aidevops"
	if [[ -d "$agents_source" ]]; then
		ln -sf "$agents_source" "$sandbox_dir/.aidevops"
	fi

	return 0
}

#######################################
# Copy runtime config files into sandbox (t1665.5 — registry-driven)
#
# Workers need their tool configs. Copies only the specific config files
# needed, not the entire .config directory (which may contain credentials).
# Uses the runtime registry if available, otherwise falls back to hardcoded paths.
#
# Does NOT copy: credentials.json, .credentials, auth tokens
#
# Args:
#   $1 = sandbox_dir
#
# Returns: 0 on success
#######################################
setup_sandbox_runtime_configs() {
	local sandbox_dir="$1"
	local config_dir="$sandbox_dir/.config"

	mkdir -p "$config_dir" || return 1

	# Copy MCP config files for all configured runtimes
	if type rt_detect_configured >/dev/null 2>&1; then
		local _sb_rt_id _sb_cfg_path _sb_cfg_dir _sb_cfg_file _sb_dst_dir
		while IFS= read -r _sb_rt_id; do
			_sb_cfg_path=$(rt_config_path "$_sb_rt_id") || continue
			[[ -z "$_sb_cfg_path" || ! -f "$_sb_cfg_path" ]] && continue

			# Reconstruct the path relative to HOME for the sandbox
			_sb_cfg_dir=$(dirname "$_sb_cfg_path")
			_sb_cfg_file=$(basename "$_sb_cfg_path")
			# Strip REAL_HOME prefix to get relative path
			local _sb_rel_dir="${_sb_cfg_dir#"${REAL_HOME}"/}"
			if [[ "$_sb_rel_dir" == "$_sb_cfg_dir" ]]; then
				# Path doesn't start with REAL_HOME — skip
				continue
			fi

			# Handle paths under .config/ vs paths under ~/.<dir>/
			if [[ "$_sb_rel_dir" == .config/* ]]; then
				_sb_dst_dir="$config_dir/${_sb_rel_dir#.config/}"
			else
				_sb_dst_dir="$sandbox_dir/$_sb_rel_dir"
			fi

			mkdir -p "$_sb_dst_dir" || continue
			cp "$_sb_cfg_path" "$_sb_dst_dir/$_sb_cfg_file" || continue
		done < <(rt_detect_configured)
	else
		# Fallback: hardcoded paths (registry not loaded)
		local opencode_src="${REAL_HOME}/.config/opencode"
		if [[ -d "$opencode_src" ]]; then
			mkdir -p "$config_dir/opencode" || return 1
			[[ -f "$opencode_src/opencode.json" ]] && { cp "$opencode_src/opencode.json" "$config_dir/opencode/" || return 1; }
		fi
		local claude_dir_src="${REAL_HOME}/.claude"
		if [[ -d "$claude_dir_src" ]]; then
			local claude_dir_dst="$sandbox_dir/.claude"
			mkdir -p "$claude_dir_dst" || return 1
			[[ -f "$claude_dir_src/settings.json" ]] && { cp "$claude_dir_src/settings.json" "$claude_dir_dst/" || return 1; }
		fi
	fi

	return 0
}

#######################################
# Create XDG directories and sentinel file for sandbox detection
#
# Sets up writable cache/data dirs for tools (npm, bun, etc.) and
# writes a sentinel file so workers and scripts can detect they're sandboxed.
#
# Args:
#   $1 = sandbox_dir
#   $2 = task_id
#
# Returns: 0 on success
#######################################
setup_sandbox_dirs_and_sentinel() {
	local sandbox_dir="$1"
	local task_id="$2"

	# XDG directories for tool state
	mkdir -p "$sandbox_dir/.local/share" || return 1
	mkdir -p "$sandbox_dir/.cache" || return 1
	mkdir -p "$sandbox_dir/.npm" || return 1

	# Sentinel file for sandbox detection
	cat >"$sandbox_dir/.aidevops-sandbox" <<-SENTINEL || return 1
		task_id=${task_id}
		created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		real_home=${REAL_HOME}
	SENTINEL

	return 0
}

#######################################
# Create a sandboxed HOME directory for a worker
#
# Creates a temporary directory with minimal git config and
# symlinks to read-only framework resources. The worker gets:
#   - Git identity (name/email) for commits
#   - GH_TOKEN for GitHub API access (via env var, not filesystem)
#   - Read-only access to agent prompts (symlink)
#   - Writable XDG dirs for tool state
#
# Does NOT include:
#   - ~/.ssh/ (no SSH key access)
#   - gopass / pass stores
#   - ~/.config/aidevops/credentials.sh
#   - Cloud provider tokens (AWS, GCP, Azure)
#   - npm/pypi publish tokens
#   - Browser profiles or cookies
#
# Args:
#   $1 = task_id (used for directory naming and logging)
#
# Outputs: sandbox HOME path on stdout
# Returns: 0 on success, 1 on failure
#######################################
create_worker_sandbox() {
	local task_id="$1"

	if [[ -z "$task_id" ]]; then
		echo "ERROR: task_id required" >&2
		return 1
	fi

	# Create unique sandbox directory
	local sandbox_dir
	sandbox_dir=$(mktemp -d "${SANDBOX_BASE}-${task_id}-XXXXXX") || {
		echo "ERROR: failed to create sandbox directory" >&2
		return 1
	}

	setup_sandbox_git_config "$sandbox_dir" || {
		rm -rf "$sandbox_dir"
		return 1
	}
	setup_sandbox_gh_config "$sandbox_dir" || {
		rm -rf "$sandbox_dir"
		return 1
	}
	setup_sandbox_runtime_configs "$sandbox_dir" || {
		rm -rf "$sandbox_dir"
		return 1
	}
	setup_sandbox_dirs_and_sentinel "$sandbox_dir" "$task_id" || {
		rm -rf "$sandbox_dir"
		return 1
	}

	log_worker_sandbox_event "created" "$task_id" "$sandbox_dir"

	echo "$sandbox_dir"
	return 0
}

#######################################
# Generate environment variables for a sandboxed worker
#
# Returns a list of export statements that the dispatch script
# should inject into the worker's environment.
#
# Args:
#   $1 = sandbox_dir (path from create_worker_sandbox)
#
# Outputs: export statements on stdout (one per line)
# Returns: 0 on success, 1 on failure
#######################################
generate_sandbox_env() {
	local sandbox_dir="$1"

	if [[ -z "$sandbox_dir" || ! -d "$sandbox_dir" ]]; then
		echo "ERROR: valid sandbox_dir required" >&2
		return 1
	fi

	# Core: override HOME
	# Use printf %q to safely escape all shell metacharacters, preventing
	# command injection if any variable contains single quotes or other
	# special characters (security fix: GH#3119, PR#3080 review feedback)
	printf "export HOME=%q\n" "${sandbox_dir}"

	# Preserve REAL_HOME so scripts that need the actual home can find it
	# (e.g., for reading repos.json, which is a framework config not a credential)
	printf "export REAL_HOME=%q\n" "${REAL_HOME}"

	# GH_TOKEN: if set in the current environment, pass it through.
	# This is the primary auth mechanism for workers (env var, not filesystem).
	# The dispatch script is responsible for setting GH_TOKEN before calling this.
	if [[ -n "${GH_TOKEN:-}" ]]; then
		printf "export GH_TOKEN=%q\n" "${GH_TOKEN}"
	fi

	# XDG overrides to keep tool state inside the sandbox
	printf "export XDG_CONFIG_HOME=%q\n" "${sandbox_dir}/.config"
	printf "export XDG_DATA_HOME=%q\n" "${sandbox_dir}/.local/share"
	printf "export XDG_CACHE_HOME=%q\n" "${sandbox_dir}/.cache"

	# npm config to use sandbox directory
	printf "export npm_config_cache=%q\n" "${sandbox_dir}/.npm"

	# Prevent tools from reading the real home's dotfiles
	printf "export GNUPGHOME=%q\n" "${sandbox_dir}/.gnupg"

	# Signal to the worker that it's sandboxed (for conditional logic)
	echo "export AIDEVOPS_SANDBOXED=true"
	printf "export AIDEVOPS_SANDBOX_DIR=%q\n" "${sandbox_dir}"

	return 0
}

#######################################
# Clean up a worker sandbox directory
#
# Removes the temporary HOME directory created by create_worker_sandbox.
# Safe to call multiple times (idempotent).
#
# Args:
#   $1 = sandbox_dir (path from create_worker_sandbox)
#
# Returns: 0 on success, 1 on failure
#######################################
cleanup_worker_sandbox() {
	local sandbox_dir="$1"
	local sandbox_task_id="unknown"

	if [[ -z "$sandbox_dir" ]]; then
		echo "ERROR: sandbox_dir required" >&2
		return 1
	fi

	# Safety: only remove directories under the expected base path
	if [[ "$sandbox_dir" != "${SANDBOX_BASE}"* ]]; then
		echo "ERROR: refusing to remove directory outside sandbox base: $sandbox_dir" >&2
		echo "Expected prefix: ${SANDBOX_BASE}" >&2
		return 1
	fi

	# Safety: verify it's actually a sandbox (has sentinel file)
	if [[ ! -f "$sandbox_dir/.aidevops-sandbox" ]]; then
		echo "ERROR: directory is not a worker sandbox (missing sentinel): $sandbox_dir" >&2
		return 1
	fi

	sandbox_task_id=$(while IFS='=' read -r key value; do
		if [[ "$key" == "task_id" ]]; then
			echo "$value"
			break
		fi
	done <"$sandbox_dir/.aidevops-sandbox")
	sandbox_task_id="${sandbox_task_id:-unknown}"

	rm -rf "$sandbox_dir"
	log_worker_sandbox_event "cleaned" "$sandbox_task_id" "$sandbox_dir"
	return 0
}

#######################################
# Clean up stale sandbox directories
#
# Removes sandbox directories older than the specified age.
# Intended to be called periodically (e.g., from pulse cleanup phase)
# to prevent /tmp from filling up with abandoned sandboxes.
#
# Args:
#   $1 = max_age_hours (default: 24)
#
# Returns: 0 always (best-effort cleanup)
#######################################
cleanup_stale_sandboxes() {
	local max_age_hours="${1:-24}"
	local max_age_minutes=$((max_age_hours * 60))
	local count=0

	# Find sandbox directories older than max_age
	while IFS= read -r -d '' sandbox_dir; do
		# Verify it's a sandbox before removing
		if [[ -f "$sandbox_dir/.aidevops-sandbox" ]]; then
			rm -rf "$sandbox_dir" || true
			count=$((count + 1))
		fi
	done < <(find "${SANDBOX_BASE}"* -maxdepth 0 -type d -mmin +"$max_age_minutes" -print0 2>/dev/null || true)

	if [[ "$count" -gt 0 ]]; then
		echo "Cleaned up $count stale sandbox directories (older than ${max_age_hours}h)"
	fi

	return 0
}

#######################################
# Check if the current process is running in a sandbox
#
# Returns: 0 if sandboxed, 1 if not
# Outputs: sandbox task_id on stdout if sandboxed
#######################################
is_sandboxed() {
	if [[ "${AIDEVOPS_SANDBOXED:-}" == "true" ]]; then
		if [[ -f "${HOME}/.aidevops-sandbox" ]]; then
			grep '^task_id=' "${HOME}/.aidevops-sandbox" 2>/dev/null | cut -d= -f2
			return 0
		fi
	fi
	return 1
}

#######################################
# Main CLI interface
#######################################
main() {
	local action="${1:-help}"
	shift || true

	case "$action" in
	create)
		local task_id="${1:-}"
		if [[ -z "$task_id" ]]; then
			echo "Usage: worker-sandbox-helper.sh create <task_id>" >&2
			return 1
		fi
		create_worker_sandbox "$task_id"
		return $?
		;;
	env)
		local task_id="${1:-}"
		if [[ -z "$task_id" ]]; then
			echo "Usage: worker-sandbox-helper.sh env <task_id>" >&2
			return 1
		fi
		local sandbox_dir
		sandbox_dir=$(create_worker_sandbox "$task_id") || return 1
		generate_sandbox_env "$sandbox_dir"
		return $?
		;;
	cleanup)
		local sandbox_dir="${1:-}"
		if [[ -z "$sandbox_dir" ]]; then
			echo "Usage: worker-sandbox-helper.sh cleanup <sandbox_path>" >&2
			return 1
		fi
		cleanup_worker_sandbox "$sandbox_dir"
		return $?
		;;
	cleanup-stale)
		local max_age="${1:-24}"
		cleanup_stale_sandboxes "$max_age"
		return $?
		;;
	is-sandboxed)
		is_sandboxed
		return $?
		;;
	help | --help | -h)
		echo "worker-sandbox-helper.sh — Create isolated HOME directories for headless workers (t1412.1)"
		echo ""
		echo "Commands:"
		echo "  create <task_id>         Create a sandbox, print path"
		echo "  env <task_id>            Create sandbox + print export statements"
		echo "  cleanup <sandbox_path>   Remove a sandbox directory"
		echo "  cleanup-stale [hours]    Remove sandboxes older than N hours (default: 24)"
		echo "  is-sandboxed             Check if running in a sandbox (exit 0 = yes)"
		echo ""
		echo "Environment variables:"
		echo "  WORKER_SANDBOX_BASE      Base path for sandboxes (default: /tmp/aidevops-worker)"
		echo "  WORKER_SANDBOX_ENABLED   Set to 'false' to disable sandboxing (default: true)"
		echo "  REAL_HOME                Original HOME (set automatically by sandbox)"
		return 0
		;;
	*)
		echo "Unknown action: $action" >&2
		echo "Run 'worker-sandbox-helper.sh help' for usage" >&2
		return 1
		;;
	esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
