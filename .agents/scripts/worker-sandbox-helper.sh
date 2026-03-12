#!/usr/bin/env bash
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

	# --- Git config (identity only, no credential helpers) ---
	local git_name git_email
	git_name=$(git config --global user.name 2>/dev/null || echo "aidevops-worker")
	git_email=$(git config --global user.email 2>/dev/null || echo "worker@aidevops.sh")

	mkdir -p "$sandbox_dir"
	cat >"$sandbox_dir/.gitconfig" <<-GITCONFIG
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

	# --- gh CLI auth ---
	# Workers use GH_TOKEN env var (set by the dispatch script), not filesystem auth.
	# Create a minimal gh config directory so gh doesn't complain about missing config.
	local gh_config_dir="$sandbox_dir/.config/gh"
	mkdir -p "$gh_config_dir"
	cat >"$gh_config_dir/config.yml" <<-GHCONFIG
		version: 1
		git_protocol: https
		editor: ""
		prompt: disabled
	GHCONFIG

	# --- Agent prompts (read-only symlink) ---
	# Workers need access to agent prompts for /full-loop, /define, etc.
	# Symlink to the deployed agents directory (read-only for the worker).
	local agents_source="${REAL_HOME}/.aidevops"
	if [[ -d "$agents_source" ]]; then
		ln -sf "$agents_source" "$sandbox_dir/.aidevops"
	fi

	# --- Claude Code / OpenCode config ---
	# Workers need their tool configs. Copy only the specific config files needed,
	# not the entire .config directory (which may contain credentials).
	local config_dir="$sandbox_dir/.config"
	mkdir -p "$config_dir"

	# OpenCode config (if exists) — needed for MCP server definitions
	local opencode_src="${REAL_HOME}/.config/opencode"
	if [[ -d "$opencode_src" ]]; then
		mkdir -p "$config_dir/opencode"
		# Copy only opencode.json (MCP config), not auth files
		if [[ -f "$opencode_src/opencode.json" ]]; then
			cp "$opencode_src/opencode.json" "$config_dir/opencode/"
		fi
	fi

	# Claude Code settings (if exists) — needed for MCP server definitions
	local claude_dir_src="${REAL_HOME}/.claude"
	if [[ -d "$claude_dir_src" ]]; then
		local claude_dir_dst="$sandbox_dir/.claude"
		mkdir -p "$claude_dir_dst"
		# Copy settings.json (MCP config, preferences) but NOT credentials
		if [[ -f "$claude_dir_src/settings.json" ]]; then
			cp "$claude_dir_src/settings.json" "$claude_dir_dst/"
		fi
		# Do NOT copy: credentials.json, .credentials, auth tokens
	fi

	# --- XDG directories for tool state ---
	# Tools like npm, bun, etc. need writable cache/data dirs
	mkdir -p "$sandbox_dir/.local/share"
	mkdir -p "$sandbox_dir/.cache"
	mkdir -p "$sandbox_dir/.npm"

	# --- Sentinel file for sandbox detection ---
	# Workers and scripts can check for this to know they're sandboxed
	cat >"$sandbox_dir/.aidevops-sandbox" <<-SENTINEL
		task_id=${task_id}
		created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		real_home=${REAL_HOME}
	SENTINEL

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

	sandbox_task_id=$(grep '^task_id=' "$sandbox_dir/.aidevops-sandbox" 2>/dev/null | cut -d= -f2- || true)
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
